//
//  Keychain.swift
//  schreibwerkstatt-focuseditor
//
//  Schmaler Wrapper um die Security-Keychain (Generic Password).
//  Das Device-Token (`swd_…`) liegt ausschließlich hier — nie in
//  UserDefaults, Plist, Logs oder Bridge-Messages an die WebView.
//

import Foundation
import Security

/// Sicherer Speicher für das Device-Token. Bewusst minimal:
/// nur speichern, lesen, löschen. Ein Eintrag pro (service, account).
enum Keychain {

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unbekannt"
                return "Keychain-Fehler (\(status)): \(msg)"
            }
        }
    }

    /// Schreibt `value`; ein vorhandener Eintrag wird zuvor entfernt
    /// (überschreiben statt mergen — vermeidet Update-Sonderfälle).
    static func save(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Nur nach dem ersten Entsperren lesbar und nicht in Backups/iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }

        // Das vorausgehende `delete` konnte den Altbestand nicht entfernen (z. B.
        // ein Eintrag mit abweichendem Accessibility-Attribut, den die delete-
        // Query nicht traf) → `add` meldet einen Duplikat. Auf ein Update des
        // vorhandenen Eintrags zurückfallen, statt den Token-Wechsel scheitern
        // zu lassen (sonst bliebe der User mit dem alten/ungültigen Token hängen).
        if status == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }

        throw KeychainError.unexpectedStatus(status)
    }

    /// Liest den Wert oder `nil`, wenn kein Eintrag existiert.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Entfernt den Eintrag (kein Fehler, wenn nichts vorhanden war).
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
