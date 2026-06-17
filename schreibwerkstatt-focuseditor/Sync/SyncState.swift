//
//  SyncState.swift
//  schreibwerkstatt-focuseditor
//
//  Persistente Server-Koordinationsdaten des Syncs — bewusst getrennt vom
//  LocalStore (dem Inhalts-Spiegel). Hält:
//   • `bookIds`        — bekannte Bücher (einmalig aus GET /content/books).
//   • `cursors`        — Keyset-Pull-Cursor pro Buch.
//   • `serverBaseISO`  — exakte Server-`updated_at`-ISO je Seite, also die
//                        Basis für den nächsten Push (`expected_updated_at`).
//
//  Persistenz vorerst als JSON-Snapshot im Application-Support (wie der
//  Platzhalter-LocalStore); später wandert das ggf. in dieselbe GRDB-DB.
//

import Foundation
import OSLog

private let syncStateLog = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "syncstate")

// `nonisolated`, weil der Snapshot off-main (auf der `ioQueue`) encodiert wird —
// unter der MainActor-Default-Isolation des Targets wäre die Codable-Conformance
// sonst MainActor-isoliert und off-main nicht nutzbar (wie StoredPage/OutboxEntry).
nonisolated struct SyncState: Codable, Sendable {
    /// Bekannte Buch-IDs (Server `id`).
    var bookIds: [Int] = []
    /// Pull-Cursor je Buch-ID.
    var cursors: [Int: SyncCursorDTO] = [:]
    /// Exakte Server-ISO-Basis je Seiten-ID (String-Key = Store-Seiten-ID).
    var serverBaseISO: [String: String] = [:]
    /// Server-HTML der letzten Basis je Seite — gemeinsamer Vorfahr (Ancestor)
    /// für den 3-Wege-Block-Merge bei 409.
    var serverBaseHtml: [String: String] = [:]

    init() {}

    // Tolerant gegen fehlende Keys (ältere Snapshots ohne `serverBaseHtml`),
    // damit ein neues Feld nicht den ganzen Sync-Zustand verwirft.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookIds = try c.decodeIfPresent([Int].self, forKey: .bookIds) ?? []
        cursors = try c.decodeIfPresent([Int: SyncCursorDTO].self, forKey: .cursors) ?? [:]
        serverBaseISO = try c.decodeIfPresent([String: String].self, forKey: .serverBaseISO) ?? [:]
        serverBaseHtml = try c.decodeIfPresent([String: String].self, forKey: .serverBaseHtml) ?? [:]
    }
}

/// Lädt/speichert `SyncState` als JSON-Snapshot.
///
/// Der In-Memory-Zustand lebt auf dem MainActor; das Encodieren + Schreiben
/// läuft NICHT dort, sondern auf einer eigenen seriellen Queue. So blockiert
/// ein Save-/Pull-Tick den Main-Thread nicht, auch wenn der Snapshot (inkl.
/// `serverBaseHtml`) groß wird. FIFO-Serialität garantiert Last-Write-Wins.
@MainActor
final class SyncStateStore {
    /// `var`, weil ein Server-Wechsel den Pfad auf den neuen Namespace umlenkt.
    private var url: URL
    private let filename: String
    private(set) var state: SyncState
    /// Serielle I/O-Queue: encode + atomic write off-main, in Aufruf-Reihenfolge.
    private let ioQueue = DispatchQueue(label: "ch.schreibwerkstatt.focuseditor.syncstate.io")

    init(filename: String = "syncstate.json") {
        self.filename = filename
        AppSupport.migrateLegacyFileIfNeeded(named: filename)
        self.url = AppSupport.serverDir().appendingPathComponent(filename)
        self.state = Self.loadState(from: url)
    }

    /// Lädt den Snapshot defensiv: Eine fehlende Datei ist der Normalfall
    /// (Erststart) → leerer Zustand, kommentarlos. Eine VORHANDENE, aber nicht
    /// dekodierbare Datei ist dagegen ein echter Fehler: Cursor + ISO-Basen sind
    /// die Push-Koordinaten — geht das verloren, droht ein Voll-Pull oder ein
    /// Push gegen die falsche Basis. Darum die korrupte Datei NICHT überschreiben,
    /// sondern als `.corrupt`-Sidecar wegsichern (forensisch + Recovery von Hand)
    /// und den Vorfall loggen, statt ihn still zu verschlucken.
    private static func loadState(from url: URL) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState() }
        if let loaded = try? JSONDecoder().decode(SyncState.self, from: data) {
            return loaded
        }
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            syncStateLog.error("SyncState korrupt — nach \(backup.lastPathComponent, privacy: .public) gesichert; starte mit leerem Zustand (Voll-Pull folgt)")
        } catch {
            syncStateLog.error("SyncState korrupt UND Sicherung fehlgeschlagen (\(error.localizedDescription, privacy: .public)); starte mit leerem Zustand")
        }
        return SyncState()
    }

    /// Server-Wechsel: Pfad auf den Namespace des aktuellen Servers umlenken und
    /// den Zustand (Buch-IDs/Cursor/Basen) des neuen Servers laden. Verwirft den
    /// In-Memory-Zustand des alten Servers, ohne dessen Datei zu löschen
    /// (Rückwechsel behält den Cursor).
    func reloadForCurrentServer() {
        AppSupport.migrateLegacyFileIfNeeded(named: filename)
        url = AppSupport.serverDir().appendingPathComponent(filename)
        state = Self.loadState(from: url)
    }

    /// Mutiert den Zustand (MainActor) und stößt einen Background-Snapshot an.
    func mutate(_ block: (inout SyncState) -> Void) {
        block(&state)
        persist()
    }

    /// Reicht eine Wert-Kopie (COW, Sendable) an die I/O-Queue; encode + write
    /// passieren dort, nicht auf dem MainActor.
    private func persist() {
        let snapshot = state
        let url = self.url
        ioQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Schreibfehler (Platte voll/Permissions) nicht still schlucken:
                // sonst läuft der In-Memory-Zustand weiter, während die Cursor/
                // Basen auf der Platte veralten — beim nächsten Start unbemerkt
                // ein Voll-Pull oder Push gegen alte Basis.
                syncStateLog.error("SyncState-Persistenz fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
