//
//  SyncPreferences.swift
//  schreibwerkstatt-focuseditor
//
//  Lokale Sync-Vorlieben (UserDefaults): wie oft die SyncEngine pollt, solange
//  das Fenster aktiv ist. Gerätespezifisch (Akku/Daten) → bewusst client-lokal.
//  „Pausieren" ist davon getrennt und sitzt als transienter Schalter in der
//  SyncEngine (gilt nur für die laufende Sitzung — kein dauerhaftes Abschalten,
//  Datenverlust-Schutz: ein vergessener Dauer-Aus würde Pushes still aufhalten).
//

import Foundation

/// Poll-Kadenz im aktiven Fenster. `manual` schaltet das automatische Polling
/// ganz aus — Sync läuft dann nur auf Knopfdruck (bzw. Reachability-Trigger
/// bleibt ebenfalls aus). Push/Pull bei manuellem Auslösen funktioniert immer.
enum SyncPollMode: String, CaseIterable, Identifiable {
    case active     // ~5 s (Doku-Richtwert, Cross-Session-Frische)
    case relaxed    // ~30 s (energie-/datenschonend)
    case manual     // kein Auto-Poll

    static let storageKey = "sync.pollMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .active:  return t("sync.poll.active")
        case .relaxed: return t("sync.poll.relaxed")
        case .manual:  return t("sync.poll.manual")
        }
    }

    /// Poll-Periode; `nil` für `manual` (kein automatischer Loop).
    var interval: Duration? {
        switch self {
        case .active:  return .seconds(5)
        case .relaxed: return .seconds(30)
        case .manual:  return nil
        }
    }

    static var current: SyncPollMode {
        SyncPollMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .active
    }
}
