//
//  HTMLToMarkdown.swift
//  schreibwerkstatt-focuseditor
//
//  Wandelt das Seiten-HTML des Manuskripts in Markdown — die Textform, in der
//  ein Buch aus diesem Client herausfindet (Ablage ▸ „Buch exportieren …").
//
//  Warum eigen und nicht `NSAttributedString(html:)`: das Cocoa-Parsing läuft
//  auf dem Hauptthread, ist für hunderte Seiten unbrauchbar langsam und liefert
//  am Ende Attribute statt Struktur — Überschriftenebene, Listen und Zitate
//  müssten daraus wieder erraten werden. Der Bestand hier ist ohnehin eng: das
//  Manuskript-HTML kommt aus dem eigenen Editor und ist eine flache Folge von
//  Blockelementen mit einfacher Inline-Auszeichnung, kein Fremd-HTML aus dem Web.
//
//  Bewusst KEIN Editor-Fork: gelesen wird nur das gespeicherte HTML aus dem
//  lokalen Spiegel. Der Editor-Code bleibt unangetastet, `data-bid` und andere
//  Attribute werden schlicht ignoriert.
//
//  Pure Funktionen, kein Zustand, keine UI — Testgegenstand von
//  `HTMLToMarkdownTests`. Die Datei-/Ordnerseite liegt in BookExport.swift.
//

import Foundation

enum HTMLToMarkdown {

    /// Konvertiert den Body eines Seiten-HTML in Markdown.
    /// Liefert einen Text ohne führende/abschliessende Leerzeilen.
    static func convert(_ html: String) -> String {
        var out: [String] = []
        for block in blocks(in: html) {
            let rendered = render(block)
            if !rendered.isEmpty { out.append(rendered) }
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: - Blockzerlegung

    /// Ein Blockelement der Seite samt seinem rohen Innen-HTML.
    struct Block {
        let tag: String
        let inner: String
        /// Verschachtelungstiefe für Listen (`ul`/`ol` ineinander).
        var listDepth: Int = 0
        /// Nummerierte Liste? (steuert `1.` vs `-`)
        var ordered: Bool = false
    }

    /// Blocktags, die eine eigene Markdown-Zeile ergeben. Alles andere (span,
    /// div ohne Bedeutung, …) wird durchgereicht und landet als Absatz-Inline.
    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "hr", "ul", "ol", "li", "figure", "figcaption",
    ]

    /// Zerlegt das HTML in seine Top-Level-Blöcke. Listen werden dabei
    /// rekursiv aufgelöst, damit `<ul><li>…` nicht als ein Klumpen ankommt.
    static func blocks(in html: String, listDepth: Int = 0, ordered: Bool = false) -> [Block] {
        var result: [Block] = []
        var scanner = Substring(html)
        /// Text, der zwischen den Blöcken steht (loses Inline-HTML) — er darf
        /// nicht verloren gehen, sondern wird zu einem eigenen Absatz.
        var loose = ""

        func flushLoose() {
            let text = loose.trimmingCharacters(in: .whitespacesAndNewlines)
            loose = ""
            if !text.isEmpty { result.append(Block(tag: "p", inner: text, listDepth: listDepth)) }
        }

        while let open = scanner.firstIndex(of: "<") {
            loose += scanner[scanner.startIndex..<open]
            scanner = scanner[open...]
            guard let tag = parseTag(scanner) else {
                // Kein gültiger Tag → das `<` ist Text.
                loose.append("<")
                scanner = scanner[scanner.index(after: scanner.startIndex)...]
                continue
            }
            guard blockTags.contains(tag.name), !tag.isClosing else {
                // Inline-Tag (oder ein schliessender Rest) — unverändert
                // weiterreichen, `renderInline` kümmert sich darum.
                loose += scanner[scanner.startIndex..<tag.end]
                scanner = scanner[tag.end...]
                continue
            }
            flushLoose()

            if tag.name == "hr" || tag.selfClosing {
                result.append(Block(tag: tag.name, inner: "", listDepth: listDepth))
                scanner = scanner[tag.end...]
                continue
            }
            // Inhalt bis zum passenden schliessenden Tag (verschachtelungsfest).
            let (inner, after) = takeElementBody(scanner[tag.end...], tag: tag.name)
            scanner = after

            switch tag.name {
            case "ul", "ol":
                result.append(contentsOf: blocks(in: inner,
                                                 listDepth: listDepth + 1,
                                                 ordered: tag.name == "ol"))
            case "li":
                // Ein `li` kann selbst Unterlisten tragen: den eigenen Text als
                // Listenzeile, verschachtelte Listen als eigene Blöcke danach.
                let (ownText, nested) = splitNestedLists(inner)
                result.append(Block(tag: "li", inner: ownText,
                                    listDepth: max(listDepth, 1), ordered: ordered))
                for sub in nested {
                    result.append(contentsOf: blocks(in: sub.inner,
                                                     listDepth: listDepth + 1,
                                                     ordered: sub.tag == "ol"))
                }
            default:
                result.append(Block(tag: tag.name, inner: inner, listDepth: listDepth))
            }
        }
        loose += scanner
        flushLoose()
        return result
    }

    /// Trennt den Eigentext eines `<li>` von darin verschachtelten Listen.
    private static func splitNestedLists(_ inner: String) -> (String, [Block]) {
        var own = ""
        var nested: [Block] = []
        var scanner = Substring(inner)
        while let open = scanner.firstIndex(of: "<") {
            own += scanner[scanner.startIndex..<open]
            scanner = scanner[open...]
            guard let tag = parseTag(scanner), tag.name == "ul" || tag.name == "ol", !tag.isClosing else {
                own.append("<")
                scanner = scanner[scanner.index(after: scanner.startIndex)...]
                continue
            }
            let (body, after) = takeElementBody(scanner[tag.end...], tag: tag.name)
            nested.append(Block(tag: tag.name, inner: body))
            scanner = after
        }
        own += scanner
        return (own, nested)
    }

    // MARK: - Blockformatierung

    private static func render(_ block: Block) -> String {
        switch block.tag {
        case "hr":
            return "---"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(block.tag.dropFirst())) ?? 1
            let text = renderInline(block.inner)
            return text.isEmpty ? "" : String(repeating: "#", count: level) + " " + text
        case "blockquote":
            // Innere Blöcke einzeln zitieren, damit mehrzeilige Zitate stimmen.
            let body = convert(block.inner)
            if body.isEmpty { return "" }
            return body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
        case "pre":
            let code = decodeEntities(stripTags(block.inner))
            return code.isEmpty ? "" : "```\n\(code)\n```"
        case "li":
            let text = renderInline(block.inner)
            if text.isEmpty { return "" }
            let indent = String(repeating: "  ", count: max(block.listDepth - 1, 0))
            return indent + (block.ordered ? "1. " : "- ") + text
        case "figcaption":
            let text = renderInline(block.inner)
            return text.isEmpty ? "" : "*\(text)*"
        default:
            return renderInline(block.inner)
        }
    }

    // MARK: - Inline

    /// Wandelt Inline-Auszeichnung in Markdown und entfernt alles Übrige.
    /// `<br>` wird zum harten Zeilenumbruch (zwei Leerzeichen + \n) — der
    /// Editor setzt ihn für Zeilenwechsel innerhalb eines Absatzes.
    static func renderInline(_ html: String) -> String {
        var out = ""
        var scanner = Substring(html)
        while let open = scanner.firstIndex(of: "<") {
            out += scanner[scanner.startIndex..<open]
            scanner = scanner[open...]
            guard let tag = parseTag(scanner) else {
                out.append("<")
                scanner = scanner[scanner.index(after: scanner.startIndex)...]
                continue
            }
            scanner = scanner[tag.end...]
            if tag.isClosing { continue }   // Marker sind schon beim Öffnen gesetzt

            switch tag.name {
            case "br":
                out += "  \n"
            case "strong", "b":
                let (inner, after) = takeElementBody(scanner, tag: tag.name)
                scanner = after
                let text = renderInline(inner)
                if !text.isEmpty { out += "**\(text)**" }
            case "em", "i":
                let (inner, after) = takeElementBody(scanner, tag: tag.name)
                scanner = after
                let text = renderInline(inner)
                if !text.isEmpty { out += "*\(text)*" }
            case "code":
                let (inner, after) = takeElementBody(scanner, tag: tag.name)
                scanner = after
                let text = decodeEntities(stripTags(inner))
                if !text.isEmpty { out += "`\(text)`" }
            case "a":
                let (inner, after) = takeElementBody(scanner, tag: tag.name)
                scanner = after
                let text = renderInline(inner)
                if let href = attribute("href", in: tag.attributes), !text.isEmpty {
                    out += "[\(text)](\(href))"
                } else {
                    out += text
                }
            case "img":
                // Manuskript-Bilder hängen als `/content/page-image/:id` am
                // Server — im Export bleibt der Alt-Text als Platzhalter, ein
                // toter lokaler Pfad wäre schlechter als eine ehrliche Lücke.
                if let alt = attribute("alt", in: tag.attributes), !alt.isEmpty {
                    out += "![\(alt)]()"
                }
            default:
                continue   // span, mark, Spellcheck-Hüllen … → nur Inhalt zählt
            }
        }
        out += scanner
        return decodeEntities(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mini-Parser

    struct Tag {
        let name: String
        let attributes: String
        let isClosing: Bool
        let selfClosing: Bool
        /// Index NACH dem `>` in der Ursprungs-Substring.
        let end: Substring.Index
    }

    /// Liest den Tag am Anfang von `s` (der bei `<` steht). `nil`, wenn dort
    /// kein wohlgeformter Tag beginnt.
    static func parseTag(_ s: Substring) -> Tag? {
        guard s.first == "<" else { return nil }
        var i = s.index(after: s.startIndex)
        guard i < s.endIndex else { return nil }
        let isClosing = s[i] == "/"
        if isClosing { i = s.index(after: i) }
        var name = ""
        while i < s.endIndex, s[i].isLetter || s[i].isNumber {
            name.append(s[i])
            i = s.index(after: i)
        }
        guard !name.isEmpty, let close = s[i...].firstIndex(of: ">") else { return nil }
        let attrs = String(s[i..<close])
        return Tag(name: name.lowercased(),
                   attributes: attrs,
                   isClosing: isClosing,
                   selfClosing: attrs.hasSuffix("/"),
                   end: s.index(after: close))
    }

    /// Nimmt den Inhalt bis zum passenden `</tag>` — verschachtelungsfest
    /// (`<em>a <em>b</em></em>` schliesst nicht zu früh). Fehlt der schliessende
    /// Tag, gilt der Rest als Inhalt (defensiv: lieber Text zu viel als
    /// abgeschnittenes Manuskript).
    static func takeElementBody(_ s: Substring, tag: String) -> (String, Substring) {
        var depth = 1
        var scanner = s
        var body = ""
        while let open = scanner.firstIndex(of: "<") {
            body += scanner[scanner.startIndex..<open]
            scanner = scanner[open...]
            guard let t = parseTag(scanner) else {
                body.append("<")
                scanner = scanner[scanner.index(after: scanner.startIndex)...]
                continue
            }
            if t.name == tag {
                if t.isClosing {
                    depth -= 1
                    if depth == 0 { return (body, scanner[t.end...]) }
                } else if !t.selfClosing {
                    depth += 1
                }
            }
            body += scanner[scanner.startIndex..<t.end]
            scanner = scanner[t.end...]
        }
        return (body + scanner, scanner[scanner.endIndex...])
    }

    /// Wert eines Attributs aus dem rohen Attribut-String eines Tags.
    static func attribute(_ name: String, in attributes: String) -> String? {
        guard let r = attributes.range(of: "\(name)=", options: [.caseInsensitive]) else { return nil }
        var rest = attributes[r.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return decodeEntities(String(rest[rest.startIndex..<end]))
    }

    /// Entfernt alle Tags, behält den Text.
    static func stripTags(_ html: String) -> String {
        var out = ""
        var scanner = Substring(html)
        while let open = scanner.firstIndex(of: "<") {
            out += scanner[scanner.startIndex..<open]
            scanner = scanner[open...]
            if let t = parseTag(scanner) {
                scanner = scanner[t.end...]
            } else {
                out.append("<")
                scanner = scanner[scanner.index(after: scanner.startIndex)...]
            }
        }
        return out + scanner
    }

    /// Die HTML-Entities, die im Manuskript-HTML tatsächlich vorkommen (der
    /// Editor schreibt nur diese) plus numerische Referenzen.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&nbsp;", "\u{00A0}"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        out = decodeNumericEntities(out)
        // `&amp;` ZULETZT — sonst würde ein codiertes „&amp;lt;" zu „<".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        var scanner = Substring(s)
        while let amp = scanner.range(of: "&#") {
            out += scanner[scanner.startIndex..<amp.lowerBound]
            let rest = scanner[amp.upperBound...]
            guard let semi = rest.firstIndex(of: ";") else {
                out += scanner[amp.lowerBound...]
                return out
            }
            let digits = rest[rest.startIndex..<semi]
            let hex = digits.first == "x" || digits.first == "X"
            let number = hex ? String(digits.dropFirst()) : String(digits)
            if let code = UInt32(number, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
            } else {
                out += scanner[amp.lowerBound...rest.index(before: semi)]
            }
            scanner = rest[rest.index(after: semi)...]
        }
        return out + scanner
    }
}
