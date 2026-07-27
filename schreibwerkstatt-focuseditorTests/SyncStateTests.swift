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

    /// Alter Snapshot ohne `serverBaseHtml`: darf NICHT scheitern, übrige Felder
    /// bleiben erhalten, das Alt-Feld = leer.
    func testDecodesOldSnapshotWithoutServerBaseHtml() throws {
        let s = try decode(#"""
        { "bookIds": [1, 2], "serverBaseISO": { "5": "2026-06-14T10:00:00.000Z" } }
        """#)
        XCTAssertEqual(s.bookIds, [1, 2])
        XCTAssertEqual(s.serverBaseISO["5"], "2026-06-14T10:00:00.000Z")
        XCTAssertTrue(s.legacyServerBaseHtml.isEmpty, "fehlendes Feld → leer, nicht Decode-Fehler")
        XCTAssertTrue(s.cursors.isEmpty)
    }

    /// Leeres Objekt → komplette Default-Initialisierung statt Wurf.
    func testDecodesEmptyObject() throws {
        let s = try decode("{}")
        XCTAssertTrue(s.bookIds.isEmpty)
        XCTAssertTrue(s.cursors.isEmpty)
        XCTAssertTrue(s.serverBaseISO.isEmpty)
        XCTAssertTrue(s.legacyServerBaseHtml.isEmpty)
    }

    /// Der Merge-Ancestor liegt seit Build 22 als Spalte `page.serverBaseHtml` im
    /// Store, NICHT mehr im Snapshot. Alt-Snapshots müssen ihn noch hergeben
    /// (`SyncEngine.migrateLegacyAncestors` zieht ihn um) — aber er darf NIE wieder
    /// mitgeschrieben werden: genau das liess die Datei auf 20 MB wachsen, die bei
    /// jeder Mutation komplett neu kodiert wurde (~50 % CPU alle ~5 s).
    func testLegacyAncestorIsReadButNeverWrittenBack() throws {
        let s = try decode(#"""
        { "bookIds": [1], "serverBaseHtml": { "10": "<p data-bid=\"b1\">alt</p>" } }
        """#)
        XCTAssertEqual(s.legacyServerBaseHtml["10"], "<p data-bid=\"b1\">alt</p>",
                       "Alt-Ancestor muss für die Migration lesbar bleiben")

        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(s), encoding: .utf8))
        XCTAssertFalse(json.contains("serverBaseHtml"),
                       "Ancestor-Dictionary darf nicht mehr in den Snapshot geschrieben werden")
        XCTAssertFalse(json.contains("legacyServerBaseHtml"),
                       "auch nicht unter dem internen Property-Namen")
        XCTAssertTrue(json.contains("bookIds"), "übrige Felder werden weiterhin geschrieben")
    }

    /// Voller Roundtrip inkl. Int-gekeyter `cursors`-Map (Swift kodiert
    /// Int-Dictionaries als JSON-Array — der Decoder MUSS dasselbe Format lesen).
    func testRoundtripWithCursors() throws {
        var s = SyncState()
        s.bookIds = [7]
        s.cursors = [7: SyncCursorDTO(since: "2026-06-14T09:00:00.000Z", since_id: 3)]
        s.serverBaseISO = ["10": "2026-06-14T10:00:00.000Z"]

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SyncState.self, from: data)

        XCTAssertEqual(back.bookIds, [7])
        XCTAssertEqual(back.cursors[7], SyncCursorDTO(since: "2026-06-14T09:00:00.000Z", since_id: 3))
        XCTAssertEqual(back.serverBaseISO["10"], "2026-06-14T10:00:00.000Z")
    }
}
