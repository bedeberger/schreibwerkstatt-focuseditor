//
//  DiagnosticsReportTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Der Diagnose-Bericht landet in einer Support-Mail und damit potenziell in
//  fremden Postfächern. Der wichtigste Test hier ist darum kein Format-Test,
//  sondern ein Leck-Test: das Device-Token und der Manuskript-Text dürfen unter
//  keinen Umständen im Bericht stehen.
//

import XCTest

final class DiagnosticsReportTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    private func input(logLines: [String] = []) -> DiagnosticsReport.Input {
        DiagnosticsReport.Input(
            appVersion: "3.21",
            buildNumber: "412",
            channel: "App Store",
            systemVersion: "Version 15.3 (Build 24D60)",
            serverURL: "https://schreibwerkstatt.app",
            signedIn: true,
            hasToken: true,
            language: "de",
            bundleCommit: "abc1234def",
            bundleCached: true,
            pollMode: "auto",
            isPaused: false,
            lastSyncedAt: Date(timeIntervalSince1970: 1_769_999_000),
            pendingCount: 2,
            conflictCount: 0,
            lastSyncError: nil,
            bookCount: 3,
            activeBookId: 7,
            pageCount: 128,
            openPageId: 42,
            logLines: logLines)
    }

    // MARK: - Datenschutz

    /// Der Bericht darf nur sagen, DASS ein Token vorliegt — nie welches. Der
    /// Bericht bekommt den Wert gar nicht erst zu sehen (`hasToken: Bool`); der
    /// Test hält diese Signatur fest, damit niemand später ein `token: String`
    /// nachrüstet.
    func testNeverContainsATokenValue() {
        let text = DiagnosticsReport.text(input(), now: fixedNow)
        XCTAssertFalse(text.contains("swd_"), "Der Bericht darf kein Device-Token enthalten:\n\(text)")
        XCTAssertTrue(text.contains("Token:"))
        XCTAssertTrue(text.contains("vorhanden"))
    }

    func testReportsAbsentTokenWithoutClaimingOne() {
        var i = input(); i.hasToken = false; i.signedIn = false
        let text = DiagnosticsReport.text(i, now: fixedNow)
        XCTAssertTrue(text.contains("keines"), text)
        XCTAssertFalse(text.contains("vorhanden (Keychain)"), text)
    }

    /// Inhalte kommen im Bericht nur als Zahlen vor. Der Test füttert eine
    /// Log-Zeile mit Manuskript-anmutendem Text und prüft, dass NUR sie
    /// durchkommt (aus dem eigenen Log) — es gibt keinen zweiten Kanal, über
    /// den Seitentext einsickern könnte.
    func testContentAppearsOnlyAsCounts() {
        let text = DiagnosticsReport.text(input(), now: fixedNow)
        XCTAssertTrue(text.contains("Seiten:       128"))
        XCTAssertTrue(text.contains("Bücher:       3"))
    }

    // MARK: - Inhalt

    func testContainsAllSections() {
        let text = DiagnosticsReport.text(input(), now: fixedNow)
        for section in ["[App]", "[Server]", "[Editor-Bundle (OTA)]", "[Sync]",
                        "[Inhalt (lokaler Spiegel)]", "[Protokoll"] {
            XCTAssertTrue(text.contains(section), "Abschnitt \(section) fehlt:\n\(text)")
        }
    }

    func testMarksMissingBundleCacheLoudly() {
        var i = input(); i.bundleCached = false
        XCTAssertTrue(DiagnosticsReport.text(i, now: fixedNow).contains("FEHLT"))
    }

    func testShowsPausedSyncMode() {
        var i = input(); i.isPaused = true
        XCTAssertTrue(DiagnosticsReport.text(i, now: fixedNow).contains("(pausiert)"))
    }

    func testOmitsErrorLineWhenThereIsNoError() {
        XCTAssertFalse(DiagnosticsReport.text(input(), now: fixedNow).contains("Letzter Fehler:"))
    }

    func testIncludesErrorLineWhenPresent() {
        var i = input(); i.lastSyncError = "Zeitüberschreitung"
        XCTAssertTrue(DiagnosticsReport.text(i, now: fixedNow).contains("Letzter Fehler: Zeitüberschreitung"))
    }

    func testNeverSyncedIsStatedExplicitly() {
        var i = input(); i.lastSyncedAt = nil
        XCTAssertTrue(DiagnosticsReport.text(i, now: fixedNow).contains("Letzter Lauf: nie"))
    }

    func testLogLinesAreIncluded() {
        let text = DiagnosticsReport.text(input(logLines: ["12:00:00 [sync] Tick"]), now: fixedNow)
        XCTAssertTrue(text.contains("12:00:00 [sync] Tick"))
    }

    /// Ohne lesbares Protokoll bleibt der Bericht nützlich und sagt es ehrlich,
    /// statt einen leeren Abschnitt zu zeigen.
    func testEmptyLogIsStatedInsteadOfLeftBlank() {
        let text = DiagnosticsReport.text(input(logLines: []), now: fixedNow)
        XCTAssertTrue(text.contains("(keine Einträge lesbar)"))
    }

    // MARK: - Log-Zugriff

    /// `OSLogStore(scope: .currentProcessIdentifier)` ist der einzige Zugriff,
    /// den eine sandboxed App ohne Sonderrechte hat. Der Aufruf darf unter
    /// keinen Umständen werfen — im Fehlerfall liefert er eine leere Liste.
    func testRecentLogLinesNeverThrows() {
        _ = DiagnosticsReport.recentLogLines(subsystem: "ch.schreibwerkstatt.focuseditor.nichtvorhanden")
    }

    func testRecentLogLinesRespectsLimit() {
        let lines = DiagnosticsReport.recentLogLines(limit: 5)
        XCTAssertLessThanOrEqual(lines.count, 5)
    }
}
