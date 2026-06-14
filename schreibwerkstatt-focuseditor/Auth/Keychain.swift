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
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
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
