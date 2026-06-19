//
//  WebAssets.swift
//  schreibwerkstatt-focuseditor
//
//  In-Source-Web-Assets für die native Shell. Der Typ ist bewusst auf mehrere
//  Dateien aufgeteilt (je ein zusammenhängendes JS/HTML-Template pro Datei),
//  damit keine einzelne über das Zeilen-Limit wächst und jedes Stück für sich
//  auffindbar bleibt:
//   • `WebAssets.swift`              — dieser Kern: nur der Handler-Name (keine Abhängigkeiten).
//   • `WebAssets+BridgeFacade.swift` — `bridgeFacadeJS`, at-document-start in JEDE
//     Seite injiziert; stellt `window.__focusBridge` bereit (das einzige Primitiv,
//     über das die WebView den Swift-Kern erreicht).
//   • `WebAssets+IndexHTML.swift`    — `indexHTML(cssFiles:sourceCommit:)`, der Boot-/
//     Bridge-Glue der Schale für das OTA-Editor-Bundle.
//   • `WebAssets+DevHarness.swift`   — `devHarnessHTML`, eine eigenständige Diagnose-
//     Seite, solange (noch) kein echtes Editor-Bundle vorliegt. Kein Produktions-Asset.
//
//  Das echte Editor-Bundle kommt per OTA aus dem Hauptrepo (CLAUDE.md); diese
//  Strings werden NICHT von Hand zu Editor-Code ausgebaut.
//

import Foundation

enum WebAssets {
    /// Name des WKScriptMessage-Handlers — Single Source of Truth. Hier (im
    /// dependency-freien Asset-Modul) verankert, damit `WebAssets` ohne den
    /// schweren `EditorBridge` (WebKit/LocalStore/APIClient) testbar/kompilierbar
    /// bleibt. `EditorBridge.handlerName` referenziert diesen Wert.
    static let handlerName = "swBridge"
}
