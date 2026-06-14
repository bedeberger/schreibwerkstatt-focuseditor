//
//  SyncEngine.swift
//  schreibwerkstatt-focuseditor
//
//  Reachability-getriebene Sync-Engine auf dem Auth-`APIClient`.
//   • Push: drainiert die Outbox des LocalStore → `PUT /content/pages/:id`
//     mit `expected_updated_at` (exakte Server-ISO-Basis). 200 → Basis
//     vorrücken; 409 → Konflikt erfassen (Block-Merge folgt, kein
//     Last-Write-Wins); 404/423 → defensiv überspringen.
//   • Pull: je Buch `GET /content/books/:id/sync` mit Keyset-Cursor, bis
//     `has_more=false`. Server-Seiten landen im Store — ABER niemals über
//     lokal ungepushte Änderungen (die löst der Push/Merge auf).
//
//  Datenverlust-Schutz (CLAUDE.md): Es wird nie automatisch verworfen oder
//  ohne Merge überschrieben. Bei Auth-Fehlern (401) beendet der APIClient die
//  Session; lokale Inhalte bleiben.
//

import Foundation
import Combine
import OSLog

@MainActor
final class SyncEngine: ObservableObject {

    enum Status: Equatable {
        case idle       // bereit, nichts zu tun
        case syncing    // Push/Pull läuft
        case offline    // kein Netz
    }

    /// Ein erfasster, noch nicht aufgelöster Server-Konflikt (409).
    struct Conflict: Identifiable, Equatable {
        var id: String { pageId }
        let pageId: String
        let serverUpdatedAt: String?
        let serverEditorName: String?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var conflicts: [Conflict] = []

    private let api: APIClient
    private let store: any LocalStore
    private let reachability: Reachability
    private let stateStore: SyncStateStore
    /// Liefert, ob synchronisiert werden darf (z. B. nur bei `signedIn`).
    private let shouldSync: () -> Bool
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "sync")

    /// Pull-Periode, solange online.
    private let pollInterval: Duration = .seconds(30)

    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    init(api: APIClient,
         store: any LocalStore,
         reachability: Reachability? = nil,
         shouldSync: @escaping () -> Bool) {
        self.api = api
        self.store = store
        self.reachability = reachability ?? Reachability()
        self.shouldSync = shouldSync
        self.stateStore = SyncStateStore()
    }

    // MARK: - Lifecycle

    /// Startet Reachability-Beobachtung + periodischen Pull.
    func start() {
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            self.status = online ? .idle : .offline
            if online { self.requestSync() }
        }
        reachability.start()
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reachability.stop()
    }

    /// Stößt einen Sync-Durchlauf an (z. B. nach lokalem Save oder Online-Wechsel).
    func requestSync() {
        Task { await syncNow() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.syncNow()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    // MARK: - Durchlauf

    func syncNow() async {
        guard shouldSync(), reachability.isOnline, !isRunning else { return }
        isRunning = true
        status = .syncing
        defer {
            isRunning = false
            if status == .syncing { status = reachability.isOnline ? .idle : .offline }
        }

        do {
            try await pushOutbox()
            try await pullDeltas()
            lastSyncedAt = Date()
            lastError = nil
        } catch AuthError.unauthorized {
            // Session beendet der APIClient bereits; hier nichts erzwingen.
            log.info("Sync abgebrochen: nicht autorisiert")
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Sync-Fehler: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    // MARK: - Push

    private func pushOutbox() async throws {
        let entries = try await store.pendingOutbox()
        for entry in entries {
            // Unaufgelöste Konflikte nicht erneut blind pushen.
            if conflicts.contains(where: { $0.pageId == entry.pageId }) { continue }

            guard let base = stateStore.state.serverBaseISO[entry.pageId] else {
                // Keine Server-Basis → Seite existiert serverseitig (noch) nicht.
                // PUT kann nur updaten, nicht anlegen (Anlegen wäre POST /content/pages).
                log.info("Push übersprungen (keine Server-Basis): \(entry.pageId, privacy: .public)")
                continue
            }

            let req = PushRequest(html: entry.html, expected_updated_at: base)
            do {
                let resp = try await api.send("/content/pages/\(entry.pageId)",
                                              method: .PUT,
                                              body: req,
                                              decode: PushResponse.self)
                // Basis vorrücken (exakte Server-ISO) + Outbox quittieren.
                stateStore.mutate { $0.serverBaseISO[entry.pageId] = resp.updated_at }
                try await store.markPushed(id: entry.pageId,
                                           queuedAt: entry.queuedAt,
                                           serverUpdatedAtMillis: ISOTime.millis(resp.updated_at) ?? entry.queuedAt)
            } catch let AuthError.server(status, _, body) where status == 409 {
                let c = body.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) }
                recordConflict(pageId: entry.pageId,
                               serverUpdatedAt: c?.server_updated_at,
                               serverEditorName: c?.server_editor_name)
                log.notice("Konflikt bei \(entry.pageId, privacy: .public) — Block-Merge nötig")
                // Outbox-Eintrag bleibt erhalten; Auflösung folgt über Block-Merge.
            } catch let AuthError.server(status, _, _) where status == 423 {
                // Seite serverseitig gesperrt (Lektorat) — später erneut versuchen.
                log.info("Seite gesperrt (423): \(entry.pageId, privacy: .public)")
            } catch let AuthError.server(status, _, _) where status == 404 {
                // Seite existiert serverseitig nicht mehr — Basis verwerfen,
                // Inhalt aber lokal behalten (kein Datenverlust).
                stateStore.mutate { $0.serverBaseISO[entry.pageId] = nil }
                log.info("Seite serverseitig nicht gefunden (404): \(entry.pageId, privacy: .public)")
            }
        }
    }

    // MARK: - Pull

    private func pullDeltas() async throws {
        // Bücherliste einmalig bootstrappen.
        if stateStore.state.bookIds.isEmpty {
            let books = try await api.send("/content/books", method: .GET, decode: [BookDTO].self)
            stateStore.mutate { $0.bookIds = books.map(\.id) }
        }

        for bookId in stateStore.state.bookIds {
            try await pullBook(bookId)
        }
    }

    private func pullBook(_ bookId: Int) async throws {
        var cursor = stateStore.state.cursors[bookId] ?? SyncCursorDTO(since: nil, since_id: 0)

        while true {
            let resp = try await api.send(syncPath(bookId: bookId, cursor: cursor),
                                          method: .GET,
                                          decode: BookSyncResponse.self)

            let pending = Set(try await store.pendingOutbox().map(\.pageId))

            for p in resp.pages {
                let pid = String(p.page_id)
                if pending.contains(pid) {
                    // Lokal ungepushte Änderung + neuerer Server-Stand → Divergenz.
                    // Nicht überschreiben und Basis NICHT vorrücken: der nächste
                    // Push läuft bewusst in ein 409 und erfasst den Konflikt.
                    log.notice("Pull übersprungen (lokale Änderung offen): \(pid, privacy: .public)")
                    continue
                }
                stateStore.mutate { $0.serverBaseISO[pid] = p.updated_at }
                try await store.applyServerPage(id: pid,
                                                html: p.html,
                                                title: p.page_name,
                                                serverUpdatedAtMillis: ISOTime.millis(p.updated_at) ?? 0)
            }

            // Cursor vorrücken + persistieren (robust gegen Abbruch mittendrin).
            stateStore.mutate { $0.cursors[bookId] = resp.cursor }

            // Schutz gegen Endlosschleife, falls der Cursor nicht vorrückt.
            if !resp.has_more || resp.pages.isEmpty { break }
            cursor = resp.cursor
        }
    }

    /// Baut `/content/books/:id/sync?…` mit korrekt kodiertem Cursor.
    private func syncPath(bookId: Int, cursor: SyncCursorDTO) -> String {
        var path = "/content/books/\(bookId)/sync?limit=200"
        if let since = cursor.since,
           let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&since=\(encoded)&since_id=\(cursor.since_id)"
        }
        return path
    }

    // MARK: - Konflikte

    private func recordConflict(pageId: String, serverUpdatedAt: String?, serverEditorName: String?) {
        let c = Conflict(pageId: pageId,
                         serverUpdatedAt: serverUpdatedAt,
                         serverEditorName: serverEditorName)
        if let idx = conflicts.firstIndex(where: { $0.pageId == pageId }) {
            conflicts[idx] = c
        } else {
            conflicts.append(c)
        }
    }

    /// Markiert einen Konflikt als aufgelöst (nach erfolgreichem Block-Merge).
    /// Der nächste Push nimmt die Seite dann wieder mit.
    func clearConflict(pageId: String) {
        conflicts.removeAll { $0.pageId == pageId }
    }
}
