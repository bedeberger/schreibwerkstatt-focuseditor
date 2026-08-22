//
//  WebAssets+GlueMount.swift
//  schreibwerkstatt-focuseditor
//
//  Der initiale Aufruf von `initSpellcheckIfEnabled()` nach dem Mount.
//
//  Teil des EINEN Boot-Moduls in [WebAssets+IndexHTML.swift](WebAssets+IndexHTML.swift):
//  die Fragmente teilen sich einen JS-Scope (`fb`, `currentPageId`, die Helfer)
//  und werden dort in fester Reihenfolge zusammengesetzt. Aufgeteilt, weil die
//  eine Datei über 1200 Zeilen gewachsen und der einzige Eintrag in der
//  Allowlist des Zeilen-Guards war — nicht, weil die Teile unabhängig wären.
//  Reihenfolge und Einrückung sind darum bindend; `WebAssetsSyntaxTests` lässt
//  `node --check` über das zusammengesetzte Ergebnis laufen.
//

import Foundation

extension WebAssets {
    /// Initialer Spellcheck-Mount — Fragment des Boot-Moduls (s. Kopfdoku).
    static let glueMountJS = """
              // ── Rechtschreibung initialer Mount ─────────────────────────────
              // Die eigentliche Logik liegt in `initSpellcheckIfEnabled` (oben
              // definiert + exposed), damit Swift sie nachträglich erneut
              // anstossen kann (Offline-Boot-Lücke). Hier nur der erste,
              // synchrone Boot-Versuch — schlägt er fehl (offline/serverseitig
              // aus), mergt sich das beim nächsten Server-Kontakt automatisch.
              await initSpellcheckIfEnabled();

        """
}
