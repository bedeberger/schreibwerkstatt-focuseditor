//
//  EditorBridge+Params.swift
//  schreibwerkstatt-focuseditor
//
//  Eingangs-Validierung der Bridge: `params` kommt aus der WebView (fremder
//  Editor-Code aus dem OTA-Bundle) und ist NICHT vertrauenswürdig. Diese Datei
//  ist die einzige Stelle, an der rohe JS-Werte zu Swift-Werten werden — jede
//  Op in `EditorBridge+Ops.swift` geht durch sie hindurch.
//
//  Prinzipien:
//   • Pflichtfelder werfen (`BridgeError.missingParam/.invalidParam`) → die
//     JS-Promise lehnt ab, der Editor sieht einen klaren Fehler.
//   • Optionale Felder degradieren still zu `nil` (nie „irgendwie" interpretiert).
//   • Zahlen: NaN/Unendlich/negative Werte werden verworfen bzw. geklemmt — ein
//     NaN-Zeitstempel im LocalStore vergiftete sonst jeden Basis-Vergleich des Syncs.
//   • Strings: harte Längen-Deckel; Seiten-IDs zusätzlich auf eine unauffällige
//     Form geprüft (sie landen in URL-Pfaden, UserDefaults-Keys und Logs).
//

import Foundation

extension EditorBridge {

    // MARK: - Grenzwerte

    /// Deckel für einen HTML-Body (`save`). Eine Buchseite liegt bei Kilobyte;
    /// alles jenseits davon ist ein Defekt und hätte nur den Spiegel aufgeblasen.
    /// Bewusst kein Datenverlust-Risiko: der Save lehnt ab, der Text bleibt im
    /// DOM des Editors, und der Nutzer sieht den Save-Fehler-Banner.
    static let maxHtmlLength = 4_000_000
    /// Deckel für den Prüftext des LanguageTool-Proxys (Serverseite limitiert
    /// ebenfalls; hier sparen wir den Roundtrip).
    static let maxCheckTextLength = 200_000
    /// Deckel für ein einzelnes Wort (Wörterbuch/Synonyme).
    static let maxWordLength = 120
    /// Deckel für den Kontext-Satz der KI-Synonyme.
    static let maxSentenceLength = 2_000
    /// Deckel für eine Seiten-ID (serverseitig sind es kurze numerische IDs).
    static let maxPageIdLength = 64
    /// Deckel für eine ins Log geschriebene JS-Meldung.
    static let maxLogMessageLength = 1_000
    /// Deckel für Wort-/Zeichenzahlen (Statistik) — jenseits davon ist der Wert Müll.
    static let maxStatsCount = 50_000_000

    // MARK: - Strings

    /// Pflicht-String. Fehlt der Wert (oder ist er kein String) → `missingParam`;
    /// ist er leer (sofern nicht erlaubt) oder überlang → `invalidParam`.
    func requireString(_ params: [String: Any], _ key: String,
                       maxLength: Int = 4_096, allowEmpty: Bool = false) throws -> String {
        guard let value = params[key] as? String else {
            throw BridgeError.missingParam(key)
        }
        if !allowEmpty && value.isEmpty {
            throw BridgeError.invalidParam(key, reason: "leer")
        }
        guard value.count <= maxLength else {
            throw BridgeError.invalidParam(key, reason: "über \(maxLength) Zeichen")
        }
        return value
    }

    /// Optionaler String (still `nil` bei fehlendem/falschem/überlangem Wert).
    func optString(_ params: [String: Any], _ key: String, maxLength: Int = 4_096) -> String? {
        guard let value = params[key] as? String, !value.isEmpty,
              value.count <= maxLength else { return nil }
        return value
    }

    /// Optionaler kurzer Bezeichner (Sprachcode o. Ä.): nur Buchstaben, Ziffern,
    /// `-`, `_`, `*`, `.`. Alles andere → `nil`, damit kein Fremdinhalt in
    /// Server-Requests wandert.
    func optToken(_ params: [String: Any], _ key: String, maxLength: Int = 32) -> String? {
        guard let raw = optString(params, key, maxLength: maxLength) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_*."))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    // MARK: - Seiten-IDs

    /// Pflicht-Seiten-ID (Default-Key `pageId`). Wirft, wenn sie fehlt oder die
    /// Form nicht stimmt — eine Seiten-ID landet im URL-Pfad des Server-Nachladens,
    /// in UserDefaults-Merkern und im Log.
    func requirePageId(_ params: [String: Any], _ key: String = "pageId") throws -> String {
        guard let raw = params[key] as? String else {
            throw BridgeError.missingParam(key)
        }
        guard let pageId = Self.validatedPageId(raw) else {
            throw BridgeError.invalidParam(key, reason: "keine gültige Seiten-ID")
        }
        return pageId
    }

    /// Optionale Seiten-ID: `nil` bei fehlendem Wert, `null` (NSNull) ODER
    /// ungültiger Form. Für `editorState`/`reportStats`, wo `null` regulär
    /// „keine Seite offen" bedeutet.
    func optPageId(_ params: [String: Any], _ key: String) -> String? {
        guard let raw = params[key] as? String else { return nil }
        return Self.validatedPageId(raw)
    }

    /// Formprüfung einer Seiten-ID: nicht leer, nicht überlang, keine
    /// Steuerzeichen/Whitespace, keine Pfadtrenner oder `..` (Traversal), keine
    /// URL-Sonderzeichen. `nil`, wenn etwas davon zutrifft.
    static func validatedPageId(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= maxPageIdLength else { return nil }
        guard !raw.contains("..") else { return nil }
        let forbidden = CharacterSet(charactersIn: "/\\?#%&: \t\n\r\"'<>")
            .union(.controlCharacters)
            .union(.whitespacesAndNewlines)
        guard raw.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return raw
    }

    // MARK: - Zahlen

    /// Optionale Buch-ID. Akzeptiert JS-Zahlen (kommen als `NSNumber`) und
    /// numerische Strings; verwirft `null`, 0, negative Werte, Brüche und
    /// NaN/Unendlich. 0 ist bewusst „kein Buch" (wie in `LibraryStore`).
    func optBookId(_ params: [String: Any], _ key: String) -> Int? {
        guard let value = Self.finiteDouble(params[key]),
              value >= 1, value <= Double(Int32.max),
              value == value.rounded(.towardZero) else { return nil }
        return Int(value)
    }

    /// Optionaler Zeitstempel (Epoch-ms, `baseUpdatedAt`). Verwirft NaN/Unendlich
    /// und Werte ≤ 0 — eine kaputte Basis würde jeden Konflikt-Vergleich des Syncs
    /// verbiegen (und `WHERE updated_at = ?` nie treffen).
    func optTimestamp(_ params: [String: Any], _ key: String) -> Double? {
        guard let value = Self.finiteDouble(params[key]), value > 0 else { return nil }
        return value
    }

    /// Wort-/Zeichenzahl aus der WebView: NaN/negativ → 0, absurd gross → Deckel.
    static func clampedCount(_ raw: Any?) -> Int {
        guard let value = finiteDouble(raw), value > 0 else { return 0 }
        return Int(min(value, Double(maxStatsCount)))
    }

    /// Rohwert → endlicher `Double` (JS-Zahl als `NSNumber`, Swift-Zahl oder
    /// numerischer String). `nil` für alles andere, insbesondere NaN/±Infinity.
    static func finiteDouble(_ raw: Any?) -> Double? {
        let value: Double?
        switch raw {
        case let n as NSNumber:  value = n.doubleValue
        case let d as Double:    value = d
        case let i as Int:       value = Double(i)
        case let s as String:    value = Double(s)
        default:                 value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    // MARK: - Log

    /// JS-Meldung log-tauglich machen: einzeilig (keine untergeschobenen
    /// „eigenen" Log-Einträge) und auf `maxLogMessageLength` gekürzt.
    static func sanitizedLogMessage(_ raw: Any?) -> String {
        let text = (raw as? String) ?? (raw.map { String(describing: $0) } ?? "")
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "⏎")
        guard flat.count > maxLogMessageLength else { return flat }
        return String(flat.prefix(maxLogMessageLength)) + "… (gekürzt)"
    }

    // MARK: - Ausgang

    /// StoredPage → JSON-serialisierbares Dictionary (nur NSJSON-konforme Typen).
    static func encode(_ page: StoredPage) -> [String: Any] {
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
