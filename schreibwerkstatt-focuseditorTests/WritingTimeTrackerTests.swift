//
//  WritingTimeTrackerTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Unit-Tests der Schreibzeit-Arithmetik: Zähl-Bedingung, Idle-Deckel (120 s),
//  Buchwechsel-Verbuchung, Uhrsprung-Schutz, Ping-Deckel (3600 s) und die
//  Persistenz des Puffers über einen „Neustart" hinweg.
//
//  Ohne echtes Warten: der Tracker bekommt eine gestellte Uhr (`now`) und eine
//  eigene `UserDefaults`-Suite (hermetisch, keine Standard-Defaults verschmutzt);
//  der Heartbeat wird über `heartbeatTick()` von Hand getrieben statt über den
//  15-s-Timer. Das Netz stubbt `MockURLProtocol` (Definition in APIClientTests).
//
//  Non-hosted Logic-Bundle: WritingTimeTracker/LibraryStore sind direkt Mitglied
//  des Test-Targets (kein @testable import).
//

import XCTest

@MainActor
final class WritingTimeTrackerTests: XCTestCase {

    /// Gestellte Uhr — Tests schieben sie in Sekunden vor.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Protokolliert die abgesetzten Pings und hält den Antwort-Status. Eigene
    /// (thread-sichere) Klasse, weil der URLProtocol-Handler NICHT auf dem
    /// MainActor läuft — direkter Zugriff auf Test-Properties wäre eine
    /// Isolationsverletzung.
    private final class PingRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var pings: [(book: Int, seconds: Int)] = []
        private var status = 200

        func record(book: Int, seconds: Int) {
            lock.lock(); defer { lock.unlock() }
            pings.append((book, seconds))
        }
        var all: [(book: Int, seconds: Int)] {
            lock.lock(); defer { lock.unlock() }
            return pings
        }
        var responseStatus: Int {
            get { lock.lock(); defer { lock.unlock() }; return status }
            set { lock.lock(); defer { lock.unlock() }; status = newValue }
        }
    }

    private var clock = TestClock()
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var recorder = PingRecorder()
    /// Sekunden aller abgesetzten Pings, in Reihenfolge.
    private var sentSeconds: [Int] { recorder.all.map(\.seconds) }

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
        suiteName = "writingtime-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        clock = TestClock()
        recorder = PingRecorder()
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Aufbau

    private func makeTracker(signedIn: Bool = true) -> WritingTimeTracker {
        let recorder = self.recorder
        MockURLProtocol.handler = { req in
            if let body = req.httpBodyStreamData(),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let book = json["book_id"] as? Int, let secs = json["seconds"] as? Int {
                recorder.record(book: book, seconds: secs)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: recorder.responseStatus,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("{}".utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_token" }, session: URLSession(configuration: cfg))
        return WritingTimeTracker(api: api,
                                  isSignedIn: { signedIn },
                                  now: { [clock] in clock.now },
                                  defaults: defaults,
                                  observeTermination: false)
    }

    /// Bringt den Tracker in den zählenden Zustand (Fenster aktiv, Seite offen).
    private func startCounting(_ t: WritingTimeTracker, book: Int = 7) {
        t.setActive(true)
        t.updateContext(bookId: book, hasOpenPage: true)
    }

    // MARK: - Zähl-Bedingung

    func testCountsOnlyWithActiveWindowAndOpenPage() async {
        let t = makeTracker()
        // Fenster aktiv, aber keine Seite offen → kein Segment, nichts gezählt.
        t.setActive(true)
        t.updateContext(bookId: 7, hasOpenPage: false)
        clock.advance(30)
        await t.heartbeatTick()
        XCTAssertTrue(t.pendingSeconds.isEmpty, "ohne offene Seite darf nichts gezählt werden")

        // Seite öffnen → ab jetzt zählt es.
        t.updateContext(bookId: 7, hasOpenPage: true)
        clock.advance(30)
        await t.heartbeatTick()
        XCTAssertEqual(sentSeconds, [30])
    }

    func testNoCountingWithoutBook() async {
        let t = makeTracker()
        t.setActive(true)
        t.updateContext(bookId: nil, hasOpenPage: true)
        clock.advance(60)
        await t.heartbeatTick()
        XCTAssertTrue(t.pendingSeconds.isEmpty)
        XCTAssertTrue(sentSeconds.isEmpty)
    }

    func testDeactivatingWindowCapturesRunningSegment() async {
        let t = makeTracker()
        startCounting(t)
        clock.advance(45)
        t.setActive(false)          // Fenster in den Hintergrund → Segment schliessen
        XCTAssertEqual(t.todaySeconds, 45)
    }

    // MARK: - Idle-Deckel

    func testIdleCapsCreditAtThreshold() async {
        let t = makeTracker()
        startCounting(t)            // Segment-Start zählt als Aktivität
        clock.advance(300)          // 5 min ohne Tippen
        let result = await t.heartbeatTick()
        XCTAssertEqual(result, .paused, "nach 300 s ohne Aktivität muss der Heartbeat pausieren")
        XCTAssertEqual(t.todaySeconds, 120, "anrechenbar ist nur bis letzte Aktivität + 120 s")
        XCTAssertEqual(sentSeconds, [120])
    }

    func testTypingKeepsTheClockRunning() async {
        let t = makeTracker()
        startCounting(t)
        // Alle 60 s tippen → nie idle, volle Zeit wird angerechnet.
        for _ in 0..<3 {
            clock.advance(60)
            t.notifyActivity()
            let r = await t.heartbeatTick()
            XCTAssertEqual(r, .counting)
        }
        XCTAssertEqual(t.todaySeconds, 180)
    }

    func testActivityResumesPausedSegment() async {
        let t = makeTracker()
        startCounting(t)
        clock.advance(300)
        await t.heartbeatTick()                 // idle → pausiert bei 120 s
        XCTAssertEqual(t.todaySeconds, 120)

        // Weiterschlafen darf nichts kosten …
        clock.advance(600)
        t.notifyActivity()                      // … erst das Tippen startet neu
        clock.advance(20)
        await t.heartbeatTick()
        XCTAssertEqual(t.todaySeconds, 140, "die Idle-Phase selbst darf nicht zählen")
    }

    // MARK: - Buchwechsel

    func testBookSwitchCreditsTimeToPreviousBook() async {
        let t = makeTracker()
        startCounting(t, book: 7)
        clock.advance(50)
        recorder.responseStatus = 500                        // offline → Puffer bleibt prüfbar
        t.updateContext(bookId: 9, hasOpenPage: true)
        XCTAssertEqual(t.pendingSeconds[7], 50, "gezählte Zeit gehört dem alten Buch")
        XCTAssertNil(t.pendingSeconds[9])

        clock.advance(30)
        t.notifyActivity()
        await t.heartbeatTick()
        XCTAssertEqual(t.pendingSeconds[9], 30)
        XCTAssertEqual(t.pendingSeconds[7], 50, "das alte Buch darf nicht umgebucht werden")
    }

    // MARK: - Uhrsprung / Ping-Deckel

    func testBackwardsClockJumpCreditsNothing() async {
        let t = makeTracker()
        startCounting(t)
        clock.advance(-120)                     // Uhr zurückgestellt
        await t.heartbeatTick()
        XCTAssertTrue(t.pendingSeconds.isEmpty)
        XCTAssertEqual(t.todaySeconds, 0)
    }

    func testPingIsCappedAtServerLimitAndDrainsOverTicks() async {
        // Grossen Rückstand (z. B. lange offline) über den persistierten Puffer
        // einspielen, statt ihn über viele Ticks aufzubauen.
        defaults.set(["7": 5000], forKey: "writingtime.pending.\(ServerNamespace.currentSlug)")
        let t = makeTracker()
        XCTAssertEqual(t.pendingSeconds[7], 5000)

        await t.heartbeatTick()
        XCTAssertEqual(recorder.all.first?.seconds, 3600, "ein Ping ist auf 3600 s gedeckelt")
        XCTAssertEqual(t.pendingSeconds[7], 1400, "der Überhang bleibt für den nächsten Tick")

        await t.heartbeatTick()
        XCTAssertEqual(sentSeconds, [3600, 1400], "der Rest drainiert über den nächsten Tick")
        XCTAssertTrue(t.pendingSeconds.isEmpty)
    }

    // MARK: - Puffer: Fehler, Persistenz, Neustart

    func testFailedPingKeepsSecondsBuffered() async {
        let t = makeTracker()
        recorder.responseStatus = 500
        startCounting(t)
        clock.advance(40)
        await t.heartbeatTick()
        XCTAssertEqual(t.pendingSeconds[7], 40, "fehlgeschlagener Ping darf nichts verwerfen")

        recorder.responseStatus = 200
        clock.advance(20)
        t.notifyActivity()
        await t.heartbeatTick()
        XCTAssertTrue(t.pendingSeconds.isEmpty, "nach dem erfolgreichen Ping ist der Puffer leer")
        XCTAssertEqual(recorder.all.last?.seconds, 60, "gepufferte + neue Sekunden zusammen")
    }

    func testPendingBufferSurvivesRestart() async {
        let t = makeTracker()
        recorder.responseStatus = 500
        startCounting(t)
        clock.advance(40)
        await t.heartbeatTick()
        XCTAssertEqual(t.pendingSeconds[7], 40)

        // „Neustart": neue Instanz auf derselben Defaults-Suite.
        let fresh = makeTracker()
        XCTAssertEqual(fresh.pendingSeconds[7], 40, "der Puffer muss den Neustart überleben")
    }

    func testSignedOutDoesNotCountOrSend() async {
        let t = makeTracker(signedIn: false)
        startCounting(t)
        clock.advance(60)
        await t.heartbeatTick()
        XCTAssertTrue(sentSeconds.isEmpty)
        XCTAssertTrue(t.pendingSeconds.isEmpty, "abgemeldet wird gar nicht erst gezählt")
    }

    // MARK: - Tages-Summe

    func testTodaySecondsAccumulateAndPersist() async {
        let t = makeTracker()
        startCounting(t)
        clock.advance(30)
        await t.heartbeatTick()
        clock.advance(30)
        t.notifyActivity()
        await t.heartbeatTick()
        XCTAssertEqual(t.todaySeconds, 60)

        let fresh = makeTracker()
        XCTAssertEqual(fresh.todaySeconds, 60, "die Tages-Summe muss den Neustart überleben")
    }

    func testTodaySecondsResetOnDayRollover() async {
        let t = makeTracker()
        startCounting(t)
        clock.advance(30)
        await t.heartbeatTick()
        XCTAssertEqual(t.todaySeconds, 30)

        // Nächster Kalendertag → frische Instanz beginnt bei 0.
        clock.advance(24 * 3600)
        let fresh = makeTracker()
        XCTAssertEqual(fresh.todaySeconds, 0)
    }
}

// MARK: - Hilfen

private extension URLRequest {
    /// `httpBody` ist bei einem über `URLSession` gestellten Upload nil — der Body
    /// steckt im `httpBodyStream`. Liest ihn vollständig aus.
    func httpBodyStreamData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
