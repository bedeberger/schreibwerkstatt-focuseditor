//
//  AuthError.swift
//  schreibwerkstatt-focuseditor
//
//  Fehlerfälle der Auth-/Netzwerk-Schicht. UI-Texte sind lokalisiert (de/en)
//  über das `macclient.*`-Katalog (siehe Localization/).
//

import Foundation

enum AuthError: Error, LocalizedError {
    /// Eingegebenes Token passt nicht zum Format `swd_<64 hex>`.
    case malformedToken
    /// Server-Antwort 401 — Token ungültig/widerrufen oder User gesperrt/gelöscht.
    case unauthorized
    /// Konfigurierte Server-URL ist unbrauchbar.
    case invalidServerURL
    /// Transport-/Verbindungsfehler (offline, Timeout, TLS …).
    case network(Error)
    /// Server antwortete mit unerwartetem Status; `code` ist das `error_code`-Feld,
    /// `body` der rohe Antwort-Body (für 409-Konfliktdetails etc.), falls vorhanden.
    case server(status: Int, code: String?, body: Data?)
    /// Antwort ließ sich nicht dekodieren.
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .malformedToken:
            return t("auth.err.malformedToken")
        case .unauthorized:
            return t("auth.err.unauthorized")
        case .invalidServerURL:
            return t("auth.err.invalidServerURL")
        case .network(let underlying):
            return t("auth.err.network", ["detail": underlying.localizedDescription])
        case .server(let status, let code, _):
            if let code { return t("auth.err.serverWithCode", ["status": "\(status)", "code": code]) }
            return t("auth.err.server", ["status": "\(status)"])
        case .decoding:
            return t("auth.err.decoding")
        }
    }
}
