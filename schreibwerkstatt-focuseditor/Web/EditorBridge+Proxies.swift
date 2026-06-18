//
//  EditorBridge+Proxies.swift
//  schreibwerkstatt-focuseditor
//
//  Server-Proxy-Schicht der Bridge: LanguageTool-Rechtschreibung, Wörterbuch
//  und Synonyme. Bewusst aus `EditorBridge.swift` ausgelagert (eigene Datei pro
//  Verantwortung + hält die Haupt-Bridge unter dem Zeilen-Limit, Vorbild
//  `SyncEngine[+Push/+Pull]`). Aufgerufen vom zentralen `route(op:params:)` in
//  `EditorBridge.swift`.
//
//  HARTE REGEL: Netzwerk macht ausschliesslich der Swift-Kern — kein direkter
//  `fetch` aus der WebView. Alle Settings (LT-URL/Picky/Regeln, KI-Provider,
//  Buch-Locale) liegen serverseitig; der Client liefert nur Text/Wort + Kontext.
//

import Foundation

extension EditorBridge {

    // MARK: LanguageTool-Proxy
    //
    // Alle LT-Settings (enabled/url/picky/rules) liegen serverseitig in
    // app_settings und werden vom `/languagetool/check`-Proxy angewandt; der
    // Client kennt sie nicht.

    /// Liefert die LanguageTool-Konfiguration aus `/config`. Bei Netz-/Auth-
    /// Fehler den letzten gecachten Stand, sonst „deaktiviert" (degradiert
    /// still — Spellcheck ist online-only und kein Offline-Kern-Inhalt).
    func spellcheckConfig() async -> [String: Any] {
        // Lokaler Override: auch bei serverseitig aktivem LT kann der Nutzer die
        // Prüfung pro Gerät abschalten (greift beim nächsten Editor-Boot; ein
        // Live-Aus wirkt zusätzlich über `languagetoolCheck`).
        let localOn = SpellcheckPrefs.localEnabled
        let i18n = Self.spellcheckI18n()
        guard let api else { return ["enabled": false, "debounceMs": 1500, "i18n": i18n] }
        do {
            let cfg = try await api.send("/config", decode: ConfigDTO.self)
            let serverEnabled = cfg.languagetool?.enabled ?? false
            let debounce = cfg.languagetool?.debounceMs ?? 1500
            ltConfig = (serverEnabled, debounce)
            return ["enabled": serverEnabled && localOn, "debounceMs": debounce, "i18n": i18n]
        } catch {
            if let cached = ltConfig {
                return ["enabled": cached.enabled && localOn, "debounceMs": cached.debounceMs, "i18n": i18n]
            }
            return ["enabled": false, "debounceMs": 1500, "i18n": i18n]
        }
    }

    /// Lokalisierte Popover-/Status-Strings für den Spellcheck-Controller.
    /// Schlüssel = die i18n-Keys, die der unveränderte Controller (Hauptrepo)
    /// anfragt; Werte aus den gebündelten Katalogen via `t()` (de/en). Über die
    /// Bridge geliefert statt ins gecachte `index.html` gebacken → ein lokaler
    /// Sprachwechsel greift sofort, nicht erst beim nächsten Bundle-Refresh.
    private static func spellcheckI18n() -> [String: String] {
        [
            "spellcheck.popover.ignore": t("spell.popover.ignore"),
            "spellcheck.popover.add_to_dict": t("spell.popover.addToDict"),
            "spellcheck.popover.no_suggestions": t("spell.popover.noSuggestions"),
            "spellcheck.popover.rule_info": t("spell.popover.ruleInfo"),
            "spellcheck.status.active": t("spell.status.active"),
            "spellcheck.status.disabled": t("spell.status.disabled"),
            "spellcheck.status.error": t("spell.status.error"),
            "spellcheck.status.matches": t("spell.status.matches"),
            "spellcheck.status.no_matches": t("spell.status.noMatches"),
            "spellcheck.extension_conflict.title": t("spell.extensionConflict.title"),
        ]
    }

    /// Liest die serverseitige Fokus-Granularität aus `/config`
    /// (`userSettings.focus_granularity`, die Web-Einstellung des Users). Dient
    /// dem `FocusController` als Initial-Default, solange keine lokale Wahl
    /// vorliegt. `nil` bei Netz-/Auth-Fehler oder fehlendem User-Kontext.
    func serverFocusGranularity() async -> String? {
        guard let api else { return nil }
        let cfg = try? await api.send("/config", decode: ConfigDTO.self)
        return cfg?.userSettings?.focus_granularity
    }

    /// Liest die serverseitige UI-Sprache aus `/config`
    /// (`userSettings.locale`, die Web-Profil-Einstellung des Users — Werte
    /// `de`/`en`). Dient dem `LocalizationController` als Initial-Default,
    /// solange keine lokale Wahl vorliegt. `nil` bei Netz-/Auth-Fehler oder
    /// fehlendem User-Kontext.
    func serverLocale() async -> String? {
        guard let api else { return nil }
        let cfg = try? await api.send("/config", decode: ConfigDTO.self)
        return cfg?.userSettings?.locale
    }

    /// Proxyt den Prüf-Request an `POST /languagetool/check`. `404` (LT
    /// serverseitig aus) wird als `{ disabled: true }` zurückgegeben — kein
    /// Fehler. Die `matches` werden als roher JSON-Baum durchgereicht
    /// (NSJSON-konform → direkt als Bridge-Reply nutzbar).
    func languagetoolCheck(text: String, language: String,
                           pageId: String?, bookId: Int?) async throws -> [String: Any] {
        guard let api else { return ["disabled": true] }
        // Lokaler Aus-Schalter wirkt sofort (auch mitten in der Sitzung): keine
        // neuen Treffer mehr, bestehende Markierungen verschwinden beim nächsten
        // Prüf-Zyklus des Controllers.
        guard SpellcheckPrefs.localEnabled else { return ["disabled": true] }
        // Lokaler Sprach-Override: gewinnt über das vom Controller gelieferte
        // „auto" (sonst löst der Server die Locale via bookId auf → de-CH).
        let effectiveLanguage = SpellcheckPrefs.languageOverride ?? language
        let req = LTCheckRequest(text: text, language: effectiveLanguage, bookId: bookId, pageId: pageId)
        let (status, data) = try await api.postExpectingJSON("/languagetool/check", body: req)
        if status == 404 { return ["disabled": true] }   // Feature serverseitig aus
        guard (200...299).contains(status) else {
            throw BridgeError.languagetool(status: status)
        }
        let obj = try? JSONSerialization.jsonObject(with: data)
        let matches = (obj as? [String: Any])?["matches"] as? [Any] ?? []
        return ["matches": matches]
    }

    /// Fügt ein Wort dem serverseitigen User-Wörterbuch hinzu (`POST /dictionary`).
    func dictionaryAdd(word: String, lang: String, bookId: Int) async throws -> [String: Any] {
        guard let api else { return ["ok": false] }
        let req = DictionaryAddRequest(word: word, bookId: bookId, lang: lang)
        let (status, _) = try await api.postExpectingJSON("/dictionary", body: req)
        return ["ok": (200...299).contains(status)]
    }

    // MARK: Synonyme-Proxy
    //
    // Zwei Quellen wie im Web-Editor: OpenThesaurus (synchron, nur Deutsch) und
    // KI (asynchroner Job über die bestehende Job-Queue). Anders als im Web pollt
    // hier der Swift-Kern den Job fertig, sodass die Bridge-Op EIN awaitbares
    // Ergebnis liefert (der Controller bekommt die fertige Liste, statt selbst zu
    // pollen). Online-only; offline/Fehler degradieren still.

    /// Lokale Synonym-Konfiguration + lokalisierte UI-Strings für den Controller.
    /// `enabled` ist rein lokal (kein Server-Schalter nötig — beide Endpoints
    /// existieren immer). Strings kommen über die Bridge (nicht ins gecachte
    /// `index.html` gebacken), damit ein lokaler Sprachwechsel sofort greift.
    func synonymConfig() -> [String: Any] {
        ["enabled": SynonymPrefs.localEnabled, "i18n": Self.synonymI18n()]
    }

    /// Lokalisierte UI-Strings für den Synonym-Controller (Menü/Picker). Schlüssel
    /// = die i18n-Keys, die der gebündelte Controller (Hauptrepo) anfragt; Werte
    /// aus den gebündelten Katalogen via `t()` (de/en).
    private static func synonymI18n() -> [String: String] {
        [
            "synonym.menu.searchFor": t("synonym.menu.searchFor"),
            "synonym.picker.titleFor": t("synonym.picker.titleFor"),
            "synonym.thesaurus": t("synonym.thesaurus"),
            "synonym.ki": t("synonym.ki"),
            "synonym.loading": t("synonym.loading"),
            "synonym.kiLoading": t("synonym.kiLoading"),
            "synonym.noMatches": t("synonym.noMatches"),
            "synonym.noneFound": t("synonym.noneFound"),
            "synonym.error": t("synonym.error"),
            "synonym.close": t("synonym.close"),
        ]
    }

    /// OpenThesaurus-Synonyme (`GET /openthesaurus/synonyms`). Nur Deutsch —
    /// serverseitig über die Buch-Locale aufgelöst; Nicht-Deutsch liefert der
    /// Server `{ disabled: true }`. Lokaler Aus-Schalter greift ebenfalls.
    func synonymsThesaurus(word: String, bookId: Int?) async throws -> [String: Any] {
        guard let api, SynonymPrefs.localEnabled else { return ["disabled": true] }
        // Wort kommt aus der (nicht vertrauenswürdigen) WebView → für den Query
        // kodieren, sonst verbögen `&`/`#`/Leerzeichen die URL.
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        var path = "/openthesaurus/synonyms?word=\(encoded)"
        if let bookId { path += "&book_id=\(bookId)" }
        let resp = try await api.send(path, decode: SynonymListResponse.self)
        if resp.disabled == true { return ["disabled": true] }
        let list = (resp.synonyme ?? []).map { ["wort": $0.wort, "hinweis": $0.hinweis ?? ""] }
        return ["synonyme": list, "disabled": false]
    }

    /// KI-Synonyme über die bestehende Job-Queue: `POST /jobs/synonym` legt den
    /// Job an, danach wird `GET /jobs/:id` gepollt, bis er terminal ist. Liefert
    /// die fertige Liste oder `{ error }` (i18n-Key des Controllers). Im Web pollt
    /// der Controller selbst; hier kapselt es der Swift-Kern (EIN awaitbares
    /// Ergebnis). Deckel ~25 s — KI-Synonyme sind kurz, Cache-Hit kommt sofort.
    func synonymsAi(wort: String, satz: String, bookId: Int?, pageId: String?) async throws -> [String: Any] {
        guard let api, SynonymPrefs.localEnabled else { return ["disabled": true] }
        let req = SynonymJobRequest(wort: wort, satz: satz, book_id: bookId, page_id: pageId)
        let created = try await api.send("/jobs/synonym", method: .POST, body: req,
                                         decode: JobCreateResponse.self)
        guard let jobId = created.jobId else { return ["error": created.error ?? "synonym.kiFailed"] }
        let encodedJob = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(500))
            // 404 (Job weg) / transienter Lesefehler → werfen; einmal überspringen
            // und weiter pollen, bis der Deckel greift (= jobUnavailable).
            guard let job = try? await api.send("/jobs/\(encodedJob)", decode: JobStatusResponse.self) else {
                continue
            }
            switch job.status {
            case "running", "queued", .none:
                continue
            case "done":
                let list = (job.result?.synonyme ?? []).map { ["wort": $0.wort, "hinweis": $0.hinweis ?? ""] }
                return ["synonyme": list]
            default:   // error / cancelled
                return ["error": job.error ?? "synonym.kiFailed"]
            }
        }
        return ["error": "synonym.jobUnavailable"]
    }
}

// MARK: - Spellcheck-DTOs

/// Antwort-Ausschnitt von `GET /config` — nur der LanguageTool-Block.
private struct ConfigDTO: Decodable {
    struct LanguageTool: Decodable {
        let enabled: Bool?
        let debounceMs: Int?
    }
    struct UserSettings: Decodable {
        let focus_granularity: String?
        let locale: String?
    }
    let languagetool: LanguageTool?
    /// Pro-User-Einstellungen (nur mit aufgelöstem User, also auch per
    /// Device-Token — der Guard setzt `req.session.user`). `nil` ohne User.
    let userSettings: UserSettings?
}

/// Body für `POST /languagetool/check` (Server-Vertrag, siehe
/// routes/languagetool.js). `bookId`/`pageId` treiben serverseitiges Caching
/// + Wörterbuch-Filter; beide optional.
private struct LTCheckRequest: Encodable {
    let text: String
    let language: String
    let bookId: Int?
    let pageId: String?
}

/// Body für `POST /dictionary` (Wort ins User-Wörterbuch). `bookId: 0` =
/// global (alle Bücher), `lang: "*"` = alle Sprachen.
private struct DictionaryAddRequest: Encodable {
    let word: String
    let bookId: Int
    let lang: String
}

// MARK: - Synonyme-DTOs

/// Ein einzelner Synonym-Vorschlag (geteilt von OpenThesaurus + KI-Job).
private struct SynonymEntry: Decodable {
    let wort: String
    let hinweis: String?
}

/// Antwort von `GET /openthesaurus/synonyms` (siehe routes/proxies.js).
/// `disabled` = serverseitig aus (Nicht-Deutsch); `lemma` ungenutzt.
private struct SynonymListResponse: Decodable {
    let synonyme: [SynonymEntry]?
    let disabled: Bool?
    let lemma: String?
}

/// Body für `POST /jobs/synonym` (KI-Synonyme über die Job-Queue). `book_id`/
/// `page_id` treiben serverseitig Zugriffsprüfung, Locale und Cache-Key.
private struct SynonymJobRequest: Encodable {
    let wort: String
    let satz: String
    let book_id: Int?
    let page_id: String?
}

/// Antwort von `POST /jobs/synonym` — die Job-ID (oder ein Fehler).
private struct JobCreateResponse: Decodable {
    let jobId: String?
    let error: String?
}

/// Antwort von `GET /jobs/:id` — Status + (bei `done`) das Synonym-Ergebnis.
/// Status: `queued`/`running` (weiterpollen) bzw. `done`/`error`/`cancelled`.
private struct JobStatusResponse: Decodable {
    struct Result: Decodable {
        let synonyme: [SynonymEntry]?
    }
    let status: String?
    let result: Result?
    let error: String?
}

// MARK: - Lokale Rechtschreib-Vorlieben (UserDefaults)

/// Gerätelokale Overrides der Rechtschreibprüfung. Die eigentlichen LT-Settings
/// (Server-URL, Picky, Regeln) liegen serverseitig — hier nur, was der Client
/// pro Gerät übersteuern darf: an/aus und die Sprache. Picky/Regeln bleiben
/// bewusst serverseitig (Client kann sie nicht setzen).
enum SpellcheckPrefs {
    static let enabledKey = "spellcheck.localEnabled"
    static let languageKey = "spellcheck.languageOverride"

    /// Lokal aktiviert? Default an (folgt dann dem Server-Schalter).
    static var localEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    /// Sprach-Override oder `nil` für „auto" (Server löst via bookId auf).
    static var languageOverride: String? {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        return raw == "auto" ? nil : raw
    }
}

// MARK: - Lokale Synonym-Vorlieben (UserDefaults)

/// Gerätelokaler Aus-Schalter für die Synonym-Hilfe (Cmd+Shift+S). Beide Quellen
/// (OpenThesaurus + KI) sind online-only und liegen serverseitig — hier nur das
/// gerätelokale An/Aus. Default an.
enum SynonymPrefs {
    static let enabledKey = "synonym.localEnabled"

    /// Lokal aktiviert? Default an.
    static var localEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }
}

// MARK: - Editor-Verhalten (UserDefaults)

/// Gerätelokales Editor-Verhalten, das der Boot-Glue beim Mount durchreicht.
/// Aktuell nur das Auto-Save-Debounce (`mountStandaloneFocus({ autosaveMs })`).
enum EditorBehaviorPrefs {
    static let autosaveKey = "editor.autosaveMs"
    /// Erlaubter Bereich des Auto-Save-Debounce (auch in der Settings-UI genutzt).
    static let autosaveRange: ClosedRange<Double> = 500...5000

    /// Auto-Save-Verzögerung in ms. Default 1500 (= Editor-Default), in die
    /// erlaubte Spanne geklemmt.
    static var autosaveMs: Int {
        guard UserDefaults.standard.object(forKey: autosaveKey) != nil else { return 1500 }
        let v = UserDefaults.standard.double(forKey: autosaveKey)
        let clamped = min(max(v, autosaveRange.lowerBound), autosaveRange.upperBound)
        return Int(clamped.rounded())
    }
}

/// Auswahl für den Sprach-Override in den Einstellungen. RawValue = der
/// LanguageTool-Sprachcode (bzw. „auto" für die serverseitige Auflösung).
enum SpellcheckLanguage: String, CaseIterable, Identifiable {
    case auto
    case deCH = "de-CH"
    case deDE = "de-DE"
    case frCH = "fr-CH"
    case fr
    case it
    case enGB = "en-GB"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return t("spell.lang.auto")
        case .deCH: return t("spell.lang.deCH")
        case .deDE: return t("spell.lang.deDE")
        case .frCH: return t("spell.lang.frCH")
        case .fr:   return t("spell.lang.fr")
        case .it:   return t("spell.lang.it")
        case .enGB: return t("spell.lang.enGB")
        }
    }
}
