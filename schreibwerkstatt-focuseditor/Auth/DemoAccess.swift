//
//  DemoAccess.swift
//  schreibwerkstatt-focuseditor
//
//  Optionaler Demo-Zugang für den Login („Demo öffnen"): Server-Host +
//  Device-Token eines Wegwerf-Demo-Kontos, die zur BUILD-Zeit ins Bundle
//  gebacken werden.
//
//  Herkunft der Werte: Config/Demo.xcconfig (gitignored, aus scripts/demo.env)
//  → Build-Settings SW_DEMO_HOST/SW_DEMO_TOKEN → Config/Info.plist
//  (SWDemoHost/SWDemoDeviceToken). Fehlt die xcconfig, sind die Keys leer oder
//  unexpandiert („$(SW_DEMO_HOST)") → `isAvailable == false`, der Login zeigt
//  den Knopf nicht. So bauen Clones ohne Demo-Zugang unverändert.
//
//  Bewusste Ausnahme zur Regel „Token nur im Keychain": ein Token im Binary ist
//  auslesbar. Darum ausschliesslich ein öffentliches Demo-Konto mit
//  wegwerfbaren Inhalten — nie ein persönliches Token. Nach dem Anmelden läuft
//  es wie jeder andere Login (Keychain, s. `AuthStore`).
//

import Foundation

enum DemoAccess {

    /// Server-Host des Demo-Zugangs (ohne Schema), oder `nil`.
    static let host: String? = plistValue("SWDemoHost")

    /// Device-Token des Demo-Kontos, oder `nil`.
    static let token: String? = plistValue("SWDemoDeviceToken")

    /// Ist ein vollständiger, plausibler Demo-Zugang eingebacken?
    static var isAvailable: Bool { serverURLString != nil && token != nil }

    /// Vollständige Basis-URL für das Server-Feld. In der xcconfig steht nur der
    /// Host (dort beginnt `//` einen Kommentar), Schema kommt hier davor.
    static var serverURLString: String? {
        guard let host else { return nil }
        let withScheme = host.contains("://") ? host : "https://\(host)"
        return ServerConfig.normalizedURL(from: withScheme)?.absoluteString
    }

    /// Host für Anzeigezwecke („Testkonto auf …"), ohne Schema.
    static var displayHost: String? {
        guard let s = serverURLString else { return nil }
        return ServerConfig.normalizedURL(from: s)?.host
    }

    // MARK: - Intern

    /// Liest einen Info.plist-Key und filtert die „nicht gesetzt"-Fälle:
    /// leer, oder eine unexpandierte Build-Setting-Referenz `$(…)`.
    private static func plistValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
