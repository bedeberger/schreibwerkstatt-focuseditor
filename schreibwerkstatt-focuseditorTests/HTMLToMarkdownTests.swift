//
//  HTMLToMarkdownTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Der Konverter hinter „Buch exportieren …". Geprüft wird an dem HTML, das der
//  Focus-Editor tatsächlich schreibt: Absätze mit `data-bid`, Überschriften,
//  Inline-Auszeichnung, Listen, Zitate — plus die Fälle, in denen ein naiver
//  Regex-Ersatz Text VERLIEREN würde (verschachtelte Auszeichnung, fehlender
//  schliessender Tag, Entities).
//
//  Text-Verlust ist hier die eigentliche Gefahr: ein Export ist ein Backup, und
//  ein Backup, dem still ein Absatz fehlt, ist schlimmer als keins.
//

import XCTest

final class HTMLToMarkdownTests: XCTestCase {

    // MARK: - Blöcke

    func testParagraphsBecomeBlankLineSeparated() {
        let html = "<p>Erster Satz.</p><p>Zweiter Satz.</p>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "Erster Satz.\n\nZweiter Satz.")
    }

    /// Der Editor hängt an jeden Block ein `data-bid` (Block-Merge-Identität).
    /// Attribute dürfen den Konverter nicht stören — und niemals im Text landen.
    func testIgnoresBlockIdAttributes() {
        let html = #"<p data-bid="a1b2">Mit Block-ID.</p>"#
        XCTAssertEqual(HTMLToMarkdown.convert(html), "Mit Block-ID.")
    }

    func testHeadingLevels() {
        let html = "<h1>Titel</h1><h2>Kapitel</h2><h3>Abschnitt</h3>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "# Titel\n\n## Kapitel\n\n### Abschnitt")
    }

    func testHorizontalRule() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>a</p><hr><p>b</p>"), "a\n\n---\n\nb")
    }

    /// Der Editor setzt `<p><br></p>` für einen leeren Absatz — daraus darf kein
    /// Markdown-Rauschen werden.
    func testEmptyParagraphProducesNothing() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p><br></p>"), "")
    }

    func testLineBreakBecomesHardBreak() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>Zeile eins<br>Zeile zwei</p>"),
                       "Zeile eins  \nZeile zwei")
    }

    // MARK: - Inline

    func testBoldAndItalic() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>Ein <strong>fettes</strong> und <em>kursives</em> Wort.</p>"),
                       "Ein **fettes** und *kursives* Wort.")
    }

    func testNestedEmphasisKeepsBothMarkers() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p><strong>ganz <em>sehr</em> fett</strong></p>"),
                       "**ganz *sehr* fett**")
    }

    func testLinkWithHref() {
        XCTAssertEqual(HTMLToMarkdown.convert(#"<p>Siehe <a href="https://example.org">hier</a>.</p>"#),
                       "Siehe [hier](https://example.org).")
    }

    /// Ein `<a>` ohne `href` (kommt aus Kopiertem vor) darf den Text behalten,
    /// statt eine kaputte Markdown-Klammer zu erzeugen.
    func testLinkWithoutHrefKeepsText() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>Siehe <a>hier</a>.</p>"), "Siehe hier.")
    }

    /// Unbekannte Inline-Hüllen (Spellcheck-Marker, `span`, `mark`) verschwinden
    /// — ihr Inhalt nicht.
    func testUnknownInlineTagsKeepTheirContent() {
        let html = #"<p>Ein <span class="sc-error">Wort</span> mit Marker.</p>"#
        XCTAssertEqual(HTMLToMarkdown.convert(html), "Ein Wort mit Marker.")
    }

    // MARK: - Listen

    func testUnorderedList() {
        let html = "<ul><li>eins</li><li>zwei</li></ul>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "- eins\n\n- zwei")
    }

    func testOrderedList() {
        let html = "<ol><li>eins</li><li>zwei</li></ol>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "1. eins\n\n1. zwei")
    }

    func testNestedListIsIndented() {
        let html = "<ul><li>oben<ul><li>unten</li></ul></li></ul>"
        let md = HTMLToMarkdown.convert(html)
        XCTAssertTrue(md.contains("- oben"), md)
        XCTAssertTrue(md.contains("  - unten"), md)
    }

    // MARK: - Zitate und Code

    func testBlockquotePrefixesEveryLine() {
        let html = "<blockquote><p>Erste Zeile.</p><p>Zweite Zeile.</p></blockquote>"
        XCTAssertEqual(HTMLToMarkdown.convert(html), "> Erste Zeile.\n>\n> Zweite Zeile.")
    }

    func testPreBecomesFencedCode() {
        XCTAssertEqual(HTMLToMarkdown.convert("<pre>let a = 1</pre>"), "```\nlet a = 1\n```")
    }

    // MARK: - Entities

    func testDecodesEntities() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>a &lt; b &amp;&amp; c &gt; d</p>"),
                       "a < b && c > d")
    }

    /// `&amp;lt;` ist ein codiertes „&lt;" und muss zu „&lt;" werden, NICHT zu „<".
    /// Genau hier vertut sich eine Ersetzung in der falschen Reihenfolge.
    func testDoubleEncodedEntityIsDecodedOnce() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>&amp;lt;</p>"), "&lt;")
    }

    func testDecodesNumericEntities() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>&#8222;Zitat&#8220;</p>"), "„Zitat“")
    }

    func testKeepsNonBreakingSpaceAsCharacter() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>a&nbsp;b</p>"), "a\u{00A0}b")
    }

    // MARK: - Robustheit (kein Textverlust)

    /// Fehlt der schliessende Tag, gilt der Rest als Inhalt — abgeschnittenes
    /// Manuskript wäre der schlimmere Ausgang.
    func testUnclosedTagKeepsRemainingText() {
        XCTAssertTrue(HTMLToMarkdown.convert("<p>Angefangen und nie beendet").contains("Angefangen"))
    }

    /// Text ausserhalb jedes Blockelements (kommt bei Altbeständen vor) darf
    /// nicht unter den Tisch fallen.
    func testLooseTextBecomesParagraph() {
        XCTAssertEqual(HTMLToMarkdown.convert("Loser Text<p>Im Absatz</p>"),
                       "Loser Text\n\nIm Absatz")
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(HTMLToMarkdown.convert(""), "")
    }

    /// Ein einzelnes `<` im Text (mathematisch, uncodiert) darf den Parser
    /// nicht aus dem Tritt bringen.
    func testStrayAngleBracketIsKeptAsText() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>3 < 5</p>"), "3 < 5")
    }

    /// Die Gegenprobe zum Ganzen: über einer realistischen Seite darf KEIN Wort
    /// verschwinden.
    func testNoWordIsLostOnARealisticPage() {
        let html = """
            <h2 data-bid="h1">Das Kapitel</h2>
            <p data-bid="p1">Ein <strong>wichtiger</strong> Satz mit <em>Betonung</em>.</p>
            <ul data-bid="l1"><li>erstens</li><li>zweitens</li></ul>
            <blockquote data-bid="q1"><p>Ein Zitat.</p></blockquote>
            <p data-bid="p2">Und ein Schluss.</p>
            """
        let md = HTMLToMarkdown.convert(html)
        for word in ["Das", "Kapitel", "wichtiger", "Betonung", "erstens",
                     "zweitens", "Zitat", "Schluss"] {
            XCTAssertTrue(md.contains(word), "„\(word)" + "“ fehlt im Export:\n\(md)")
        }
    }
}
