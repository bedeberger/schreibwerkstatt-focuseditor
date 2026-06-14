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
import os

@MainActor
final class AppCore: ObservableObject {
    let auth: AuthStore
    /// App-weiter Inhalts-Spiegel — GRDB/SQLite, mit In-Memory-Fallback falls
    /// die DB nicht geöffnet werden kann (App startet trotzdem).
    let store: any LocalStore
    /// App-weite WebView-Bridge — geteilt zwischen FocusWebView und SyncEngine
    /// (Open-Page-Reload, Block-Merge laufen über dieselbe Instanz).
    let bridge: EditorBridge
    let sync: SyncEngine
    /// Lese-Zugriff auf Buch-/Seiten-Struktur (Buch- + Seitenauswahl).
    let content: ContentAPI
    /// Buch-/Seitenauswahl-Zustand (aktives Buch persistiert, treibt den Picker).
    let library: LibraryStore
    /// OTA-Bundle des Focus-Editors (lädt/cacht die Editor-Assets vom Server).
    let editorBundle: EditorBundleStore
    /// OTA-Override der Oberflächen-Strings (macclient.*); gebündelte Kataloge
    /// bleiben der Offline-Fallback.
    let i18n: I18nBundleStore

    init() {
        let auth = AuthStore()
        let store: any LocalStore
        do {
            store = try GRDBLocalStore()
        } catch {
            // DB-Öffnen fehlgeschlagen → In-Memory-Fallback. Lokale, noch nicht
            // gepushte Inhalte sind dann flüchtig; der Sync re-hydratisiert aus
            // dem Server. Kein Crash beim Start.
            Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "store")
                .error("GRDB-Store nicht öffenbar, In-Memory-Fallback: \(error.localizedDescription, privacy: .public)")
            store = InMemoryLocalStore()
        }
        let bridge = EditorBridge(store: store, api: auth.api)
        let content = ContentAPI(api: auth.api)
        self.auth = auth
        self.store = store
        self.bridge = bridge
        self.content = content
        self.library = LibraryStore(content: content, store: store, bridge: bridge)
        self.editorBundle = EditorBundleStore(api: auth.api)
        self.i18n = I18nBundleStore(api: auth.api)
        let sync = SyncEngine(api: auth.api,
                              content: content,
                              store: store,
                              shouldSync: { auth.state == .signedIn })
        sync.editor = bridge   // SyncEngine ↔ Editor-Kopplung (schwach gehalten)
        self.sync = sync
    }

    /// Beim App-Start: Token prüfen, dann Sync hochfahren.
    func bootstrap() async {
        await auth.bootstrap()
        sync.start()
        // String-Override still im Hintergrund ziehen (greift beim nächsten
        // Start; gebündelte Kataloge bleiben der Offline-Fallback).
        Task { await i18n.refresh() }
    }
}
