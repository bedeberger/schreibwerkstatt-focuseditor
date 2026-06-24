//
//  WritingTimeTracker.swift
//  schreibwerkstatt-focuseditor
//
//  Schreibzeit-Tracking: misst, wie lange der Nutzer im Editor verbringt, und
//  meldet die Sekunden an den Server (`POST /history/writing-time`, serverseitig
//  pro Buch/Tag aufaddiert). Das native Pendant zum Heartbeat der Web-Plattform
//  (`public/js/book/writing-time.js` im Hauptrepo).
//
//  Kontext-Bedingung wie dort: gezählt wird, solange das Fenster aktiv ist UND
//  eine Seite im aktiven Buch offen ist — das Analog zur Web-Bedingung
//  `(editMode||focusActive) && selectedBookId && visible`. (Dieser Client hat
//  keinen Buchorganizer; „in der App mit offener Seite" = „im Editor".)
//
//  ZUSÄTZLICH (anders als die Web-Plattform) eine Idle-Erkennung: liegt das
//  Tippen länger als `idleThreshold` (120 s) zurück, wird die Schreibzeit
//  pausiert. Anrechenbar ist nur Zeit bis `letzte Aktivität + idleThreshold`;
//  längere Tipp-Pausen (Lesen, Weglaufen) zählen nicht. „Aktivität" ist jede
//  `reportStats`-Meldung der WebView (debounced bei `input` → echtes Tippen),
//  geliefert über `bridge.onActivity` → `notifyActivity()`; ein frischer
//  Segment-Start (Seite geöffnet / Fenster aktiviert) zählt ebenfalls als
//  Aktivität, damit die Uhr nicht sofort abläuft.
//
//  Best-effort: nicht bestätigte Sekunden bleiben in `pending` (pro Buch) und
//  werden beim nächsten Tick erneut gesendet — eine kurze Offline-Phase geht so
//  nicht verloren. Der Puffer wird zusätzlich SERVER-SKOPIERT in den UserDefaults
//  persistiert (`writingtime.pending.<slug>`), damit ein Crash/Beenden ZWISCHEN
//  zwei Heartbeats die bereits gezählte Zeit nicht verliert — beim nächsten Start
//  (oder Server-Rückwechsel) wird sie geladen und gesendet. Inhalte/Outbox sind
//  nie betroffen; ein verlorener Ping kostet höchstens ein paar Sekunden Statistik.
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
    /// Tipp-Pause, ab der die Schreibzeit als idle pausiert. Zeit über diese
    /// Schwelle hinaus (seit der letzten Aktivität) wird nicht angerechnet.
    private let idleThreshold: TimeInterval = 120

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
    /// Zeitpunkt der letzten Nutzer-Aktivität (Tippen / Segment-Start). Deckelt die
    /// anrechenbare Zeit (`+ idleThreshold`) und treibt das Idle-Aufwachen. `nil` =
    /// noch keine Aktivität in dieser Sitzung gesehen.
    private var lastActivityAt: Date?

    /// Noch nicht vom Server bestätigte Sekunden, pro Buch. Wächst bei Sende-
    /// Fehlern (offline) und wird beim nächsten Tick erneut versucht. Jede Änderung
    /// wird persistiert (server-skopiert), damit der Puffer einen Neustart übersteht.
    private var pending: [Int: Int] = [:] {
        didSet { persistPending() }
    }
    /// Server-Slug, zu dem der aktuelle `pending` gehört (Buch-IDs gelten nur am
    /// Server, der sie vergeben hat). Bestimmt den Persistenz-Schlüssel; bei einem
    /// Server-Wechsel über `reset()` umgebunden.
    private var slug: String
    /// Verhindert überlappende Sendeläufe (Heartbeat + Stop-Flush gleichzeitig).
    private var isFlushing = false

    private var heartbeat: Task<Void, Never>?

    init(api: APIClient, isSignedIn: @escaping () -> Bool) {
        self.api = api
        self.isSignedIn = isSignedIn
        // Puffer des aktuell konfigurierten Servers aus einer früheren Sitzung
        // laden. Initialer Set im Init → didSet feuert nicht (kein Rück-Schreiben).
        self.slug = ServerNamespace.currentSlug
        self.pending = Self.loadPersisted(slug: self.slug)
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
        // Beim Aktivieren einen evtl. aus einer früheren Sitzung restaurierten
        // Puffer best-effort senden — auch ohne offene Seite. `flushPending` no-opt,
        // falls (noch) nicht angemeldet; sonst greift der nächste Heartbeat-Tick.
        if active && !pending.isEmpty { Task { await self.flushPending() } }
        reevaluate()
    }

    /// Server-Wechsel: laufendes Segment beenden und die In-Memory-Sicht auf den
    /// neuen Server umbinden. Buch-IDs gelten nur am Server, der sie vergeben hat —
    /// sonst würde die Zeit am neuen Server auf eine fremde Buch-ID gebucht. Der
    /// persistierte Puffer des ALTEN Servers bleibt unter dessen Slug liegen (kein
    /// `removeAll` → kein Lösch-Schreiben) und wird bei einem Rückwechsel erneut
    /// gesendet; geladen wird der Puffer des NEUEN Servers.
    func reset() {
        stopHeartbeat()
        segmentStart = nil
        segmentBookId = nil
        lastActivityAt = nil
        slug = ServerNamespace.currentSlug
        pending = Self.loadPersisted(slug: slug)
    }

    // MARK: - Zähl-Logik

    /// Gezählt wird, solange Fenster aktiv, eine Seite offen, ein Buch gewählt und
    /// angemeldet — das native Pendant zur Web-Bedingung.
    private var shouldCount: Bool {
        isActive && hasOpenPage && activeBookId != nil && isSignedIn()
    }

    /// Liegt die letzte Aktivität länger als `idleThreshold` zurück? Ohne je
    /// gesehene Aktivität `false` (nicht spurios pausieren — der Segment-Start
    /// setzt `lastActivityAt` ohnehin sofort).
    private var isIdle: Bool {
        guard let last = lastActivityAt else { return false }
        return Date().timeIntervalSince(last) > idleThreshold
    }

    /// Vom `bridge.onActivity`-Hook bei jeder `reportStats`-Meldung gerufen
    /// (debounced bei `input` → echtes Tippen). Setzt die Idle-Uhr zurück und
    /// nimmt ein idle-pausiertes Segment wieder auf (Kontext zählt, Segment ruht).
    func notifyActivity() {
        lastActivityAt = Date()
        if shouldCount, segmentStart == nil, let book = activeBookId {
            segmentStart = Date()
            segmentBookId = book
            startHeartbeat()
        }
    }

    /// Bewertet nach jeder Eingangs-Änderung, ob (und unter welchem Buch) gezählt
    /// wird: startet/stoppt das Segment und schaltet den Heartbeat entsprechend.
    private func reevaluate() {
        if shouldCount, let book = activeBookId {
            if segmentStart == nil {
                // Frischer Start (Seite geöffnet / Fenster aktiviert / Login, oder
                // Aufwachen aus Idle-Pause): zählt als Aktivität, damit die Idle-Uhr
                // nicht sofort wieder abläuft.
                lastActivityAt = Date()
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
        // Idle-Deckel: anrechenbar nur bis `letzte Aktivität + idleThreshold`.
        // Eine längere Tipp-Pause (Idle) wird so nicht mitgezählt — auch wenn der
        // Heartbeat sie erst beim nächsten Tick bemerkt, bindet der Deckel hier.
        let deadline = (lastActivityAt ?? start).addingTimeInterval(idleThreshold)
        let creditUntil = min(now, deadline)
        // Uhrsprung-Schutz: negativ (Uhr zurückgestellt) → verwerfen; nach oben
        // auf das Server-Limit deckeln. `.rounded()` mittelt die Sub-Sekunden-
        // Reste über die Ticks aus (kein systematisches Unterzählen).
        let elapsed = Int(creditUntil.timeIntervalSince(start).rounded())
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
                if self.isIdle {
                    // Idle: das Reststück bis zur Deadline gutschreiben (greift im
                    // Deckel von captureSegment), Segment schließen und pausieren.
                    // `notifyActivity()` nimmt es beim nächsten Tippen wieder auf.
                    self.captureSegment(continueCounting: false)
                    self.stopHeartbeat()
                    await self.flushPending()
                    break
                }
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

    // MARK: - Persistenz (server-skopiert, überlebt App-Neustart)

    private static let pendingKeyPrefix = "writingtime.pending."

    /// Schreibt `pending` in die UserDefaults — unter dem Slug des Servers, zu dem
    /// die Buch-IDs gehören. Leerer Puffer → Eintrag entfernen (kein Müll-Key).
    private func persistPending() {
        let key = Self.pendingKeyPrefix + slug
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            // UserDefaults verlangt String-Keys → Buch-ID als String ablegen.
            let encoded = Dictionary(uniqueKeysWithValues: pending.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Liest den persistierten Puffer eines Servers zurück (defensiv: nur positive
    /// Sekunden, nur ganzzahlige Buch-IDs — Fremdformate werden verworfen).
    private static func loadPersisted(slug: String) -> [Int: Int] {
        let key = pendingKeyPrefix + slug
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw where v > 0 {
            if let id = Int(k) { out[id] = v }
        }
        return out
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
