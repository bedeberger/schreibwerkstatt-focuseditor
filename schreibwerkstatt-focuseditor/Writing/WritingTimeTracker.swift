//
//  WritingTimeTracker.swift
//  schreibwerkstatt-focuseditor
//
//  Schreibzeit-Tracking: misst, wie lange der Nutzer im Editor verbringt, und
//  meldet die Sekunden an den Server (`POST /history/writing-time`, serverseitig
//  pro Buch/Tag aufaddiert). Das native Pendant zum Heartbeat der Web-Plattform
//  (`public/js/book/writing-time.js` im Hauptrepo).
//
//  Wie dort gibt es bewusst KEINE Idle-Erkennung: gezählt wird, solange das
//  Fenster aktiv ist UND eine Seite im aktiven Buch offen ist — das Analog zur
//  Web-Bedingung `(editMode||focusActive) && selectedBookId && visible`. (Dieser
//  Client hat keinen Buchorganizer; „in der App mit offener Seite" = „im Editor".)
//
//  Best-effort und nur in-memory gepuffert: nicht bestätigte Sekunden bleiben in
//  `pending` (pro Buch) und werden beim nächsten Tick erneut gesendet — eine
//  kurze Offline-Phase geht so nicht verloren. KEIN persistenter Puffer über
//  App-Neustarts hinaus (wie die Web-Seite). Inhalte/Outbox sind nie betroffen;
//  ein verlorener Ping kostet höchstens ein paar Sekunden Statistik.
//

import Foundation
import os

@MainActor
final class WritingTimeTracker {
    private let api: APIClient
    /// Nur melden, wenn angemeldet (sonst 401). Spiegelt `SyncEngine.shouldSync`.
    private let isSignedIn: () -> Bool
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "writing-time")

    /// Heartbeat-Kadenz — wie die Web-Seite (15 s).
    private let heartbeatInterval: Duration = .seconds(15)
    /// Der Server clampt jeden Ping auf 1 h (Schutz gegen Uhrsprünge); lokal
    /// genauso deckeln, damit ein Ping nie serverseitig beschnitten „verloren"
    /// scheint — Überhang drainiert über mehrere Ticks.
    private let maxSecondsPerPing = 3600

    // MARK: - Eingänge (gespiegelt)

    /// Fenster im Vordergrund (Scene-Phase `.active`) — wie beim Sync-Poll.
    private var isActive = false
    /// Ob eine Seite im Editor offen ist (vom LibraryStore gemeldet).
    private var hasOpenPage = false
    /// Aktives Buch — Verbuchungs-Schlüssel der gemeldeten Zeit.
    private var activeBookId: Int?

    // MARK: - Laufendes Segment

    /// Start des aktuell laufenden Zähl-Segments (`nil` = zählt gerade nicht).
    private var segmentStart: Date?
    /// Buch, unter dem das laufende Segment verbucht wird. Eingefroren beim Start,
    /// damit ein Buchwechsel die bereits gezählte Zeit nicht umbucht.
    private var segmentBookId: Int?

    /// Noch nicht vom Server bestätigte Sekunden, pro Buch. Wächst bei Sende-
    /// Fehlern (offline) und wird beim nächsten Tick erneut versucht.
    private var pending: [Int: Int] = [:]
    /// Verhindert überlappende Sendeläufe (Heartbeat + Stop-Flush gleichzeitig).
    private var isFlushing = false

    private var heartbeat: Task<Void, Never>?

    init(api: APIClient, isSignedIn: @escaping () -> Bool) {
        self.api = api
        self.isSignedIn = isSignedIn
    }

    /// Koppelt den Tracker an den LibraryStore: jede Änderung am „wo schreibt der
    /// Nutzer"-Kontext (aktives Buch / offene Seite) bewertet das Zählen neu.
    func attach(to library: LibraryStore) {
        library.onWritingContextChange = { [weak self] bookId, hasOpenPage in
            guard let self else { return }
            self.activeBookId = bookId
            self.hasOpenPage = hasOpenPage
            self.reevaluate()
        }
        // Anfangszustand übernehmen (der Callback feuert nur bei Änderungen).
        activeBookId = library.activeBookId
        hasOpenPage = library.openPageId != nil
        reevaluate()
    }

    /// Vom Scene-Phasen-Wechsel getrieben (parallel zu `SyncEngine.setActive`).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        reevaluate()
    }

    /// Server-Wechsel: laufendes Segment + Puffer verwerfen. Buch-IDs gelten nur
    /// am Server, der sie vergeben hat — sonst würde die Zeit am neuen Server auf
    /// eine fremde Buch-ID gebucht.
    func reset() {
        stopHeartbeat()
        segmentStart = nil
        segmentBookId = nil
        pending.removeAll()
    }

    // MARK: - Zähl-Logik

    /// Gezählt wird, solange Fenster aktiv, eine Seite offen, ein Buch gewählt und
    /// angemeldet — das native Pendant zur Web-Bedingung.
    private var shouldCount: Bool {
        isActive && hasOpenPage && activeBookId != nil && isSignedIn()
    }

    /// Bewertet nach jeder Eingangs-Änderung, ob (und unter welchem Buch) gezählt
    /// wird: startet/stoppt das Segment und schaltet den Heartbeat entsprechend.
    private func reevaluate() {
        if shouldCount, let book = activeBookId {
            if segmentStart == nil {
                segmentStart = Date()
                segmentBookId = book
                startHeartbeat()
            } else if segmentBookId != book {
                // Buchwechsel bei laufendem Zählen → bisherige Zeit dem alten Buch
                // gutschreiben, dann frisch fürs neue Buch weiterzählen.
                captureSegment(continueCounting: false)
                segmentStart = Date()
                segmentBookId = book
            }
        } else if segmentStart != nil {
            // Zähl-Bedingung entfallen → letztes Stück sichern + Heartbeat aus.
            captureSegment(continueCounting: false)
            stopHeartbeat()
            Task { await self.flushPending() }
        }
    }

    /// Schreibt die seit `segmentStart` verstrichene Zeit dem Segment-Buch gut.
    /// `continueCounting == true`: das Segment läuft ab jetzt weiter (Heartbeat);
    /// `false`: das Segment endet.
    private func captureSegment(continueCounting: Bool) {
        guard let start = segmentStart, let book = segmentBookId else { return }
        let now = Date()
        // Uhrsprung-Schutz: negativ (Uhr zurückgestellt) → verwerfen; nach oben
        // auf das Server-Limit deckeln. `.rounded()` mittelt die Sub-Sekunden-
        // Reste über die Ticks aus (kein systematisches Unterzählen).
        let elapsed = Int(now.timeIntervalSince(start).rounded())
        let seconds = min(max(0, elapsed), maxSecondsPerPing)
        if continueCounting {
            segmentStart = now
        } else {
            segmentStart = nil
            segmentBookId = nil
        }
        if seconds > 0 {
            pending[book, default: 0] += seconds
        }
    }

    // MARK: - Heartbeat (Task-Loop wie SyncEngine.startPolling)

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.heartbeatInterval)
                if Task.isCancelled { break }
                self.captureSegment(continueCounting: true)
                await self.flushPending()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    // MARK: - Senden

    /// Sendet die gepufferten Sekunden je Buch. Erfolg → abziehen; Fehler →
    /// behalten (nächster Tick versucht erneut). Pro Ping aufs Server-Limit
    /// gedeckelt; ein größerer Rückstand drainiert über mehrere Ticks.
    private func flushPending() async {
        guard !isFlushing, isSignedIn() else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Über eine Schlüssel-Kopie iterieren — `pending` kann zwischen den
        // `await`s von anderen MainActor-Ticks verändert werden.
        for book in Array(pending.keys) {
            guard let secs = pending[book], secs > 0 else { continue }
            let toSend = min(secs, maxSecondsPerPing)
            do {
                try await api.sendVoid("/history/writing-time", method: .POST,
                                       body: WritingTimePing(bookId: book, seconds: toSend))
                let rest = (pending[book] ?? 0) - toSend
                pending[book] = rest > 0 ? rest : nil
            } catch {
                // Best-effort: behalten und beim nächsten Tick erneut versuchen.
                // Keine Inhalte betroffen. Bei einem Fehler die übrigen Bücher
                // diesmal nicht weiterversuchen (meist offline → ohnehin alle).
                log.debug("Schreibzeit-Ping fehlgeschlagen (Buch \(book, privacy: .public), \(secs, privacy: .public)s) — gepuffert")
                break
            }
        }
    }
}

/// Payload für `POST /history/writing-time` — `{ book_id, seconds }`.
private struct WritingTimePing: Encodable {
    let bookId: Int
    let seconds: Int
    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case seconds
    }
}
