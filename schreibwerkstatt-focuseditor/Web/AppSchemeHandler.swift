//
//  AppSchemeHandler.swift
//  schreibwerkstatt-focuseditor
//
//  Custom-URL-Scheme-Handler, der das gecachte OTA-Editor-Bundle aus dem
//  web-cache/-Verzeichnis (Application Support) unter EINER echten Origin
//  (swk-app://local/…) ausliefert.
//
//  WARUM (statt loadFileURL): Unter `file://` bekommt JEDE Datei eine eigene,
//  opake Origin. WKWebView wertet damit jeden ES-Modul-`import` als
//  Cross-Origin-Request und blockt ihn per CORS ("Cross-origin script load
//  denied …"). Über ein eigenes Scheme teilen sich alle Bundle-Dateien EINE
//  Origin (swk-app://local) — der Modulgraph lädt nativ.
//
//  HARTE REGEL (CLAUDE.md): Liefert ausschließlich lokale Bundle-Dateien aus
//  dem Cache-Verzeichnis (webRoot). Kein Netzwerk, kein Pfad ausserhalb der Wurzel.
//

import Foundation
import WebKit
import UniformTypeIdentifiers

/// Eigenes Scheme — bewusst kein reserviertes (http/https/file/about/…), sonst
/// lehnt WebKit die Registrierung ab.
enum AppScheme {
    static let scheme = "swk-app"
    static let host = "local"
    /// Einstiegs-URL der WebView.
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!
}

final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Wurzelverzeichnis des gecachten OTA-Bundles (Application Support/…/web-cache).
    private let webRoot: URL

    init(webRoot: URL) {
        self.webRoot = webRoot.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let requestURL = urlSchemeTask.request.url

        guard let resolved = resolve(requestURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: resolved)
            let response = HTTPURLResponse(
                url: requestURL ?? AppScheme.indexURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType(for: resolved),
                    "Content-Length": String(data.count),
                    // Eine Origin, keine Caches über Sessions — reine Bundle-Auslieferung.
                    "Cache-Control": "no-cache"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchrone Auslieferung — nichts abzubrechen.
    }

    /// Mappt eine swk-app://local/<pfad>-URL auf eine Datei unter webRoot und
    /// verhindert Pfad-Ausbruch ausserhalb der Wurzel (Path-Traversal-Schutz).
    private func resolve(_ url: URL?) -> URL? {
        guard let url, url.scheme == AppScheme.scheme else { return nil }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }

        let candidate = webRoot.appendingPathComponent(path).standardizedFileURL

        // Muss innerhalb der webRoot-Wurzel liegen.
        guard candidate.path == webRoot.path
            || candidate.path.hasPrefix(webRoot.path + "/") else { return nil }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return candidate
    }

    /// MIME-Type aus der Dateiendung. KRITISCH für ES-Module: .js MUSS als
    /// JavaScript-Typ ausgeliefert werden, sonst verweigert der Browser das Modul.
    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "otf":         return "font/otf"
        case "map":         return "application/json; charset=utf-8"
        default:
            if let type = UTType(filenameExtension: url.pathExtension),
               let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }
}
