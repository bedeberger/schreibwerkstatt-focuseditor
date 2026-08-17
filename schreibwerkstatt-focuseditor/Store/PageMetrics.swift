//
//  PageMetrics.swift
//  schreibwerkstatt-focuseditor
//
//  Zählwerte einer Seite (Zeichen + Wörter) aus ihrem gespiegelten HTML.
//  Speist die Zahlen im Seiten-Picker (Zeile + Summenzeile) — der Server-Tree
//  liefert keine Zählwerte, also rechnet sie der lokale Spiegel selbst.
//
//  Die Zählung SPIEGELT bewusst die Editor-Zählung in der WebView
//  ([WebAssets+IndexHTML](../Web/WebAssets+IndexHTML.swift), `countAndReport`):
//  Wörter = Läufe zwischen Leerraum, Zeichen = Länge des GERENDERTEN Textes
//  (inkl. Leerzeichen, Blockgrenzen als ein Zeilenumbruch). Damit zeigt der
//  Picker für die offene Seite dieselbe Zahl wie die Toolbar — eine zweite,
//  abweichende Metrik wäre schlimmer als keine.
//
//  Kein `NSAttributedString`-HTML-Parser und keine Regex: der Scanner läuft in
//  einem Durchgang über die Unicode-Skalare. Beim einmaligen Backfill eines
//  grossen Buchs (mehrere Tausend Seiten, s. `GRDBLocalStore`) zählt genau das —
//  ein Regex-Strip pro Seite wäre am Start spürbar.
//

import Foundation

/// Zählwerte einer Seite. `chars` inkl. Leerzeichen, aber ohne führenden/
/// abschliessenden Leerraum — so ist `chars == 0` verlässlich „Seite ist leer"
/// (auch bei einem leeren Absatz `<p><br></p>`, den der Editor anlegt).
nonisolated struct PageStats: Codable, Equatable {
    var chars: Int
    var words: Int

    static let zero = PageStats(chars: 0, words: 0)

    /// Keine Zeichen → unbeschriebene Seite (treibt das „leer"-Badge im Picker).
    var isEmpty: Bool { chars == 0 }
}

nonisolated enum PageMetrics {

    /// Zählt Zeichen + Wörter im gerenderten Text des HTML.
    static func counts(html: String) -> PageStats {
        var chars = 0
        var words = 0
        var inWord = false
        // Offener Leerraum (echte Leerzeichen ODER Blockgrenzen). Als Flag, nicht
        // als Zähler: der Browser klappt Leerraum-Läufe im gerenderten Text zu EINEM
        // Zeichen zusammen (`white-space`-Collapsing) — „a  b" und „<p>a</p><p>b</p>"
        // sind beide 3 bzw. 3+1+1 Zeichen. Gezählt wird er erst, wenn danach
        // wirklich Text kommt: so fällt führender/abschliessender Leerraum weg (und
        // eine „leere" Seite bleibt verlässlich bei 0).
        var pendingSpace = false

        func take(_ s: Unicode.Scalar) {
            if isSpace(s) {
                pendingSpace = true
                inWord = false
                return
            }
            if chars > 0 && pendingSpace { chars += 1 }
            pendingSpace = false
            chars += 1
            if !inWord {
                words += 1
                inWord = true
            }
        }

        let v = html.unicodeScalars
        var i = v.startIndex
        while i < v.endIndex {
            let s = v[i]
            if s == "<" {
                let (next, name) = skipTag(v, from: i)
                // Blockgrenze verhält sich wie ein Zeilenumbruch im gerenderten
                // Text; Inline-Tags (<em>, <strong>) trennen KEIN Wort — sonst
                // zählte „Wo<em>rt</em>" als zwei Wörter.
                if blockTags.contains(name) {
                    pendingSpace = true
                    inWord = false
                }
                i = next
                continue
            }
            if s == "&", let (next, scalar) = readEntity(v, from: i) {
                take(scalar)
                i = next
                continue
            }
            take(s)
            i = v.index(after: i)
        }
        return PageStats(chars: chars, words: words)
    }

    // MARK: - Scanner-Teile

    /// Überspringt ein Tag ab `<` und liefert die Position dahinter plus den
    /// klein geschriebenen Tag-Namen (ohne `/`). Attribut-Werte mit `>` darin
    /// beenden das Tag hier zu früh — dieselbe (praktisch unkritische) Grenze wie
    /// beim bisherigen Regex-Strip in `PageTitle`/`PageText`.
    private static func skipTag(_ v: String.UnicodeScalarView,
                               from start: String.UnicodeScalarView.Index)
        -> (next: String.UnicodeScalarView.Index, name: String) {
        var j = v.index(after: start)
        if j < v.endIndex, v[j] == "/" { j = v.index(after: j) }
        var name = ""
        while j < v.endIndex, isNameScalar(v[j]) {
            name.unicodeScalars.append(lowercased(v[j]))
            j = v.index(after: j)
        }
        while j < v.endIndex, v[j] != ">" { j = v.index(after: j) }
        if j < v.endIndex { j = v.index(after: j) }
        return (j, name)
    }

    /// Liest eine HTML-Entität ab `&` und löst sie in EIN Zeichen auf. `nil`,
    /// wenn sie unbekannt oder unabgeschlossen ist — dann zählt das `&` als
    /// normales Zeichen (und der Rest als Text, wie im Browser).
    private static func readEntity(_ v: String.UnicodeScalarView,
                                   from start: String.UnicodeScalarView.Index)
        -> (next: String.UnicodeScalarView.Index, scalar: Unicode.Scalar)? {
        var j = v.index(after: start)
        var body = ""
        var closed = false
        // Deckel: eine Entität ist kurz — ohne Grenze würde ein einzelnes „&"
        // im Text den halben Absatz aufsaugen.
        while j < v.endIndex, body.unicodeScalars.count <= 10 {
            if v[j] == ";" {
                closed = true
                j = v.index(after: j)
                break
            }
            body.unicodeScalars.append(v[j])
            j = v.index(after: j)
        }
        guard closed, let scalar = resolve(entity: body) else { return nil }
        return (j, scalar)
    }

    /// Entitätsname (oder `#123` / `#x1f60a`) → Zeichen.
    private static func resolve(entity: String) -> Unicode.Scalar? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap(Unicode.Scalar.init)
        }
        return entities[entity.lowercased()]
    }

    /// Tag-Namen, die im gerenderten Text eine Zeilengrenze setzen (alles, was
    /// der Browser als Block bzw. Umbruch darstellt). Alles andere ist Inline.
    private static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "li", "ul", "ol", "dl", "dt", "dd",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre",
        "table", "thead", "tbody", "tr", "td", "th",
        "section", "article", "aside", "header", "footer", "nav",
        "figure", "figcaption", "main", "form", "fieldset", "address"
    ]

    /// Die im Editor-HTML praktisch vorkommenden benannten Entitäten. Alles
    /// darüber hinaus liefert der Server als echtes Zeichen (UTF-8) — für die
    /// Zählung genügt diese Auswahl; Unbekanntes zählt als Rohtext.
    private static let entities: [String: Unicode.Scalar] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "shy": "\u{ad}", "ndash": "–", "mdash": "—", "hellip": "…",
        "laquo": "«", "raquo": "»", "bdquo": "„", "sbquo": "‚",
        "ldquo": "\u{201c}", "rdquo": "\u{201d}", "lsquo": "‘", "rsquo": "’",
        "szlig": "ß", "auml": "ä", "ouml": "ö", "uuml": "ü",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü"
    ]

    /// Leerraum wie `String.trimmingCharacters(in: .whitespacesAndNewlines)` es
    /// sieht. Die häufigen Fälle zuerst — `properties.isWhitespace` ist ein
    /// Unicode-Tabellen-Zugriff und im Millionen-Skalar-Backfill der teure Teil.
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x0A, 0x09, 0x0D, 0x0B, 0x0C, 0xA0: return true
        default: return s.value > 0x2000 && s.properties.isWhitespace
        }
    }

    /// Zeichen, die zu einem Tag-Namen gehören (`div`, `h1`, `figcaption`).
    private static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x61 && s.value <= 0x7A)   // a–z
            || (s.value >= 0x41 && s.value <= 0x5A)   // A–Z
            || (s.value >= 0x30 && s.value <= 0x39)   // 0–9
    }

    /// ASCII-Kleinschreibung eines Skalars (Tag-Namen sind ASCII).
    private static func lowercased(_ s: Unicode.Scalar) -> Unicode.Scalar {
        guard s.value >= 0x41, s.value <= 0x5A else { return s }
        return Unicode.Scalar(s.value + 32) ?? s
    }
}
