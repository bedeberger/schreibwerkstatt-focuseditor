//
//  LocalDataPurge.swift
//  schreibwerkstatt-focuseditor
//
//  Vollständiges Entfernen aller LOKALEN Spuren eines Servers: der Inhalts-
//  Spiegel (SQLite), der Sync-Zustand (Cursor/Basen/Konflikte) und die
//  server-skopierten UserDefaults (zuletzt offene Seite, aktives Buch,
//  Schreibzeit-Puffer). Gebraucht nach einer bestätigten Konto-Löschung —
//  „Konto gelöscht" muss auch auf diesem Mac gelten, nicht nur am Server.
//
//  Bewusst NICHT betroffen: das gecachte Editor-Bundle (`web-cache/`). Das sind
//  App-Assets, keine Nutzerinhalte — es zu löschen brächte nur einen erneuten
//  (dann tokenlosen und damit unmöglichen) Download. Ebenso bleiben reine
//  Geräte-Vorlieben (Typografie, Sprache, Erscheinungsbild) erhalten.
//
//  Gegenstück und einziger anderer Ort mit Löschsemantik:
//  `EditorBundleStore.clearEditorCache()` (Assets) — hier geht es um Inhalte.
//

import Foundation
import os

enum LocalDataPurge {

    private static let logger = AppLog.purge

    /// Löscht Dateien und Defaults des angegebenen Server-Namespaces.
    ///
    /// WICHTIG: Der Aufrufer muss den Sync vorher anhalten und den Store danach
    /// neu öffnen (`AppCore.purgeLocalDataForCurrentServer()`) — sonst schriebe
    /// ein laufender Durchlauf in die bereits entkoppelte (gelöschte) DB-Datei.
    static func purgeServerNamespace(slug: String = ServerNamespace.currentSlug) {
        let dir = AppSupport.serverDir(slug: slug)
        do {
            try FileManager.default.removeItem(at: dir)
        } catch CocoaError.fileNoSuchFile {
            // Nichts da — kein Fehlerfall.
        } catch {
            logger.error("Namespace-Ordner nicht löschbar: \(error.localizedDescription, privacy: .public)")
        }
        purgeDefaults(slug: slug)
    }

    /// Entfernt die server-skopierten UserDefaults-Schlüssel. Server-skopierte
    /// Schlüssel tragen per Konvention den Slug als Suffix (`…​.<slug>`, s.
    /// `ServerScopedKey`) — darum suffix-basiert statt als Liste, die bei jedem
    /// neuen Schlüssel veraltet.
    static func purgeDefaults(slug: String) {
        let defaults = UserDefaults.standard
        let suffix = ".\(slug)"
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
        // Nicht server-skopiert, aber aus Nutzerinhalten abgeleitet: die
        // Legacy-Schlüssel von vor dem Namespacing (`ServerScopedKey.legacyKeys`,
        // damit ein neu hinzugekommener Schlüssel hier nicht vergessen wird) und
        // die Tages-Baseline der Wortzahl.
        for key in ServerScopedKey.legacyKeys + ["writing.dailyBaseline"] {
            defaults.removeObject(forKey: key)
        }
    }
}
