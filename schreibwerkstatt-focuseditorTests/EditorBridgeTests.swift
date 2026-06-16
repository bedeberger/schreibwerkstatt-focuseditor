//
//  EditorBridgeTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Unit-Tests der Bridge-Dispatch (`EditorBridge.route`) — die EINZIGE
//  Kopplungsschicht WebView ⇄ Swift-Kern. Treibt die Ops direkt (ohne WebView/
//  `WKScriptMessage`/Netz) gegen einen reinen In-Memory-`FakeLocalStore`.
//
//  Non-hosted Logic-Bundle: EditorBridge + Abhängigkeiten (LocalStore,
//  EditorCoordinating, TypographyController, FocusController) sind direkt Mitglied
//  dieses Targets (kein @testable import). Der Store hier ist BEWUSST nicht
//  `InMemoryLocalStore` — der schriebe einen JSON-Snapshot nach Application
//  Support (Pfad der echten App) und wäre damit weder deterministisch noch
//  nebenwirkungsfrei. `FakeLocalStore` hält alles im Speicher.
//

import XCTest

/// Reiner In-Memory-Spiegel für die Tests — kein Disk-I/O, kein AppSupport.
@MainActor
private final class FakeLocalStore: LocalStore {
    var pages: [String: StoredPage] = [:]
    var outbox: [String: OutboxEntry] = [:]
    /// Monoton hochgezählter „Server-Stempel“ (Epoch-ms-Ersatz) für deterministische
    /// `updatedAt`-Werte ohne Uhr.
    private var clock: Double = 1000

    private func tick() -> Double { clock += 1; return clock }

    func page(id: String) async throws -> StoredPage? { pages[id] }

    func list(bookId: Int?) async throws -> [PageSummary] {
        pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .map { PageSummary(id: $0.id, title: $0.title, pageName: $0.pageName,
                               bookId: $0.bookId, chapterId: $0.chapterId, updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        // No-op-Guard wie die echten Stores: inhaltsgleicher Save erzeugt keinen
        // neuen Outbox-Eintrag.
        if let existing = pages[id], existing.html == html { return existing }
        let now = tick()
        let page = StoredPage(id: id, html: html, title: PageTitle.derive(from: html),
                              pageName: pages[id]?.pageName, bookId: pages[id]?.bookId,
                              chapterId: pages[id]?.chapterId, updatedAt: now,
                              baseUpdatedAt: baseUpdatedAt ?? pages[id]?.baseUpdatedAt)
        pages[id] = page
        outbox[id] = OutboxEntry(pageId: id, html: html, baseUpdatedAt: page.baseUpdatedAt, queuedAt: now)
        return page
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        outbox.values.sorted { $0.queuedAt < $1.queuedAt }
    }

    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        guard let e = outbox[id], e.queuedAt == queuedAt else { return false }
        outbox[id] = nil
        pages[id]?.baseUpdatedAt = serverUpdatedAtMillis
        return true
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?,
                         chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        pages[id] = StoredPage(id: id, html: html, title: PageTitle.derive(from: html),
                               pageName: pageName, bookId: bookId, chapterId: chapterId,
                               updatedAt: serverUpdatedAtMillis, baseUpdatedAt: serverUpdatedAtMillis)
    }

    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?,
                                chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool {
        if outbox[id] != nil { return false }
        try await applyServerPage(id: id, html: html, pageName: pageName, bookId: bookId,
                                  chapterId: chapterId, serverUpdatedAtMillis: serverUpdatedAtMillis)
        return true
    }

    func deletePage(id: String) async throws { pages[id] = nil; outbox[id] = nil }

    func pageIdsWithoutBook() async throws -> [String] {
        pages.values.filter { $0.bookId == nil }.map(\.id)
    }

    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        guard pages[pageId] != nil else { return }
        pages[pageId]?.bookId = bookId
        if let chapterId { pages[pageId]?.chapterId = chapterId }
    }

    func switchToCurrentServer() async throws {}
}

@MainActor
final class EditorBridgeTests: XCTestCase {

    private func makeBridge() -> (EditorBridge, FakeLocalStore) {
        let store = FakeLocalStore()
        // Ohne APIClient: die Spellcheck-/Nachlade-Pfade laufen offline-still,
        // die hier getesteten lokalen Ops brauchen kein Netz.
        let bridge = EditorBridge(store: store)
        return (bridge, store)
    }

    // MARK: save → LocalStore + Outbox

    func testSaveCreatesPageAndOutboxEntry() async throws {
        let (bridge, store) = makeBridge()
        let result = try await bridge.route(op: "save",
                                            params: ["pageId": "p1", "html": "<p>Hallo</p>"])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["id"] as? String, "p1")

        XCTAssertEqual(store.pages["p1"]?.html, "<p>Hallo</p>", "Save muss local-first spiegeln")
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.pageId), ["p1"], "Save muss genau einen Outbox-Eintrag anlegen")
    }

    func testSaveIdenticalHtmlIsNoOp() async throws {
        let (bridge, store) = makeBridge()
        _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": "<p>x</p>"])
        // Ersten (echten) Eintrag quittieren, dann inhaltsgleich erneut speichern.
        let pendingBefore = try await store.pendingOutbox()
        let first = try XCTUnwrap(pendingBefore.first)
        try await store.markPushed(id: "p1", queuedAt: first.queuedAt, serverUpdatedAtMillis: 9999)
        _ = try await bridge.route(op: "save", params: ["pageId": "p1", "html": "<p>x</p>"])
        let afterPending = try await store.pendingOutbox()
        XCTAssertTrue(afterPending.isEmpty,
                      "Inhaltsgleicher Save darf keinen neuen Outbox-Eintrag erzeugen")
    }

    func testSaveMissingHtmlThrows() async throws {
        let (bridge, _) = makeBridge()
        await assertThrowsBridgeError(missingParam: "html") {
            _ = try await bridge.route(op: "save", params: ["pageId": "p1"])
        }
    }

    // MARK: load → local-first

    func testLoadReturnsMirroredPage() async throws {
        let (bridge, store) = makeBridge()
        try await store.applyServerPage(id: "p7", html: "<p>Server</p>", pageName: "S7",
                                        bookId: 3, chapterId: nil, serverUpdatedAtMillis: 42)
        let result = try await bridge.route(op: "load", params: ["pageId": "p7"])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["id"] as? String, "p7")
        XCTAssertEqual(dict["html"] as? String, "<p>Server</p>")
    }

    func testLoadUnknownWithoutApiReturnsNil() async throws {
        let (bridge, _) = makeBridge()
        // Kein lokaler Spiegel, kein APIClient → still nil (kein Fehler).
        let result = try await bridge.route(op: "load", params: ["pageId": "ghost"])
        XCTAssertNil(result)
    }

    func testLoadMissingPageIdThrows() async throws {
        let (bridge, _) = makeBridge()
        await assertThrowsBridgeError(missingParam: "pageId") {
            _ = try await bridge.route(op: "load", params: [:])
        }
    }

    // MARK: list → Buch-Filter

    func testListFiltersByBook() async throws {
        let (bridge, store) = makeBridge()
        try await store.applyServerPage(id: "a", html: "<p>a</p>", pageName: nil, bookId: 1, chapterId: nil, serverUpdatedAtMillis: 1)
        try await store.applyServerPage(id: "b", html: "<p>b</p>", pageName: nil, bookId: 2, chapterId: nil, serverUpdatedAtMillis: 2)

        let allResult = try await bridge.route(op: "list", params: [:])
        let all = try XCTUnwrap(allResult as? [[String: Any]])
        XCTAssertEqual(all.count, 2)

        let book1Result = try await bridge.route(op: "list", params: ["bookId": 1])
        let book1 = try XCTUnwrap(book1Result as? [[String: Any]])
        XCTAssertEqual(book1.map { $0["id"] as? String }, ["a"])
    }

    // MARK: editorState → Dirty-Tracking + openPageId

    func testEditorStateTracksDirtyAndOpenPage() async throws {
        let (bridge, _) = makeBridge()
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": true])
        XCTAssertEqual(bridge.openPageId, "p1")
        XCTAssertTrue(bridge.isDirty("p1"), "dirty=true muss die Seite als dirty markieren")

        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": false])
        XCTAssertFalse(bridge.isDirty("p1"), "dirty=false muss das Flag löschen")
    }

    func testEditorStateNotifiesDirtyChange() async throws {
        let (bridge, _) = makeBridge()
        var received: [Bool] = []
        bridge.onOpenDirtyChange = { received.append($0) }
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": true])
        _ = try await bridge.route(op: "editorState", params: ["pageId": "p1", "dirty": false])
        XCTAssertEqual(received, [true, false], "Save-Indikator muss bei echten Wechseln feuern")
    }

    // MARK: reportStats → Callback

    func testReportStatsForwardsToCallback() async throws {
        let (bridge, _) = makeBridge()
        var seen: (String?, Int, Int)?
        bridge.onStats = { seen = ($0, $1, $2) }
        _ = try await bridge.route(op: "reportStats",
                                   params: ["pageId": "p1", "words": 12, "chars": 80])
        XCTAssertEqual(seen?.0, "p1")
        XCTAssertEqual(seen?.1, 12)
        XCTAssertEqual(seen?.2, 80)
    }

    // MARK: Boot-Pull-Ops

    func testFocusGranularityIsReturned() async throws {
        let (bridge, _) = makeBridge()
        let result = try await bridge.route(op: "focusGranularity", params: [:])
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertNotNil(dict["granularity"] as? String)
    }

    // MARK: Unbekannte Op

    func testUnknownOpThrows() async throws {
        let (bridge, _) = makeBridge()
        do {
            _ = try await bridge.route(op: "doesNotExist", params: [:])
            XCTFail("unbekannte Op muss werfen")
        } catch let BridgeError.unknownOp(op) {
            XCTAssertEqual(op, "doesNotExist")
        }
    }

    // MARK: Hilfe

    /// Erwartet `BridgeError.missingParam(key)` aus dem `body`.
    private func assertThrowsBridgeError(missingParam key: String,
                                         _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("erwarteter BridgeError.missingParam(\(key)) blieb aus")
        } catch let BridgeError.missingParam(k) {
            XCTAssertEqual(k, key)
        } catch {
            XCTFail("falscher Fehler: \(error)")
        }
    }
}
