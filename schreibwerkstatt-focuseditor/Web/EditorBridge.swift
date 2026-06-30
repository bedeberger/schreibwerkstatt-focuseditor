//
//  EditorBridge.swift
//  schreibwerkstatt-focuseditor
//
//  Die EINZIGE Kopplungsschicht zwischen WebView (gebündelter Focus-Editor) und
//  Swift-Kern. Kein direkter `fetch` aus dem Editor — alles läuft über diese
//  Bridge. Netzwerk macht ausschliesslich der Swift-Kern; die WebView spricht
//  nur diese Nachrichten.
//
//  Transport: `WKScriptMessageHandlerWithReply` → jede `postMessage` aus JS
//  liefert nativ ein Promise zurück (kein manuelles requestId-Matching nötig).
//
//  Nachrichtenvertrag (JS → Swift), je `{ op, params }`:
//    • load { pageId }                         → { id, html, updatedAt, baseUpdatedAt? }
//    • save { pageId, html, baseUpdatedAt? }   → { id, updatedAt }
//    • list { bookId? }                        → [ { id, title?, pageName?, bookId?, chapterId?, updatedAt } ]
//    • activeBook {}                           → { bookId }  (Toolbar-Buch, Boot-Pull; skopiert die Seitenauswahl)
//    • editorState { pageId, dirty }           → null   (offene Seite + Dirty-Flag)
//    • log  { level?, message }                → null   (JS-Diagnose im Swift-Log)
//
//  Rechtschreibprüfung (LanguageTool) — Proxy über den Swift-Kern, NIE direkter
//  fetch aus der WebView (HARTE REGEL). Die Server-Settings (enabled/url/picky)
//  werden serverseitig angewandt; der Client liefert nur Text + Sprache:
//    • spellcheckConfig {}                     → { enabled, debounceMs }  (aus /config)
//    • languagetoolCheck { text, language?, pageId?, bookId? }
//                                              → { matches: [...] } | { disabled: true }
//    • dictionaryAdd { word, lang?, bookId? }  → { ok }   (Wort ins User-Wörterbuch)
//    • focusGranularity {}                     → { granularity }  (lokale Fokus-Stufe, Boot-Pull)
//
//  Synonyme (Cmd+Shift+S) — ebenfalls Proxy über den Swift-Kern, NIE direkter
//  fetch. Zwei Quellen wie im Web-Editor; der KI-Job wird serverseitig fertig
//  gepollt (EIN awaitbares Ergebnis):
//    • synonymConfig {}                        → { enabled, i18n }   (lokal an/aus + UI-Strings)
//    • synonymsThesaurus { word, bookId? }     → { synonyme:[{wort,hinweis}], disabled } (OpenThesaurus, de-only)
//    • synonymsAi { wort, satz, bookId?, pageId? }
//                                              → { synonyme:[{wort,hinweis}] } | { error } | { disabled }
//
//  Events (Swift → JS, via `__focusBridge._receive(event, payload)`):
//    • serverUpdate { pageId, html, baseUpdatedAt }  (offene Seite serverseitig aktualisiert)
//    • openPage     { pageId, html?, baseUpdatedAt? } (nativer Picker öffnet Seite)
//    • closePage    {}                               (offene Seite schliessen → ruhige Leerfläche; Buchwechsel oder Toolbar)
//    • focusGranularity { granularity }              (Fokus-Stufe live umgeschaltet)
//
//  Erweiterung: Braucht der Editor eine neue Root-Methode, wird sie ZUERST hier
//  und in der JS-Facade (focusHost-Vertrag) ergänzt und in CLAUDE.md dokumentiert.
//

import Foundation
import WebKit
import OSLog

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandlerWithReply, EditorCoordinating {
    /// Name, unter dem die Bridge in JS erreichbar ist:
    /// `window.webkit.messageHandlers.swBridge.postMessage(...)`.
    /// Single Source of Truth in `WebAssets` (dependency-frei, testbar).
    static let handlerName = WebAssets.handlerName

    /// UserDefaults-Key für die zuletzt geöffnete Seite — pro Server-Namespace
    /// (eine Seiten-ID gilt nur am Server, der sie vergeben hat; sonst öffnete der
    /// Client am neuen Server eine Seite des alten). Analog zu `LibraryStore`.
    /// Legacy/Fallback: der buch-skopierte Restore läuft über `lastOpenByBookKey`.
    static var lastOpenPageKey: String { "editor.lastOpenPageId.\(ServerNamespace.currentSlug)" }

    /// UserDefaults-Key für die zuletzt geöffnete Seite PRO Buch — pro Server-
    /// Namespace. Wert ist ein `[String(bookId): String(pageId)]`-Dict. Der Boot-
    /// Restore (`lastOpenPage(bookId)`) liest hier, damit nie eine Seite eines
    /// anderen Buchs geöffnet wird (der globale Key oben gilt server-, nicht
    /// buchweit und wurde bei jedem Seitenwechsel über alle Bücher überschrieben).
    static var lastOpenByBookKey: String { "editor.lastOpenByBook.\(ServerNamespace.currentSlug)" }

    /// Zuletzt geöffnete Seite des Buchs (gerätelokal), oder `nil`.
    static func lastOpenPageId(forBook bookId: Int) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: lastOpenByBookKey) as? [String: String]
        return map?[String(bookId)]
    }

    /// Zuletzt geöffnete Seite des Buchs merken (gerätelokal).
    static func setLastOpenPageId(_ pageId: String, forBook bookId: Int) {
        var map = (UserDefaults.standard.dictionary(forKey: lastOpenByBookKey) as? [String: String]) ?? [:]
        map[String(bookId)] = pageId
        UserDefaults.standard.set(map, forKey: lastOpenByBookKey)
    }

    /// UserDefaults-Key des in der Toolbar gewählten Buchs — pro Server-Namespace,
    /// exakt wie in `LibraryStore` (dort die SSoT). Die Bridge liest ihn beim Boot,
    /// um die initiale Seitenauswahl auf dieses Buch zu beschränken (sonst lüde die
    /// global gemerkte `lastOpenPage` eine Seite aus einem anderen Buch).
    static var activeBookKey: String { "library.activeBookId.\(ServerNamespace.currentSlug)" }

    private let store: any LocalStore
    /// HTTP-Client für den LanguageTool-/Wörterbuch-/Synonym-Proxy. Optional,
    /// damit die Bridge ohne Netz-Abhängigkeit (Tests/Dev-Harness) konstruierbar
    /// bleibt; fehlt er, melden die Proxy-Ops „deaktiviert". `internal` (nicht
    /// `private`), damit die Proxy-Methoden in `EditorBridge+Proxies.swift` (eigene
    /// Datei, hält EditorBridge.swift unter dem Größen-Limit) darauf zugreifen.
    let api: APIClient?
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "bridge")

    /// Zuletzt vom Server gelesene LanguageTool-Konfiguration (aus `/config`).
    /// Wird gecacht, damit ein Offline-Tick den letzten bekannten Stand behält
    /// statt die Prüfung fälschlich abzuschalten. `internal` für die Proxy-
    /// Extension (s. `api`).
    var ltConfig: (enabled: Bool, debounceMs: Int)?

    /// WebView für den Swift→JS-Kanal (`callAsyncJavaScript`). Schwach: die
    /// View besitzt die Bridge (Handler-Registrierung), nicht umgekehrt.
    private weak var webView: WKWebView?

    /// Lokal gewählte Fokus-Granularität (CSS-Klasse `focus-mode--<value>`).
    /// Vom `FocusController` gesetzt; Default aus UserDefaults, damit der
    /// Boot-Pull schon vor `FocusController.bind(_:)` den richtigen Wert liefert.
    var focusGranularity: String = {
        let raw = UserDefaults.standard.string(forKey: FocusGranularity.storageKey) ?? ""
        return (FocusGranularity(rawValue: raw) ?? .paragraph).rawValue
    }()

    /// CSS-fertiges Typografie-Payload (Schriftgrösse/Zeilenhöhe/measure/Familie/
    /// Papier-Ton). Vom `TypographyController` gesetzt; Boot-Pull liefert es über
    /// die `editorTypography`-Op, Live-Umschalten über `pushTypography()`.
    /// Default aus UserDefaults (analog `focusGranularity`), damit der Boot-Pull
    /// schon VOR `TypographyController.bind(_:)` die persistierten Werte liefert —
    /// sonst startete der Editor mit seinen CSS-Defaults, falls der Pull das
    /// `bind(_:)` im `.task` gewinnt (Symptom: „Typografie verschwindet").
    var typography: [String: Any] = TypographyController.persistedPayload()

    /// Aktuell im Editor geöffnete Seite (vom JS via `editorState` gemeldet).
    private(set) var openPageId: String? {
        didSet {
            guard openPageId != oldValue else { return }
            onOpenPageChange?(openPageId)
            // Genau EIN echtes Öffnen einer Seite (nicht beim Schliessen → nil):
            // treibt den gezielten Einzelseiten-Pull (Frische beim Öffnen, statt
            // aufs Poll-Intervall zu warten). Folgemeldungen (dirty/Stats) für
            // dieselbe Seite refeuern nicht (didSet-Guard auf Wertwechsel).
            if let pid = openPageId { onPageOpened?(pid) }
        }
    }
    /// Benachrichtigung bei Wechsel der offenen Seite (treibt die Toolbar-Anzeige).
    var onOpenPageChange: ((String?) -> Void)?
    /// Benachrichtigung beim Öffnen einer (echten) Seite — triggert den gezielten
    /// Einzelseiten-Pull der SyncEngine („sicherheitshalber frisch beim Öffnen").
    /// Feuert NICHT beim Schliessen (nil) und nicht bei Folgemeldungen derselben Seite.
    var onPageOpened: ((String) -> Void)?
    /// Benachrichtigung, wenn sich der Dirty-Zustand der OFFENEN Seite ändert
    /// (treibt den lokalen Save-Indikator in der Toolbar). `true` = ungespeicherte
    /// Änderung offen, `false` = lokal gesichert / keine Seite offen.
    var onOpenDirtyChange: ((Bool) -> Void)?
    /// Zuletzt gemeldeter Dirty-Zustand der offenen Seite (Entprellung der Events).
    private var lastNotifiedDirty = false
    /// Lebende Schreibstatistik (pageId, Wörter, Zeichen) aus der WebView —
    /// treibt die Stats-Anzeige, das Schreibziel und den Tages-Delta. Die pageId
    /// erlaubt dem Store, „heute geschrieben" PRO Seite zu führen. Gesetzt vom
    /// `WritingStatsStore`.
    var onStats: ((String?, Int, Int) -> Void)?
    /// Nutzer-Tippaktivität (jede `reportStats`-Meldung der WebView). Vom `onStats`
    /// bewusst GETRENNT, damit der `WritingStatsStore` seinen `onStats`-Slot behält.
    /// Treibt die Idle-Erkennung im `WritingTimeTracker` (Schreibzeit pausiert bei
    /// längerer Tipp-Pause). Gesetzt von `AppCore`.
    var onActivity: (() -> Void)?
    /// Ergebnis eines lokalen Saves: `nil` = erfolgreich, sonst die Fehlermeldung.
    /// Ein fehlgeschlagener `save` bedeutet, dass der Tippstand NICHT im lokalen
    /// Spiegel landete (Platte voll / DB-Fehler) — ein echter, sonst nur geloggter
    /// Datenverlust-Pfad. Treibt einen sichtbaren Warn-Banner (gesetzt von `AppCore`
    /// → `LibraryStore`), statt den Fehler still im Log verschwinden zu lassen.
    var onSaveResult: ((String?) -> Void)?
    /// Seiten mit ungespeicherten Editor-Änderungen.
    private var dirtyPages: Set<String> = []

    init(store: any LocalStore, api: APIClient? = nil) {
        self.store = store
        self.api = api
    }

    /// Verbindet die Bridge mit der WebView (Swift→JS-Kanal). Wird vom
    /// `FocusWebView`-Host nach dem Erstellen der WKWebView aufgerufen.
    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: WKScriptMessageHandlerWithReply

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String else {
            replyHandler(nil, "Bridge: ungültige Nachricht (op fehlt)")
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]

        Task {
            do {
                let result = try await route(op: op, params: params)
                replyHandler(result, nil)
            } catch {
                self.log.error("Bridge-Op \(op, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    // MARK: Routing

    /// Zentraler Dispatch der Bridge-Ops. `internal` (nicht `private`), damit das
    /// Logic-Test-Bundle die Ops ohne WebView/`WKScriptMessage` direkt treiben kann
    /// (`EditorBridgeTests`); der reguläre Einstieg bleibt der Message-Handler.
    func route(op: String, params: [String: Any]) async throws -> Any? {
        switch op {
        case "load":
            let pageId = try requireString(params, "pageId")
            // Local-first: gespiegelte Seite mit Inhalt direkt liefern.
            if let page = try await store.page(id: pageId), !page.html.isEmpty {
                return Self.encode(page)
            }
            // Lokaler Spiegel fehlt oder ist leer — der Sync-Pull hat die Seite
            // noch nicht (oder ohne Body) erfasst. Online direkt vom Server
            // nachladen + spiegeln, damit bestehende Seiten beim Öffnen sofort
            // Inhalt zeigen. Offline/unbekannt → leer (kein Fehler).
            if let page = await fetchAndMirror(pageId: pageId) {
                return Self.encode(page)
            }
            return nil

        case "save":
            let pageId = try requireString(params, "pageId")
            let html = try requireString(params, "html")
            let base = params["baseUpdatedAt"] as? Double
            do {
                let saved = try await store.save(id: pageId, html: html, baseUpdatedAt: base)
                // Erfolgreicher Save → einen zuvor gezeigten Save-Fehler-Banner lösen.
                onSaveResult?(nil)
                return ["id": saved.id, "updatedAt": saved.updatedAt]
            } catch {
                // Lokaler Save fehlgeschlagen = potenzieller Datenverlust → den
                // Nutzer warnen (sichtbarer Banner), nicht nur loggen. Fehler
                // trotzdem an die WebView durchreichen (Editor-Promise lehnt ab).
                onSaveResult?(error.localizedDescription)
                throw error
            }

        case "list":
            // Optionaler Buch-Filter: nil = alle Seiten (Picker reicht book_id durch).
            let bookId = params["bookId"] as? Int
            let summaries = try await store.list(bookId: bookId)
            return summaries.map { ["id": $0.id,
                                    "title": $0.title as Any,
                                    "pageName": $0.pageName as Any,
                                    "bookId": $0.bookId as Any,
                                    "chapterId": $0.chapterId as Any,
                                    "updatedAt": $0.updatedAt] }

        case "log":
            let level = (params["level"] as? String) ?? "info"
            let msg = (params["message"] as? String) ?? ""
            log.log(level: level == "error" ? .error : .info,
                    "WebView: \(msg, privacy: .public)")
            return nil

        case "editorState":
            // Editor meldet offene Seite + Dirty-Flag (für Open-Page-Reload/-Schutz).
            openPageId = params["pageId"] as? String
            if let pageId = openPageId {
                let dirty = (params["dirty"] as? Bool) ?? false
                if dirty { dirtyPages.insert(pageId) } else { dirtyPages.remove(pageId) }
                // Zuletzt geöffnete Seite gerätelokal merken (Boot-Restore via
                // `lastOpenPage`). Nur echte Seiten — `nil`/„default" nie merken,
                // damit eine geschlossene/leere Fläche die Erinnerung nicht löscht.
                // PRO Buch merken (bookId reicht der Editor mit), damit der Restore
                // nie ein fremdes Buch öffnet; globaler Key bleibt als Fallback.
                UserDefaults.standard.set(pageId, forKey: Self.lastOpenPageKey)
                if let bookId = params["bookId"] as? Int {
                    Self.setLastOpenPageId(pageId, forBook: bookId)
                }
            }
            notifyDirty()
            return nil

        case "lastOpenPage":
            // Boot-Pull: zuletzt geöffnete Seite (gerätelokal). Mit `bookId`
            // buch-skopiert (so öffnet der Restore nie eine Seite eines anderen
            // Buchs); ohne `bookId` der globale Legacy-Wert. Der Editor-Glue
            // bevorzugt sie in `loadPage`, fällt sonst auf die erste Seite zurück.
            // `nil`, wenn (für dieses Buch) noch nie eine Seite geöffnet wurde.
            if let bookId = params["bookId"] as? Int {
                return ["pageId": Self.lastOpenPageId(forBook: bookId) as Any]
            }
            return ["pageId": UserDefaults.standard.string(forKey: Self.lastOpenPageKey) as Any]

        case "activeBook":
            // Boot-Pull: das in der Toolbar gewählte Buch (gerätelokal, pro Server).
            // Der Editor-Glue skopiert `list`/`lastOpenPage` darauf, damit beim Start
            // nie eine Seite aus einem anderen Buch geladen wird. 0 = keins → null.
            let bid = UserDefaults.standard.integer(forKey: Self.activeBookKey)
            return ["bookId": (bid == 0 ? nil : bid) as Any]

        case "focusGranularity":
            // Boot-Pull: der Editor liest die lokale Fokus-Stufe beim Mounten.
            return ["granularity": focusGranularity]

        case "editorTypography":
            // Boot-Pull: der Editor-Glue liest die lokale Typografie beim Mounten.
            return typography

        case "editorBehavior":
            // Boot-Pull: Editor-Verhalten (Auto-Save-Debounce). `mountStandaloneFocus`
            // nimmt `autosaveMs` als Parameter (Default 1500 ms im Editor) — wir
            // reichen den lokal gewählten Wert beim Mounten durch. Wirkt beim
            // nächsten Editor-Mount/App-Start (kein Live-Remount).
            return ["autosaveMs": EditorBehaviorPrefs.autosaveMs]

        case "reportStats":
            // WebView meldet Wort-/Zeichenzahl der offenen Seite (Live-Stats +
            // Ziel + Tages-Delta). pageId trägt den Seitenbezug für „heute".
            let words = (params["words"] as? Int) ?? (params["words"] as? NSNumber)?.intValue ?? 0
            let chars = (params["chars"] as? Int) ?? (params["chars"] as? NSNumber)?.intValue ?? 0
            let pageId = params["pageId"] as? String
            onStats?(pageId, words, chars)
            // Jede Meldung ist ein Lebenszeichen → Idle-Uhr der Schreibzeit zurück.
            onActivity?()
            return nil

        case "spellcheckConfig":
            return await spellcheckConfig()

        case "languagetoolCheck":
            let text = try requireString(params, "text")
            let language = (params["language"] as? String) ?? "auto"
            let pageId = params["pageId"] as? String
            let bookId = params["bookId"] as? Int
            return try await languagetoolCheck(text: text, language: language,
                                               pageId: pageId, bookId: bookId)

        case "dictionaryAdd":
            let word = try requireString(params, "word")
            let lang = (params["lang"] as? String) ?? "*"
            let bookId = (params["bookId"] as? Int) ?? 0
            return try await dictionaryAdd(word: word, lang: lang, bookId: bookId)

        case "synonymConfig":
            return synonymConfig()

        case "synonymsThesaurus":
            let word = try requireString(params, "word")
            let bookId = params["bookId"] as? Int
            return try await synonymsThesaurus(word: word, bookId: bookId)

        case "synonymsAi":
            let wort = try requireString(params, "wort")
            let satz = (params["satz"] as? String) ?? wort
            let bookId = params["bookId"] as? Int
            let pageId = params["pageId"] as? String
            return try await synonymsAi(wort: wort, satz: satz, bookId: bookId, pageId: pageId)

        default:
            throw BridgeError.unknownOp(op)
        }
    }

    // MARK: Server-Nachladen (offline-first-Lücke)

    /// Lädt eine Seite direkt vom Server (`GET /content/pages/:id`, liefert
    /// immer den vollen HTML-Body) und spiegelt sie in den LocalStore. Fallback
    /// für `load`, wenn der Sync-Pull die Seite noch nicht (oder ohne Body)
    /// erfasst hat — der Picker listet alle Server-Seiten (Tree), der Inhalt
    /// kommt aber sonst nur aus dem Spiegel. Ohne API/offline → der lokale
    /// (ggf. leere) Stand; der nächste Pull holt die Seite regulär nach.
    ///
    /// Setzt KEINE Sync-Basis (`serverBaseISO` führt die SyncEngine) — reines
    /// Anzeige-Nachladen; der Pull-Tick erfasst die Basis ohnehin. Verwirft NIE
    /// eine lokal anhängige Änderung (Datenverlust-Schutz): liegt für die Seite
    /// ein Outbox-Eintrag vor, bleibt der lokale Stand unangetastet.
    private func fetchAndMirror(pageId: String) async -> StoredPage? {
        guard let api else { return nil }
        if let pending = try? await store.pendingOutbox(),
           pending.contains(where: { $0.pageId == pageId }) {
            return try? await store.page(id: pageId)
        }
        // pageId kommt aus der (nicht vertrauenswürdigen) WebView → für den
        // URL-Pfad kodieren. Ohne Encoding könnten `/`, `?`, `#`, `..` o. Ä. den
        // Pfad verbiegen oder `URL(string:)` scheitern lassen.
        guard let encodedId = pageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return try? await store.page(id: pageId)
        }
        guard let resp = try? await api.send("/content/pages/\(encodedId)",
                                             method: .GET,
                                             decode: PushResponse.self),
              let html = resp.html else {
            return try? await store.page(id: pageId)
        }
        let ms = ISOTime.millis(resp.updated_at) ?? 0
        // book_id/chapter_id liefert `/content/pages/:id` (noch) nicht zwingend
        // (anders als der Sync-Pull) → ggf. nil. Dann bleibt das Buch vorerst
        // ungesetzt; der Delete-Reconcile trägt es über den Buch-Tree nach
        // (LocalStore.assignBook), damit die Seite nicht als Waise unsichtbar wird.
        //
        // Datenverlust-Schutz: der `pending`-Check oben liegt VOR dem (suspendierenden)
        // GET — bis hierher kann ein lokaler Save einen Outbox-Eintrag angelegt haben.
        // Darum den Server-Stand ATOMAR-bedingt schreiben (`…IfClean` prüft die Outbox
        // in derselben Transaktion wie der Write, wie der Sync-Pull): liegt nun eine
        // lokale Änderung vor, bleibt sie unangetastet und wir liefern den lokalen
        // Stand zurück (der Push/409-Merge löst die Divergenz auf).
        _ = try? await store.applyServerPageIfClean(id: pageId, html: html,
                                                    pageName: resp.name,
                                                    bookId: resp.book_id, chapterId: resp.chapter_id,
                                                    serverUpdatedAtMillis: ms)
        return try? await store.page(id: pageId)
    }

    // MARK: EditorCoordinating (Swift→JS)

    func isDirty(_ pageId: String) -> Bool {
        dirtyPages.contains(pageId)
    }

    /// Meldet den Dirty-Zustand der OFFENEN Seite an Beobachter (Toolbar-Save-
    /// Indikator), aber nur bei echtem Wechsel. Keine offene Seite → `false`.
    private func notifyDirty() {
        let dirty = openPageId.map { dirtyPages.contains($0) } ?? false
        guard dirty != lastNotifiedDirty else { return }
        lastNotifiedDirty = dirty
        onOpenDirtyChange?(dirty)
    }

    /// Lädt die saubere, offene Seite still in der WebView neu (`serverUpdate`-Event).
    func reloadPage(pageId: String, html: String, baseUpdatedAt: Double) async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('serverUpdate', { pageId, html, baseUpdatedAt });",
                arguments: ["pageId": pageId, "html": html, "baseUpdatedAt": baseUpdatedAt],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("reloadPage(\(pageId, privacy: .public)) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Öffnet eine (beliebige) Seite im Editor — vom nativen Picker getrieben.
    /// Lädt den lokalen Stand aus dem Store (offline-first) und schickt ihn als
    /// `openPage`-Event an den Editor-Host. Liefert `false`, wenn keine WebView
    /// verfügbar ist (Aufrufer kann eine Hinweis-UI zeigen).
    @discardableResult
    func openPage(pageId: String) async -> Bool {
        guard let webView else { return false }
        let page = try? await store.page(id: pageId)
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('openPage', { pageId, html, baseUpdatedAt });",
                arguments: ["pageId": pageId,
                            "html": page?.html as Any,
                            "baseUpdatedAt": page?.baseUpdatedAt as Any],
                in: nil,
                contentWorld: .page)
            return true
        } catch {
            log.error("openPage(\(pageId, privacy: .public)) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Schliesst die aktuell offene Seite im Editor (`closePage`-Event) — beim
    /// Buchwechsel ODER bewusst über die Toolbar. Der Editor-Glue sichert zuerst
    /// den aktuellen Stand (local-first), leert dann die Schreibfläche und blendet
    /// eine ruhige Leerfläche ein. Setzt die offene Seite zurück (Toolbar leert
    /// sich). No-op ohne WebView; Fehler werden nur geloggt (kein Datenverlust —
    /// der Stand wurde JS-seitig vor dem Leeren gesichert).
    func closePage() async {
        guard let webView else { return }
        openPageId = nil
        notifyDirty()   // keine Seite offen → Save-Indikator zurücksetzen
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('closePage', {});",
                arguments: [:],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("closePage fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Schaltet die Fokus-Granularität live in der WebView um (`focusGranularity`-
    /// Event). No-op, solange noch keine WebView verbunden ist (der Boot-Pull
    /// liest dann ohnehin `focusGranularity`). Fehler werden nur geloggt — die
    /// Stufe ist rein visuell, kein Datenverlust-Risiko.
    func pushFocusGranularity() async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('focusGranularity', { granularity });",
                arguments: ["granularity": focusGranularity],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("pushFocusGranularity fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Schaltet die Editor-Typografie live in der WebView um (`editorTypography`-
    /// Event). No-op ohne WebView (der Boot-Pull liest dann ohnehin `typography`).
    /// Rein visuell, kein Datenverlust-Risiko → Fehler werden nur geloggt.
    func pushTypography() async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('editorTypography', payload);",
                arguments: ["payload": typography],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("pushTypography fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wendet eine Inline-Formatierung auf die aktuelle Auswahl im Editor an
    /// (`format`-Event). Native Entsprechung zu den ⌘B/⌘I/⌘U des contenteditable-
    /// Editors, jetzt auch über das Format-Menü erreichbar. `command` ist ein
    /// `document.execCommand`-Name (`bold`/`italic`/`underline`). No-op ohne
    /// WebView; rein visuell (kein Datenverlust-Risiko) → Fehler nur geloggt.
    func applyFormat(_ command: String) async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "window.__focusBridge._receive('format', { command });",
                arguments: ["command": command],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("applyFormat(\(command, privacy: .public)) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persistiert den offenen Draft sofort (`_flushSave`) und WARTET darauf —
    /// für ⌘S, das vor dem manuellen Sync den aktuellen Stand sichern soll
    /// (der Editor-Autosave läuft entprellt). Awaitable im Gegensatz zum
    /// Event-Bus (`_receive`), damit der Outbox-Eintrag garantiert vor dem
    /// Push liegt. No-op ohne WebView/offenen Editor; Fehler werden nur geloggt
    /// (der Autosave holt den Stand ohnehin nach → kein Datenverlust).
    func flushDraftSave() async {
        guard let webView else { return }
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await window.__focusBridge._flushSave();",
                arguments: [:],
                in: nil,
                contentWorld: .page)
        } catch {
            log.error("flushDraftSave fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ruft `block-merge.js` in der WebView (3-Wege-Merge). Wirft, wenn keine
    /// WebView/kein Bundle verfügbar ist → Aufrufer behandelt das als Konflikt.
    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome {
        guard let webView else { throw BridgeError.webViewUnavailable }
        // Timeout-Schutz: `_merge3` macht ein dynamisches `import(block-merge.js)`.
        // Hängt das Modul (z. B. stockender Import), würde der awaitende 409-Push
        // des Syncs SONST UNBEGRENZT blockieren. Race gegen einen Timeout; greift
        // er, behandelt der Aufrufer es wie „Merge nicht verfügbar" (→ Konflikt-UI).
        let result: Any?
        do {
            result = try await withThrowingTaskGroup(of: Any?.self) { group in
                group.addTask { @MainActor in
                    try await webView.callAsyncJavaScript(
                        "return await window.__focusBridge._merge3(base, local, server);",
                        arguments: ["base": base ?? "", "local": local, "server": server],
                        in: nil,
                        contentWorld: .page)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw BridgeError.mergeTimedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        }
        guard let dict = result as? [String: Any],
              let merged = dict["merged"] as? String else {
            throw BridgeError.mergeFailed
        }
        let count = (dict["conflictCount"] as? Int) ?? (dict["conflictCount"] as? NSNumber)?.intValue ?? 0
        return MergeOutcome(merged: merged, conflictCount: count)
    }

    // MARK: Hilfen

    private func requireString(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else {
            throw BridgeError.missingParam(key)
        }
        return value
    }

    /// StoredPage → JSON-serialisierbares Dictionary (nur NSJSON-konforme Typen).
    private static func encode(_ page: StoredPage) -> [String: Any] {
        var dict: [String: Any] = [
            "id": page.id,
            "html": page.html,
            "updatedAt": page.updatedAt,
        ]
        if let title = page.title { dict["title"] = title }
        if let pageName = page.pageName { dict["pageName"] = pageName }
        if let bookId = page.bookId { dict["bookId"] = bookId }
        if let chapterId = page.chapterId { dict["chapterId"] = chapterId }
        if let base = page.baseUpdatedAt { dict["baseUpdatedAt"] = base }
        return dict
    }
}

enum BridgeError: LocalizedError {
    case unknownOp(String)
    case missingParam(String)
    case webViewUnavailable
    case mergeFailed
    case mergeTimedOut
    case languagetool(status: Int)

    var errorDescription: String? {
        switch self {
        case .unknownOp(let op):     return "Bridge: unbekannte Operation '\(op)'"
        case .missingParam(let key): return "Bridge: Parameter '\(key)' fehlt"
        case .webViewUnavailable:    return "Bridge: keine WebView verfügbar (Swift→JS)"
        case .mergeFailed:           return "Bridge: Block-Merge lieferte kein Ergebnis"
        case .mergeTimedOut:         return "Bridge: Block-Merge zeitüberschritten"
        case .languagetool(let s):   return "Bridge: LanguageTool-Proxy antwortete mit Status \(s)"
        }
    }
}
