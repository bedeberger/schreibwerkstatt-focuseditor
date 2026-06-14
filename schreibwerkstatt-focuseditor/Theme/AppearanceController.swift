//
//  AppearanceController.swift
//  schreibwerkstatt-focuseditor
//
//  Manueller Light/Dark/System-Umschalter. Setzt `NSApp.appearance` —
//  das wirkt in einem Zug auf die native Shell (BrandColor löst dynamisch
//  über die Effective-Appearance auf) UND auf die WKWebView (der Editor
//  liest `prefers-color-scheme` aus derselben Appearance). Die Wahl wird
//  in UserDefaults persistiert; `.system` (= nil) folgt wieder dem OS.
//

import SwiftUI
import AppKit
import Combine

/// Drei Modi: dem System folgen, oder Hell/Dunkel erzwingen.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Menü-Beschriftung (lokalisiert).
    var label: String {
        switch self {
        case .system: return t("appearance.mode.system")
        case .light:  return t("appearance.mode.light")
        case .dark:   return t("appearance.mode.dark")
        }
    }

    /// Das app-weit zu setzende NSAppearance — `nil` heisst „System folgen".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

/// Hält die gewählte Appearance, persistiert sie und wendet sie app-weit an.
@MainActor
final class AppearanceController: ObservableObject {
    private static let storageKey = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        mode = AppearanceMode(rawValue: raw) ?? .system
        apply()
    }

    /// Setzt die Appearance auf der laufenden NSApplication. Idempotent.
    func apply() {
        NSApplication.shared.appearance = mode.nsAppearance
    }
}
