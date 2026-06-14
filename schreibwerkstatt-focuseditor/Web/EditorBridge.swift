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
//    • list                                    → [ { id, title?, updatedAt } ]
//    • log  { level?, message }                → null   (JS-Diagnose im Swift-Log)
//
//  Erweiterung: Braucht der Editor eine neue Root-Methode, wird sie ZUERST hier
//  und in der JS-Facade (focusHost-Vertrag) ergänzt und in CLAUDE.md dokumentiert.
//

import Foundation
import WebKit
import OSLog

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// Name, unter dem die Bridge in JS erreichbar ist:
    /// `window.webkit.messageHandlers.swBridge.postMessage(...)`.
    static let handlerName = "swBridge"

    private let store: any LocalStore
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "bridge")

    init(store: any LocalStore) {
        self.store = store
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

        default:
            throw BridgeError.unknownOp(op)
        }
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

    var errorDescription: String? {
        switch self {
        case .unknownOp(let op):     return "Bridge: unbekannte Operation '\(op)'"
        case .missingParam(let key): return "Bridge: Parameter '\(key)' fehlt"
        }
    }
}
