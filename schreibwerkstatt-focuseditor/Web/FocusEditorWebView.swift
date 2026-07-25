//
//  FocusEditorWebView.swift
//  schreibwerkstatt-focuseditor
//
//  WKWebView-Subklasse, die dem nativen Kontextmenü der Schreibfläche einen
//  eigenen Eintrag „Synonyme vorschlagen" voranstellt. Nötig, weil das Menü der
//  WKWebView von WebKit selbst gebaut wird — der einzige saubere Eingriffspunkt
//  ist `willOpenMenu(_:with:)`. Der Eintrag ist der Rechtsklick-Zwilling zum
//  Toolbar-Knopf und zu ⌘⇧S; die eigentliche Arbeit macht wie immer der
//  gebündelte Synonym-Controller aus dem Hauptrepo (kein Fork).
//
//  Die Position des Rechtsklicks wird mitgegeben (CSS-Viewport-Punkt): der
//  Rechtsklick setzt in einem contenteditable nicht zuverlässig den Caret, also
//  bestimmt der Glue das Wort über `caretRangeFromPoint` statt über einen
//  womöglich veralteten Caret an anderer Stelle.
//

import AppKit
import WebKit

final class FocusEditorWebView: WKWebView {
    /// Auslöser für die Synonym-Hilfe. Parameter ist der Klickpunkt in
    /// CSS-Viewport-Koordinaten (`nil` = kein Punkt bekannt → Auswahl/Caret).
    var onSynonyms: ((CGPoint?) -> Void)?

    /// Soll der Eintrag überhaupt erscheinen? (Synonym-Hilfe lokal aktiv UND eine
    /// Seite offen — sonst wäre der Klick wirkungslos.)
    var isSynonymsAvailable: (() -> Bool)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard isSynonymsAvailable?() ?? false else { return }

        // AppKit-Punkt → CSS-Viewport-Punkt. WKWebView ist nicht geflippt, die
        // y-Achse läuft also von unten; `caretRangeFromPoint` erwartet Client-
        // Koordinaten (von oben, ohne Scroll-Offset).
        let local = convert(event.locationInWindow, from: nil)
        let cssPoint = CGPoint(x: local.x,
                               y: isFlipped ? local.y : bounds.height - local.y)

        let item = NSMenuItem(title: t("contextmenu.synonyms"),
                              action: #selector(triggerSynonyms(_:)),
                              keyEquivalent: "")
        item.target = self
        // Punkt am Eintrag selbst mitführen: die Aktion feuert erst NACH dem
        // Schliessen des Menüs — ein Zustand an der View wäre bis dahin schon
        // wieder aufzuräumen bzw. veraltet.
        item.representedObject = NSValue(point: cssPoint)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func triggerSynonyms(_ sender: Any?) {
        let point = (sender as? NSMenuItem)?.representedObject as? NSValue
        onSynonyms?(point?.pointValue)
    }
}
