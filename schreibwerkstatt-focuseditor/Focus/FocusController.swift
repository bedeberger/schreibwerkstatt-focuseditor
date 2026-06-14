//
//  FocusController.swift
//  schreibwerkstatt-focuseditor
//
//  Lokale Fokus-Granularität — analog zum AppearanceController. Die Mutter-App
//  führt diese Einstellung serverseitig pro User (`app_users.focus_granularity`,
//  Werte siehe `VALID_FOCUS_GRANULARITIES` in routes/usersettings.js). Hier ist
//  sie bewusst LOKAL (UserDefaults): der Offline-Kern soll ohne Netz wählbar
//  bleiben, und der native Client darf vom Server-Default abweichen.
//
//  Geliefert wird der Wert an den Editor über die Bridge:
//   • Pull beim Boot — die `focusGranularity`-Op liest `EditorBridge.focusGranularity`.
//   • Push bei Änderung — `EditorBridge.pushFocusGranularity()` schickt das Event
//     `focusGranularity` live in die WebView (Umschalten bei offenem Editor).
//

import SwiftUI
import Combine

/// Die vier Fokus-Stufen des Editors. RawValue = exakt der String, den die
/// Focus-Engine als CSS-Klasse `focus-mode--<raw>` erwartet (Mutter-App-Vertrag).
enum FocusGranularity: String, CaseIterable, Identifiable {
    case paragraph
    case sentence
    case window3 = "window-3"
    case typewriterOnly = "typewriter-only"

    /// UserDefaults-Schlüssel — von EditorBridge UND FocusController genutzt
    /// (die Bridge liest den persistierten Wert als Boot-Default ohne Binding).
    static let storageKey = "focusGranularity"

    var id: String { rawValue }

    /// Menü-/Settings-Beschriftung (de, gespiegelt aus der Mutter-App-i18n).
    var label: String {
        switch self {
        case .paragraph:      return "Absatz (Standard)"
        case .sentence:       return "Satz"
        case .window3:        return "Drei Absätze (vor + aktiv + nach)"
        case .typewriterOnly: return "Nur Typewriter-Scroll (kein Dim)"
        }
    }
}

/// Hält die gewählte Fokus-Granularität, persistiert sie und reicht sie an die
/// Editor-Bridge weiter. `bind(_:)` koppelt die Bridge nach (wie `attach` bei
/// der WebView) — bis dahin trägt die Bridge den persistierten Default selbst.
@MainActor
final class FocusController: ObservableObject {
    private weak var bridge: EditorBridge?

    @Published var granularity: FocusGranularity {
        didSet {
            UserDefaults.standard.set(granularity.rawValue, forKey: FocusGranularity.storageKey)
            apply()
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: FocusGranularity.storageKey) ?? ""
        granularity = FocusGranularity(rawValue: raw) ?? .paragraph
    }

    /// Verbindet den Controller mit der app-weiten Bridge und spiegelt den
    /// aktuellen Wert hinein (Boot-Pull liefert ihn dann korrekt). Idempotent.
    func bind(_ bridge: EditorBridge) {
        self.bridge = bridge
        bridge.focusGranularity = granularity.rawValue
    }

    /// Spiegelt die Wahl in die Bridge (Op-Antwort) und pusht sie live in die
    /// WebView. No-op vor `bind(_:)` oder ohne offene WebView.
    private func apply() {
        guard let bridge else { return }
        bridge.focusGranularity = granularity.rawValue
        Task { await bridge.pushFocusGranularity() }
    }
}
