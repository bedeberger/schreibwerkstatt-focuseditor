//
//  BrandFont.swift
//  schreibwerkstatt-focuseditor
//
//  Native Entsprechung der Typografie-Tokens
//  (public/css/tokens/typography.css). Das Web-Bundle nutzt self-hosted
//  Inter (Sans) + Source Serif 4 (Headings/Reading). Damit das native Chrome
//  (Login-Hero, Überschriften, Dialoge) GENAU wie die Schreibfläche wirkt,
//  bündeln wir dieselben beiden Familien als variable TTFs und registrieren sie
//  zur Laufzeit (CTFontManager) — kein ATSApplicationFontsPath nötig (das
//  Projekt generiert sein Info.plist). Fehlen die Ressourcen, fällt jede
//  Funktion sauber auf die System-Pendants zurück (SF / .serif-Design).
//
//  Variable Fonts: Das Gewicht setzen wir über den Weight-Trait des
//  Font-Descriptors (nicht über eine fixierte `wght`-Variation), damit Core Text
//  die optische Grösse (opsz-Achse) weiter automatisch an die Punktgrösse
//  koppelt.
//

import SwiftUI
import AppKit
import CoreText

enum BrandFont {
    /// Serif (editorial) — Headings, Wordmark, Reading-Frame.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        FontLoader.ensureRegistered()
        if FontLoader.hasSerif {
            return custom(family: FontLoader.serifFamily, size: size, weight: weight, fallback: .serif)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// Sans (UI) — Buttons, Labels, dichte Bedienelemente.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        FontLoader.ensureRegistered()
        if FontLoader.hasSans {
            return custom(family: FontLoader.sansFamily, size: size, weight: weight, fallback: .default)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    /// Baut einen `Font` aus einer gebündelten Familie mit gesetztem Gewicht.
    /// Der Weight-Trait des Descriptors lässt Core Text das passende Gewicht der
    /// variablen `wght`-Achse wählen und erhält die Auto-Optical-Size.
    private static func custom(family: String, size: CGFloat,
                               weight: Font.Weight, fallback: Font.Design) -> Font {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight).rawValue],
        ])
        if let nsFont = NSFont(descriptor: descriptor, size: size) {
            return Font(nsFont)
        }
        return .system(size: size, weight: weight, design: fallback)
    }

    /// Font.Weight → NSFont.Weight (gleiche Stufen; default → .regular).
    private static func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}

/// Registriert die gebündelten variablen Fonts einmalig pro Prozess. Idempotent
/// und MainActor-isoliert (Default-Isolation des Projekts) — die `BrandFont`-
/// Funktionen rufen aus dem View-Body, also vom MainActor.
private enum FontLoader {
    /// Familiennamen, unter denen die variablen TTFs registriert sind (aus den
    /// `name`-Tabellen der konvertierten Fonts).
    static let serifFamily = "Source Serif 4 Variable"
    static let sansFamily  = "Inter Variable"

    private(set) static var hasSerif = false
    private(set) static var hasSans  = false
    private static var done = false

    static func ensureRegistered() {
        guard !done else { return }
        done = true
        // Upright zuerst (entscheidet die Verfügbarkeit); Kursiv best-effort
        // dahinter, damit `.italic()` dieselbe Familie findet.
        hasSerif = register("SourceSerif4-VF")
        _ = register("SourceSerif4-Italic-VF")
        hasSans = register("Inter-VF")
        _ = register("Inter-Italic-VF")
    }

    /// Registriert eine gebündelte TTF im Prozess-Scope. Liefert `true`, wenn der
    /// Font danach verfügbar ist (frisch registriert ODER bereits registriert).
    private static func register(_ resource: String) -> Bool {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }
        if let cfError = error?.takeRetainedValue(),
           CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        return false
    }
}
