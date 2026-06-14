//
//  EditorCoordinating.swift
//  schreibwerkstatt-focuseditor
//
//  Kopplung zwischen SyncEngine und der WebView-Bridge — die SyncEngine kennt
//  den Editor nur über dieses Protokoll (keine direkte WebKit-Abhängigkeit).
//  Damit kann der Pull die offene Seite still neu laden bzw. schützen und der
//  409-Pfad den 3-Wege-Block-Merge in der WebView ausführen.
//

import Foundation

/// Ergebnis eines 3-Wege-Block-Merges (`block-merge.js`).
struct MergeOutcome {
    /// Provisorisch gemergtes HTML (lokale Auswahl bei Konflikten).
    let merged: String
    /// Anzahl echter Block-Kollisionen (>0 → Editor-Konflikt-UI nötig).
    let conflictCount: Int
}

@MainActor
protocol EditorCoordinating: AnyObject {
    /// Aktuell im Editor geöffnete Seite (oder `nil`).
    var openPageId: String? { get }
    /// Hat die Seite ungespeicherte Editor-Änderungen (dirty)?
    func isDirty(_ pageId: String) -> Bool
    /// Lädt die saubere, offene Seite still in der WebView neu (Swift→JS).
    func reloadPage(pageId: String, html: String, baseUpdatedAt: Double) async
    /// 3-Wege-Block-Merge in der WebView. Wirft, wenn nicht verfügbar
    /// (kein Editor-Bundle / keine WebView) — Aufrufer behandelt das als Konflikt.
    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome
}
