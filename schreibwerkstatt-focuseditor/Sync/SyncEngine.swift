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
        case idle               // bereit, nichts zu tun
        case syncing            // Push/Pull läuft
        case offline            // kein Netz (Reachability-Pfad nicht erreichbar)
        case serverUnreachable  // Netz da, aber der Server antwortet nicht
                                // (Verbindung abgelehnt/Timeout) — Server gekappt o. Ä.
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
    /// Anzahl lokal noch nicht gepushter Seiten (Outbox) — für die Status-UI.
    @Published private(set) var pendingCount: Int = 0

    /// Poll-Kadenz (persistiert). Änderung startet den Loop passend neu.
    @Published var pollMode: SyncPollMode {
        didSet {
            guard pollMode != oldValue else { return }
            UserDefaults.standard.set(pollMode.rawValue, forKey: SyncPollMode.storageKey)
            restartPolling()
        }
    }

    /// Transientes Pausieren des Auto-Polls (nur diese Sitzung). Manueller Sync
    /// bleibt möglich; Pushes gehen so beim nächsten manuellen Tick raus.
    @Published var isPaused: Bool = false {
        didSet {
            guard isPaused != oldValue else { return }
            restartPolling()
        }
    }

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

    /// Aktive Poll-Periode aus dem gewählten Modus (`nil` = manuell, kein Loop).
    private var pollInterval: Duration? { isPaused ? nil : pollMode.interval }
    /// Soll der Auto-Poll laufen? (Aktives Fenster + Modus ≠ manuell + nicht pausiert.)
    private var autoPollEnabled: Bool { isActive && !isPaused && pollMode.interval != nil }
    /// Delete-Reconcile ist teurer (ein Tree-Fetch je Buch) → seltener als der
    /// Poll. Mindestabstand zwischen zwei Reconcile-Durchläufen.
    private let reconcileInterval: TimeInterval = 60
    private var lastReconcileAt: Date?
    /// Die Bücherliste wird (anders als früher) nicht nur einmal gebootstrappt,
    /// sondern gedrosselt aufgefrischt — sonst würden in der Web-App neu
    /// angelegte Bücher nie gepullt. Gleiche Kadenz wie der Reconcile.
    private let booksRefreshInterval: TimeInterval = 60
    private var lastBooksRefreshAt: Date?
    /// Serverseitig gesperrte Seiten (423 PAGE_LOCKED): nicht bei jedem Tick
    /// erneut pushen, sondern bis zum Ablauf der Sperrfrist überspringen
    /// (vermeidet Dauer-PUTs + Log-Spam bei langem Lektorats-Lock).
    private let lockBackoff: TimeInterval = 60
    private var lockedUntil: [String: Date] = [:]

    private var isRunning = false
    private var isActive = false
    private var pollTask: Task<Void, Never>?
    /// Wurde der Server im laufenden Sync-Durchlauf (transport-seitig) erreicht?
    /// Jede HTTP-Antwort (auch 4xx/5xx/401) zählt als erreichbar, nur ein echter
    /// Transport-Fehler (`AuthError.network`: Verbindung abgelehnt/Timeout/TLS)
    /// lässt das Flag false — daraus leitet `syncNow()` `.serverUnreachable` ab,
    /// unterscheidet also „Server weg" von „kein Netz" (`.offline`).
    private var serverReachedThisRun = false

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
        self.pollMode = SyncPollMode.current
    }

    // MARK: - Lifecycle

    /// Startet die Reachability-Beobachtung. Das Polling selbst hängt an der
    /// Scene-Phase und wird über `setActive(_:)` ein-/ausgeschaltet.
    func start() {
        reachability.onChange = { [weak self] online in
            guard let self else { return }
            if online {
                // Netz wieder da: noch NICHT blind auf `.idle` — ob der Server
                // antwortet, klärt erst der folgende Tick (sonst „grün", obwohl
                // der Server weg ist). Mit Auto-Poll sofort ein Tick; sonst den
                // bisherigen Stand halten (der nächste manuelle Sync prüft).
                if self.autoPollEnabled { self.requestSync() }
            } else {
                self.status = .offline
            }
        }
        reachability.start()
    }

    func stop() {
        stopPolling()
        reachability.stop()
    }

    /// Server-Wechsel: den persistenten Sync-Zustand (Buch-IDs/Cursor/Basen) auf
    /// den Namespace des aktuellen Servers umladen und alle transienten Spuren des
    /// alten Servers verwerfen. Ohne das würde der Loop weiter die Buch-IDs des
    /// alten Servers pollen (→ `NO_BOOK_ACCESS` am neuen Server). Den Poll-Loop
    /// danach passend neu aufsetzen.
    func reloadForCurrentServer() {
        stopPolling()
        stateStore.reloadForCurrentServer()
        conflicts = []
        pendingCount = 0
        lastReconcileAt = nil
        // Bücherliste beim nächsten Tick zwingend neu (autoritativ) ziehen, damit
        // evtl. aus dem alten Server migrierte/fremde Buch-IDs sofort gekürzt
        // werden — nicht erst nach Ablauf des Refresh-Intervalls.
        lastBooksRefreshAt = nil
        // Lektorats-Sperren des alten Servers verwerfen.
        lockedUntil = [:]
        lastError = nil
        status = .idle
        if isActive {
            if autoPollEnabled { requestSync() }
            startPolling()
        }
    }

    /// Vom Scene-Phasen-Wechsel getrieben: aktiv → sofortiger Tick + 5 s-Poll;
    /// inaktiv/Hintergrund → Poll pausieren (CLAUDE.md: nur solange Fenster aktiv).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if autoPollEnabled { requestSync() }   // sofortiger Tick beim Reaktivieren
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Stößt einen Sync-Durchlauf an (Scene-aktiv, Online-Wechsel, lokaler Save).
    func requestSync() {
        Task { await syncNow() }
    }

    /// Manueller Sync-Auslöser (Menü/Toolbar/Settings) — wirkt auch bei
    /// pausiertem oder manuellem Modus (überschreibt den Auto-Poll-Stopp).
    func syncManually() {
        Task { await syncNow() }
    }

    /// Startet den Poll-Loop, sofern der Auto-Poll erlaubt ist; sonst No-op
    /// (manueller Modus/pausiert → kein automatischer Tick).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard autoPollEnabled, let interval = pollInterval else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Erster Tick kommt über requestSync(); der Loop ergänzt Folge-Ticks.
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self.syncNow()
            }
        }
    }

    /// Loop nach einer Modus-/Pause-Änderung neu aufsetzen (nur im aktiven Fenster).
    private func restartPolling() {
        guard isActive else { return }
        stopPolling()
        if autoPollEnabled { requestSync() }
        startPolling()
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
        serverReachedThisRun = false
        defer {
            isRunning = false
            // Status aus dem Lauf neu ableiten: kein Netz → offline; Netz da,
            // aber kein einziger Request hat den Server erreicht → serverUnreachable;
            // sonst idle. (Konflikte zeigt die UI unabhängig vom Status.)
            if !reachability.isOnline {
                status = .offline
            } else if !serverReachedThisRun {
                status = .serverUnreachable
            } else {
                status = .idle
            }
        }

        do {
            try await pushOutbox()
            try await pullDeltas()
            await reconcileDeletesIfDue()
            pendingCount = (try? await store.pendingOutbox().count) ?? pendingCount
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

    /// Führt einen Server-Aufruf aus und merkt sich für `serverReachedThisRun`,
    /// ob der Server antwortete. Jede HTTP-Antwort (Erfolg ODER 4xx/5xx/401)
    /// gilt als erreichbar; nur `AuthError.network` (Transport-Fehler) lässt das
    /// Flag unverändert. Der Fehler wird unverändert weitergereicht — die
    /// bestehende Fehlerbehandlung (409-Merge, 404/423-Skip, 401-Abbruch) bleibt.
    @discardableResult
    private func reachableSend<T>(_ call: () async throws -> T) async throws -> T {
        do {
            let result = try await call()
            serverReachedThisRun = true
            return result
        } catch {
            if case AuthError.network = error {
                // Transport-Fehler → Server NICHT erreicht; Flag bleibt false.
            } else {
                serverReachedThisRun = true   // Server hat geantwortet (nur Status ≠ 2xx)
            }
            throw error
        }
    }

    // MARK: - Push

    private func pushOutbox() async throws {
        let entries = try await store.pendingOutbox()
        let now = Date()
        for entry in entries {
            // Unaufgelöste Konflikte nicht erneut blind pushen.
            if conflicts.contains(where: { $0.pageId == entry.pageId }) { continue }

            // Serverseitig gesperrte Seite (423) noch in der Backoff-Frist → diesen
            // Tick überspringen, statt erneut nutzlos zu pushen.
            if let until = lockedUntil[entry.pageId], until > now { continue }

            guard let base = stateStore.state.serverBaseISO[entry.pageId] else {
                // Keine Server-Basis → Seite existiert serverseitig (noch) nicht.
                // PUT kann nur updaten, nicht anlegen (Anlegen wäre POST /content/pages).
                log.info("Push übersprungen (keine Server-Basis): \(entry.pageId, privacy: .public)")
                continue
            }

            let req = PushRequest(html: entry.html, expected_updated_at: base)
            do {
                let resp = try await reachableSend {
                    try await api.send("/content/pages/\(entry.pageId)",
                                       method: .PUT,
                                       body: req,
                                       decode: PushResponse.self)
                }
                // Basis vorrücken (exakte Server-ISO + HTML als Merge-Ancestor) + Outbox quittieren.
                stateStore.mutate {
                    $0.serverBaseISO[entry.pageId] = resp.updated_at
                    $0.serverBaseHtml[entry.pageId] = entry.html
                }
                try await store.markPushed(id: entry.pageId,
                                           queuedAt: entry.queuedAt,
                                           serverUpdatedAtMillis: ISOTime.millis(resp.updated_at) ?? entry.queuedAt)
                // Erfolgreicher Push → eine etwaige Lock-Backoff-Frist aufheben.
                lockedUntil[entry.pageId] = nil
            } catch let AuthError.server(status, _, body) where status == 409 {
                // Stale-Write → 3-Wege-Block-Merge versuchen, sonst Konflikt erfassen.
                let c = body.flatMap { try? JSONDecoder().decode(ConflictBody.self, from: $0) }
                await resolveConflict(entry: entry, conflict: c)
            } catch let AuthError.server(status, _, _) where status == 423 {
                // Seite serverseitig gesperrt (Lektorat) — später erneut versuchen,
                // aber mit Backoff: bis zum Ablauf der Frist überspringt der Push
                // diese Seite (kein Dauer-PUT bei langem Lock). Lokaler Stand bleibt.
                lockedUntil[entry.pageId] = now.addingTimeInterval(lockBackoff)
                log.info("Seite gesperrt (423), Backoff \(self.lockBackoff, privacy: .public)s: \(entry.pageId, privacy: .public)")
            } catch let AuthError.server(status, _, _) where status == 404 {
                // Seite existiert serverseitig nicht mehr (PUT legt nicht an) —
                // Basis verwerfen, Inhalt aber lokal behalten (kein Datenverlust).
                // OHNE Server-Basis würde der Push die Seite ab jetzt STILL für
                // immer überspringen (Sackgasse). Darum als sichtbaren Konflikt
                // erfassen, damit der Nutzer es bemerkt; der Konflikt-Guard oben
                // verhindert zugleich nutzlose Re-Pushes.
                stateStore.mutate { $0.serverBaseISO[entry.pageId] = nil }
                recordConflict(pageId: entry.pageId, serverUpdatedAt: nil, serverEditorName: nil)
                log.notice("Seite serverseitig nicht gefunden (404), als Konflikt erfasst: \(entry.pageId, privacy: .public)")
            } catch AuthError.unauthorized {
                // Session beendet → ganzen Sync abbrechen (kein blindes Weiterpushen).
                throw AuthError.unauthorized
            } catch {
                // Netzfehler/Timeout o. Ä. → nur diesen Eintrag überspringen, die
                // restliche Outbox nicht blockieren. Nächster Tick versucht erneut.
                log.error("Push fehlgeschlagen \(entry.pageId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }

    /// 409-Auflösung per 3-Wege-Block-Merge in der WebView. Kollisionsfrei →
    /// gemergtes HTML mit der neuen Server-Basis erneut pushen; echte Block-
    /// Kollision oder kein Merge möglich → Konflikt erfassen (Editor-UI/Block-Merge).
    /// Verwirft NIE lokale Inhalte.
    private func resolveConflict(entry: OutboxEntry, conflict c: ConflictBody?) async {
        let pid = entry.pageId

        // Kein WebView/Editor-Bundle → nicht auto-mergebar, echter Konflikt für die UI.
        guard let editor else {
            recordConflict(pageId: pid,
                           serverUpdatedAt: c?.server_updated_at,
                           serverEditorName: c?.server_editor_name)
            log.notice("Konflikt \(pid, privacy: .public): kein Editor zum Mergen")
            return
        }

        // Aktuelles Server-HTML + neue Basis holen. Ein transienter Netzfehler hier
        // darf KEINEN klebrigen Konflikt setzen (würde die Seite bis Neustart vom
        // Sync ausschließen). Stattdessen still verschieben: Eintrag bleibt in der
        // Outbox ohne Konflikt-Flag, der nächste Push-Tick versucht es erneut.
        let serverPage: PushResponse
        do {
            serverPage = try await reachableSend {
                try await api.send("/content/pages/\(pid)",
                                   method: .GET,
                                   decode: PushResponse.self)
            }
        } catch {
            log.notice("Konflikt-Merge für \(pid, privacy: .public) verschoben: \(error.localizedDescription, privacy: .public)")
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
            let resp = try await reachableSend {
                try await api.send("/content/pages/\(pid)",
                                   method: .PUT,
                                   body: req,
                                   decode: PushResponse.self)
            }
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
        // Bücherliste auffrischen: beim ersten Mal (leer) zwingend, danach
        // gedrosselt — sonst würden in der Web-App neu angelegte Bücher nie
        // gepullt.
        let booksDue: Bool = {
            guard let last = lastBooksRefreshAt else { return true }
            return Date().timeIntervalSince(last) >= booksRefreshInterval
        }()
        if stateStore.state.bookIds.isEmpty || booksDue {
            let books = try await reachableSend {
                try await api.send("/content/books", method: .GET, decode: [BookDTO].self)
            }
            lastBooksRefreshAt = Date()
            let ids = books.map(\.id)
            // `GET /content/books` ist AUTORITATIV: die vollständige Liste der für
            // diesen User zugänglichen Bücher. Buch-IDs, die nicht (mehr) darin
            // stehen — etwa von einem anderen Server (Namespace-Altlast) oder nach
            // Zugriffsentzug —, werden NICHT gepollt; sonst läuft jeder Tick in ein
            // `NO_BOOK_ACCESS` (Server-Log-Flut). Darum die bekannte Liste auf den
            // Server-Bestand kürzen, statt sie nur zu vereinigen. Schutz gegen eine
            // transient leere Antwort: nur kürzen, wenn die Liste nicht leer ist
            // (eine echte leere Antwort lässt der nächste Tick erneut prüfen).
            if ids.isEmpty {
                log.notice("Bücherliste leer — Buch-IDs unverändert gelassen (kein Prune)")
            } else {
                let valid = Set(ids)
                let dropped = stateStore.state.bookIds.filter { !valid.contains($0) }
                stateStore.mutate { state in
                    // Cursor verschwundener Bücher mit aufräumen (kein toter Ballast).
                    for id in dropped { state.cursors[id] = nil }
                    state.bookIds = ids   // Server-Reihenfolge, autoritativ (gekürzt)
                }
                if !dropped.isEmpty {
                    log.info("Buch-IDs gekürzt: \(dropped.map(String.init).joined(separator: ","), privacy: .public) nicht (mehr) zugänglich")
                }
            }
        }

        for bookId in stateStore.state.bookIds {
            do {
                try await pullBook(bookId)
            } catch AuthError.unauthorized {
                // Session beendet → ganzen Sync abbrechen.
                throw AuthError.unauthorized
            } catch {
                // Netzfehler/Timeout bei einem Buch blockiert die restlichen nicht.
                log.error("Pull Buch \(bookId) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }

    private func pullBook(_ bookId: Int) async throws {
        var cursor = stateStore.state.cursors[bookId] ?? SyncCursorDTO(since: nil, since_id: 0)

        // Harte Obergrenze gegen ein endloses Paging bei fehlerhaftem Server-
        // Cursor (oszillierend/nicht-monoton). Bei 200 Seiten/Page deckt das
        // sehr große Bücher ab; wird sie erreicht, beim nächsten Tick weiter.
        let maxPages = 500
        var pageCount = 0

        while true {
            pageCount += 1
            if pageCount > maxPages {
                log.notice("Pull Buch \(bookId, privacy: .public): Paging-Limit (\(maxPages, privacy: .public)) erreicht — beim nächsten Tick weiter")
                break
            }
            let resp = try await reachableSend {
                try await api.send(syncPath(bookId: bookId, cursor: cursor),
                                   method: .GET,
                                   decode: BookSyncResponse.self)
            }

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
                // Echo des eigenen, eben gepushten Edits: `/sync` liefert bewusst
                // auch eigene Edits zurück, und nach dem Push steht unsere Basis
                // bereits auf genau diesem Server-Stempel. Gleicher Stempel = kein
                // neuer Inhalt → NICHT erneut in den Store mergen und vor allem die
                // offene Seite NICHT neu laden. Sonst lädt jeder Auto-Save die Seite
                // einen Tick später unnötig neu und die Live-Statistik (Wortzahl/
                // „heute") flackert. Fremd-Edits (anderes Gerät/Session) tragen einen
                // ANDEREN updated_at und greifen darum weiterhin. Cursor rückt unten
                // trotzdem regulär vor.
                if stateStore.state.serverBaseISO[pid] == serverUpdatedAt { continue }

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
            let previous = cursor
            stateStore.mutate { $0.cursors[bookId] = resp.cursor }

            // Schutz gegen Endlosschleife, falls der Cursor nicht vorrückt.
            if !resp.has_more || resp.pages.isEmpty { break }
            // Server meldet `has_more`, liefert aber denselben Cursor zurück
            // (Server-Bug) → nicht ewig pagen, beim nächsten Tick neu ansetzen.
            if resp.cursor == previous {
                log.notice("Pull Buch \(bookId, privacy: .public): Cursor rückt nicht vor — Schleife abgebrochen")
                break
            }
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

        // Datenverlust-Schutz: Ein leerer Tree ist verdächtig (transienter
        // Server-200 mit leerem Array, halb-deployter Endpoint, frische Buch-ID)
        // und würde JEDE lokale, saubere Seite löschen — die der cursor-
        // inkrementelle Pull NICHT von selbst zurückbringt. In dem Fall lieber
        // nichts löschen und beim nächsten Lauf erneut prüfen.
        guard !soll.isEmpty else {
            log.notice("Reconcile Buch \(bookId, privacy: .public) übersprungen: leerer Server-Tree, behalte \(ist.count, privacy: .public) lokale Seite(n)")
            return
        }

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
