//
//  EditorBridge+Recents.swift
//  schreibwerkstatt-focuseditor
//
//  Gerätelokale Merker rund um die offene Seite — alle in UserDefaults und alle
//  PRO SERVER-NAMESPACE (eine Seiten-ID gilt nur am Server, der sie vergeben hat;
//  sonst öffnete der Client am neuen Server eine Seite des alten):
//
//   • zuletzt geöffnete Seite pro Buch  → Boot-Restore ohne Buch-Verwechslung
//   • zuletzt geöffnete Seite global    → Legacy-Fallback
//   • MRU-Historie pro Buch             → Gruppe „Zuletzt geöffnet" im Seiten-Picker
//   • aktives Buch (von `LibraryStore` geschrieben, hier nur gelesen)
//
//  Aus `EditorBridge.swift` ausgelagert (eine Datei = eine Verantwortung).
//  Härtung: gelesene Werte werden gegen die erwartete Form geprüft (die Defaults
//  können von einer älteren Version, einem Absturz oder von Hand stammen) und
//  geschriebene IDs vorher validiert — Müll darf nicht in den Boot-Restore geraten.
//

import Foundation

extension EditorBridge {

    // MARK: - Zuletzt geöffnete Seite

    /// Zuletzt geöffnete Seite — global pro Server-Namespace. Legacy/Fallback:
    /// der buch-skopierte Restore läuft über `lastOpenByBookKey`.
    static var lastOpenPageKey: String { ServerScopedKey.lastOpenPageId.key() }

    /// Zuletzt geöffnete Seite PRO Buch — Wert ist ein `[String(bookId): String(pageId)]`-
    /// Dict. Der Boot-Restore (`lastOpenPage(bookId)`) liest hier, damit nie eine
    /// Seite eines anderen Buchs geöffnet wird (der globale Key oben gilt server-,
    /// nicht buchweit und wurde bei jedem Seitenwechsel über alle Bücher überschrieben).
    static var lastOpenByBookKey: String { ServerScopedKey.lastOpenByBook.key() }

    /// Zuletzt geöffnete Seite des Buchs (gerätelokal), oder `nil`.
    static func lastOpenPageId(forBook bookId: Int,
                              defaults: UserDefaults = .standard) -> String? {
        let map = defaults.dictionary(forKey: lastOpenByBookKey) as? [String: String]
        guard let raw = map?[String(bookId)] else { return nil }
        return validatedPageId(raw)
    }

    /// Zuletzt geöffnete Seite des Buchs merken (gerätelokal).
    static func setLastOpenPageId(_ pageId: String, forBook bookId: Int,
                                  defaults: UserDefaults = .standard) {
        guard let pageId = validatedPageId(pageId) else { return }
        var map = (defaults.dictionary(forKey: lastOpenByBookKey) as? [String: String]) ?? [:]
        map[String(bookId)] = pageId
        defaults.set(map, forKey: lastOpenByBookKey)
    }

    // MARK: - MRU-Historie (Gruppe „Zuletzt geöffnet" im Picker)

    /// HISTORIE der zuletzt geöffneten Seiten pro Buch — Wert ein
    /// `[String(bookId): [String(pageId)]]`-Dict in MRU-Reihenfolge (Index 0 =
    /// zuletzt geöffnet). Bewusst GETRENNT von `lastOpenByBookKey`: der Ein-Wert-Key
    /// treibt den Boot-Restore und soll seine Bedeutung behalten.
    static var recentPagesByBookKey: String { ServerScopedKey.recentPagesByBook.key() }

    /// Länge der Historie pro Buch = Grösse der Picker-Gruppe.
    /// `nonisolated`, damit der Wert als Default-Argument (LibraryStore) auch aus
    /// nonisolated Kontext lesbar ist — eine Konstante braucht keine Isolation.
    nonisolated static let recentPagesLimit = 5

    /// Zuletzt geöffnete Seiten des Buchs (gerätelokal, MRU; Index 0 = zuletzt).
    /// `defaults` ist injizierbar (Tests); produktiv immer `.standard`.
    /// Härtung: nur formal gültige IDs, dedupliziert, auf `recentPagesLimit`
    /// gekürzt — ein von Hand/älterer Version verbogener Eintrag kann den Picker
    /// nicht mit Müll oder Dubletten füllen.
    static func recentPageIds(forBook bookId: Int, defaults: UserDefaults = .standard) -> [String] {
        let map = defaults.dictionary(forKey: recentPagesByBookKey) as? [String: [String]]
        guard let raw = map?[String(bookId)] else { return [] }
        var seen: Set<String> = []
        return raw.compactMap { validatedPageId($0) }
            .filter { seen.insert($0).inserted }
            .prefix(recentPagesLimit)
            .map { $0 }
    }

    /// Seite an die Spitze der Historie setzen (MRU, dedupliziert, auf
    /// `recentPagesLimit` gekürzt). No-op, wenn sie schon vorne steht — `editorState`
    /// feuert bei jedem Dirty-Wechsel, ein Defaults-Schreiben pro Tastendruck wäre
    /// pure Verschwendung.
    static func pushRecentPageId(_ pageId: String, forBook bookId: Int,
                                 defaults: UserDefaults = .standard) {
        guard let pageId = validatedPageId(pageId) else { return }
        var map = (defaults.dictionary(forKey: recentPagesByBookKey) as? [String: [String]]) ?? [:]
        var list = map[String(bookId)] ?? []
        guard list.first != pageId else { return }
        list.removeAll { $0 == pageId }
        list.insert(pageId, at: 0)
        map[String(bookId)] = Array(list.prefix(recentPagesLimit))
        defaults.set(map, forKey: recentPagesByBookKey)
    }

    // MARK: - Aktives Buch (Lese-Seite)

    /// UserDefaults-Key des in der Toolbar gewählten Buchs. Die Bridge liest ihn
    /// beim Boot, um die initiale Seitenauswahl auf dieses Buch zu beschränken
    /// (sonst lüde der Client eine global gemerkte Seite aus einem anderen Buch).
    /// Dasselbe Prefix schreibt `LibraryStore` — beide über `ServerScopedKey`.
    static var activeBookKey: String { ServerScopedKey.activeBookId.key() }

    /// Aktives Buch oder `nil` (0/negativ = keins). Von der `activeBook`-Op und
    /// der Anführungszeichen-Normalisierung genutzt.
    static var activeBookId: Int? {
        let raw = UserDefaults.standard.integer(forKey: activeBookKey)
        return raw > 0 ? raw : nil
    }
}
