//
//  BookExport.swift
//  schreibwerkstatt-focuseditor
//
//  Setzt aus den Seiten eines Buchs EIN Markdown-Dokument zusammen — die
//  Textform, in der das Manuskript den Client verlässt.
//
//  Quelle ist ausschliesslich der LOKALE Spiegel: was der Client hat, kann er
//  exportieren, auch offline. Nie gepullte Seiten (Body nie gesehen) werden
//  nicht erfunden, sondern als fehlend ausgewiesen — dieselbe Ehrlichkeit wie
//  das „—" im Seiten-Picker. Ein Export, der stillschweigend Lücken hat, wäre
//  schlimmer als gar keiner: er sieht aus wie ein vollständiges Backup.
//
//  Pure Funktionen, kein Dateisystem, keine UI (Testgegenstand von
//  `BookExportTests`); die Save-Panel-Seite liegt in BookExportController.swift.
//

import Foundation

enum BookExport {

    /// Eine Seite, wie sie in den Export eingeht — in Baumreihenfolge.
    struct Entry {
        let name: String
        /// Kapitelpfad von aussen nach innen; leer = Seite auf Buchebene.
        let chapterPath: [String]
        /// Seiten-HTML aus dem lokalen Spiegel. `nil` = nie gepullt.
        let html: String?
    }

    struct Result {
        let markdown: String
        /// Namen der Seiten ohne lokalen Body — die UI nennt sie hinterher.
        let missingPages: [String]
    }

    /// Baut das Dokument. `now` ist injizierbar, damit der Test einen festen
    /// Zeitstempel prüfen kann.
    static func document(bookTitle: String, entries: [Entry], now: Date,
                         locale: Locale = .current, timeZone: TimeZone = .current) -> Result {
        var out: [String] = ["# \(bookTitle)"]
        var missing: [String] = []
        /// Zuletzt ausgegebener Kapitelpfad — Überschriften nur beim Wechsel.
        var lastPath: [String] = []

        for entry in entries {
            // Kapitelüberschriften für jede Ebene, die neu ist. Ein Wechsel auf
            // einer oberen Ebene macht alle darunter ebenfalls neu, darum wird
            // ab der ersten Abweichung durchgeschrieben.
            let common = commonPrefixLength(lastPath, entry.chapterPath)
            for level in common..<entry.chapterPath.count {
                // Buchtitel ist H1 → Kapitel starten bei H2.
                out.append(String(repeating: "#", count: min(level + 2, 6)) + " " + entry.chapterPath[level])
            }
            lastPath = entry.chapterPath

            // Seitentitel eine Ebene unter ihrem Kapitel.
            let pageLevel = min(entry.chapterPath.count + 2, 6)
            out.append(String(repeating: "#", count: pageLevel) + " " + entry.name)

            guard let html = entry.html else {
                missing.append(entry.name)
                out.append("*\(t("export.missingPage"))*")
                continue
            }
            let body = HTMLToMarkdown.convert(html)
            out.append(body.isEmpty ? "*\(t("export.emptyPage"))*" : body)
        }

        let stamp = timestamp(now, locale: locale, timeZone: timeZone)
        out.append("---")
        out.append("*" + t("export.footer", ["date": stamp]) + "*")

        return Result(markdown: out.joined(separator: "\n\n") + "\n", missingPages: missing)
    }

    /// Dateiname-Vorschlag: Buchtitel, entschärft für das Dateisystem.
    /// `/` und `:` sind unter macOS in Dateinamen verboten (`:` wird im Finder
    /// als `/` angezeigt) — beide werden zum Bindestrich.
    static func suggestedFilename(bookTitle: String) -> String {
        var name = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\n", "\r", "\t"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        // Führende Punkte machen die Datei unsichtbar.
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Export" : name
    }

    // MARK: - Helpers

    static func commonPrefixLength(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    private static func timestamp(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
