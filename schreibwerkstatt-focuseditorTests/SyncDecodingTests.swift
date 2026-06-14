//
//  SyncDecodingTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für die Sync-DTOs (SyncModels.swift) gegen den
//  Server-Vertrag (routes/content.js im Hauptrepo) — anhand von JSON-Fixtures,
//  KEIN Server nötig. Fängt Decoding-Drift (umbenannte/entfernte Felder,
//  Pflicht-vs.-Optional) bevor er erst im Live-Sync auffällt.
//

import XCTest

final class SyncDecodingTests: XCTestCase {

    private let dec = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try dec.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - BookSyncResponse

    func testBookSyncResponseDecodesFully() throws {
        let json = """
        {
          "now": "2026-06-14T10:00:00.000Z",
          "has_more": true,
          "cursor": { "since": "2026-06-14T09:59:00.000Z", "since_id": 42 },
          "pages": [
            { "page_id": 42, "page_name": "Kapitel 1", "chapter_id": 7,
              "updated_at": "2026-06-14T09:59:00.000Z", "html": "<p data-bid=\\"b1\\">Hallo.</p>" }
          ]
        }
        """
        let resp = try decode(BookSyncResponse.self, json)
        XCTAssertTrue(resp.has_more)
        XCTAssertEqual(resp.cursor.since_id, 42)
        XCTAssertEqual(resp.pages.count, 1)
        XCTAssertEqual(resp.pages.first?.page_id, 42)
        XCTAssertEqual(resp.pages.first?.html, "<p data-bid=\"b1\">Hallo.</p>")
    }

    func testSyncPageToleratesNullHtmlAndUpdatedAt() throws {
        // Randfall laut SyncModels: eine einzelne null-Seite darf den Array-Decode
        // (und damit den ganzen Sync) NICHT scheitern lassen.
        let json = """
        {
          "now": "2026-06-14T10:00:00.000Z",
          "has_more": false,
          "cursor": { "since": null, "since_id": 0 },
          "pages": [
            { "page_id": 1, "page_name": null, "chapter_id": null, "updated_at": null, "html": null }
          ]
        }
        """
        let resp = try decode(BookSyncResponse.self, json)
        XCTAssertEqual(resp.pages.first?.page_id, 1)
        XCTAssertNil(resp.pages.first?.updated_at)
        XCTAssertNil(resp.pages.first?.html)
        XCTAssertNil(resp.cursor.since)   // Voll-Pull-Cursor
    }

    // MARK: - Push / Konflikt

    func testPushResponseDecodes() throws {
        let json = """
        { "id": 42, "updated_at": "2026-06-14T10:01:00.000Z", "name": "Kapitel 1", "html": "<p>x</p>" }
        """
        let resp = try decode(PushResponse.self, json)
        XCTAssertEqual(resp.id, 42)
        XCTAssertEqual(resp.updated_at, "2026-06-14T10:01:00.000Z")
    }

    func testConflictBodyDecodes() throws {
        let json = """
        { "error_code": "PAGE_CONFLICT",
          "server_updated_at": "2026-06-14T10:02:00.000Z",
          "server_editor_email": "a@b.ch", "server_editor_name": "Anna" }
        """
        let body = try decode(ConflictBody.self, json)
        XCTAssertEqual(body.error_code, "PAGE_CONFLICT")
        XCTAssertEqual(body.server_updated_at, "2026-06-14T10:02:00.000Z")
        XCTAssertEqual(body.server_editor_name, "Anna")
    }

    func testPushRequestEncodesMacappSource() throws {
        // `source` markiert die Revision serverseitig als Mac-App-Edit (Default macapp).
        let req = PushRequest(html: "<p>x</p>", expected_updated_at: "2026-06-14T10:00:00.000Z")
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, "macapp")
        XCTAssertEqual(obj?["expected_updated_at"] as? String, "2026-06-14T10:00:00.000Z")
        XCTAssertEqual(obj?["html"] as? String, "<p>x</p>")
    }

    // MARK: - ISO-Zeit

    func testISOTimeParsesWithFractionalSeconds() {
        let d = ISOTime.date("2026-06-14T10:00:00.123Z")
        XCTAssertNotNil(d)
    }

    func testISOTimeParsesWithoutFractionalSeconds() {
        // Server liefert in Randfällen ISO ohne Millis — beide Formen müssen parsen.
        let d = ISOTime.date("2026-06-14T10:00:00Z")
        XCTAssertNotNil(d)
    }

    func testISOTimeMillisRoundsToEpoch() {
        // 1970-01-01T00:00:01Z = 1000 ms seit Epoch.
        XCTAssertEqual(ISOTime.millis("1970-01-01T00:00:01Z"), 1000)
    }

    func testISOTimeReturnsNilOnGarbage() {
        XCTAssertNil(ISOTime.date("nicht-ein-datum"))
        XCTAssertNil(ISOTime.millis("nicht-ein-datum"))
    }
}
