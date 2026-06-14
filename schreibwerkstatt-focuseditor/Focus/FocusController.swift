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
//  Initial-Default: Solange der Nutzer hier NICHT selbst gewählt hat (kein
//  UserDefaults-Eintrag), folgt die Stufe dem Server-Wert (`/config` →
//  userSettings.focus_granularity, die Web-Einstellung). Sobald lokal gewählt
//  wird, gewinnt die lokale Wahl dauerhaft — `seedFromServerIfNeeded()` ist dann
//  ein No-op. So bleibt der Default offline-sicher und web-synchron zugleich.
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

    /// Hat der Nutzer lokal gewählt? Genau dann liegt ein UserDefaults-Eintrag
    /// vor — Server-Seeding ist dann gesperrt (lokale Wahl gewinnt dauerhaft).
    private var hasLocalOverride: Bool {
        UserDefaults.standard.object(forKey: FocusGranularity.storageKey) != nil
    }

    /// Unterdrückt die Persistenz, während ein Server-Default eingespielt wird:
    /// Seeding soll NICHT als lokale Wahl zählen (sonst friert der erste Server-
    /// Wert die „folgt dem Server"-Semantik ein).
    private var isSeeding = false

    @Published var granularity: FocusGranularity {
        didSet {
            if !isSeeding {
                UserDefaults.standard.set(granularity.rawValue, forKey: FocusGranularity.storageKey)
            }
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

    /// Zieht den Server-Default (`/config` → userSettings.focus_granularity),
    /// solange der Nutzer lokal nichts gewählt hat. Nach jedem Anmelden aufrufen
    /// (der `/config`-Request braucht ein gültiges Token). Offline/Fehler →
    /// bleibt beim aktuellen Wert. Eine zwischenzeitliche lokale Wahl gewinnt.
    func seedFromServerIfNeeded() async {
        guard !hasLocalOverride, let bridge else { return }
        guard let raw = await bridge.serverFocusGranularity(),
              let server = FocusGranularity(rawValue: raw) else { return }
        guard !hasLocalOverride, server != granularity else { return }
        isSeeding = true
        granularity = server      // aktualisiert UI + pusht live, ohne zu persistieren
        isSeeding = false
    }

    /// Spiegelt die Wahl in die Bridge (Op-Antwort) und pusht sie live in die
    /// WebView. No-op vor `bind(_:)` oder ohne offene WebView.
    private func apply() {
        guard let bridge else { return }
        bridge.focusGranularity = granularity.rawValue
        Task { await bridge.pushFocusGranularity() }
    }
}
