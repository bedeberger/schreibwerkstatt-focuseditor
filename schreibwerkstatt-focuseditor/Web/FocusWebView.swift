//
//  FocusWebView.swift
//  schreibwerkstatt-focuseditor
//
//  SwiftUI-Host für die WKWebView, die den Focus-Editor trägt.
//
//  HARTE REGEL (CLAUDE.md): Die WebView lädt IMMER lokal — nie eine Server-URL.
//   • Liegt im OTA-Cache (web-cache/, von EditorBundleStore gezogen) ein
//     bootfähiges Bundle (index.html), wird es über das eigene Scheme
//     (swk-app://) via AppSchemeHandler geladen — eine Origin, ES-Module laden.
//   • Sonst Fallback auf die In-Source-Dev-Harness (`loadHTMLString`), damit die
//     Shell + Bridge schon vor dem ersten Bundle-Download lauffähig und testbar sind.
//
//  Die Bridge-Facade wird at-document-start in beide Fälle injiziert.
//

import SwiftUI
import WebKit

struct FocusWebView: NSViewRepresentable {
    /// App-weite Bridge (geteilt mit der SyncEngine über `AppCore`).
    let bridge: EditorBridge
    /// Wurzelverzeichnis des lokal gecachten OTA-Editor-Bundles (web-cache/).
    /// Der AppSchemeHandler liefert ausschließlich Dateien hierunter aus.
    let webRoot: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.bridge = bridge   // Lebensdauer an die View koppeln

        let controller = WKUserContentController()
        // Bridge-Primitiv at-document-start bereitstellen.
        controller.addUserScript(WKUserScript(source: WebAssets.bridgeFacadeJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        // Promise-basierter Handler (JS-`postMessage` liefert nativ ein Reply).
        controller.addScriptMessageHandler(bridge, contentWorld: .page, name: EditorBridge.handlerName)

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        // Bundle über ein eigenes Scheme ausliefern (EINE Origin → ES-Module laden;
        // loadFileURL gibt jeder Datei eine opake Origin → CORS-Block). Quelle ist
        // der lokale OTA-Cache (web-cache/); liegt dort kein index.html, greift
        // unten die Dev-Harness.
        if hasBundle {
            let handler = AppSchemeHandler(webRoot: webRoot)
            context.coordinator.schemeHandler = handler  // Lebensdauer an die View koppeln
            config.setURLSchemeHandler(handler, forURLScheme: AppScheme.scheme)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        Self.makeTransparent(webView)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.isInspectable = true   // Web-Inspector im Debug-Build
        }
        #endif

        // Swift→JS-Kanal verbinden (Open-Page-Reload, Block-Merge).
        bridge.attach(webView)

        load(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Statisches lokales Bundle — kein dynamisches Reload nötig.
    }

    /// Schaltet den opaken WKWebView-Hintergrund aus, damit die Brand-Fläche
    /// (BrandColor.bg) durchscheint. Es gibt KEINE öffentliche API dafür — die
    /// `drawsBackground`-Property ist privat und nur über KVC erreichbar. Der
    /// Zugriff ist gegen ein künftig fehlendes Setter-Selektor abgesichert
    /// (degradiert dann still zu opakem Weiss, statt zu crashen). Bewusst
    /// akzeptiert: Distribution läuft über Sparkle/Notarization, nicht den
    /// App Store (CLAUDE.md Roadmap 5).
    private static func makeTransparent(_ webView: WKWebView) {
        guard webView.responds(to: Selector(("setDrawsBackground:"))) else { return }
        webView.setValue(false, forKey: "drawsBackground")
    }

    /// Liegt im Cache ein bootfähiges Bundle (index.html)?
    private var hasBundle: Bool {
        FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path)
    }

    /// Lädt das gecachte Editor-Bundle über das eigene Scheme, sonst die Dev-Harness.
    private func load(into webView: WKWebView) {
        if hasBundle {
            webView.load(URLRequest(url: AppScheme.indexURL))
        } else {
            webView.loadHTMLString(WebAssets.devHarnessHTML, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: EditorBridge?
        var schemeHandler: AppSchemeHandler?

        // HARTE REGEL: keine externen Navigationen. Nur lokale Schemes erlauben.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == AppScheme.scheme || scheme == "file" || scheme == "about" || scheme == nil {
                decisionHandler(.allow)
            } else {
                // http(s)/mailto/… gehören nicht in die Editor-WebView.
                decisionHandler(.cancel)
            }
        }
    }
}
