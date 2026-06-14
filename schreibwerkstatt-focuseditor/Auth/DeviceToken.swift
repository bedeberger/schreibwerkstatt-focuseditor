//
//  DeviceToken.swift
//  schreibwerkstatt-focuseditor
//
//  Format & Modelle rund um das Device-Token. Token-Format laut
//  Hauptrepo (`db/device-tokens.js`): Prefix „swd_“ + 64 Hex-Zeichen,
//  Server hasht mit SHA256, Klartext nur einmalig bei der Ausstellung
//  sichtbar. Der Mac-Client kann ein Token NICHT selbst ausstellen
//  (POST /me/device-tokens ist via Device-Token gesperrt:
//  DEVICE_TOKEN_SELF_MINT_FORBIDDEN) — der User stellt es im Web-
//  `/me`-Bereich aus und fügt es hier ein.
//

import Foundation

enum DeviceToken {
    static let prefix = "swd_"

    /// Validiert das Klartext-Format `swd_<64 hex>` (entspricht
    /// /^swd_[0-9a-f]{64}$/ im Server).
    static func isValidFormat(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(prefix) else { return false }
        let hex = t.dropFirst(prefix.count)
        guard hex.count == 64 else { return false }
        return hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Trimmt Whitespace/Newlines (Copy-Paste-Reste).
    static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ein Eintrag aus `GET /me/device-tokens` (ohne Klartext).
struct DeviceTokenInfo: Decodable, Identifiable {
    let id: Int
    let device_name: String
    let platform: String?
    let scopes: String
    let last_used_at: String?
    let last_used_ip: String?
    let expires_at: String?
    let revoked_at: String?
    let created_at: String
}

/// Antwort von `GET /me/device-tokens`.
struct DeviceTokenListResponse: Decodable {
    let tokens: [DeviceTokenInfo]
}

/// Generische Fehler-Antwort des Servers (`{ error_code, detail }`).
struct ServerErrorBody: Decodable {
    let error_code: String?
    let detail: String?
}
