//
//  PagePickerModel.swift
//  schreibwerkstatt-focuseditor
//
//  Reine Aufbereitung der Seiten-Picker-Liste: Filter (Name / Kapitelpfad /
//  Volltext), Verschneidung mit den zuletzt geöffneten Seiten, Gruppierung in
//  Kapitelblöcke und die flache Indizierung für die Tastatur-Navigation.
//
//  UI-frei und ohne Zustand — bewusst wie `ContentAPI.flatten`: eine pure
//  Funktion, die aus `[PagePickerRow]` das fertige Anzeigemodell rechnet. Damit
//  ist genau die Logik testbar, in der die Picker-Bugs sassen (Zeilen-/Sektions-
//  Identität, Kapitel-Läufe, Trefferzahl) — die View selbst ist im Test-Target
//  nicht kompilierbar.
//
//  Ansteuerung: [PagePickerOverlay](PagePickerOverlay.swift) `recompute()`.
//

import Foundation

/// Welchen Zählwert der Seiten-Picker rechts an der Zeile zeigt (gerätelokal,
/// Einstellungen → Schreiben). Default `chars` — die Zeichenzahl ist die Zahl,
/// an der man den Umfang einer Seite erkennt, ohne dass die Zeile voll läuft.
enum PagePickerMetric: String, CaseIterable, Identifiable {
    case off, chars, words, both

    var id: String { rawValue }

    /// UserDefaults-Key (gerätelokale Einstellung, kein Server-Wert → NICHT
    /// server-skopiert wie `library.activeBookId`).
    static let defaultsKey = "picker.metric"

    /// i18n-Key des Labels im Einstellungs-Menü.
    var labelKey: String { "settings.writing.pickerMetric.\(rawValue)" }

    var showsChars: Bool { self == .chars || self == .both }
    var showsWords: Bool { self == .words || self == .both }
}

enum PagePickerModel {

    /// Zu welchem Block der Liste gehört eine Zeile: die Gruppe „Zuletzt
    /// geöffnet" oder der Kapitelbaum. Eine Seite kann in BEIDEN stehen.
    enum Section: Hashable { case recent, tree }

    /// Sektions-qualifizierte Zeilen-Identität. Eine Seite erscheint bewusst
    /// zweimal (Gruppe „Zuletzt geöffnet" UND ihr Platz im Kapitelbaum) — die
    /// reine Seiten-ID wäre als `ForEach`-/Scroll-Identität also doppelt, was
    /// SwiftUI mit recycelten Zeilen quittiert.
    struct RowKey: Hashable {
        let section: Section
        let pageId: Int
    }

    /// Eine Seitenzeile samt ihrem flachen Index in der Trefferliste — der Index
    /// ist die Brücke zur Tastatur-/Hover-Auswahl, der `key` die Identität für
    /// `ForEach` und den Auto-Scroll.
    struct IndexedRow: Identifiable {
        let index: Int
        let key: RowKey
        let row: PagePickerRow
        var id: RowKey { key }
    }

    /// Identität einer Sektion. Bewusst ein EIGENER Typ und NICHT `RowKey`: die
    /// Gruppen-ID enthält die erste Seiten-ID des Laufs, wäre als `RowKey` also
    /// deckungsgleich mit der Identität der ERSTEN Zeile derselben Gruppe. Ein
    /// Bezeichner, der bei einem Update seine Rolle wechselt (in einem Frame
    /// Sektion, im nächsten Zeile), lässt die `LazyVStack` mit gepinnten Headern
    /// eine Zombie-Sektion stehen, die über den neuen Zeilen liegt und deren
    /// Klicks/Hover schluckt — messbar als „ganze Kapitel-Gruppe nicht
    /// selektierbar" (Suche liefert erst einen Namenstreffer, dann kommen die
    /// Volltext-Treffer nach → genau dieser Rollenwechsel).
    struct GroupKey: Hashable {
        let section: Section
        let path: [String]
        /// Erste Seiten-ID im Lauf — hält die Identität inhaltsgebunden und stabil
        /// (der reine Lauf-Index 0, 1, … liess SwiftUI die alte Sektion samt Zeilen
        /// recyceln: „falsche Seiten unter richtigem Kapitel-Header").
        let firstPageId: Int
    }

    /// Ein Block der Liste: entweder die Gruppe „Zuletzt geöffnet" (`isRecent`)
    /// oder ein Kapitelblock — ein zusammenhängender Lauf gleichen `path` in der
    /// depth-first-Reihenfolge (Top-Level-Seiten → leerer Pfad, kein Header).
    struct Group: Identifiable {
        let id: GroupKey
        let isRecent: Bool
        let path: [String]   // voller Kapitelpfad; leer = Top-Level bzw. Zuletzt-Gruppe
        let rows: [IndexedRow]
    }

    /// Fertiges Anzeigemodell: flache Zeilenfolge (für die Auswahl-Indizes), die
    /// Gruppen (für die Darstellung), die Trefferzahl und der Struktur-Stempel.
    struct Result {
        /// Stempel über die GESAMTE Gliederung (Gruppen in Reihenfolge + ihre
        /// Zeilen). Ändert sich genau dann, wenn die Liste anders aufgebaut ist —
        /// nicht, wenn nur Auswahl/Hover wandern. Die View hängt ihn als `.id` an
        /// die Ergebnisliste, damit SwiftUI den Scroll-Teilbaum bei einem Umbau
        /// NEU aufbaut statt Zeilen zu recyceln.
        ///
        /// Warum: die `LazyVStack` mit gepinnten Sektions-Headern hängt Zeilen beim
        /// Umbau nachweislich in die falsche Sektion (gemessen 2026-08-03: unter
        /// „DER VATER" standen drei Zeilen, deren Hover die Indizes der Gruppe
        /// „DER KÜNSTLER" meldete). Folge: Markierung, Tastatur-Auswahl und Klick
        /// zielen an der sichtbaren Zeile vorbei — ganze Kapitel-Gruppen wirken
        /// „nicht selektierbar", die Markierung sitzt fest. Auslöser im Alltag: die
        /// Suche liefert erst die Namenstreffer und zieht die Volltext-Treffer
        /// asynchron nach — also mitten in der offenen Liste.
        let structureID: Int
        /// Flache Zeilenfolge in Anzeige-Reihenfolge (Gruppe „Zuletzt geöffnet"
        /// zuerst, dann der Kapitelbaum) — die Brücke zur Tastatur-Auswahl.
        let rows: [IndexedRow]
        let groups: [Group]
        /// Zahl der ECHTEN Treffer im Kapitelbaum (ohne die Zuletzt-Geöffnet-
        /// Kopien) — speist die Trefferzahl im Suchfeld, die sonst durch die
        /// Duplikate zu hoch wäre.
        let matchCount: Int
        /// Umfang der Trefferliste (Seiten/Wörter/Zeichen) für die Summenzeile.
        let summary: Summary
    }

    /// Umfang der aktuellen Trefferliste — bei leerer Suche also des ganzen Buchs
    /// bzw. bei aktiver Suche der Treffer. `unknown` sind Treffer, deren Inhalt
    /// lokal (noch) nicht vorliegt und die darum in `chars`/`words` fehlen; die
    /// Summenzeile weist sie aus, statt eine zu kleine Summe als vollständig
    /// auszugeben.
    struct Summary: Equatable {
        let pages: Int
        let chars: Int
        let words: Int
        let unknown: Int

        static let empty = Summary(pages: 0, chars: 0, words: 0, unknown: 0)
    }

    /// Rechnet Trefferliste + Gruppierung: zuerst die zuletzt geöffneten Seiten,
    /// dann die Kapitelblöcke.
    ///
    /// Die Kapitelblöcke entstehen als Läufe gleichen VOLLEN Pfads: da `pickerRows`
    /// depth-first abflacht (alle Seiten eines Kapitels stehen am Stück), genügt das
    /// Aufbrechen bei jedem Pfadwechsel — gleichnamige Unterkapitel verschiedener
    /// Eltern (z. B. „Januar" in 2025 und 2026) bleiben so getrennte Blöcke, statt
    /// fälschlich zu verschmelzen.
    ///
    /// - Parameters:
    ///   - pages: Seiten des aktiven Buchs in depth-first-Reihenfolge.
    ///   - recents: Zuletzt geöffnete Seiten in MRU-Reihenfolge
    ///     (`LibraryStore.recentPageRows()`), bereits gegen `pages` aufgelöst.
    ///   - query: Sucheingabe; leer = alles zeigen.
    ///   - contentMatches: Seiten-IDs mit Volltext-Treffer (async nachgeladen).
    ///   - stats: Zählwerte je Seiten-ID aus dem lokalen Spiegel
    ///     (`LibraryStore.pageStats`) — nur für die Summenzeile; fehlende Seiten
    ///     zählen als `unknown`.
    static func build(pages: [PagePickerRow], recents: [PagePickerRow],
                      query: String, contentMatches: Set<Int>,
                      stats: [Int: PageStats] = [:]) -> Result {
        let treeRows: [PagePickerRow]
        if query.isEmpty {
            treeRows = pages
        } else {
            treeRows = pages.filter { row in
                // Name ODER irgendein Pfad-Segment (Jahr ODER Monat), nicht nur das
                // Leaf — so findet „2026" auch die Seiten unter dem Jahres-Kapitel.
                matchesNameOrChapter(row, query: query)
                // Volltext-Treffer im Seiteninhalt (async nachgeladen).
                || contentMatches.contains(row.id)
            }
        }
        // Zuletzt geöffnete Seiten — bei aktiver Suche auf die Treffer eingeschränkt,
        // damit die Gruppe die Ergebnisliste nicht mit Nicht-Treffern verwässert.
        let matchIds = Set(treeRows.map(\.id))
        let recentRows = recents.filter { matchIds.contains($0.id) }

        var flat: [IndexedRow] = []
        var built: [Group] = []

        func appendGroup(_ section: Section, path: [String], rows: [PagePickerRow]) {
            guard let first = rows.first else { return }
            var entries: [IndexedRow] = []
            for row in rows {
                let entry = IndexedRow(index: flat.count,
                                       key: RowKey(section: section, pageId: row.id),
                                       row: row)
                flat.append(entry)
                entries.append(entry)
            }
            built.append(Group(id: GroupKey(section: section, path: path,
                                            firstPageId: first.id),
                               isRecent: section == .recent,
                               path: path, rows: entries))
        }

        appendGroup(.recent, path: [], rows: recentRows)

        var run: [PagePickerRow] = []
        var runPath: [String] = []
        for row in treeRows {
            if !run.isEmpty && row.chapterPath != runPath {
                appendGroup(.tree, path: runPath, rows: ranked(run, query: query))
                run = []
            }
            if run.isEmpty { runPath = row.chapterPath }
            run.append(row)
        }
        appendGroup(.tree, path: runPath, rows: ranked(run, query: query))

        // Struktur-Stempel: Gruppen-Identitäten + Zeilen-Identitäten in
        // Anzeige-Reihenfolge. Bewusst über die IDs (nicht über Namen/Zeitstempel),
        // damit ein reiner Inhalts-Refresh derselben Gliederung den Teilbaum NICHT
        // wegwirft (Scroll-Position bleibt) — nur ein echter Umbau tut das.
        var hasher = Hasher()
        for group in built {
            hasher.combine(group.id)
            hasher.combine(group.rows.count)
            for entry in group.rows { hasher.combine(entry.key) }
        }
        return Result(structureID: hasher.finalize(), rows: flat,
                      groups: built, matchCount: treeRows.count,
                      summary: summary(for: treeRows, stats: stats))
    }

    /// Ordnet die Zeilen EINES Kapitelblocks nach Trefferqualität: Treffer im
    /// Seitennamen (bzw. im Kapitelpfad) zuerst, Nur-im-Text-Treffer danach. Wer
    /// den Titel einer Seite sucht, will sie nicht unter zwanzig Volltextstellen
    /// finden.
    ///
    /// Bewusst NUR innerhalb des Blocks: die Kapitelreihenfolge des Buchs bleibt
    /// unangetastet (kein globales Umsortieren, das die Gliederung zerreisst) —
    /// jedes Kapitel priorisiert für sich. Die Sortierung ist **stabil**, innerhalb
    /// einer Rangstufe gilt also weiter die `book_order`-Reihenfolge des Servers.
    /// Ohne Suche ist es ein No-op (alle Zeilen haben denselben Rang).
    private static func ranked(_ rows: [PagePickerRow], query: String) -> [PagePickerRow] {
        guard !query.isEmpty, rows.count > 1 else { return rows }
        // `sorted(by:)` ist in Swift NICHT garantiert stabil → über den
        // Ursprungs-Index als Tiebreaker selbst stabil machen.
        return rows.enumerated()
            .sorted { a, b in
                let ra = matchesNameOrChapter(a.element, query: query) ? 0 : 1
                let rb = matchesNameOrChapter(b.element, query: query) ? 0 : 1
                if ra != rb { return ra < rb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Summiert Zeichen/Wörter über die Trefferzeilen des Kapitelbaums. BEWUSST
    /// über `treeRows` und nicht über die flache Zeilenfolge: dort steht eine
    /// zuletzt geöffnete Seite zweimal und würde doppelt gezählt.
    static func summary(for rows: [PagePickerRow], stats: [Int: PageStats]) -> Summary {
        var chars = 0
        var words = 0
        var unknown = 0
        for row in rows {
            guard let s = stats[row.id] else { unknown += 1; continue }
            chars += s.chars
            words += s.words
        }
        return Summary(pages: rows.count, chars: chars, words: words, unknown: unknown)
    }

    /// Passt die Zeile über ihren Namen oder ein Segment ihres Kapitelpfads zur
    /// Suche? EINE Regel für den Filter UND das „im Text"-Badge — sonst driften
    /// die beiden auseinander, sobald der Filter erweitert wird.
    static func matchesNameOrChapter(_ row: PagePickerRow, query: String) -> Bool {
        row.name.localizedCaseInsensitiveContains(query)
            || row.chapterPath.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Passt die Zeile NUR über ihren Inhalt (Volltext), nicht über Name oder
    /// Kapitelpfad? Dann trägt sie das „im Text"-Badge. Bei leerer Suche nie.
    static func isContentOnlyMatch(_ row: PagePickerRow, query: String,
                                   contentMatches: Set<Int>) -> Bool {
        guard !query.isEmpty, contentMatches.contains(row.id) else { return false }
        return !matchesNameOrChapter(row, query: query)
    }
}
