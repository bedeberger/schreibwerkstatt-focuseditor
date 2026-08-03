//
//  PagePickerModelTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Unit-Tests der Picker-Listenaufbereitung — die Logik, in der die bisherigen
//  Seiten-Picker-Bugs sassen: Kapitel-Läufe, Zeilen-/Sektions-Identität,
//  Trefferzahl und die Regel, wann eine Zeile das „im Text"-Badge trägt.
//
//  Ohne UI, ohne Server, ohne Store: `PagePickerModel.build` ist eine pure
//  Funktion über `[PagePickerRow]`.
//

import XCTest

@MainActor
final class PagePickerModelTests: XCTestCase {

    private func row(_ id: Int, _ name: String, _ path: [String] = []) -> PagePickerRow {
        PagePickerRow(id: id, name: name, chapterPath: path)
    }

    private func build(pages: [PagePickerRow], recents: [PagePickerRow] = [],
                       query: String = "", content: Set<Int> = []) -> PagePickerModel.Result {
        PagePickerModel.build(pages: pages, recents: recents, query: query, contentMatches: content)
    }

    // MARK: - Gruppierung in Kapitelblöcke

    func testChapterRunsBreakOnPathChange() {
        let result = build(pages: [
            row(1, "Vorwort"),                            // Top-Level (kein Header)
            row(2, "Neujahr", ["2026", "Januar"]),
            row(3, "Dreikönig", ["2026", "Januar"]),
            row(4, "Fasnacht", ["2026", "Februar"]),
        ])

        XCTAssertEqual(result.groups.map(\.path),
                       [[], ["2026", "Januar"], ["2026", "Februar"]])
        XCTAssertEqual(result.groups.map { $0.rows.count }, [1, 2, 1])
        XCTAssertFalse(result.groups.contains { $0.isRecent }, "ohne Recents keine Recent-Gruppe")
    }

    /// Gleichnamige Unterkapitel verschiedener Eltern dürfen NICHT verschmelzen —
    /// darum bricht der Lauf am VOLLEN Pfad, nicht am Kapitelnamen.
    func testSameChapterNameUnderDifferentParentsStaysSeparate() {
        let result = build(pages: [
            row(1, "Rückblick", ["2025", "Januar"]),
            row(2, "Neujahr", ["2026", "Januar"]),
        ])

        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups.map(\.path), [["2025", "Januar"], ["2026", "Januar"]])
        XCTAssertEqual(Set(result.groups.map(\.id)).count, 2, "getrennte Sektions-Identitäten")
    }

    // MARK: - Identitäten (Zeilen + Sektionen)

    /// Die Konstellation, in der die Zombie-Sektion entstand: die Recent-Gruppe
    /// beginnt mit DERSELBEN Seite wie der erste Kapitelblock.
    ///
    /// Dass die Sektions-Identität dabei nicht mit der Identität ihrer ersten Zeile
    /// kollidieren kann, garantiert inzwischen der Typ (`GroupKey` ≠ `RowKey`, zwei
    /// getrennte Identitätsräume) — hier bleibt zu prüfen, dass innerhalb jedes
    /// Raums alles eindeutig ist und dieselbe Seite in beiden Gruppen zwei
    /// verschiedene Zeilen-Identitäten trägt.
    func testIdentitiesStayUniqueWhenRecentGroupStartsWithSamePage() {
        let pages = [row(5, "Neujahr", ["2026"]), row(6, "Dreikönig", ["2026"])]
        let result = build(pages: pages, recents: [pages[0]])

        XCTAssertEqual(result.groups.map(\.isRecent), [true, false])
        XCTAssertEqual(Set(result.groups.map(\.id)).count, result.groups.count,
                       "Sektions-Identitäten eindeutig")
        XCTAssertEqual(Set(result.rows.map(\.key)).count, result.rows.count,
                       "Zeilen-Identitäten eindeutig — auch bei der doppelten Seite")

        let keysOfPage5 = result.rows.filter { $0.row.id == 5 }.map(\.key)
        XCTAssertEqual(keysOfPage5, [.init(section: .recent, pageId: 5),
                                     .init(section: .tree, pageId: 5)],
                       "dieselbe Seite: zwei sektions-qualifizierte Identitäten")
    }

    /// `selected` ist ein Index in `rows` — die Indizes müssen darum lückenlos der
    /// Anzeige-Reihenfolge folgen (Recent-Gruppe zuerst).
    func testFlatIndicesAreContiguousWithRecentFirst() {
        let pages = [row(1, "A"), row(2, "B", ["Kap"]), row(3, "C", ["Kap"])]
        let result = build(pages: pages, recents: [pages[2], pages[0]])

        XCTAssertEqual(result.rows.map(\.index), Array(0..<result.rows.count))
        XCTAssertEqual(result.rows.map(\.row.id), [3, 1, 1, 2, 3],
                       "erst die Recents (MRU), dann der Baum in depth-first-Ordnung")
        // Die Gruppen-Zeilen tragen dieselben Indizes wie die flache Liste.
        XCTAssertEqual(result.groups.flatMap { $0.rows.map(\.index) },
                       result.rows.map(\.index))
    }

    // MARK: - Gruppe „Zuletzt geöffnet"

    func testRecentGroupIsRestrictedToMatchesAndKeepsMRUOrder() {
        let pages = [row(1, "Neujahr"), row(2, "Fasnacht"), row(3, "Neujahrskonzert")]
        // MRU: Fasnacht zuletzt, davor Neujahr.
        let result = build(pages: pages, recents: [pages[1], pages[0]], query: "neujahr")

        let recent = result.groups.first
        XCTAssertEqual(recent?.isRecent, true)
        XCTAssertEqual(recent?.rows.map(\.row.id), [1],
                       "Fasnacht ist kein Treffer → fällt aus der Recent-Gruppe")
        XCTAssertEqual(result.groups.count, 2, "Recent-Gruppe + ein Kapitelblock")
    }

    func testMatchCountExcludesRecentDuplicates() {
        let pages = [row(1, "Neujahr"), row(2, "Fasnacht")]
        let result = build(pages: pages, recents: [pages[0]])

        XCTAssertEqual(result.matchCount, 2, "zählt nur den Baum, nicht die Recent-Kopie")
        XCTAssertEqual(result.rows.count, 3, "die Zeile selbst steht zweimal in der Liste")
    }

    func testEmptyQueryKeepsRecentGroupAndAllPages() {
        let pages = [row(1, "A"), row(2, "B")]
        let result = build(pages: pages, recents: [pages[1]])

        XCTAssertEqual(result.groups.first?.rows.map(\.row.id), [2])
        XCTAssertEqual(result.matchCount, 2)
    }

    // MARK: - Filter

    /// Ein Treffer im ELTERN-Segment muss die Seiten darunter liefern (Suche „2026"
    /// findet die Seiten im Jahres-Kapitel, obwohl ihr Name das Jahr nicht enthält).
    func testFilterMatchesParentChapterSegment() {
        let result = build(pages: [
            row(1, "Neujahr", ["2026", "Januar"]),
            row(2, "Rückblick", ["2025", "Dezember"]),
        ], query: "2026")

        XCTAssertEqual(result.rows.map(\.row.id), [1])
        XCTAssertEqual(result.matchCount, 1)
    }

    func testContentMatchesExtendTheResultSet() {
        let pages = [row(1, "Neujahr"), row(2, "Fasnacht")]

        XCTAssertEqual(build(pages: pages, query: "leuchtturm").matchCount, 0)
        XCTAssertEqual(build(pages: pages, query: "leuchtturm", content: [2]).rows.map(\.row.id), [2],
                       "Volltext-Treffer erweitert die Namens-/Kapitelsuche")
    }

    func testFilterIsCaseInsensitive() {
        let result = build(pages: [row(1, "Neujahr")], query: "NEUJ")
        XCTAssertEqual(result.matchCount, 1)
    }

    // MARK: - „im Text"-Badge

    func testIsContentOnlyMatch() {
        let named = row(1, "Neujahr", ["2026"])
        let other = row(2, "Fasnacht", ["2026"])

        XCTAssertTrue(PagePickerModel.isContentOnlyMatch(other, query: "neujahr", contentMatches: [2]),
                      "Treffer steckt nur im Text → Badge")
        XCTAssertFalse(PagePickerModel.isContentOnlyMatch(named, query: "neujahr", contentMatches: [1]),
                       "Namens-Treffer → kein Badge")
        XCTAssertFalse(PagePickerModel.isContentOnlyMatch(other, query: "2026", contentMatches: [2]),
                       "Kapitelpfad-Treffer → kein Badge (dieselbe Regel wie der Filter)")
        XCTAssertFalse(PagePickerModel.isContentOnlyMatch(other, query: "", contentMatches: [2]),
                       "ohne Suche nie ein Badge")
        XCTAssertFalse(PagePickerModel.isContentOnlyMatch(other, query: "neujahr", contentMatches: []),
                       "kein Volltext-Treffer → kein Badge")
    }

    // MARK: - Randfälle

    func testEmptyPagesYieldEmptyResult() {
        let result = build(pages: [])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.matchCount, 0)
    }

    /// Kein Treffer → auch keine (leere) Recent-Gruppe, sonst stünde im Picker ein
    /// gepinnter Header über einer leeren Liste.
    func testNoMatchesYieldNoGroupsAtAll() {
        let pages = [row(1, "Neujahr")]
        let result = build(pages: pages, recents: [pages[0]], query: "leuchtturm")

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
    }

    // MARK: - Struktur-Stempel

    /// Der Stempel hängt in der View als `.id` an der Ergebnisliste: gleicher
    /// Stempel = Teilbaum bleibt stehen (Scroll-Position hält), neuer Stempel =
    /// SwiftUI baut neu auf, statt Zeilen über Sektionsgrenzen zu recyceln.
    func testStructureIDIsStableForTheSameOutline() {
        let pages = [row(1, "Neujahr", ["2026"]), row(2, "Fasnacht", ["2026"])]

        XCTAssertEqual(build(pages: pages).structureID, build(pages: pages).structureID)
    }

    /// Nur der Inhalt einer Zeile änderte sich (hier: die Änderungszeit, wie nach
    /// einem Sync-Tick) — die Gliederung ist dieselbe, der Teilbaum darf NICHT
    /// weggeworfen werden.
    func testStructureIDIgnoresPureContentRefresh() {
        let before = [row(1, "Neujahr", ["2026"])]
        let after = [PagePickerRow(id: 1, name: "Neujahr", chapterPath: ["2026"],
                                   updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]

        XCTAssertEqual(build(pages: before).structureID, build(pages: after).structureID)
    }

    /// Der Alltagsfall des Bugs: die Suche zeigt erst den Namenstreffer, dann
    /// trudeln die Volltext-Treffer nach und schieben Zeilen in die Gruppe.
    func testStructureIDChangesWhenContentMatchesArrive() {
        let pages = [
            row(1, "Der erste Kuss", ["Der Vater"]),
            row(2, "Die neue Sexualität", ["Der Vater"]),
        ]
        let nameOnly = build(pages: pages, query: "die neue sexualität")
        let withContent = build(pages: pages, query: "die neue sexualität", content: [1])

        XCTAssertEqual(nameOnly.rows.count, 1)
        XCTAssertEqual(withContent.rows.count, 2)
        XCTAssertNotEqual(nameOnly.structureID, withContent.structureID)
    }

    /// Auch eine reine Umsortierung (gleiche Seiten, andere Reihenfolge) ist ein
    /// Umbau — sonst blieben die Zeilen an ihren alten Plätzen kleben.
    func testStructureIDChangesWhenRowOrderChanges() {
        let a = row(1, "Neujahr", ["2026"])
        let b = row(2, "Fasnacht", ["2026"])

        XCTAssertNotEqual(build(pages: [a, b]).structureID, build(pages: [b, a]).structureID)
    }
}
