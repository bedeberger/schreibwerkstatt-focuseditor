//
//  LocalStore.swift
//  schreibwerkstatt-focuseditor
//
//  Lokaler Spiegel der Seiten — das Fundament des Offline-Kerns.
//  Jeder Save geht ZUERST hierher (local-first), erst danach in die Outbox
//  und bei Konnektivität an den Server (siehe Sync/, noch nicht implementiert).
//
//  HINWEIS: Dies ist ein Platzhalter VOR GRDB. Persistenz läuft vorerst über
//  einen JSON-Snapshot im Application-Support-Verzeichnis. Das `LocalStore`-
//  Protokoll ist die Kopplungsschicht — die GRDB/SQLite-Implementierung (laut
//  CLAUDE.md) ersetzt später `InMemoryLocalStore`, ohne dass Bridge oder Shell
//  angefasst werden müssen.
//

import Foundation

/// Eine Seite im lokalen Spiegel. `updatedAt` ist ein Epoch-Millis-Zeitstempel
/// (Double) — passt 1:1 zu `Date.now()` in der WebView und zur Sync-Basis.
nonisolated struct StoredPage: Codable, Equatable, Identifiable {
    var id: String
    var html: String
    /// Aus dem HTML abgeleiteter Anzeige-Fallback (erste Textzeile).
    var title: String?
    /// Server-seitiger Seitenname (autoritativ für die Anzeige im Picker).
    var pageName: String?
    /// Zugehöriges Buch — steuert Filterung im Picker und den buch-skopierten Pull.
    var bookId: Int?
    /// Zugehöriges Kapitel (für Gruppierung im Picker). Optional.
    var chapterId: Int?
    /// Letzte lokale Änderung (Epoch ms).
    var updatedAt: Double
    /// Server-Basis für den nächsten Push (`expected_updated_at`). `nil`, solange
    /// die Seite noch nie synchronisiert wurde. Wird beim Pull/erfolgreichen Push
    /// auf den Server-Stand gesetzt.
    var baseUpdatedAt: Double?
}

/// Eintrag der Schreib-Queue. Jeder lokale Save erzeugt (oder aktualisiert) einen
/// Outbox-Eintrag; die SyncEngine arbeitet ihn bei Konnektivität ab.
nonisolated struct OutboxEntry: Codable, Equatable {
    var pageId: String
    var html: String
    /// Server-Basis, gegen die gepusht wird (`expected_updated_at`).
    var baseUpdatedAt: Double?
    /// Wann der Eintrag lokal angelegt wurde (Epoch ms).
    var queuedAt: Double
}

/// Kopplungsschicht zum lokalen Speicher. Bridge und Shell sprechen nur dieses
/// Protokoll — die konkrete Engine (vorerst In-Memory/JSON, später GRDB) ist
/// austauschbar.
@MainActor
protocol LocalStore: AnyObject {
    /// Liefert eine Seite, oder `nil` wenn unbekannt.
    func page(id: String) async throws -> StoredPage?
    /// Seitenliste (ohne HTML-Body — schlanke Übersicht). `bookId == nil`
    /// liefert alle Seiten, sonst nur die des gewählten Buchs (Picker-Filter).
    func list(bookId: Int?) async throws -> [PageSummary]
    /// Schreibt eine Seite lokal UND legt einen Outbox-Eintrag an (local-first).
    /// Liefert die gespeicherte Seite mit neuem `updatedAt` zurück.
    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage
    /// Noch nicht gepushte Outbox-Einträge (für die spätere SyncEngine).
    func pendingOutbox() async throws -> [OutboxEntry]

    /// Quittiert einen erfolgreichen Push: setzt die lokale Server-Basis der
    /// Seite auf `serverUpdatedAtMillis` und entfernt den Outbox-Eintrag —
    /// aber nur, wenn er seit `queuedAt` nicht erneut geändert wurde (sonst
    /// liegt eine neuere lokale Änderung vor, die noch gepusht werden muss).
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws

    /// Schreibt eine vom Server gezogene Seite in den Spiegel, OHNE einen
    /// Outbox-Eintrag zu erzeugen (Pull ist keine lokale Änderung). Setzt
    /// `updatedAt` und `baseUpdatedAt` auf den Server-Stand.
    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws

    /// Entfernt eine Seite aus dem Spiegel (serverseitig gelöscht, Delete-Reconcile).
    /// Räumt einen evtl. vorhandenen Outbox-Eintrag mit weg. Der Aufrufer stellt
    /// sicher, dass keine ungepushte/ungespeicherte Änderung verloren geht.
    func deletePage(id: String) async throws

    /// Wechselt den persistenten Spiegel auf den aktuell konfigurierten Server
    /// (Per-Server-Namespace). In-Place: die Objekt-Identität bleibt erhalten,
    /// nur die zugrundeliegende Datei wechselt — bestehende Referenzen (z. B. die
    /// Bridge) bleiben gültig. So pollt der Sync nach einem Server-Wechsel nicht
    /// mehr die Buch-IDs des alten Servers.
    func switchToCurrentServer() async throws
}

/// Titel-Ableitung aus dem HTML — von allen LocalStore-Implementierungen
/// geteilt, damit In-Memory- und GRDB-Spiegel denselben Anzeigenamen erzeugen.
/// `nonisolated`, weil GRDB die Ableitung im DB-Writer-Thread aufruft.
nonisolated enum PageTitle {
    /// Grobe Titel-Ableitung: erste nicht-leere Textzeile des HTML (max. 80 Zeichen).
    static func derive(from html: String) -> String? {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        let firstLine = stripped.split(whereSeparator: \.isNewline).first.map(String.init) ?? stripped
        return String(firstLine.prefix(80))
    }
}

/// Schlanke Listenzeile (kein HTML-Body).
nonisolated struct PageSummary: Codable, Equatable, Identifiable {
    var id: String
    var title: String?
    var pageName: String?
    var bookId: Int?
    var chapterId: Int?
    var updatedAt: Double

    /// Bevorzugter Anzeigename: Server-Seitenname, sonst HTML-Ableitung.
    var displayName: String { pageName ?? title ?? "Ohne Titel" }
}

// MARK: - Platzhalter-Implementierung (In-Memory + JSON-Snapshot)

/// Vorläufige Implementierung bis GRDB integriert ist. Hält alles im Speicher und
/// schreibt nach jeder Mutation einen JSON-Snapshot. Bewusst simpel — definiert
/// das Verhalten, nicht die endgültige Persistenz.
@MainActor
final class InMemoryLocalStore: LocalStore {
    private var pages: [String: StoredPage] = [:]
    private var outbox: [OutboxEntry] = []

    private var snapshotURL: URL

    init() {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.json")
        self.snapshotURL = AppSupport.serverDir().appendingPathComponent("localstore.json")
        loadSnapshot()
    }

    /// Server-Wechsel: in-place auf den Namespace des aktuellen Servers
    /// umschalten (Speicher leeren + Snapshot des neuen Servers laden).
    func switchToCurrentServer() async throws {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.json")
        snapshotURL = AppSupport.serverDir().appendingPathComponent("localstore.json")
        pages = [:]
        outbox = []
        loadSnapshot()
    }

    func page(id: String) async throws -> StoredPage? {
        pages[id]
    }

    func list(bookId: Int?) async throws -> [PageSummary] {
        pages.values
            .filter { bookId == nil || $0.bookId == bookId }
            .map { PageSummary(id: $0.id,
                               title: $0.title,
                               pageName: $0.pageName,
                               bookId: $0.bookId,
                               chapterId: $0.chapterId,
                               updatedAt: $0.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        let now = nowMillis()
        // Basis übernehmen: explizit übergebene Basis gewinnt, sonst bisherige behalten.
        let base = baseUpdatedAt ?? pages[id]?.baseUpdatedAt
        let title = PageTitle.derive(from: html) ?? pages[id]?.title
        // Buch-Zuordnung bleibt erhalten (lokaler Save ändert nur Inhalt).
        let existing = pages[id]
        let page = StoredPage(id: id,
                              html: html,
                              title: title,
                              pageName: existing?.pageName,
                              bookId: existing?.bookId,
                              chapterId: existing?.chapterId,
                              updatedAt: now,
                              baseUpdatedAt: base)
        pages[id] = page

        // Outbox: einen Eintrag pro Seite vorhalten (jüngster Stand gewinnt).
        outbox.removeAll { $0.pageId == id }
        outbox.append(OutboxEntry(pageId: id, html: html, baseUpdatedAt: base, queuedAt: now))

        persistSnapshot()
        return page
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        outbox
    }

    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws {
        // Server-Basis übernehmen (Inhalt/updatedAt bleiben unangetastet).
        if var page = pages[id] {
            page.baseUpdatedAt = serverUpdatedAtMillis
            pages[id] = page
        }
        // Outbox-Eintrag nur entfernen, wenn unverändert seit dem Push.
        if let idx = outbox.firstIndex(where: { $0.pageId == id }),
           outbox[idx].queuedAt == queuedAt {
            outbox.remove(at: idx)
        }
        persistSnapshot()
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        let derived = PageTitle.derive(from: html) ?? pages[id]?.title
        pages[id] = StoredPage(id: id,
                               html: html,
                               title: derived,
                               pageName: pageName ?? pages[id]?.pageName,
                               bookId: bookId ?? pages[id]?.bookId,
                               chapterId: chapterId ?? pages[id]?.chapterId,
                               updatedAt: serverUpdatedAtMillis,
                               baseUpdatedAt: serverUpdatedAtMillis)
        persistSnapshot()
    }

    func deletePage(id: String) async throws {
        pages.removeValue(forKey: id)
        outbox.removeAll { $0.pageId == id }
        persistSnapshot()
    }

    // MARK: Hilfen

    /// Epoch-Millisekunden — gleiche Einheit wie `Date.now()` in der WebView.
    private func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    // MARK: JSON-Snapshot (Platzhalter-Persistenz)

    private struct Snapshot: Codable {
        var pages: [StoredPage]
        var outbox: [OutboxEntry]
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        pages = Dictionary(uniqueKeysWithValues: snap.pages.map { ($0.id, $0) })
        outbox = snap.outbox
    }

    private func persistSnapshot() {
        let snap = Snapshot(pages: Array(pages.values), outbox: outbox)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }
}
