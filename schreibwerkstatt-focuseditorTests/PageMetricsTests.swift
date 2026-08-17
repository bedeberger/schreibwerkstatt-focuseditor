//
//  PageMetricsTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Zählwerte einer Seite (Zeichen/Wörter) aus dem HTML — die Zahl, die im
//  Seiten-Picker an jeder Zeile steht. Getestet wird das, was der Scanner
//  leisten muss, damit die Zahl nicht lügt:
//    • Inline-Tags trennen KEIN Wort, Blocktags schon (sonst zählt „Wo<em>rt</em>"
//      doppelt bzw. „<p>a</p><p>b</p>" als ein Wort).
//    • Ein leerer Editor-Absatz (`<p><br></p>`) ist LEER (0 Zeichen) — davon hängt
//      das „leer"-Badge ab.
//    • Entitäten zählen als EIN Zeichen, `&nbsp;` als Leerzeichen.
//    • Führender/abschliessender Leerraum zählt nicht mit.
//

import XCTest

final class PageMetricsTests: XCTestCase {

    // MARK: - Leere Seiten

    func testEmptyHtmlIsEmpty() {
        XCTAssertEqual(PageMetrics.counts(html: ""), PageStats.zero)
        XCTAssertTrue(PageMetrics.counts(html: "").isEmpty)
    }

    /// Der Editor legt eine frische Seite als leeren Absatz an — die muss als
    /// „leer" gelten, sonst trägt jede unbeschriebene Seite eine Zeichenzahl.
    func testEditorEmptyParagraphIsEmpty() {
        XCTAssertTrue(PageMetrics.counts(html: "<p><br></p>").isEmpty)
        XCTAssertTrue(PageMetrics.counts(html: "<p data-bid=\"a1\">  \n </p>").isEmpty)
        XCTAssertTrue(PageMetrics.counts(html: "<p>&nbsp;</p>").isEmpty)
    }

    // MARK: - Wörter

    func testInlineTagsDoNotSplitWords() {
        let stats = PageMetrics.counts(html: "<p>Wo<em>rt</em></p>")
        XCTAssertEqual(stats.words, 1)
        XCTAssertEqual(stats.chars, 4)
    }

    func testBlockTagsSeparateWords() {
        let stats = PageMetrics.counts(html: "<p>eins</p><p>zwei</p>")
        XCTAssertEqual(stats.words, 2)
        // „eins" + Zeilengrenze + „zwei" — wie `innerText` im Editor.
        XCTAssertEqual(stats.chars, 9)
    }

    func testBreakSeparatesWords() {
        XCTAssertEqual(PageMetrics.counts(html: "<p>eins<br>zwei</p>").words, 2)
    }

    func testListItemsCountSeparately() {
        let stats = PageMetrics.counts(html: "<ul><li>eins</li><li>zwei drei</li></ul>")
        XCTAssertEqual(stats.words, 3)
    }

    // MARK: - Zeichen

    func testInternalWhitespaceCountsOnceLeadingAndTrailingDoNot() {
        // „ein wort" = 8 Zeichen; der Leerraum aussen zählt nicht.
        let stats = PageMetrics.counts(html: "<p>\n  ein wort  \n</p>")
        XCTAssertEqual(stats.chars, 8)
        XCTAssertEqual(stats.words, 2)
    }

    func testEntitiesCountAsSingleCharacter() {
        // „a&b" = 3 Zeichen, ein Wort.
        let stats = PageMetrics.counts(html: "<p>a&amp;b</p>")
        XCTAssertEqual(stats.chars, 3)
        XCTAssertEqual(stats.words, 1)
    }

    func testNumericEntityCountsAsSingleCharacter() {
        XCTAssertEqual(PageMetrics.counts(html: "<p>a&#233;b</p>").chars, 3)
        XCTAssertEqual(PageMetrics.counts(html: "<p>a&#xe9;b</p>").chars, 3)
    }

    /// Ein einzelnes „&" im Text ist keine Entität — es zählt als Zeichen, und der
    /// Rest des Absatzes darf nicht verschluckt werden.
    func testLoneAmpersandCountsAsText() {
        let stats = PageMetrics.counts(html: "<p>a & b</p>")
        XCTAssertEqual(stats.chars, 5)
        XCTAssertEqual(stats.words, 3)
    }

    func testNbspBetweenWordsCountsAsSpace() {
        let stats = PageMetrics.counts(html: "<p>ein&nbsp;wort</p>")
        XCTAssertEqual(stats.chars, 8)
        XCTAssertEqual(stats.words, 2)
    }

    // MARK: - Attribute / Robustheit

    /// Attribute (auch die `data-bid`-Marken des Block-Merges) dürfen nie in die
    /// Zählung geraten.
    func testAttributesAreNotCounted() {
        let html = "<p data-bid=\"b7\" class=\"x\"><strong style=\"color:red\">Hallo</strong></p>"
        let stats = PageMetrics.counts(html: html)
        XCTAssertEqual(stats.words, 1)
        XCTAssertEqual(stats.chars, 5)
    }

    func testTypographicQuotesAndDashesCount() {
        let stats = PageMetrics.counts(html: "<p>«Hallo» — ja</p>")
        XCTAssertEqual(stats.words, 3)
        XCTAssertEqual(stats.chars, 12)
    }

    /// Leerraum-Läufe zählen als EIN Zeichen — wie im gerenderten Text
    /// (`white-space`-Collapsing), auf den sich die Editor-Zählung stützt.
    func testWhitespaceRunsCollapse() {
        XCTAssertEqual(PageMetrics.counts(html: "<p>a   b</p>").chars, 3)
        XCTAssertEqual(PageMetrics.counts(html: "<div><p>a</p></div><p>b</p>").chars, 3)
    }

    /// Mehrere Absätze mit Umlauten: die Zählung läuft über Unicode-Skalare, nicht
    /// über Bytes — „Grüße" sind fünf Zeichen, nicht sieben.
    func testUmlautsCountAsOneCharacterEach() {
        XCTAssertEqual(PageMetrics.counts(html: "<p>Grüße</p>").chars, 5)
    }
}
