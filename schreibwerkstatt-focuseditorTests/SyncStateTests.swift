//
//  SyncStateTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für die Codable-Toleranz von SyncState. Der
//  Sync-Zustand (Pull-Cursor, exakte Server-ISO-Basis je Seite, Merge-Ancestor)
//  ist datenverlustnah: ein zu strenger Decode würde bei einem alten Snapshot
//  den ganzen Zustand verwerfen → Voll-Pull + möglicher 409-Sturm. Diese Tests
//  sichern, dass fehlende/neue Felder tolerant behandelt werden.
//

import XCTest

final class SyncStateTests: XCTestCase {

    private func decode(_ json: String) throws -> SyncState {
        try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
    }

    /// Alter Snapshot ohne `serverBaseHtml` (vor Einführung des 3-Wege-Merge):
    /// darf NICHT scheitern, übrige Felder bleiben erhalten, neues Feld = leer.
    func testDecodesOldSnapshotWithoutServerBaseHtml() throws {
        let s = try decode(#"""
        { "bookIds": [1, 2], "serverBaseISO": { "5": "2026-06-14T10:00:00.000Z" } }
        """#)
        XCTAssertEqual(s.bookIds, [1, 2])
        XCTAssertEqual(s.serverBaseISO["5"], "2026-06-14T10:00:00.000Z")
        XCTAssertTrue(s.serverBaseHtml.isEmpty, "fehlendes Feld → leer, nicht Decode-Fehler")
        XCTAssertTrue(s.cursors.isEmpty)
    }

    /// Leeres Objekt → komplette Default-Initialisierung statt Wurf.
    func testDecodesEmptyObject() throws {
        let s = try decode("{}")
        XCTAssertTrue(s.bookIds.isEmpty)
        XCTAssertTrue(s.cursors.isEmpty)
        XCTAssertTrue(s.serverBaseISO.isEmpty)
        XCTAssertTrue(s.serverBaseHtml.isEmpty)
    }

    /// Voller Roundtrip inkl. Int-gekeyter `cursors`-Map (Swift kodiert
    /// Int-Dictionaries als JSON-Array — der Decoder MUSS dasselbe Format lesen).
    func testRoundtripWithCursors() throws {
        var s = SyncState()
        s.bookIds = [7]
        s.cursors = [7: SyncCursorDTO(since: "2026-06-14T09:00:00.000Z", since_id: 3)]
        s.serverBaseISO = ["10": "2026-06-14T10:00:00.000Z"]
        s.serverBaseHtml = ["10": "<p data-bid=\"b1\">x</p>"]

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SyncState.self, from: data)

        XCTAssertEqual(back.bookIds, [7])
        XCTAssertEqual(back.cursors[7], SyncCursorDTO(since: "2026-06-14T09:00:00.000Z", since_id: 3))
        XCTAssertEqual(back.serverBaseISO["10"], "2026-06-14T10:00:00.000Z")
        XCTAssertEqual(back.serverBaseHtml["10"], "<p data-bid=\"b1\">x</p>")
    }
}
