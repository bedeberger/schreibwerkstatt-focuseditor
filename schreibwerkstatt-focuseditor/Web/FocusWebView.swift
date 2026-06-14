//
//  FocusWebView.swift
//  schreibwerkstatt-focuseditor
//
//  SwiftUI-Host für die WKWebView, die den Focus-Editor trägt.
//
//  HARTE REGEL (CLAUDE.md): Die WebView lädt IMMER lokal — nie eine Server-URL.
//   • Liegt ein gebündeltes Editor-Build unter Resources/web/index.html, wird
//     dieses per `loadFileURL` geladen (Produktionspfad, sobald der Build-Step
//     existiert).
//   • Sonst Fallback auf die In-Source-Dev-Harness (`loadHTMLString`), damit die
//     Shell + Bridge schon vor dem Editor-Bundle lauffähig und testbar sind.
//
//  Die Bridge-Facade wird at-document-start in beide Fälle injiziert.
//

import SwiftUI
import WebKit

struct FocusWebView: NSViewRepresentable {
    /// App-weite Bridge (geteilt mit der SyncEngine über `AppCore`).
    let bridge: EditorBridge

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
        // loadFileURL gibt jeder Datei eine opake Origin → CORS-Block). Nur wenn
        // ein echtes Build vorliegt; sonst greift unten die Dev-Harness.
        if let webRoot = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")?
            .deletingLastPathComponent() {
            let handler = AppSchemeHandler(webRoot: webRoot)
            context.coordinator.schemeHandler = handler  // Lebensdauer an die View koppeln
            config.setURLSchemeHandler(handler, forURLScheme: AppScheme.scheme)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // Brand-Hintergrund durchscheinen lassen
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

    /// Lädt das gebündelte Editor-Build über das eigene Scheme, sonst die Dev-Harness.
    private func load(into webView: WKWebView) {
        if Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") != nil {
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
