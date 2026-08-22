//
//  LektoratJobStoreTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Der Lektorats-Job (`POST /jobs/check` + `GET /jobs/:id`-Poll) hat mehr
//  Zustände als jeder andere Netz-Pfad im Client, und alle enden in einem
//  Banner über der Schreibfläche. Geprüft werden die Übergänge, die man von
//  Hand kaum nachstellt: der Reihenfolge-Vertrag (erst sichern + pushen, DANN
//  den Job anlegen — sonst lektoriert der Server einen veralteten Text), das
//  Überspringen transienter Lesefehler, der Deckel und das Abbrechen.
//
//  Poll-Kadenz und Deckel sind für den Test in Millisekunden gesetzt
//  (`pollInterval`/`maxPolls` im Initializer) — sonst liefe eine Timeout-Probe
//  echte sechs Minuten.
//

import XCTest

@MainActor
final class LektoratJobStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Ein Skript aus Antworten: `POST /jobs/check` und danach je ein
    /// `GET /jobs/:id` pro Eintrag in `pollResponses` (der letzte wiederholt
    /// sich). `nil` steht für einen Transportfehler.
    private func makeStore(
        createStatus: Int = 200,
        createJSON: String = #"{"jobId":"job-1"}"#,
        pollResponses: [(status: Int, json: String)?] = [],
        maxPolls: Int = 8,
        prepare: @escaping () async -> Void = {}
    ) -> (LektoratJobStore, () -> [String]) {
        var calls: [String] = []
        var pollIndex = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            calls.append("\(request.httpMethod ?? "?") \(path)")
            if path.hasSuffix("/jobs/check") {
                let response = HTTPURLResponse(url: request.url!, statusCode: createStatus,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(createJSON.utf8))
            }
            if request.httpMethod == "DELETE" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"ok":true}"#.utf8))
            }
            // Poll
            let entry = pollResponses.isEmpty ? nil
                : pollResponses[min(pollIndex, pollResponses.count - 1)]
            pollIndex += 1
            guard let entry else { throw URLError(.networkConnectionLost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: entry.status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, Data(entry.json.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_test" },
                            session: URLSession(configuration: cfg))
        let store = LektoratJobStore(api: api,
                                     pollInterval: .milliseconds(5),
                                     maxPolls: maxPolls,
                                     prepare: prepare)
        return (store, { calls })
    }

    /// Wartet, bis der Store terminal ist (oder die Frist reisst).
    private func waitForTerminal(_ store: LektoratJobStore,
                                 timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isBusy || store.phase == .idle {
            if Date() > deadline { return XCTFail("Store wurde nicht terminal: \(store.phase)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Erfolgsfall

    func testCountsFindingsFromFinishedJob() async throws {
        let (store, _) = makeStore(pollResponses: [
            (200, #"{"status":"running","progress":40}"#),
            (200, #"{"status":"done","result":{"fehler":[{"a":1},{"a":2},{"a":3}]}}"#),
        ])
        store.start(pageId: 42, bookId: 7, pageName: "Kapitel 1")
        try await waitForTerminal(store)
        XCTAssertEqual(store.phase, .done(count: 3))
    }

    /// Eine leere Seite liefert `empty: true` ohne `fehler`-Array — das sind
    /// null Beanstandungen, kein Fehler.
    func testEmptyPageResultCountsAsZeroFindings() async throws {
        let (store, _) = makeStore(pollResponses: [(200, #"{"status":"done","result":{"empty":true}}"#)])
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        XCTAssertEqual(store.phase, .done(count: 0))
    }

    // MARK: - Reihenfolge-Vertrag

    /// Der Server lektoriert den SERVER-Stand. Läuft `prepare` (Draft sichern +
    /// pushen) nicht VOR dem Anlegen des Jobs, prüft er den Text von vorgestern.
    func testPrepareRunsBeforeTheJobIsCreated() async throws {
        var order: [String] = []
        let (store, calls) = makeStore(
            pollResponses: [(200, #"{"status":"done","result":{"fehler":[]}}"#)],
            prepare: { order.append("prepare") })
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        XCTAssertEqual(order, ["prepare"], "prepare muss genau einmal laufen")
        XCTAssertTrue(calls().first?.contains("/jobs/check") == true,
                      "erster Request muss das Anlegen sein: \(calls())")
    }

    func testPhaseIsPreparingBeforeTheJobStarts() async throws {
        let gate = AsyncGate()
        let (store, _) = makeStore(
            pollResponses: [(200, #"{"status":"done","result":{"fehler":[]}}"#)],
            prepare: { await gate.wait() })
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.phase, .preparing)
        await gate.open()
        try await waitForTerminal(store)
    }

    // MARK: - Fehlerfälle

    func testForbiddenReportsMissingRole() async throws {
        let (store, _) = makeStore(createStatus: 403, createJSON: #"{"error_code":"FORBIDDEN"}"#)
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        guard case .failed = store.phase else {
            return XCTFail("erwartet .failed, bekam \(store.phase)")
        }
    }

    /// Antwort ohne `jobId` — der Server hat den Job nicht angelegt. Kein
    /// endloses Pollen auf eine leere ID.
    func testMissingJobIdFailsImmediately() async throws {
        let (store, calls) = makeStore(createJSON: #"{}"#)
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        guard case .failed = store.phase else {
            return XCTFail("erwartet .failed, bekam \(store.phase)")
        }
        XCTAssertFalse(calls().contains { $0.contains("GET /jobs/") && !$0.contains("check") },
                       "ohne jobId darf nicht gepollt werden: \(calls())")
    }

    func testServerSideJobErrorReportsFailure() async throws {
        let (store, _) = makeStore(pollResponses: [(200, #"{"status":"error","error":"jobs.err.provider"}"#)])
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        guard case .failed = store.phase else {
            return XCTFail("erwartet .failed, bekam \(store.phase)")
        }
    }

    /// Ein zuckendes Netz darf den Lauf NICHT beenden — der Job läuft
    /// serverseitig weiter, der Client pollt einfach nochmal.
    func testTransientPollFailureIsSkipped() async throws {
        let (store, _) = makeStore(pollResponses: [
            nil,                                                   // Transportfehler
            nil,
            (200, #"{"status":"done","result":{"fehler":[{"a":1}]}}"#),
        ])
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        XCTAssertEqual(store.phase, .done(count: 1), "transiente Lesefehler dürfen nicht abbrechen")
    }

    /// Antwortet der Job dauerhaft „running", greift der Deckel — sonst hinge
    /// der Banner für immer im Spinner.
    func testPollCapEndsWithTimeout() async throws {
        let (store, _) = makeStore(pollResponses: [(200, #"{"status":"running","progress":10}"#)],
                                   maxPolls: 3)
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        guard case .failed = store.phase else {
            return XCTFail("erwartet .failed (Timeout), bekam \(store.phase)")
        }
    }

    // MARK: - Abbrechen

    func testCancelStopsPollingAndCancelsTheServerJob() async throws {
        let (store, calls) = makeStore(pollResponses: [(200, #"{"status":"running","progress":10}"#)],
                                       maxPolls: 200)
        store.start(pageId: 1, bookId: nil, pageName: nil)
        // Warten, bis der Job angelegt ist (sonst gibt es keine ID zum Stornieren).
        try await Task.sleep(for: .milliseconds(60))
        store.cancel()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(calls().contains { $0.hasPrefix("DELETE /jobs/") },
                      "Abbrechen muss den Server-Job stornieren: \(calls())")
    }

    func testSecondStartWhileBusyIsIgnored() async throws {
        let (store, _) = makeStore(pollResponses: [(200, #"{"status":"running","progress":10}"#)],
                                   maxPolls: 200)
        store.start(pageId: 1, bookId: nil, pageName: "Erste")
        try await Task.sleep(for: .milliseconds(30))
        store.start(pageId: 2, bookId: nil, pageName: "Zweite")
        XCTAssertEqual(store.pageId, 1, "ein laufender Lauf darf nicht überschrieben werden")
        store.cancel()
    }

    // MARK: - Ohne API

    func testWithoutAPIFailsInsteadOfHanging() async throws {
        let store = LektoratJobStore(api: nil)
        store.start(pageId: 1, bookId: nil, pageName: nil)
        try await waitForTerminal(store)
        guard case .failed = store.phase else {
            return XCTFail("erwartet .failed, bekam \(store.phase)")
        }
    }
}

/// Minimales Tor, um `prepare` im Test anzuhalten und den `.preparing`-Zustand
/// beobachtbar zu machen.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
