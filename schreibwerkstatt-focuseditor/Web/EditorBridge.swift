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
//  Events (Swift → JS, via `__focusBridge._receive(event, payload)`):
//    • serverUpdate { pageId, html, baseUpdatedAt }  (offene Seite serverseitig aktualisiert)
//    • openPage     { pageId, html?, baseUpdatedAt? } (nativer Picker öffnet Seite)
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
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "bridge")

    /// WebView für den Swift→JS-Kanal (`callAsyncJavaScript`). Schwach: die
    /// View besitzt die Bridge (Handler-Registrierung), nicht umgekehrt.
    private weak var webView: WKWebView?

    /// Aktuell im Editor geöffnete Seite (vom JS via `editorState` gemeldet).
    private(set) var openPageId: String?
    /// Seiten mit ungespeicherten Editor-Änderungen.
    private var dirtyPages: Set<String> = []

    init(store: any LocalStore) {
        self.store = store
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
            guard let page = try await store.page(id: pageId) else {
                // Unbekannte Seite ist kein Fehler — Editor startet leer.
                return nil
            }
            return Self.encode(page)

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

        default:
            throw BridgeError.unknownOp(op)
        }
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

    var errorDescription: String? {
        switch self {
        case .unknownOp(let op):     return "Bridge: unbekannte Operation '\(op)'"
        case .missingParam(let key): return "Bridge: Parameter '\(key)' fehlt"
        case .webViewUnavailable:    return "Bridge: keine WebView verfügbar (Swift→JS)"
        case .mergeFailed:           return "Bridge: Block-Merge lieferte kein Ergebnis"
        }
    }
}
