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

struct SyncState: Codable, Sendable {
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
    private let url: URL
    private(set) var state: SyncState
    /// Serielle I/O-Queue: encode + atomic write off-main, in Aufruf-Reihenfolge.
    private let ioQueue = DispatchQueue(label: "ch.schreibwerkstatt.focuseditor.syncstate.io")

    init(filename: String = "syncstate.json") {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("schreibwerkstatt-focuseditor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent(filename)

        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(SyncState.self, from: data) {
            self.state = loaded
        } else {
            self.state = SyncState()
        }
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
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
