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

struct SyncState: Codable {
    /// Bekannte Buch-IDs (Server `id`).
    var bookIds: [Int] = []
    /// Pull-Cursor je Buch-ID.
    var cursors: [Int: SyncCursorDTO] = [:]
    /// Exakte Server-ISO-Basis je Seiten-ID (String-Key = Store-Seiten-ID).
    var serverBaseISO: [String: String] = [:]
}

/// Lädt/speichert `SyncState` als JSON-Snapshot.
@MainActor
final class SyncStateStore {
    private let url: URL
    private(set) var state: SyncState

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

    /// Mutiert den Zustand und schreibt sofort einen Snapshot.
    func mutate(_ block: (inout SyncState) -> Void) {
        block(&state)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
