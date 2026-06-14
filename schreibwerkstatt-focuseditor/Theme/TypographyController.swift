//
//  TypographyController.swift
//  schreibwerkstatt-focuseditor
//
//  Lokale Editor-Typografie — analog zu AppearanceController/FocusController.
//  Steuert, WIE der gebündelte Focus-Editor den Fließtext darstellt:
//  Schriftgrösse, Zeilenhöhe, Spaltenbreite (measure), Schriftfamilie und
//  Papier-Ton. Bewusst LOKAL (UserDefaults) — reine Anzeige-Vorlieben pro
//  Gerät, kein Inhalt, kein Netzwerk (Speicherort-Entscheid: client-lokal).
//
//  Kein Editor-Fork (HARTE REGEL): Die Werte fliessen als FERTIGE CSS-Strings
//  über die Bridge in die WebView; der Boot-Glue (WebAssets.indexHTML) setzt sie
//  als CSS-Custom-Properties auf :root und injiziert EIN <style>, das den
//  Editor-Content (.focus-editor__content) überschreibt. Damit bleibt der
//  Editor-Code unangetastet — wir legen nur eine Override-Schicht darüber.
//
//   • Boot-Pull  — die Bridge-Op `editorTypography` liest `EditorBridge.typography`.
//   • Live-Push  — `EditorBridge.pushTypography()` schickt das Event
//     `editorTypography` in die WebView (sofortige Wirkung bei offenem Editor).
//

import SwiftUI
import Combine

/// Schriftfamilie des Fliesstexts. RawValue wird persistiert.
enum EditorFontFamily: String, CaseIterable, Identifiable {
    case serif
    case sans

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: return "Serif (Source Serif)"
        case .sans:  return "Sans (Inter)"
        }
    }

    /// CSS-Font-Stack — spiegelt die self-hosted Stacks des Web-Bundles mit
    /// System-Fallbacks (greift, falls die OTA-Schriften nicht laden).
    var cssStack: String {
        switch self {
        case .serif: return "'Source Serif 4', 'Source Serif Pro', ui-serif, Georgia, serif"
        case .sans:  return "'Inter', ui-sans-serif, system-ui, -apple-system, sans-serif"
        }
    }
}

/// Papier-Ton der Schreibfläche. „System" lässt die Fläche transparent, sodass
/// die native Brand-Fläche (Light/Dark) durchscheint; alle anderen erzwingen
/// einen festen Hintergrund/Textton (augenschonend bzw. kontraststark).
enum PaperTone: String, CaseIterable, Identifiable {
    case system
    case paper
    case sepia
    case night
    case highContrast = "high-contrast"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:       return "System (folgt Hell/Dunkel)"
        case .paper:        return "Papier (warm)"
        case .sepia:        return "Sepia"
        case .night:        return "Nacht"
        case .highContrast: return "Hoher Kontrast"
        }
    }

    /// (Hintergrund, Text) als CSS-Farben — `nil` heisst „nicht überschreiben".
    var colors: (bg: String, text: String)? {
        switch self {
        case .system:       return nil
        case .paper:        return ("#faf7f2", "#1f1c18")
        case .sepia:        return ("#f4ecd8", "#4a3f2f")
        case .night:        return ("#1a1816", "#e6e2d9")
        case .highContrast: return ("#ffffff", "#111111")
        }
    }
}

/// Hält die Typografie-Einstellungen, persistiert sie und reicht sie als
/// CSS-fertiges Payload an die Editor-Bridge weiter. `bind(_:)` koppelt die
/// Bridge nach (wie FocusController) — bis dahin trägt die Bridge den
/// persistierten Default selbst (Boot-Pull greift dann korrekt).
@MainActor
final class TypographyController: ObservableObject {
    private weak var bridge: EditorBridge?

    // UserDefaults-Schlüssel (auch von EditorBridge gelesen, damit der Boot-Pull
    // schon vor `bind(_:)` den richtigen Wert liefert).
    enum Key {
        static let fontSize = "typo.fontSize"
        static let lineHeight = "typo.lineHeight"
        static let measure = "typo.measure"       // 0 = aus (keine Spaltenbreite)
        static let fontFamily = "typo.fontFamily"
        static let paperTone = "typo.paperTone"
        static let focusDimEnabled = "typo.focusDimEnabled"
        static let focusDimOpacity = "typo.focusDimOpacity"
    }

    // Grenzen (auch in der Settings-UI verwendet).
    static let fontSizeRange: ClosedRange<Double> = 14...30
    static let lineHeightRange: ClosedRange<Double> = 1.3...2.2
    static let measureRange: ClosedRange<Double> = 40...100   // in `ch`; 0 = aus
    static let focusDimRange: ClosedRange<Double> = 0.05...0.6   // Opazität der abgeblendeten Umgebung

    @Published var fontSize: Double { didSet { persist(fontSize, Key.fontSize); apply() } }
    @Published var lineHeight: Double { didSet { persist(lineHeight, Key.lineHeight); apply() } }
    /// Maximale Spaltenbreite in `ch`. 0 = unbegrenzt (Editor-Default).
    @Published var measure: Double { didSet { persist(measure, Key.measure); apply() } }
    @Published var fontFamily: EditorFontFamily {
        didSet { UserDefaults.standard.set(fontFamily.rawValue, forKey: Key.fontFamily); apply() }
    }
    @Published var paperTone: PaperTone {
        didSet { UserDefaults.standard.set(paperTone.rawValue, forKey: Key.paperTone); apply() }
    }
    /// Eigene Fokus-Abdunklung aktiv? Aus = Editor-Default (theme-korrekt, kein
    /// Override). An = überschreibt die Opazität der nicht-aktiven Absätze.
    @Published var focusDimEnabled: Bool {
        didSet { UserDefaults.standard.set(focusDimEnabled, forKey: Key.focusDimEnabled); apply() }
    }
    /// Opazität der abgeblendeten Umgebung (kleiner = stärker abgedunkelt).
    @Published var focusDimOpacity: Double {
        didSet { persist(focusDimOpacity, Key.focusDimOpacity); apply() }
    }

    init() {
        let d = UserDefaults.standard
        fontSize = Self.read(d, Key.fontSize, default: 19, in: Self.fontSizeRange)
        lineHeight = Self.read(d, Key.lineHeight, default: 1.7, in: Self.lineHeightRange)
        // measure: 0 (aus) ausdrücklich erlauben, sonst in die Range klemmen.
        let m = d.object(forKey: Key.measure) as? Double ?? 64
        measure = (m == 0) ? 0 : min(max(m, Self.measureRange.lowerBound), Self.measureRange.upperBound)
        fontFamily = EditorFontFamily(rawValue: d.string(forKey: Key.fontFamily) ?? "") ?? .serif
        paperTone = PaperTone(rawValue: d.string(forKey: Key.paperTone) ?? "") ?? .system
        focusDimEnabled = (d.object(forKey: Key.focusDimEnabled) as? Bool) ?? false
        focusDimOpacity = Self.read(d, Key.focusDimOpacity, default: 0.35, in: Self.focusDimRange)
    }

    /// Verbindet den Controller mit der app-weiten Bridge und spiegelt den
    /// aktuellen Stand hinein (Boot-Pull liefert ihn dann korrekt). Idempotent.
    func bind(_ bridge: EditorBridge) {
        self.bridge = bridge
        bridge.typography = payload()
    }

    /// Setzt alle Werte auf die Standardvorgaben zurück.
    func resetToDefaults() {
        fontSize = 19
        lineHeight = 1.7
        measure = 64
        fontFamily = .serif
        paperTone = .system
        focusDimEnabled = false
        focusDimOpacity = 0.35
    }

    // MARK: - Bridge-Payload

    /// CSS-fertiges Payload für die WebView (alle Strings direkt setzbar).
    func payload() -> [String: Any] {
        var dict: [String: Any] = [
            "fontSize": "\(Int(fontSize.rounded()))px",
            "lineHeight": String(format: "%.2f", lineHeight),
            "measure": measure == 0 ? "none" : "\(Int(measure.rounded()))ch",
            "fontFamily": fontFamily.cssStack,
        ]
        if let c = paperTone.colors {
            dict["paperBg"] = c.bg
            dict["paperText"] = c.text
        } else {
            dict["paperBg"] = NSNull()
            dict["paperText"] = NSNull()
        }
        // Fokus-Abdunklung: nur überschreiben, wenn eingeschaltet — sonst null
        // (Editor-Default, theme-korrekt). Wert als Opazitäts-String.
        dict["focusDim"] = focusDimEnabled ? String(format: "%.2f", focusDimOpacity) : NSNull()
        return dict
    }

    private func apply() {
        guard let bridge else { return }
        bridge.typography = payload()
        Task { await bridge.pushTypography() }
    }

    // MARK: - Persistenz-Helfer

    private func persist(_ value: Double, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func read(_ d: UserDefaults, _ key: String,
                             default def: Double, in range: ClosedRange<Double>) -> Double {
        guard d.object(forKey: key) != nil else { return def }
        let v = d.double(forKey: key)
        return min(max(v, range.lowerBound), range.upperBound)
    }
}
