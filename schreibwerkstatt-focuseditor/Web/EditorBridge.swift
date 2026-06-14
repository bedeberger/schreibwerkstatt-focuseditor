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
//  Events (Swift → JS, via `__focusBridge._receive(event, payload)`):
//    • serverUpdate { pageId, html, baseUpdatedAt }  (offene Seite serverseitig aktualisiert)
//    • openPage     { pageId, html?, baseUpdatedAt? } (nativer Picker öffnet Seite)
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
    static let handlerName = "swBridge"

    private let store: any LocalStore
    /// HTTP-Client für den LanguageTool-/Wörterbuch-Proxy. Optional, damit die
    /// Bridge ohne Netz-Abhängigkeit (Tests/Dev-Harness) konstruierbar bleibt;
    /// fehlt er, melden die Spellcheck-Ops „deaktiviert".
    private let api: APIClient?
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "bridge")

    /// Zuletzt vom Server gelesene LanguageTool-Konfiguration (aus `/config`).
    /// Wird gecacht, damit ein Offline-Tick den letzten bekannten Stand behält
    /// statt die Prüfung fälschlich abzuschalten.
    private var ltConfig: (enabled: Bool, debounceMs: Int)?

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
    var typography: [String: Any] = [:]

    /// Aktuell im Editor geöffnete Seite (vom JS via `editorState` gemeldet).
    private(set) var openPageId: String? {
        didSet {
            guard openPageId != oldValue else { return }
            onOpenPageChange?(openPageId)
        }
    }
    /// Benachrichtigung bei Wechsel der offenen Seite (treibt die Toolbar-Anzeige).
    var onOpenPageChange: ((String?) -> Void)?
    /// Lebende Schreibstatistik (Wörter, Zeichen) aus der WebView — treibt die
    /// Stats-Anzeige + das Schreibziel. Gesetzt vom `WritingStatsStore`.
    var onStats: ((Int, Int) -> Void)?
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

    private func route(op: String, params: [String: Any]) async throws -> Any? {
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
            let saved = try await store.save(id: pageId, html: html, baseUpdatedAt: base)
            return ["id": saved.id, "updatedAt": saved.updatedAt]

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
            }
            return nil

        case "focusGranularity":
            // Boot-Pull: der Editor liest die lokale Fokus-Stufe beim Mounten.
            return ["granularity": focusGranularity]

        case "editorTypography":
            // Boot-Pull: der Editor-Glue liest die lokale Typografie beim Mounten.
            return typography

        case "reportStats":
            // WebView meldet Wort-/Zeichenzahl der offenen Seite (Live-Stats + Ziel).
            let words = (params["words"] as? Int) ?? (params["words"] as? NSNumber)?.intValue ?? 0
            let chars = (params["chars"] as? Int) ?? (params["chars"] as? NSNumber)?.intValue ?? 0
            onStats?(words, chars)
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
        guard let resp = try? await api.send("/content/pages/\(pageId)",
                                             method: .GET,
                                             decode: PushResponse.self),
              let html = resp.html else {
            return try? await store.page(id: pageId)
        }
        let ms = ISOTime.millis(resp.updated_at) ?? 0
        try? await store.applyServerPage(id: pageId, html: html,
                                         pageName: resp.name, bookId: nil, chapterId: nil,
                                         serverUpdatedAtMillis: ms)
        return try? await store.page(id: pageId)
    }

    // MARK: LanguageTool-Proxy
    //
    // Netzwerk macht ausschliesslich der Swift-Kern — die WebView reicht nur
    // Plain-Text + Sprache durch. Alle LT-Settings (enabled/url/picky/rules)
    // liegen serverseitig in app_settings und werden vom `/languagetool/check`-
    // Proxy angewandt; der Client kennt sie nicht.

    /// Liefert die LanguageTool-Konfiguration aus `/config`. Bei Netz-/Auth-
    /// Fehler den letzten gecachten Stand, sonst „deaktiviert" (degradiert
    /// still — Spellcheck ist online-only und kein Offline-Kern-Inhalt).
    private func spellcheckConfig() async -> [String: Any] {
        guard let api else { return ["enabled": false, "debounceMs": 1500] }
        do {
            let cfg = try await api.send("/config", decode: ConfigDTO.self)
            let enabled = cfg.languagetool?.enabled ?? false
            let debounce = cfg.languagetool?.debounceMs ?? 1500
            ltConfig = (enabled, debounce)
            return ["enabled": enabled, "debounceMs": debounce]
        } catch {
            if let cached = ltConfig {
                return ["enabled": cached.enabled, "debounceMs": cached.debounceMs]
            }
            return ["enabled": false, "debounceMs": 1500]
        }
    }

    /// Liest die serverseitige Fokus-Granularität aus `/config`
    /// (`userSettings.focus_granularity`, die Web-Einstellung des Users). Dient
    /// dem `FocusController` als Initial-Default, solange keine lokale Wahl
    /// vorliegt. `nil` bei Netz-/Auth-Fehler oder fehlendem User-Kontext.
    func serverFocusGranularity() async -> String? {
        guard let api else { return nil }
        let cfg = try? await api.send("/config", decode: ConfigDTO.self)
        return cfg?.userSettings?.focus_granularity
    }

    /// Proxyt den Prüf-Request an `POST /languagetool/check`. `404` (LT
    /// serverseitig aus) wird als `{ disabled: true }` zurückgegeben — kein
    /// Fehler. Die `matches` werden als roher JSON-Baum durchgereicht
    /// (NSJSON-konform → direkt als Bridge-Reply nutzbar).
    private func languagetoolCheck(text: String, language: String,
                                   pageId: String?, bookId: Int?) async throws -> [String: Any] {
        guard let api else { return ["disabled": true] }
        let req = LTCheckRequest(text: text, language: language, bookId: bookId, pageId: pageId)
        let (status, data) = try await api.postExpectingJSON("/languagetool/check", body: req)
        if status == 404 { return ["disabled": true] }   // Feature serverseitig aus
        guard (200...299).contains(status) else {
            throw BridgeError.languagetool(status: status)
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        let matches = (obj as? [String: Any])?["matches"] as? [Any] ?? []
        return ["matches": matches]
    }

    /// Fügt ein Wort dem serverseitigen User-Wörterbuch hinzu (`POST /dictionary`).
    private func dictionaryAdd(word: String, lang: String, bookId: Int) async throws -> [String: Any] {
        guard let api else { return ["ok": false] }
        let req = DictionaryAddRequest(word: word, bookId: bookId, lang: lang)
        let (status, _) = try await api.postExpectingJSON("/dictionary", body: req)
        return ["ok": (200...299).contains(status)]
    }

    // MARK: EditorCoordinating (Swift→JS)

    func isDirty(_ pageId: String) -> Bool {
        dirtyPages.contains(pageId)
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

    /// Ruft `block-merge.js` in der WebView (3-Wege-Merge). Wirft, wenn keine
    /// WebView/kein Bundle verfügbar ist → Aufrufer behandelt das als Konflikt.
    func merge3(base: String?, local: String, server: String) async throws -> MergeOutcome {
        guard let webView else { throw BridgeError.webViewUnavailable }
        let result = try await webView.callAsyncJavaScript(
            "return await window.__focusBridge._merge3(base, local, server);",
            arguments: ["base": base ?? "", "local": local, "server": server],
            in: nil,
            contentWorld: .page)
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
    case languagetool(status: Int)

    var errorDescription: String? {
        switch self {
        case .unknownOp(let op):     return "Bridge: unbekannte Operation '\(op)'"
        case .missingParam(let key): return "Bridge: Parameter '\(key)' fehlt"
        case .webViewUnavailable:    return "Bridge: keine WebView verfügbar (Swift→JS)"
        case .mergeFailed:           return "Bridge: Block-Merge lieferte kein Ergebnis"
        case .languagetool(let s):   return "Bridge: LanguageTool-Proxy antwortete mit Status \(s)"
        }
    }
}

// MARK: - Spellcheck-DTOs

/// Antwort-Ausschnitt von `GET /config` — nur der LanguageTool-Block.
private struct ConfigDTO: Decodable {
    struct LanguageTool: Decodable {
        let enabled: Bool?
        let debounceMs: Int?
    }
    struct UserSettings: Decodable {
        let focus_granularity: String?
    }
    let languagetool: LanguageTool?
    /// Pro-User-Einstellungen (nur mit aufgelöstem User, also auch per
    /// Device-Token — der Guard setzt `req.session.user`). `nil` ohne User.
    let userSettings: UserSettings?
}

/// Body für `POST /languagetool/check` (Server-Vertrag, siehe
/// routes/languagetool.js). `bookId`/`pageId` treiben serverseitiges Caching
/// + Wörterbuch-Filter; beide optional.
private struct LTCheckRequest: Encodable {
    let text: String
    let language: String
    let bookId: Int?
    let pageId: String?
}

/// Body für `POST /dictionary` (Wort ins User-Wörterbuch). `bookId: 0` =
/// global (alle Bücher), `lang: "*"` = alle Sprachen.
private struct DictionaryAddRequest: Encodable {
    let word: String
    let bookId: Int
    let lang: String
}
