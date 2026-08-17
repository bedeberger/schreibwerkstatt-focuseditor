//
//  NumberText.swift
//  schreibwerkstatt-focuseditor
//
//  Zahlen in der App-Sprache: Tausender-Gruppierung (de „12 400", en „12,400")
//  und die Plural-Auswahl für Zähl-Texte MIT gruppierter Zahl.
//
//  Warum eigen: `tn()` setzt `{n}` selbst auf die nackte Zahl und lässt sich
//  darum nicht mit einer formatierten überschreiben (s. Localization.swift).
//  Für vier- und fünfstellige Zeichenzahlen im Seiten-Picker ist die
//  Gruppierung aber genau der Unterschied zwischen lesbar und Ziffernbrei.
//

import Foundation

enum NumberText {

    /// Wiederverwendeter Formatter — wie `RelativeTime.formatter` bewusst EIN
    /// Objekt: der Seiten-Picker formatiert pro sichtbarer Zeile, ein neuer
    /// `NumberFormatter` pro Zelle wäre beim Scrollen spürbar. Die Locale wird vor
    /// jeder Nutzung nachgeführt (App-Sprache umstellbar).
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Gruppierte Zahl in der REGION des Systems (de-CH → „12'400", de-DE →
    /// „12.400", en-US → „12,400").
    ///
    /// Bewusst die Region und NICHT die App-Sprache: Zahlformate hängen am
    /// Ländereinstellung, nicht an der Oberflächensprache — und genauso formatiert
    /// SwiftUI selbst, wenn eine Zahl in `Text("\(n)")` interpoliert wird (z. B. die
    /// Trefferzahl im Suchfeld des Pickers). Mit `Locale(identifier: "de")` standen
    /// im selben Picker „2'498" (SwiftUI) und „2.498" (hier) nebeneinander.
    static func grouped(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let f = formatter
        f.locale = locale
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Plural-Text mit gruppierter Zahl: wählt `<baseKey>.one` / `.other` (nach
    /// APP-SPRACHE — das ist Grammatik) und setzt `{n}` auf die nach Region
    /// formatierte Zahl (z. B. „12'400 Zeichen").
    static func plural(_ value: Int, _ baseKey: String,
                       locale: Locale = .autoupdatingCurrent) -> String {
        t(value == 1 ? "\(baseKey).one" : "\(baseKey).other",
          ["n": grouped(value, locale: locale)])
    }
}
