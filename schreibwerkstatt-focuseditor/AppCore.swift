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

    /// Server-Namespace, auf den die Stores aktuell zeigen. Erkennt einen Wechsel
    /// (Settings ODER URL-Edit im Login) gegen `ServerNamespace.currentSlug`.
    private var boundSlug: String
    /// Reentrancy-Schutz: der Sign-in-Status-Publisher kann mehrfach feuern
    /// (Start-mit-Token UND Login) → einen laufenden Wechsel nicht doppelt fahren.
    private var switchInFlight = false

    init() {
        self.boundSlug = ServerNamespace.currentSlug
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
        // Beim Öffnen einer Seite gezielt deren frischen Server-Stand ziehen
        // („sicherheitshalber"), statt aufs Poll-Intervall zu warten. Best-effort
        // und still; respektiert den Datenverlust-Schutz (dirty/Outbox bleibt).
        bridge.onPageOpened = { [weak sync] pid in
            Task { await sync?.pullPage(pageId: pid) }
        }
    }

    /// Server-Wechsel (in-place): den lokalen Spiegel, den Sync-Zustand und die
    /// Buchauswahl auf den Namespace des NEUEN Servers umschalten. Ohne das pollt
    /// der Client weiter die Buch-IDs des alten Servers (→ `NO_BOOK_ACCESS`-Flut).
    /// Voraussetzung: `ServerConfig.baseURLString` zeigt bereits auf den neuen
    /// Server (der Aufrufer setzt URL + meldet ab, bevor er das hier ruft).
    ///
    /// Objekt-Identitäten bleiben erhalten (Store/Sync/Library tauschen nur ihre
    /// zugrundeliegenden Dateien) → Bridge- und Controller-Bindungen bleiben gültig.
    func switchServer() async {
        // Sync VOR dem Store-Tausch anhalten und einen laufenden Durchlauf
        // abwarten — sonst committet ein in-flight DB-Write evtl. noch in die
        // alte Namespace-DB (Datenverlust für den neuen Server).
        await sync.suspendForServerSwitch()
        do {
            try await store.switchToCurrentServer()
        } catch {
            Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "store")
                .error("Store-Wechsel auf neuen Server fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
        sync.reloadForCurrentServer()
        library.reloadForCurrentServer()
        boundSlug = ServerNamespace.currentSlug
    }

    /// Schaltet nur um, wenn sich der Server-Namespace seit dem letzten Binden
    /// geändert hat. Deckt den Login-Pfad ab (URL im Login-Screen editiert, dann
    /// angemeldet) und ist nach einem direkten `switchServer()` ein No-op. Der
    /// Reentrancy-Guard verhindert, dass der mehrfach feuernde Sign-in-Publisher
    /// zwei Wechsel überlappend fährt (Race auf Store/Sync-Zustand).
    func switchServerIfNeeded() async {
        guard !switchInFlight, boundSlug != ServerNamespace.currentSlug else { return }
        switchInFlight = true
        defer { switchInFlight = false }
        await switchServer()
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
