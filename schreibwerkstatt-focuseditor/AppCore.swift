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
    /// App-weite WebView-Bridge — geteilt zwischen FocusWebView und SyncEngine
    /// (Open-Page-Reload, Block-Merge laufen über dieselbe Instanz).
    let bridge: EditorBridge
    let sync: SyncEngine
    /// Lese-Zugriff auf Buch-/Seiten-Struktur (Buch- + Seitenauswahl).
    let content: ContentAPI
    /// Buch-/Seitenauswahl-Zustand (aktives Buch persistiert, treibt den Picker).
    let library: LibraryStore

    init() {
        let auth = AuthStore()
        let store = InMemoryLocalStore()
        let bridge = EditorBridge(store: store)
        let content = ContentAPI(api: auth.api)
        self.auth = auth
        self.store = store
        self.bridge = bridge
        self.content = content
        self.library = LibraryStore(content: content, store: store, bridge: bridge)
        let sync = SyncEngine(api: auth.api,
                              store: store,
                              shouldSync: { auth.state == .signedIn })
        sync.editor = bridge   // SyncEngine ↔ Editor-Kopplung (schwach gehalten)
        self.sync = sync
    }

    /// Beim App-Start: Token prüfen, dann Sync hochfahren.
    func bootstrap() async {
        await auth.bootstrap()
        sync.start()
    }
}
