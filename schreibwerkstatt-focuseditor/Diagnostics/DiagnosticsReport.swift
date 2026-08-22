//
//  DiagnosticsReport.swift
//  schreibwerkstatt-focuseditor
//
//  Einstellungen ▸ Konto ▸ „Diagnose kopieren": ein Textblock, den man in eine
//  Support-Mail kleben kann.
//
//  Warum: die App loggt sauber über `os.log`, aber an diese Zeilen kommt ein
//  normaler Nutzer nicht heran (Konsole.app, richtiges Subsystem, richtiger
//  Zeitraum). Bei einer App-Store-Meldung („Sync geht nicht") stand darum bisher
//  Aussage gegen Vermutung. Der Bericht macht aus der Rückfrage einen Copy-Paste.
//
//  DATENSCHUTZ — was hier NICHT hineingehört:
//    • Das Device-Token (Keychain-Regel: nie in Logs, Defaults oder Ausgaben).
//      Der Bericht nennt nur, OB eines vorliegt.
//    • Manuskript-Inhalte. Es werden Zahlen genannt, nie Text.
//    • Die E-Mail-Adresse des Kontos — der Nutzer schreibt ohnehin aus ihr.
//  Die Log-Zeilen kommen aus dem EIGENEN Prozess (`.currentProcessIdentifier`)
//  und aus dem eigenen Subsystem; fremde Prozesse sind für die Sandbox
//  unsichtbar, und das ist gut so.
//

import Foundation
import OSLog

nonisolated enum DiagnosticsReport {

    /// Alles, was der Bericht braucht — vom Aufrufer aus den Stores gesammelt,
    /// damit die Formatierung pur und testbar bleibt.
    struct Input {
        var appVersion: String
        var buildNumber: String
        /// „App Store" oder „DMG (Sparkle)" — erklärt Update-Rückfragen.
        var channel: String
        var systemVersion: String
        var serverURL: String
        var signedIn: Bool
        var hasToken: Bool
        var language: String
        var bundleCommit: String?
        var bundleCached: Bool
        var pollMode: String
        var isPaused: Bool
        var lastSyncedAt: Date?
        var pendingCount: Int
        var conflictCount: Int
        var lastSyncError: String?
        var bookCount: Int
        var activeBookId: Int?
        var pageCount: Int
        var openPageId: Int?
        var logLines: [String]
    }

    /// Baut den Bericht. `now` injizierbar für den Test.
    static func text(_ input: Input, now: Date) -> String {
        var out: [String] = []
        out.append("Schreibwerkstatt Focus-Editor — Diagnose")
        out.append("Erstellt: \(iso(now))")
        out.append("")

        out.append("[App]")
        out.append("Version:      \(input.appVersion) (\(input.buildNumber))")
        out.append("Kanal:        \(input.channel)")
        out.append("macOS:        \(input.systemVersion)")
        out.append("Sprache:      \(input.language)")
        out.append("")

        out.append("[Server]")
        out.append("URL:          \(input.serverURL)")
        out.append("Angemeldet:   \(yesNo(input.signedIn))")
        // Bewusst nur die Existenz — nie der Wert.
        out.append("Token:        \(input.hasToken ? "vorhanden (Keychain)" : "keines")")
        out.append("")

        out.append("[Editor-Bundle (OTA)]")
        out.append("Cache:        \(input.bundleCached ? "vorhanden" : "FEHLT")")
        out.append("Commit:       \(input.bundleCommit ?? "unbekannt")")
        out.append("")

        out.append("[Sync]")
        out.append("Modus:        \(input.pollMode)\(input.isPaused ? " (pausiert)" : "")")
        out.append("Letzter Lauf: \(input.lastSyncedAt.map(iso) ?? "nie")")
        out.append("Offen (Push): \(input.pendingCount)")
        out.append("Konflikte:    \(input.conflictCount)")
        if let error = input.lastSyncError {
            out.append("Letzter Fehler: \(error)")
        }
        out.append("")

        out.append("[Inhalt (lokaler Spiegel)]")
        out.append("Bücher:       \(input.bookCount)")
        out.append("Aktives Buch: \(input.activeBookId.map(String.init) ?? "keines")")
        out.append("Seiten:       \(input.pageCount)")
        out.append("Offene Seite: \(input.openPageId.map(String.init) ?? "keine")")
        out.append("")

        out.append("[Protokoll (jüngste Einträge dieser Sitzung)]")
        if input.logLines.isEmpty {
            out.append("(keine Einträge lesbar)")
        } else {
            out.append(contentsOf: input.logLines)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Sammeln

    /// Liest die jüngsten Log-Zeilen des EIGENEN Prozesses aus dem eigenen
    /// Subsystem. `OSLogStore(scope: .currentProcessIdentifier)` ist der einzige
    /// Zugriff, den eine sandboxed App ohne Sonderrechte hat — er reicht, weil
    /// alle interessanten Meldungen von uns selbst stammen.
    ///
    /// Scheitert das (ältere Systeme, gesperrter Store), liefert die Funktion
    /// eine leere Liste statt zu werfen: ein Bericht ohne Protokoll ist immer
    /// noch nützlich.
    static func recentLogLines(subsystem: String = "ch.schreibwerkstatt.focuseditor",
                               limit: Int = 200) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(timeIntervalSinceLatestBoot: 0)
            let entries = try store.getEntries(at: since,
                                               matching: NSPredicate(format: "subsystem == %@", subsystem))
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
                "\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)"
            }
            return Array(lines.suffix(limit))
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "ja" : "nein" }
}
