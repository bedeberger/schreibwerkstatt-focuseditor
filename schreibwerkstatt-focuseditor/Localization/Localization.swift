//
//  Localization.swift
//  schreibwerkstatt-focuseditor
//
//  Zweisprachige (de/en) Oberfläche des nativen macOS-Clients. Die Strings der
//  App-Shell sind macOS-spezifisch (Settings, Toolbar, Kürzel-Hilfe, Login, …)
//  und existieren NICHT in der Web-i18n — sie haben einen eigenen Namespace
//  `macclient.*`.
//
//  Quelle der Strings (Fallback-Kette, gespiegelt aus der Web-`i18n.js`):
//    OTA[locale][key]  →  bundled[locale][key]  →  bundled["de"][key]  →  key
//
//   • bundled — im App-Bundle mitgelieferte `mac-de.json`/`mac-en.json`. Garantie
//     für Offline-/Erststart (CLAUDE.md Offline-Kern: kein Netz beim ersten Start
//     der UI nötig).
//   • OTA      — optionaler Server-Override (I18nBundleStore zieht/cacht ihn,
//     ETag-getrieben). Greift wie das Editor-Bundle erst beim NÄCHSTEN Start.
//     Solange kein Override da ist (oder Server `404`), zählt der gebündelte
//     Stand — stilles Degradieren, kein Fehler.
//
//  HARTE REGEL: Strings werden NIE direkt im Code dupliziert — immer `t(key)`.
//  Plural über `tn(count, baseKey)` (wählt `<key>.one` / `<key>.other`).
//
//  MainActor-Default-Isolation des Projekts: `t()`/`tn()` und der `L10nStore`
//  sind bewusst `nonisolated`, damit auch nicht-isolierte Aufrufer (z. B.
//  `AuthError.errorDescription`, Enum-`label`s) sie verwenden können.
//

import Foundation
import Combine

// MARK: - Lookup-Store (thread-sicher, isolations-frei)

/// Hält die geladenen Kataloge und löst Keys auf. Bewusst `nonisolated` und
/// lock-geschützt, damit der Lookup von überall (auch von Hintergrund-Threads
/// und nicht-isolierten Protokoll-Anforderungen) sicher ist.
nonisolated final class L10nStore: @unchecked Sendable {
    static let shared = L10nStore()

    private let lock = NSLock()
    /// locale → (key → value)
    private var bundled: [String: [String: String]] = [:]
    private var ota: [String: [String: String]] = [:]
    private var locale: String = "de"

    /// Pfad des gecachten OTA-Overrides (vom I18nBundleStore geschrieben).
    static var otaCacheURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
            .appendingPathComponent("i18n-cache.json")
    }

    private init() {
        loadBundled()
        loadOTAFromCache()
    }

    // MARK: Laden

    /// Lädt die im App-Bundle mitgelieferten Kataloge (Offline-Fallback).
    private func loadBundled() {
        var loaded: [String: [String: String]] = [:]
        for code in ["de", "en"] {
            if let dict = Self.readCatalog(bundleResource: "mac-\(code)") {
                loaded[code] = dict
            }
        }
        lock.lock(); bundled = loaded; lock.unlock()
    }

    /// Lädt den gecachten OTA-Override (falls vorhanden). Format:
    /// `{ "de": { key: value, … }, "en": { … } }`.
    func loadOTAFromCache() {
        guard let data = try? Data(contentsOf: Self.otaCacheURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return }
        lock.lock(); ota = parsed; lock.unlock()
    }

    private static func readCatalog(bundleResource name: String) -> [String: String]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return dict
    }

    // MARK: Setzen

    func setLocale(_ code: String) {
        lock.lock(); locale = code; lock.unlock()
    }

    /// Aktive Locale ("de"/"en") — z. B. für `RelativeDateTimeFormatter`.
    var localeCode: String {
        lock.lock(); defer { lock.unlock() }
        return locale
    }

    // MARK: Auflösen

    func resolve(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return ota[locale]?[key]
            ?? bundled[locale]?[key]
            ?? bundled["de"]?[key]
            ?? key
    }

    /// Ersetzt `{name}`-Platzhalter (gleiche Syntax wie die Web-i18n).
    static func interpolate(_ template: String, _ params: [String: String]) -> String {
        guard !params.isEmpty else { return template }
        var out = template
        for (k, v) in params {
            out = out.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return out
    }
}

// MARK: - Globale Kurzformen

/// Übersetzt `key` in der aktiven Sprache und ersetzt `{param}`-Platzhalter.
nonisolated func t(_ key: String, _ params: [String: String] = [:]) -> String {
    L10nStore.interpolate(L10nStore.shared.resolve(key), params)
}

/// Plural-Variante: wählt `<baseKey>.one` (count == 1) bzw. `<baseKey>.other`
/// und stellt die Zahl als `{n}` bereit.
nonisolated func tn(_ count: Int, _ baseKey: String, _ params: [String: String] = [:]) -> String {
    var p = params
    p["n"] = "\(count)"
    return t(count == 1 ? "\(baseKey).one" : "\(baseKey).other", p)
}

// MARK: - App-Sprache + Controller (SwiftUI-Re-Render)

/// Wahl der Oberflächensprache. `system` folgt der Systemsprache (de/en).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case de
    case en

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return t("settings.language.system")
        case .de:     return "Deutsch"
        case .en:     return "English"
        }
    }
}

/// MainActor-ObservableObject als Re-Render-Auslöser für SwiftUI. Der eigentliche
/// Lookup läuft über den nicht-isolierten `L10nStore`; dieser Controller hält nur
/// die gewählte Sprache, persistiert sie und schiebt die effektive Locale in den
/// Store. Views, die ihn als `@EnvironmentObject` halten, rendern bei einem
/// Sprachwechsel neu (und lesen damit frische `t()`-Werte).
@MainActor
final class LocalizationController: ObservableObject {
    static let storageKey = "app.language"

    private weak var bridge: EditorBridge?

    /// Hat der Nutzer lokal gewählt? Genau dann liegt ein UserDefaults-Eintrag
    /// vor — Server-Seeding ist dann gesperrt (lokale Wahl gewinnt dauerhaft).
    private var hasLocalOverride: Bool {
        UserDefaults.standard.object(forKey: Self.storageKey) != nil
    }

    /// Unterdrückt die Persistenz, während ein Server-Default eingespielt wird:
    /// Seeding soll NICHT als lokale Wahl zählen (sonst friert der erste Server-
    /// Wert die „folgt dem Server"-Semantik ein).
    private var isSeeding = false

    @Published var language: AppLanguage {
        didSet {
            if !isSeeding {
                UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            }
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
        guard !hasLocalOverride, let bridge else { return }
        guard let raw = await bridge.serverLocale(),
              let server = AppLanguage(rawValue: raw) else { return }
        guard !hasLocalOverride, server != language else { return }
        isSeeding = true
        language = server      // aktualisiert UI + Locale, ohne zu persistieren
        isSeeding = false
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
