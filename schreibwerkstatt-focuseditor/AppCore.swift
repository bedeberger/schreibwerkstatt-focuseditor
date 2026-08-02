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
    /// Misst die im Editor verbrachte Zeit und meldet sie an den Server
    /// (`POST /history/writing-time`) — das native Pendant zum Schreibzeit-
    /// Heartbeat der Web-Plattform. Scene-Phase über `setActive(_:)`.
    let writingTime: WritingTimeTracker
    /// Serverseitiges Seiten-Lektorat (`POST /jobs/check` + Poll) — Start über
    /// den Toolbar-Knopf, Ergebnis als Banner über der Schreibfläche.
    let lektorat: LektoratJobStore
    /// Konto-Löschung aus der App (`DELETE /me/account`, Guideline 5.1.1(v)) —
    /// räumt nach bestätigter Server-Löschung auch lokal auf.
    let accountDeletion: AccountDeletionController

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
        let library = LibraryStore(content: content, store: store, bridge: bridge)
        self.library = library
        self.editorBundle = EditorBundleStore(api: auth.api)
        self.i18n = I18nBundleStore(api: auth.api)
        let writingTime = WritingTimeTracker(api: auth.api,
                                             isSignedIn: { auth.state == .signedIn })
        self.writingTime = writingTime
        writingTime.attach(to: library)
        // Tippaktivität der WebView (eigener Hook neben `onStats`) speist die
        // Idle-Erkennung der Schreibzeit — pausiert bei längerer Tipp-Pause.
        bridge.onActivity = { [weak writingTime] in writingTime?.notifyActivity() }
        // Ergebnis eines lokalen Saves → Warn-Banner (Fehler) bzw. dessen Auflösung
        // (Erfolg). Ein fehlgeschlagener Save ist ein echter Datenverlust-Pfad und
        // darf nicht nur im Log stehen.
        bridge.onSaveResult = { [weak library] message in library?.reportSaveResult(message) }
        let sync = SyncEngine(api: auth.api,
                              content: content,
                              store: store,
                              shouldSync: { auth.state == .signedIn })
        sync.editor = bridge   // SyncEngine ↔ Editor-Kopplung (schwach gehalten)
        self.sync = sync
        // Offline-Boot-Lücke: startete die App ohne erreichbaren Server, lief
        // `spellcheckConfig` beim Boot leer zurück → der Spellcheck-Controller
        // wurde nie mounted. Sobald der Server im Sync-Tick antwortet, gibt
        // die Bridge der WebView die Chance, die Initialisierung idempotent
        // nachzuholen (`bridge.pushDeferredSpellcheckInit`).
        sync.onServerReached = { [weak bridge] in
            guard let bridge else { return }
            Task { await bridge.pushDeferredSpellcheckInit() }
        }
        // Beim Öffnen einer Seite gezielt deren frischen Server-Stand ziehen
        // („sicherheitshalber"), statt aufs Poll-Intervall zu warten. Best-effort
        // und still; respektiert den Datenverlust-Schutz (dirty/Outbox bleibt).
        bridge.onPageOpened = { [weak sync] pid in
            Task { await sync?.pullPage(pageId: pid) }
        }
        // Lektorats-Job: der Server prüft den SERVER-Stand der Seite → vor dem
        // Anlegen den offenen Draft sichern (Bridge) und pushen (Sync), sonst
        // lektoriert er einen veralteten Text. Genau die ⌘S-Semantik, nur
        // awaitbar — darum hier verdrahtet statt `syncManually()`.
        self.lektorat = LektoratJobStore(api: auth.api) { [weak bridge, weak sync] in
            await bridge?.flushDraftSave()
            await sync?.syncNow(manual: true)
        }
        self.accountDeletion = AccountDeletionController(api: auth.api)
        // Erst NACH bestätigter Server-Löschung lokal aufräumen: Spiegel/Sync-
        // Zustand dieses Servers verwerfen, dann abmelden (→ Login-Screen).
        // Reihenfolge zählt — `signOut()` zuerst würde die UI umschalten, während
        // der Store noch auf die gelöschten Dateien zeigt.
        self.accountDeletion.onDeleted = { [weak self] in
            guard let self else { return }
            await self.purgeLocalDataForCurrentServer()
            self.auth.signOut()
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
        // Schreibzeit-Puffer des alten Servers verwerfen (Buch-IDs gelten nur dort).
        writingTime.reset()
        // Laufendes/abgeschlossenes Lektorat verwerfen: Job-ID und Deep-Link
        // gelten nur am alten Server.
        lektorat.reset()
        // Verzögerten Spellcheck-Nachzieh-Versuch für den NEUEN Server
        // freigeben (Boot-Config des alten Servers könnte `enabled:false`
        // geliefert haben). Die JS-Seite bleibt idempotent (Guard
        // `if (window.__spellcheck) return`); ein Re-Mount findet nur statt,
        // wenn der neue Server enabled liefert UND noch nichts mounted ist.
        bridge.resetSpellcheckDeferred()
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

    /// Nach bestätigter Konto-Löschung am Server: alle lokalen Inhalte dieses
    /// Servers verwerfen. Bewusst NUR aus diesem Pfad heraus aufgerufen — überall
    /// sonst gilt „Datenverlust-Schutz vor allem" (Abmelden/401 behalten alles).
    ///
    /// Ablauf wie beim Server-Wechsel: Sync anhalten (kein in-flight Write in die
    /// gleich gelöschte DB), Puffer verwerfen, Dateien + Defaults löschen, danach
    /// eine frische (leere) DB am selben Pfad öffnen und Sync/Library darauf neu
    /// aufsetzen — die Objekt-Identitäten bleiben gültig (Bridge-Bindungen etc.).
    func purgeLocalDataForCurrentServer() async {
        await sync.suspendForServerSwitch()
        lektorat.reset()
        // Löschen und Verwerfen des Schreibzeit-Puffers ohne `await` dazwischen:
        // auf dem MainActor kann kein Heartbeat-Tick einhaken und den alten
        // `pending`-Wert nach dem Purge zurückschreiben. `reset()` zieht den
        // In-Memory-Puffer danach aus den (nun leeren) Defaults nach.
        LocalDataPurge.purgeServerNamespace()
        writingTime.reset()
        do {
            try await store.switchToCurrentServer()
        } catch {
            Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "store")
                .error("Frischen Store nach Konto-Löschung nicht öffenbar: \(error.localizedDescription, privacy: .public)")
        }
        sync.reloadForCurrentServer()
        library.reloadForCurrentServer()
        boundSlug = ServerNamespace.currentSlug
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
