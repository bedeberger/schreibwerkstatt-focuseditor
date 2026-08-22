//
//  LibraryStoreTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Unit-Tests der Buch-/Seitenauswahl — ohne Server und ohne WebView. Deckt die
//  Pfade ab, an denen in der Vergangenheit echte Fehler sassen:
//    • Buchwechsel-Race: eine späte Tree-Antwort des ALTEN Buchs darf die Seiten
//      des neuen nicht überschreiben.
//    • Buchwechsel-Ablauf: offene Seite zu, Lade-Zustand, Picker-Anforderung.
//    • Offline-Fallback der Seitenliste (lokaler Spiegel) inkl. Fehlermeldung nur
//      dann, wenn auch lokal nichts da ist.
//    • Optimistisches `openPage` samt Rollback, wenn keine WebView hängt.
//    • Der Schreibzeit-Kontext-Callback (`onWritingContextChange`).
//
//  HTTP stubbt `MockURLProtocol` (Definition in APIClientTests), der lokale
//  Spiegel ist ein echter GRDB-Store auf einer temporären Datei, und das aktive
//  Buch landet in einer eigenen UserDefaults-Suite (keine Standard-Defaults).
//

import XCTest

@MainActor
final class LibraryStoreTests: XCTestCase {

    /// Antwort-Tabelle nach Pfad (thread-sicher — der URLProtocol-Handler läuft
    /// nicht auf dem MainActor). `delay` simuliert eine langsame Route, um das
    /// Buchwechsel-Race deterministisch zu treffen.
    private final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: (status: Int, json: String, delay: TimeInterval)] = [:]

        func set(_ path: String, status: Int = 200, json: String = "{}", delay: TimeInterval = 0) {
            lock.lock(); defer { lock.unlock() }
            table[path] = (status, json, delay)
        }
        func lookup(_ path: String) -> (status: Int, json: String, delay: TimeInterval)? {
            lock.lock(); defer { lock.unlock() }
            return table[path]
        }
    }

    private var routes = Routes()
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var dbURL: URL!
    private var store: GRDBLocalStore!
    private var bridge: EditorBridge!

    override func setUp() {
        super.setUp()
        ServerConfig.baseURLString = "http://127.0.0.1:3737"
        routes = Routes()
        suiteName = "library-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarystore-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        bridge = nil
        try? FileManager.default.removeItem(at: dbURL)
        super.tearDown()
    }

    // MARK: - Aufbau

    private func makeStore() throws -> LibraryStore {
        let routes = self.routes
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            guard let hit = routes.lookup(path) else { throw URLError(.cannotConnectToHost) }
            if hit.delay > 0 { Thread.sleep(forTimeInterval: hit.delay) }
            let resp = HTTPURLResponse(url: req.url!, statusCode: hit.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data(hit.json.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(tokenProvider: { "swd_token" }, session: URLSession(configuration: cfg))
        store = try GRDBLocalStore(url: dbURL)
        bridge = EditorBridge(store: store, api: api)
        return LibraryStore(content: ContentAPI(api: api), store: store, bridge: bridge, defaults: defaults)
    }

    /// Ein Tree mit `pages` als Top-Level-Seiten (Name = „Seite <id>").
    private func treeJSON(topPageIds: [Int], chapter: (id: Int, name: String, pageIds: [Int])? = nil) -> String {
        func page(_ id: Int, chapter: Int?) -> String {
            let ch = chapter.map(String.init) ?? "null"
            return #"{"id":\#(id),"chapter_id":\#(ch),"name":"Seite \#(id)","position":\#(id),"updated_at":null}"#
        }
        let top = topPageIds.map { page($0, chapter: nil) }.joined(separator: ",")
        guard let chapter else { return #"{"chapters":[],"topPages":[\#(top)]}"# }
        let inner = chapter.pageIds.map { page($0, chapter: chapter.id) }.joined(separator: ",")
        return #"""
        {"chapters":[{"id":\#(chapter.id),"name":"\#(chapter.name)","position":1,"parent_chapter_id":null,"pages":[\#(inner)],"subchapters":[]}],"topPages":[\#(top)]}
        """#
    }

    // MARK: - Bücher laden

    func testLoadBooksSelectsFirstBookWhenNoneActive() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"Roman","slug":"roman"},{"id":12,"name":"Notizen","slug":"n"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101, 102]))
        let lib = try makeStore()

        await lib.loadBooks()
        XCTAssertTrue(lib.booksLoaded)
        XCTAssertEqual(lib.books.count, 2)
        XCTAssertEqual(lib.activeBookId, 11, "ohne gespeicherte Wahl gewinnt das erste Buch")
        XCTAssertEqual(defaults.integer(forKey: "library.activeBookId.\(ServerNamespace.currentSlug)"), 11)

        // Die erste Auswahl lädt die Seiten nach (Task in selectBook).
        try await waitUntil { lib.pages.count == 2 }
        XCTAssertEqual(lib.pages.map(\.name), ["Seite 101", "Seite 102"])
    }

    func testLoadBooksKeepsSavedBookAndReportsError() async throws {
        defaults.set(12, forKey: "library.activeBookId.\(ServerNamespace.currentSlug)")
        routes.set("/content/books", json: #"[{"id":11,"name":"Roman","slug":"roman"},{"id":12,"name":"Notizen","slug":"n"}]"#)
        routes.set("/content/books/12/tree", json: treeJSON(topPageIds: [201]))
        let lib = try makeStore()
        XCTAssertEqual(lib.activeBookId, 12, "gespeichertes Buch wird beim Start übernommen")

        await lib.loadBooks()
        XCTAssertEqual(lib.activeBookId, 12, "gültige gespeicherte Wahl bleibt bestehen")
        XCTAssertEqual(lib.pages.map(\.id), [201])
        XCTAssertNil(lib.lastError)
    }

    func testLoadBooksFailureSetsErrorAndKeepsBooksUnloaded() async throws {
        // Keine Route registriert → Verbindungsfehler.
        let lib = try makeStore()
        await lib.loadBooks()
        XCTAssertFalse(lib.booksLoaded)
        XCTAssertNotNil(lib.lastError)
        XCTAssertTrue(lib.books.isEmpty)
    }

    // MARK: - Buchwechsel

    func testBookSwitchClosesPageAndRequestsPicker() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"},{"id":12,"name":"B","slug":"b"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101]))
        routes.set("/content/books/12/tree", json: treeJSON(topPageIds: [201, 202]))
        let lib = try makeStore()
        await lib.loadBooks()
        try await waitUntil { lib.pages.count == 1 }

        let requestsBefore = lib.pickerOpenRequest
        lib.selectBook(12)
        XCTAssertEqual(lib.activeBookId, 12)
        XCTAssertNil(lib.openPageId, "beim Wechsel wird die offene Seite sofort geschlossen")
        XCTAssertTrue(lib.isSwitchingBook, "bis die Seiten geladen sind, läuft der Wechsel")

        try await waitUntil { !lib.isSwitchingBook }
        XCTAssertEqual(lib.pages.map(\.id), [201, 202])
        XCTAssertEqual(lib.pickerOpenRequest, requestsBefore + 1, "nach dem Wechsel öffnet der Picker")
    }

    func testSelectingSameBookIsNoop() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101]))
        let lib = try makeStore()
        await lib.loadBooks()
        try await waitUntil { lib.pages.count == 1 }

        let requests = lib.pickerOpenRequest
        lib.selectBook(11)
        XCTAssertEqual(lib.pickerOpenRequest, requests, "gleiches Buch → kein Wechsel, kein Picker")
        XCTAssertFalse(lib.isSwitchingBook)
    }

    /// Der Kern des Race: der Tree des ALTEN Buchs antwortet erst, nachdem schon
    /// zum neuen gewechselt wurde — seine Zeilen dürfen nicht landen.
    func testLateTreeResponseOfPreviousBookIsDiscarded() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"},{"id":12,"name":"B","slug":"b"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101, 102]), delay: 0.4)
        routes.set("/content/books/12/tree", json: treeJSON(topPageIds: [201]))
        let lib = try makeStore()

        await lib.loadBooks()                    // wählt 11, startet den langsamen Tree
        XCTAssertEqual(lib.activeBookId, 11)
        lib.selectBook(12)                       // Wechsel, während 11er-Tree noch läuft
        try await waitUntil { !lib.isSwitchingBook }
        XCTAssertEqual(lib.pages.map(\.id), [201])

        // Auch nachdem die späte Antwort eingetroffen sein muss, bleibt es dabei.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(lib.pages.map(\.id), [201], "späte Antwort des alten Buchs darf nicht landen")
        XCTAssertEqual(lib.activeBookId, 12)
    }

    // MARK: - Offline-Fallback der Seitenliste

    func testOfflineFallsBackToLocalMirror() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        // KEIN Tree-Stub → Server nicht erreichbar.
        let lib = try makeStore()
        // Lokalen Spiegel füllen (wie nach einem früheren Pull).
        try await store.applyServerPage(id: "101", html: "<p>Text</p>", pageName: "Lokale Seite",
                                        bookId: 11, chapterId: nil, serverUpdatedAtMillis: 1000)

        await lib.loadBooks()
        try await waitUntil { !lib.pages.isEmpty }
        XCTAssertEqual(lib.pages.map(\.name), ["Lokale Seite"])
        XCTAssertNil(lib.lastError, "solange der lokale Spiegel trägt, keine Fehlermeldung")
    }

    func testOfflineWithEmptyMirrorReportsError() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        let lib = try makeStore()
        await lib.loadBooks()
        try await waitUntil { lib.lastError != nil }
        XCTAssertTrue(lib.pages.isEmpty)
        XCTAssertNotNil(lib.lastError, "ohne lokalen Inhalt muss der wahre Grund sichtbar werden")
    }

    // MARK: - Seite öffnen

    func testOpenPageWithoutWebViewRollsBackOptimisticState() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101]))
        let lib = try makeStore()
        await lib.loadBooks()
        try await waitUntil { lib.pages.count == 1 }

        lib.openPage(lib.pages[0])
        XCTAssertEqual(lib.openPageId, 101, "die Toolbar zeigt die Seite sofort (optimistisch)")
        // Ohne WebView liefert die Bridge false → die Anzeige muss zurückrollen.
        try await waitUntil { lib.openPageId == nil }
    }

    // MARK: - Schreibzeit-Kontext

    func testWritingContextCallbackReportsBookAndOpenPage() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101]))
        let lib = try makeStore()
        var seen: [(Int?, Bool)] = []
        lib.onWritingContextChange = { book, open in seen.append((book, open)) }

        await lib.loadBooks()
        XCTAssertEqual(seen.last?.0, 11)
        XCTAssertEqual(seen.last?.1, false, "Buch gewählt, aber noch keine Seite offen")

        try await waitUntil { lib.pages.count == 1 }
        lib.openPage(lib.pages[0])
        XCTAssertEqual(seen.last?.1, true, "offene Seite meldet den Schreib-Kontext")
    }

    // MARK: - Suche + Save-Fehler

    func testSearchContentIdsUsesLocalMirror() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101, 102]))
        let lib = try makeStore()
        try await store.applyServerPage(id: "101", html: "<p>Vom Leuchtturm aus</p>", pageName: "Kapitel 1",
                                        bookId: 11, chapterId: nil, serverUpdatedAtMillis: 1000)
        try await store.applyServerPage(id: "102", html: "<p>Nichts dergleichen</p>", pageName: "Kapitel 2",
                                        bookId: 11, chapterId: nil, serverUpdatedAtMillis: 1000)
        await lib.loadBooks()
        try await waitUntil { lib.pages.count == 2 }

        let hits = await lib.searchContentIds(query: "leuchtturm")
        XCTAssertEqual(hits, [101])
        let none = await lib.searchContentIds(query: "   ")
        XCTAssertTrue(none.isEmpty, "leere Eingabe sucht nicht")
    }

    func testSaveErrorBannerLifecycle() async throws {
        let lib = try makeStore()
        lib.reportSaveResult("Platte voll")
        XCTAssertEqual(lib.saveError, "Platte voll")
        lib.reportSaveResult(nil)
        XCTAssertNil(lib.saveError, "ein erfolgreicher Save löst den Banner")

        lib.reportSaveResult("DB-Fehler")
        lib.dismissSaveError()
        XCTAssertNil(lib.saveError)
    }

    // MARK: - Widerrufen / Wiederherstellen (Hinweis)

    func testHistoryNoticeOnlyForNotableUndo() async throws {
        let lib = try makeStore()

        // Kleine Korrektur (ein Wort) bleibt still — sonst poppte der Hinweis
        // bei jedem ⌘Z für eine Silbe.
        lib.reportHistoryEdit(undo: true, chars: 12)
        XCTAssertNil(lib.historyNotice, "kleines Undo darf keinen Hinweis zeigen")

        // Ein grosser Wurf muss sichtbar werden: WebKit fasst die ganze
        // Tippstrecke in EINEN Undo-Schritt zusammen.
        lib.reportHistoryEdit(undo: true, chars: 1_240)
        let notice = try XCTUnwrap(lib.historyNotice)
        XCTAssertTrue(notice.isUndo)
        XCTAssertEqual(notice.chars, 1_240)

        // Wiederherstellen ersetzt den Hinweis (eigene Meldung, kein Stapel).
        lib.reportHistoryEdit(undo: false, chars: 1_240)
        let redo = try XCTUnwrap(lib.historyNotice)
        XCTAssertFalse(redo.isUndo)
        XCTAssertNotEqual(redo.id, notice.id, "neue Meldung, nicht die alte recycelt")

        lib.dismissHistoryNotice()
        XCTAssertNil(lib.historyNotice)
    }

    // MARK: - Zuletzt geöffnete Seiten (Picker-Gruppe)

    func testRecentPageRowsResolveAgainstActiveBookInMRUOrder() async throws {
        routes.set("/content/books", json: #"[{"id":11,"name":"A","slug":"a"}]"#)
        routes.set("/content/books/11/tree", json: treeJSON(topPageIds: [101, 102, 103]))
        // Historie: 102 zuletzt, dann 101; 999 existiert nicht (mehr) im Buch.
        EditorBridge.pushRecentPageId("101", forBook: 11, defaults: defaults)
        EditorBridge.pushRecentPageId("999", forBook: 11, defaults: defaults)
        EditorBridge.pushRecentPageId("102", forBook: 11, defaults: defaults)
        // Andere Bücher dürfen nicht durchschlagen.
        EditorBridge.pushRecentPageId("777", forBook: 12, defaults: defaults)

        let lib = try makeStore()
        await lib.loadBooks()
        try await waitUntil { lib.pages.count == 3 }

        XCTAssertEqual(lib.recentPageRows().map(\.id), [102, 101],
                       "MRU-Reihenfolge, unbekannte Seiten fallen raus")
        XCTAssertEqual(lib.recentPageRows(limit: 1).map(\.id), [102])
    }

    func testRecentHistoryDedupesAndCapsAtLimit() {
        for id in 1...7 { EditorBridge.pushRecentPageId(String(id), forBook: 11, defaults: defaults) }
        XCTAssertEqual(EditorBridge.recentPageIds(forBook: 11, defaults: defaults),
                       ["7", "6", "5", "4", "3"], "jüngste zuerst, auf 5 gekürzt")

        EditorBridge.pushRecentPageId("4", forBook: 11, defaults: defaults)
        XCTAssertEqual(EditorBridge.recentPageIds(forBook: 11, defaults: defaults),
                       ["4", "7", "6", "5", "3"], "erneutes Öffnen rückt vor, ohne Duplikat")

        // Schon vorne → kein erneutes Schreiben (editorState feuert bei jedem
        // Dirty-Wechsel); die Liste bleibt identisch.
        EditorBridge.pushRecentPageId("4", forBook: 11, defaults: defaults)
        XCTAssertEqual(EditorBridge.recentPageIds(forBook: 11, defaults: defaults),
                       ["4", "7", "6", "5", "3"])
        XCTAssertTrue(EditorBridge.recentPageIds(forBook: 12, defaults: defaults).isEmpty)
    }

    // MARK: - Hilfen

    /// Pollt eine Bedingung auf dem MainActor (die Stores arbeiten mit
    /// unbeobachtbaren `Task`s — Warten ist verlässlicher als `expectation`).
    private func waitUntil(timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Bedingung nicht innerhalb von \(timeout)s erfüllt", file: file, line: line)
    }
}
