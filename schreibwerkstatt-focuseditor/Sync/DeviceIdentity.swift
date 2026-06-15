//
//  DeviceIdentity.swift
//  schreibwerkstatt-focuseditor
//
//  Stabile Geräte-UUID dieses Mac-Clients. Wird im Push-Body (`device_id`,
//  PushRequest) mitgeschickt: der Server stempelt damit `pages.last_editor_device_id`
//  und registriert das Gerät als Buch-Präsenz (`book_presence`). So erkennt ein
//  parallel offener Browser desselben Users den Push dieses Clients als
//  Remote-Change (geräte-bewusster `/content/books/:id/changes`-Feed) und lädt die
//  Seite automatisch nach — statt den Stand bis zum manuellen Reload zu halten.
//
//  Geräte-, NICHT serverbezogen: dieselbe physische Maschine behält ihre UUID über
//  Server-Wechsel hinweg (jeder Server-Namespace registriert sie in seiner eigenen
//  `app_users_devices`-Tabelle). Kein Geheimnis → UserDefaults genügt (der
//  Device-Token für die Auth liegt weiterhin ausschließlich in der Keychain).
//
//  Format passt zum Server-Validator (`UUID_RE`, routes/content.js): kleingeschrieben.
//

import Foundation

enum DeviceIdentity {

    private static let defaultsKey = "sw_device_id"

    /// Cached, damit nicht jeder Push erneut UserDefaults liest.
    private static let cached: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), isValid(existing) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }()

    /// Die stabile Geräte-UUID (lowercased, Server-kompatibel).
    static var current: String { cached }

    private static func isValid(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }
}
