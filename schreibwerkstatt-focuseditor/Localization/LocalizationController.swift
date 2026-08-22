//
//  LocalizationController.swift
//  schreibwerkstatt-focuseditor
//
//  SwiftUI-Re-Render-Auslöser für den Sprachwechsel. Bewusst getrennt vom
//  Übersetzungs-Kern (`Localization.swift`: L10nStore + t()/tn() + AppLanguage):
//  Dieser Controller hängt an `EditorBridge` (Server-Default via /config), der
//  Kern bleibt dagegen dependency-frei und damit im Offline-Test-Target nutzbar
//  (geteilte `AuthError.errorDescription` ruft `t()`). Siehe Localization.swift.
//

import Foundation
import Combine

/// MainActor-ObservableObject als Re-Render-Auslöser für SwiftUI. Der eigentliche
/// Lookup läuft über den nicht-isolierten `L10nStore`; dieser Controller hält nur
/// die gewählte Sprache, persistiert sie und schiebt die effektive Locale in den
/// Store. Views, die ihn als `@EnvironmentObject` halten, rendern bei einem
/// Sprachwechsel neu (und lesen damit frische `t()`-Werte).
@MainActor
final class LocalizationController: ObservableObject {
    static let storageKey = "app.language"

    private weak var bridge: EditorBridge?

    /// „Lokale Wahl gewinnt, sonst folgt der Server" — inklusive der Regel, dass
    /// ein eingespielter Server-Wert NICHT als lokale Wahl zählen darf
    /// ([ServerSeededChoice](../Theme/ServerSeededChoice.swift)).
    private let choice = ServerSeededChoice(storageKey: LocalizationController.storageKey)

    @Published var language: AppLanguage {
        didSet {
            choice.persist(language.rawValue)
            apply()
        }
    }

    /// Effektive Locale ("de" oder "en") — abgeleitet aus `language` bzw. System.
    @Published private(set) var locale: String = "de"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        language = AppLanguage(rawValue: raw) ?? .system
        apply()
    }

    /// Verbindet den Controller mit der app-weiten Bridge (Quelle für den
    /// Server-Default). Idempotent. Vor `seedFromServerIfNeeded()` aufrufen.
    func bind(_ bridge: EditorBridge) {
        self.bridge = bridge
    }

    /// Zieht die UI-Sprache aus dem Server-Profil (`/config` →
    /// userSettings.locale), solange der Nutzer lokal nichts gewählt hat. Nach
    /// jedem Anmelden aufrufen (der `/config`-Request braucht ein gültiges
    /// Token). Offline/Fehler → bleibt beim aktuellen Wert (System-Fallback).
    /// Eine zwischenzeitliche lokale Wahl gewinnt. Der Seed-Wert wird NICHT
    /// persistiert, damit die „folgt dem Server"-Semantik erhalten bleibt.
    func seedFromServerIfNeeded() async {
        guard !choice.hasLocalOverride, let bridge else { return }
        guard let raw = await bridge.serverLocale() else { return }
        // Server liefert ggf. eine regionale Locale (z. B. "de-CH", s. CLAUDE.md
        // getBookLocale) — exakte `rawValue`-Zuordnung würde daran scheitern. Auf
        // de/en normalisieren (gleiche Regel wie `resolveLocale`).
        let server: AppLanguage = raw.lowercased().hasPrefix("de") ? .de : .en
        // Erneut prüfen: der `await` oben gibt dem Nutzer Zeit, inzwischen selbst
        // zu wählen — die lokale Wahl darf der Seed nicht überschreiben.
        guard !choice.hasLocalOverride, server != language else { return }
        choice.seed { language = server }      // UI + Locale, ohne zu persistieren
    }

    private func apply() {
        let resolved = Self.resolveLocale(for: language)
        locale = resolved
        L10nStore.shared.setLocale(resolved)
    }

    /// Bildet die gewählte Sprache auf eine konkrete Locale ab. `system` liest die
    /// bevorzugte Systemsprache; alles außer Deutsch fällt auf Englisch (die App
    /// liefert genau de/en).
    private static func resolveLocale(for language: AppLanguage) -> String {
        switch language {
        case .de: return "de"
        case .en: return "en"
        case .system:
            let pref = Locale.preferredLanguages.first ?? "de"
            return pref.lowercased().hasPrefix("de") ? "de" : "en"
        }
    }
}
