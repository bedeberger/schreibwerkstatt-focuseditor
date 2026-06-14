//
//  Reachability.swift
//  schreibwerkstatt-focuseditor
//
//  Dünner Wrapper um `NWPathMonitor`. Treibt den Sync: Wird der Pfad wieder
//  erreichbar, drainiert die SyncEngine die Outbox und zieht Deltas.
//  Der Pfad-Callback läuft auf einer eigenen Queue → wir hoppen auf den
//  MainActor, bevor wir Zustand veröffentlichen.
//

import Foundation
import Network
import Combine

@MainActor
final class Reachability: ObservableObject {
    @Published private(set) var isOnline: Bool = false

    /// Wird bei jeder Statusänderung mit dem neuen Wert aufgerufen.
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ch.schreibwerkstatt.focuseditor.reachability")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.update(online)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
    }

    private func update(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
