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

// MARK: - App-Sprache

/// Wahl der Oberflächensprache. `system` folgt der Systemsprache (de/en).
/// Der zugehörige `LocalizationController` (SwiftUI-Re-Render + Server-Seeding
/// via EditorBridge) liegt bewusst in `LocalizationController.swift` — so bleibt
/// dieser Übersetzungs-Kern dependency-frei und im Offline-Test-Target nutzbar.
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
