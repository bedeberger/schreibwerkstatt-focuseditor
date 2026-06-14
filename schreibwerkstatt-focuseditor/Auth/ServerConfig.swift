//
//  ServerConfig.swift
//  schreibwerkstatt-focuseditor
//
//  Konfiguration der Server-Basis-URL. Kein Geheimnis → UserDefaults
//  (das Token gehört in die Keychain, nicht hierher). Der Server liest
//  seinen öffentlichen Host aus `APP_URL`/app_settings; es gibt keinen
//  fest verdrahteten Prod-Host im Hauptrepo, daher konfigurierbar mit
//  Dev-Default (Port 3737).
//

import Foundation

enum ServerConfig {
    private static let defaultsKey = "server.baseURL"
    private static let fallback = "http://localhost:3737"

    /// Aktuelle Basis-URL als String (für Anzeige/Eingabe).
    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? fallback }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Basis-URL als `URL`, oder `nil` bei ungültiger Eingabe.
    static var baseURL: URL? {
        normalizedURL(from: baseURLString)
    }

    /// Trimmt, entfernt trailing Slash und prüft auf http/https + Host.
    static func normalizedURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
