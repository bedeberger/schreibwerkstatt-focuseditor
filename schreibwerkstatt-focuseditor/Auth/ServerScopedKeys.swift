//
//  ServerScopedKeys.swift
//  schreibwerkstatt-focuseditor
//
//  Die UserDefaults-Schlüssel, die zu GENAU EINEM Server gehören — Buchauswahl,
//  zuletzt geöffnete Seiten, Schreibzeit-Puffer. Sie tragen per Konvention den
//  Namespace-Slug als Suffix (`<prefix>.<slug>`, s. [ServerNamespace](ServerNamespace.swift)),
//  weil eine Buch-/Seiten-ID nur am Server gilt, der sie vergeben hat.
//
//  Warum als Aufzählung statt als Literal an der Verwendungsstelle: der Key
//  `library.activeBookId.<slug>` stand an ZWEI Stellen im Code (LibraryStore und
//  EditorBridge+Recents), beide mit einem Kommentar, der die jeweils andere zur
//  „einzigen Quelle" erklärte. Eine Prefix-Änderung hätte still nur die Hälfte
//  erwischt: die Bridge hätte das Buch des Nutzers nicht mehr gefunden und beim
//  Start eine Seite aus einem fremden Buch geöffnet.
//
//  `LocalDataPurge` löscht nach wie vor suffix-basiert (jeder Key mit `.<slug>`),
//  nutzt aber `legacyKeys` für die Alt-Schlüssel von vor dem Namespacing.
//

import Foundation

/// Ein server-skopierter Defaults-Schlüssel. `rawValue` ist das Prefix OHNE Slug —
/// und zugleich der Alt-Schlüssel aus der Zeit vor dem Namespacing.
enum ServerScopedKey: String, CaseIterable {
    /// In der Toolbar gewähltes Buch (`Int`).
    case activeBookId = "library.activeBookId"
    /// Zuletzt geöffnete Seite, server-global (`String`). Legacy-Pfad des
    /// Boot-Restores; der buch-skopierte Weg läuft über `lastOpenByBook`.
    case lastOpenPageId = "editor.lastOpenPageId"
    /// Zuletzt geöffnete Seite PRO Buch (`[bookId: pageId]`).
    case lastOpenByBook = "editor.lastOpenByBook"
    /// MRU-Historie der zuletzt geöffneten Seiten pro Buch (`[bookId: [pageId]]`).
    case recentPagesByBook = "editor.recentPagesByBook"
    /// Noch nicht gemeldete Schreibzeit je Buch (`[bookId: seconds]`).
    case writingTimePending = "writingtime.pending"
    /// Heute bereits gemeldete Schreibzeit je Buch (`[bookId: seconds]`).
    case writingTimeToday = "writingtime.today"

    /// Der Schlüssel im Namespace eines Servers. Ohne Argument der aktuelle —
    /// `slug` ist nur dort explizit, wo ein anderer Server gemeint sein kann
    /// (Schreibzeit-Puffer, der seinen Slug über einen Wechsel hinweg festhält).
    func key(slug: String = ServerNamespace.currentSlug) -> String {
        "\(rawValue).\(slug)"
    }

    /// Alt-Schlüssel von vor dem Namespacing (global, ohne Slug). Werden einmalig
    /// migriert bzw. beim Purge mitgelöscht.
    static var legacyKeys: [String] { allCases.map(\.rawValue) }
}
