//
//  AppCore.swift
//  schreibwerkstatt-focuseditor
//
//  App-weiter Wurzel-Container: besitzt genau eine Instanz von AuthStore,
//  LocalStore und SyncEngine. Wichtig — der LocalStore ist app-weit (nicht
//  pro Fenster), damit Editor-Bridge und SyncEngine denselben Spiegel sehen.
//

import Foundation
import Combine

@MainActor
final class AppCore: ObservableObject {
    let auth: AuthStore
    /// App-weiter Inhalts-Spiegel (vorerst In-Memory/JSON, später GRDB).
    let store: any LocalStore
    let sync: SyncEngine

    init() {
        let auth = AuthStore()
        let store = InMemoryLocalStore()
        self.auth = auth
        self.store = store
        self.sync = SyncEngine(api: auth.api,
                               store: store,
                               shouldSync: { auth.state == .signedIn })
    }

    /// Beim App-Start: Token prüfen, dann Sync hochfahren.
    func bootstrap() async {
        await auth.bootstrap()
        sync.start()
    }
}
