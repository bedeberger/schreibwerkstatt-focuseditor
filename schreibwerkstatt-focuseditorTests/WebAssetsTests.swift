//
//  WebAssetsTests.swift
//  schreibwerkstatt-focuseditorTests
//
//  Offline-Regressionstests für den Client-Glue: `WebAssets.indexHTML` (Boot-/
//  Bridge-HTML, das der EditorBundleStore in den Cache schreibt) und die
//  `bridgeFacadeJS` (at-document-start injizierte Bridge). Reine Strings, kein
//  Server. Sichert die Vertragspunkte, deren stille Änderung den Editor-Boot
//  oder die JS⇄Swift-Brücke bricht (Mount-Pfad, CSS-Reihenfolge, __focusBridge).
//

import XCTest

final class WebAssetsTests: XCTestCase {

    // MARK: - indexHTML

    func testEmitsCssLinksInGivenOrder() {
        let html = WebAssets.indexHTML(cssFiles: ["css/focus.css", "css/spellcheck.css"],
                                       sourceCommit: "deadbeef")
        XCTAssertTrue(html.contains(#"<link rel="stylesheet" href="css/focus.css">"#))
        XCTAssertTrue(html.contains(#"<link rel="stylesheet" href="css/spellcheck.css">"#))
        // Reihenfolge muss erhalten bleiben (= Link-/Kaskaden-Reihenfolge).
        let a = html.range(of: "css/focus.css")!
        let b = html.range(of: "css/spellcheck.css")!
        XCTAssertTrue(a.lowerBound < b.lowerBound, "CSS-Reihenfolge muss der Eingabe folgen")
    }

    func testEmptyCssFilesProducesValidHtmlWithoutLinks() {
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "abc")
        XCTAssertFalse(html.contains("<link"), "ohne CSS keine Link-Tags")
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains(#"id="mount""#))
    }

    func testIncludesSourceCommitInComment() {
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "c0ffee123")
        XCTAssertTrue(html.contains("c0ffee123"), "Quell-Commit muss zur Nachverfolgung im HTML stehen")
    }

    func testImportsStandaloneMountPath() {
        // Bricht dieser Pfad, mountet die Focus-Engine nicht → leerer Editor.
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "x")
        XCTAssertTrue(html.contains("./js/editor/focus/standalone.js"))
        XCTAssertTrue(html.contains("mountStandaloneFocus"))
    }

    func testReferencesFocusBridge() {
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "x")
        XCTAssertTrue(html.contains("window.__focusBridge"))
    }

    func testContainsNativeTypographyStyleHook() {
        // Die Typografie-Override-Schicht hängt an dieser ID (live umschaltbar).
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "x")
        XCTAssertTrue(html.contains("sw-native-typography"))
    }

    func testLanguageToolBadgeIsPinnedFixed() {
        // Override über dem Editor-CSS (kein Fork): Badge muss fixed ans Eck.
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "x")
        XCTAssertTrue(html.contains(".lt-badge"))
        XCTAssertTrue(html.contains("position: fixed !important"))
    }

    func testDeclaresGermanLang() {
        let html = WebAssets.indexHTML(cssFiles: [], sourceCommit: "x")
        XCTAssertTrue(html.contains(#"<html lang="de">"#))
    }

    // MARK: - bridgeFacadeJS

    func testFacadeWiresConfiguredHandlerName() {
        // Die Facade muss exakt den Handler ansprechen, den EditorBridge registriert.
        XCTAssertTrue(WebAssets.bridgeFacadeJS.contains("messageHandlers.\(WebAssets.handlerName)"))
        XCTAssertTrue(WebAssets.bridgeFacadeJS.contains("window.__focusBridge"))
    }

    func testFacadeExposesCoreBridgeOps() {
        let js = WebAssets.bridgeFacadeJS
        for op in ["load:", "save:", "list:", "reportStats:", "_merge3:"] {
            XCTAssertTrue(js.contains(op), "Bridge-Facade muss \(op) bereitstellen")
        }
    }

    func testHandlerNameIsStable() {
        // Single Source of Truth (EditorBridge referenziert diesen Wert). Ändert
        // sich der Name, muss die JS-Facade unten mitziehen — daher hier verankert.
        XCTAssertEqual(WebAssets.handlerName, "swBridge")
    }
}
