//
//  RelativeTime.swift
//  schreibwerkstatt-focuseditor
//
//  „vor 3 Std."-Zeitangaben in der App-Sprache — an einer Stelle, statt an jeder
//  Anzeigestelle einen eigenen `RelativeDateTimeFormatter` zu bauen.
//
//  Liegt in `Localization/`, weil der Helfer allein wegen der App-Sprache
//  existiert: der Formatter muss die aktive Locale tragen (s. `L10nStore.localeCode`),
//  sonst spricht die Zeitangabe Systemsprache, während der Rest der UI de/en folgt.
//
//  Nutzung: Picker-Zeilen, Sync-Tooltip der Toolbar, Einstellungen → Sync,
//  Konflikt-Sheet.
//

import Foundation

enum RelativeTime {

    /// Wiederverwendeter Formatter — `RelativeDateTimeFormatter` ist teuer in der
    /// Erzeugung; bei einem grossen Buch würde ein neuer pro Zeile/Render beim
    /// Scrollen spürbar bremsen. Die Locale wird vor jeder Nutzung nachgeführt
    /// (falls der Nutzer die App-Sprache umstellt). MainActor-gebunden wie die
    /// Views, die ihn nutzen — darum ist das gemeinsame Objekt unkritisch.
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Kurze Relativ-Zeit in der App-Sprache (z. B. „vor 3 Std.").
    ///
    /// - Parameter localeCode: Standardmässig die aktive App-Sprache. Views, die am
    ///   `LocalizationController` hängen, übergeben dessen `locale` explizit — so
    ///   bleibt die SwiftUI-Abhängigkeit sichtbar und die Ansicht rendert beim
    ///   Sprachwechsel neu (ein Zugriff auf `L10nStore.shared` allein tut das nicht).
    static func string(for date: Date,
                       localeCode: String = L10nStore.shared.localeCode,
                       relativeTo reference: Date = Date()) -> String {
        let f = formatter
        f.locale = Locale(identifier: localeCode)
        return f.localizedString(for: date, relativeTo: reference)
    }
}
