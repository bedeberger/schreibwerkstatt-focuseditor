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
    // Default = öffentlicher Prod-Host. Frische Installs starten gegen die
    // produktive Schreibwerkstatt; ein einmal eingegebener (Dev-)Server bleibt
    // in UserDefaults erhalten und überstimmt diesen Fallback. Für lokale Tests
    // weiterhin `http://127.0.0.1:3737` ins Login-Feld eintragen (IPv4 statt
    // `localhost`: der Dev-Server bindet nur `*:3737`, `localhost` löst unter
    // macOS bevorzugt auf IPv6 `::1` auf → „Connection refused").
    private static let fallback = siteURLString

    /// Kanonische öffentliche Adresse der Schreibwerkstatt (Marketing/Onboarding).
    /// Basis für Register-/Token-Links, falls das eingegebene Server-Feld (noch)
    /// ungültig ist.
    static let siteURLString = "https://schreibwerkstatt.app"

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
              let host = url.host else {
            return nil
        }
        // Eingebettete Credentials (http://user:pass@host) ablehnen: sie landeten
        // sonst im Klartext in UserDefaults und in jeder Request-URL.
        guard url.user == nil, url.password == nil else { return nil }
        // `localhost` deterministisch auf IPv4 zwingen (s. `fallback`).
        if host.lowercased() == "localhost",
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.host = "127.0.0.1"
            if let coerced = comps.url { return coerced }
        }
        return url
    }

    /// Baut eine Browser-Seite (z. B. `register`, `me`) auf einer eingegebenen
    /// Server-Basis. Für die Onboarding-Links im Login: respektiert den im Feld
    /// stehenden Server (auch Dev), fällt bei ungültiger Eingabe auf die
    /// kanonische Site zurück — so öffnet der Knopf nie eine kaputte URL.
    static func pageURL(onServer raw: String, path: String) -> URL {
        let base = normalizedURL(from: raw)
            ?? URL(string: siteURLString)!
        return base.appendingPathComponent(path)
    }
}
