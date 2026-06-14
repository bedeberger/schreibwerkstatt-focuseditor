//
//  SyncEngine.swift
//  schreibwerkstatt-focuseditor
//
//  Sync-Engine auf dem Auth-`APIClient`. Getrieben durch die Scene-Phase:
//  Solange das Fenster aktiv ist, wird periodisch (~5 s) gepollt; im
//  Hintergrund pausiert der Loop (Energie), beim Reaktivieren gibt es sofort
//  einen Tick. Zusätzlicher Trigger: Reachability (Netz wieder da → Tick).
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
    private let content: ContentAPI
    private let store: any LocalStore
    private let reachability: Reachability
    private let stateStore: SyncStateStore
    /// Editor-Kopplung (Open-Page-Reload, Block-Merge). Schwach: AppCore besitzt
    /// die Bridge. `nil` solange keine WebView läuft → Merge fällt auf Konflikt zurück.
    weak var editor: EditorCoordinating?
    /// Liefert, ob synchronisiert werden darf (z. B. nur bei `signedIn`).
    private let shouldSync: () -> Bool
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "sync")

    /// Poll-Periode, solange das Fenster aktiv ist (Doku-Richtwert ~5 s).
    private let pollInterval: Duration = .seconds(5)
    /// Delete-Reconcile ist teurer (ein Tree-Fetch je Buch) → seltener als der
    /// Poll. Mindestabstand zwischen zwei Reconcile-Durchläufen.
    private let reconcileInterval: TimeInterval = 60
    private var lastReconcileAt: Date?

    private var isRunning = false
    private var isActive = false
    private var pollTask: Task<Void, Never>?

    init(api: APIClient,
         content: ContentAPI,
         store: any LocalStore,
         reachability: Reachability? = nil,
         shouldSync: @escaping () -> Bool) {
        self.api = api
        self.content = content
        self.store = store
        self.reachability = reachability ?? Reachability()
        self.shouldSync = shouldSync
        self.stateStore = SyncStateStore()
    }

    // MARK: - Lifecycle

    /// Startet die Reachability-Beobachtung. Das Polling selbst hängt an der
    /// Scene-Phase und wird über `setActive(_:)` ein-/ausgeschaltet.
    func start() {
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            self.status = online ? .idle : .offline
            // Netz wieder da + Fenster aktiv → sofort ein Tick.
            if online && self.isActive { self.requestSync() }
        }
        reachability.start()
    }

    func stop() {
        stopPolling()
        reachability.stop()
    }

    /// Vom Scene-Phasen-Wechsel getrieben: aktiv → sofortiger Tick + 5 s-Poll;
    /// inaktiv/Hintergrund → Poll pausieren (CLAUDE.md: nur solange Fenster aktiv).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            requestSync()        // sofortiger Tick beim Reaktivieren
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Stößt einen Sync-Durchlauf an (Scene-aktiv, Online-Wechsel, lokaler Save).
    func requestSync() {
        Task { await syncNow() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Erster Tick kommt über requestSync(); der Loop ergänzt Folge-Ticks.
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                await self.syncNow()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Durchlauf

    func syncNow() async {
        guard isActive, shouldSync(), reachability.isOnline, !isRunning else { return }
        isRunning = true
        status = .syncing
        defer {
            isRunning = false
            if status == .syncing { status = reachability.isOnline ? .idle : .offline }
        }

        do {
            try await pushOutbox()
            try await pullDeltas()
            await reconcileDeletesIfDue()
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
                // Basis vorrücken (exakte Server-ISO + HTML als Merge-Ancestor) + Outbox quittieren.
                stateStore.mutate {
                    $0.serverBaseISO[entry.pageId] = resp.updated_at
                    $0.serverBaseHtml[entry.pageId] = entry.html
                }
                try await store.markPushed(id: entry.pageId,
                                           queuedAt: entry.queuedAt,
                                           serverUpdatedAtMillis: ISOTime.millis(resp.updated_at) ?? entry.queuedAt)
            } catch let AuthError.server(status, _, body) where status == 409 {
                // Stale-Write → 3-Wege-Block-Merge versuchen, sonst Konflikt erfassen.
                let c = body.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) }
                await resolveConflict(entry: entry, conflict: c)
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

    /// 409-Auflösung per 3-Wege-Block-Merge in der WebView. Kollisionsfrei →
    /// gemergtes HTML mit der neuen Server-Basis erneut pushen; echte Block-
    /// Kollision oder kein Merge möglich → Konflikt erfassen (Editor-UI/Block-Merge).
    /// Verwirft NIE lokale Inhalte.
    private func resolveConflict(entry: OutboxEntry, conflict c: ConflictBody?) async {
        let pid = entry.pageId

        // Aktuelles Server-HTML + neue Basis holen.
        guard let editor,
              let serverPage = try? await api.send("/content/pages/\(pid)",
                                                    method: .GET,
                                                    decode: PushResponse.self) else {
            recordConflict(pageId: pid,
                           serverUpdatedAt: c?.server_updated_at,
                           serverEditorName: c?.server_editor_name)
            log.notice("Konflikt \(pid, privacy: .public): Merge-Voraussetzungen fehlen")
            return
        }

        let serverHtml = serverPage.html ?? ""
        let base = stateStore.state.serverBaseHtml[pid]

        let outcome: MergeOutcome
        do {
            outcome = try await editor.merge3(base: base, local: entry.html, server: serverHtml)
        } catch {
            // Kein Editor-Bundle/WebView → nicht auto-mergebar, als Konflikt zur UI.
            recordConflict(pageId: pid,
                           serverUpdatedAt: serverPage.updated_at,
                           serverEditorName: c?.server_editor_name)
            log.notice("Block-Merge nicht verfügbar für \(pid, privacy: .public) — Konflikt offen")
            return
        }

        guard outcome.conflictCount == 0 else {
            // Echte Block-Kollision → Konflikt-Modal des Editors.
            recordConflict(pageId: pid,
                           serverUpdatedAt: serverPage.updated_at,
                           serverEditorName: c?.server_editor_name)
            log.notice("Block-Kollision bei \(pid, privacy: .public): \(outcome.conflictCount) Block/Blöcke — UI nötig")
            return
        }

        // Kollisionsfrei: gemergtes HTML mit der neuen Server-Basis erneut pushen.
        let req = PushRequest(html: outcome.merged, expected_updated_at: serverPage.updated_at)
        do {
            let resp = try await api.send("/content/pages/\(pid)",
                                          method: .PUT,
                                          body: req,
                                          decode: PushResponse.self)
            let ms = ISOTime.millis(resp.updated_at) ?? entry.queuedAt
            stateStore.mutate {
                $0.serverBaseISO[pid] = resp.updated_at
                $0.serverBaseHtml[pid] = outcome.merged
            }
            // Gemergten Stand lokal übernehmen + Outbox quittieren.
            try? await store.applyServerPage(id: pid, html: outcome.merged,
                                             pageName: nil, bookId: nil, chapterId: nil,
                                             serverUpdatedAtMillis: ms)
            try? await store.markPushed(id: pid, queuedAt: entry.queuedAt, serverUpdatedAtMillis: ms)
            clearConflict(pageId: pid)
            // Offene, saubere Seite still mit dem Merge-Ergebnis aktualisieren.
            if editor.openPageId == pid, !editor.isDirty(pid) {
                await editor.reloadPage(pageId: pid, html: outcome.merged, baseUpdatedAt: ms)
            }
            log.info("Auto-Merge gepusht: \(pid, privacy: .public)")
        } catch let AuthError.server(status, _, _) where status == 409 {
            // Erneutes Rennen — nächster Tick versucht es frisch (kein Konflikt-Flag).
            log.notice("Auto-Merge verlor das Rennen (erneut 409): \(pid, privacy: .public)")
        } catch {
            log.error("Auto-Merge-Push fehlgeschlagen \(pid, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                let isOpen = (editor?.openPageId == pid)
                let isDirtyOpen = isOpen && (editor?.isDirty(pid) ?? false)
                if pending.contains(pid) || isDirtyOpen {
                    // Lokal ungepushte Änderung (Outbox ODER dirty offene Seite) +
                    // neuerer Server-Stand → Divergenz. Nicht überschreiben und Basis
                    // NICHT vorrücken: der nächste Push läuft bewusst in ein 409 und
                    // löst per Block-Merge auf (Datenverlust-Schutz).
                    log.notice("Pull übersprungen (lokale Änderung offen): \(pid, privacy: .public)")
                    continue
                }
                // Ohne Server-`updated_at` gibt es keine gültige Konflikt-Basis
                // (PUT braucht den exakten ISO-String). Seite überspringen, statt
                // sie ohne Basis in den Store zu mergen.
                guard let serverUpdatedAt = p.updated_at else {
                    log.notice("Pull übersprungen (Seite ohne updated_at): \(pid, privacy: .public)")
                    continue
                }
                let serverHtml = p.html ?? ""
                let ms = ISOTime.millis(serverUpdatedAt) ?? 0
                // ISO als Push-Basis + HTML als Merge-Ancestor mitführen.
                stateStore.mutate {
                    $0.serverBaseISO[pid] = serverUpdatedAt
                    $0.serverBaseHtml[pid] = serverHtml
                }
                try await store.applyServerPage(id: pid,
                                                html: serverHtml,
                                                pageName: p.page_name,
                                                bookId: bookId,
                                                chapterId: p.chapter_id,
                                                serverUpdatedAtMillis: ms)
                // Saubere, offene Seite still in der WebView neu laden (clean reload).
                if isOpen {
                    await editor?.reloadPage(pageId: pid, html: serverHtml, baseUpdatedAt: ms)
                }
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

    // MARK: - Delete-Reconcile

    /// Entfernt lokal Seiten, die der Server nicht mehr kennt. `/sync` meldet
    /// keine Löschungen (CLAUDE.md) — der Soll-Bestand kommt aus dem Buch-Tree.
    /// Gedrosselt (≤ 1×/`reconcileInterval`), da je Buch ein Tree-Fetch anfällt.
    private func reconcileDeletesIfDue() async {
        let now = Date()
        if let last = lastReconcileAt, now.timeIntervalSince(last) < reconcileInterval { return }
        lastReconcileAt = now

        for bookId in stateStore.state.bookIds {
            do {
                try await reconcileBookDeletes(bookId)
            } catch {
                // Ein Tree-Fehler (offline/Serverproblem) darf die anderen Bücher
                // nicht blockieren und nichts löschen — beim nächsten Mal erneut.
                log.notice("Reconcile Buch \(bookId, privacy: .public) übersprungen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reconcileBookDeletes(_ bookId: Int) async throws {
        // Soll: alle Seiten, die der Server-Tree für das Buch kennt (vollständig —
        // ensureTree nimmt auch ungeordnete Seiten auf, kein False-Positive).
        let soll = Set(try await content.pickerRows(bookId: bookId).map { String($0.id) })
        // Ist: lokal gespiegelte Seiten dieses Buchs.
        let ist = try await store.list(bookId: bookId)
        guard !ist.isEmpty else { return }

        let pending = Set(try await store.pendingOutbox().map(\.pageId))

        for summary in ist where !soll.contains(summary.id) {
            let pid = summary.id
            // Datenverlust-Schutz: nie löschen, wenn lokale Änderung offen/ungepusht
            // ist oder die Seite gerade dirty im Editor liegt.
            if pending.contains(pid) {
                log.notice("Reconcile: \(pid, privacy: .public) serverseitig weg, aber Outbox offen — behalten")
                continue
            }
            if editor?.openPageId == pid, editor?.isDirty(pid) == true {
                log.notice("Reconcile: \(pid, privacy: .public) serverseitig weg, aber dirty im Editor — behalten")
                continue
            }

            try await store.deletePage(id: pid)
            stateStore.mutate {
                $0.serverBaseISO[pid] = nil
                $0.serverBaseHtml[pid] = nil
            }
            log.info("Reconcile: lokale Seite \(pid, privacy: .public) entfernt (serverseitig gelöscht)")
        }
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
