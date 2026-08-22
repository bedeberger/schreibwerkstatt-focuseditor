//
//  BookExportTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Zusammenbau des Buch-Exports: Kapitel-Überschriften nur beim Wechsel,
//  Seitentitel eine Ebene tiefer, und — der eigentliche Punkt — Seiten OHNE
//  lokalen Text werden ausgewiesen statt still übersprungen.
//
//  Auf die i18n-Texte wird bewusst NICHT geprüft: das Test-Bundle ist
//  non-hosted und trägt die Kataloge nicht, `t()` liefert hier den Roh-Key. Die
//  Kataloge selbst hütet LocalizationCatalogTests.
//

import XCTest

final class BookExportTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    private func entry(_ name: String, _ path: [String], _ html: String?) -> BookExport.Entry {
        BookExport.Entry(name: name, chapterPath: path, html: html)
    }

    // MARK: - Struktur

    func testBookTitleIsTopLevelHeading() {
        let result = BookExport.document(bookTitle: "Mein Buch", entries: [], now: fixedNow)
        XCTAssertTrue(result.markdown.hasPrefix("# Mein Buch\n"), result.markdown)
    }

    func testPageOnBookLevelIsHeadingTwo() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Vorwort", [], "<p>Text</p>"),
        ], now: fixedNow)
        XCTAssertTrue(result.markdown.contains("\n## Vorwort\n"), result.markdown)
    }

    func testChapterHeadingPrecedesItsPages() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Seite A", ["Erstes Kapitel"], "<p>a</p>"),
        ], now: fixedNow)
        let chapter = result.markdown.range(of: "## Erstes Kapitel")
        let page = result.markdown.range(of: "### Seite A")
        XCTAssertNotNil(chapter); XCTAssertNotNil(page)
        XCTAssertTrue(chapter!.lowerBound < page!.lowerBound)
    }

    /// Die Kapitelüberschrift darf nur EINMAL erscheinen, nicht vor jeder Seite.
    func testChapterHeadingIsNotRepeatedForConsecutivePages() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("A", ["Kapitel"], "<p>a</p>"),
            entry("B", ["Kapitel"], "<p>b</p>"),
        ], now: fixedNow)
        let occurrences = result.markdown.components(separatedBy: "## Kapitel").count - 1
        XCTAssertEqual(occurrences, 1, result.markdown)
    }

    func testNestedChapterGetsDeeperHeading() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Seite", ["Teil", "Kapitel"], "<p>x</p>"),
        ], now: fixedNow)
        XCTAssertTrue(result.markdown.contains("## Teil"), result.markdown)
        XCTAssertTrue(result.markdown.contains("### Kapitel"), result.markdown)
        XCTAssertTrue(result.markdown.contains("#### Seite"), result.markdown)
    }

    /// Wechselt der Pfad auf einer oberen Ebene, müssen ALLE darunterliegenden
    /// Überschriften neu geschrieben werden — sonst stünde die zweite Seite
    /// unter der Kapitelüberschrift des ersten Teils.
    func testSwitchingTopLevelRewritesDeeperHeadings() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("A", ["Teil 1", "Kapitel"], "<p>a</p>"),
            entry("B", ["Teil 2", "Kapitel"], "<p>b</p>"),
        ], now: fixedNow)
        XCTAssertEqual(result.markdown.components(separatedBy: "### Kapitel").count - 1, 2,
                       "Kapitel muss unter beiden Teilen erscheinen:\n\(result.markdown)")
    }

    /// Überschriftenebenen sind bei 6 gedeckelt (Markdown kennt nicht mehr).
    func testHeadingLevelIsCappedAtSix() {
        let deep = ["A", "B", "C", "D", "E", "F", "G"]
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Tief", deep, "<p>x</p>"),
        ], now: fixedNow)
        XCTAssertFalse(result.markdown.contains("#######"), "mehr als sechs Rauten:\n\(result.markdown)")
    }

    // MARK: - Fehlende Seiten (der Vertrauenspunkt)

    func testPageWithoutLocalHtmlIsReportedAsMissing() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Nie geladen", [], nil),
            entry("Da", [], "<p>Text</p>"),
        ], now: fixedNow)
        XCTAssertEqual(result.missingPages, ["Nie geladen"])
    }

    func testFullyLocalBookReportsNoMissingPages() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("A", [], "<p>a</p>"),
            entry("B", [], "<p>b</p>"),
        ], now: fixedNow)
        XCTAssertTrue(result.missingPages.isEmpty)
    }

    /// Eine leere Seite ist NICHT dasselbe wie eine fehlende: sie wurde geladen
    /// und ist tatsächlich leer.
    func testEmptyPageIsNotCountedAsMissing() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("Leer", [], "<p><br></p>"),
        ], now: fixedNow)
        XCTAssertTrue(result.missingPages.isEmpty)
    }

    // MARK: - Inhalt

    func testPageContentIsConvertedToMarkdown() {
        let result = BookExport.document(bookTitle: "B", entries: [
            entry("S", [], "<p>Ein <strong>Wort</strong>.</p>"),
        ], now: fixedNow)
        XCTAssertTrue(result.markdown.contains("Ein **Wort**."), result.markdown)
    }

    func testDocumentEndsWithNewline() {
        let result = BookExport.document(bookTitle: "B", entries: [], now: fixedNow)
        XCTAssertTrue(result.markdown.hasSuffix("\n"))
    }

    // MARK: - Dateiname

    func testFilenameStripsPathSeparators() {
        XCTAssertEqual(BookExport.suggestedFilename(bookTitle: "Teil 1/2"), "Teil 1-2")
        XCTAssertEqual(BookExport.suggestedFilename(bookTitle: "Buch: Untertitel"), "Buch- Untertitel")
    }

    /// Ein führender Punkt macht die Datei unter macOS unsichtbar.
    func testFilenameDropsLeadingDots() {
        XCTAssertEqual(BookExport.suggestedFilename(bookTitle: ".versteckt"), "versteckt")
    }

    func testFilenameFallsBackWhenTitleIsBlank() {
        XCTAssertEqual(BookExport.suggestedFilename(bookTitle: "   "), "Export")
    }

    func testFilenameKeepsUmlauts() {
        XCTAssertEqual(BookExport.suggestedFilename(bookTitle: "Über Öl"), "Über Öl")
    }

    // MARK: - Helper

    func testCommonPrefixLength() {
        XCTAssertEqual(BookExport.commonPrefixLength(["a", "b"], ["a", "b", "c"]), 2)
        XCTAssertEqual(BookExport.commonPrefixLength(["a", "b"], ["a", "x"]), 1)
        XCTAssertEqual(BookExport.commonPrefixLength([], ["a"]), 0)
    }
}
