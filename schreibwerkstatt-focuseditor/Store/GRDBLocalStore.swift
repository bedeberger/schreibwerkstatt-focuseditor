//
//  GRDBLocalStore.swift
//  schreibwerkstatt-focuseditor
//
//  GRDB/SQLite-Implementierung des `LocalStore` (CLAUDE.md Roadmap 4) — ersetzt
//  den `InMemoryLocalStore`-Platzhalter als app-weiter, persistenter Spiegel.
//  Verhalten ist bewusst 1:1 zum Platzhalter (gleiche Outbox-/Basis-Semantik),
//  nur die Persistenz wechselt von JSON-Snapshot auf eine echte DB.
//
//  DB-I/O läuft über die async-APIs der `DatabaseQueue` (eigener Writer-Thread);
//  die @MainActor-Methoden suspendieren nur und blockieren den Main-Thread nicht.
//

import Foundation
import GRDB

@MainActor
final class GRDBLocalStore: LocalStore {
    /// `var`, weil ein Server-Wechsel die zugrundeliegende DB in-place tauscht
    /// (Objekt-Identität bleibt erhalten → die Bridge-Referenz bleibt gültig).
    private var dbQueue: DatabaseQueue
    /// Fester Pfad-Override (Tests). `nil` → Per-Server-Standardort.
    private let fixedURL: URL?

    /// Öffnet (oder legt an) die SQLite-Datei und führt die Migrationen aus.
    /// `url == nil` → Per-Server-Standardort im Application-Support-Verzeichnis.
    init(url: URL? = nil) throws {
        self.fixedURL = url
        let dbURL = try url ?? Self.defaultURL()
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Wechselt den Spiegel auf den aktuell konfigurierten Server (Per-Server-
    /// Namespace). In-Place: die alte `DatabaseQueue` wird ersetzt (und beim
    /// Freigeben geschlossen), die Objekt-Identität bleibt erhalten. Bei festem
    /// Pfad-Override (Tests) ein No-op.
    func switchToCurrentServer() async throws {
        guard fixedURL == nil else { return }
        let dbURL = try Self.defaultURL()
        let newQueue = try DatabaseQueue(path: dbURL.path)
        try Self.migrator.migrate(newQueue)
        dbQueue = newQueue
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_pages_outbox") { db in
            // Spiegel der Seiten. Spaltennamen == StoredPage-Properties
            // (GRDB-Codable-Record mappt direkt darauf).
            try db.create(table: "page") { t in
                t.primaryKey("id", .text)
                t.column("html", .text).notNull().defaults(to: "")
                t.column("title", .text)
                t.column("pageName", .text)
                t.column("bookId", .integer)
                t.column("chapterId", .integer)
                t.column("updatedAt", .double).notNull().defaults(to: 0)
                t.column("baseUpdatedAt", .double)
            }
            // Schreib-Queue: genau ein Eintrag pro Seite (jüngster Stand gewinnt)
            // → pageId ist Primärschlüssel.
            try db.create(table: "outbox") { t in
                t.primaryKey("pageId", .text)
                t.column("html", .text).notNull().defaults(to: "")
                t.column("baseUpdatedAt", .double)
                t.column("queuedAt", .double).notNull().defaults(to: 0)
            }
            // Picker-Filter + Pull sind buch-skopiert.
            try db.create(index: "page_on_bookId", on: "page", columns: ["bookId"])
        }
        m.registerMigration("v2_outbox_queuedAt_index") { db in
            // `pendingOutbox()` liest die Queue in `queuedAt`-Reihenfolge (FIFO-Push).
            // Ohne Index ist das ein Full-Table-Scan + Sortierung — bei normalerweise
            // winziger Outbox unkritisch, aber bei einem grossen Offline-Rückstau
            // (lange offline, viele Seiten editiert) würde der Read den Push-Tick
            // bremsen. Index hält die geordnete Lese-Operation auch dann flott.
            try db.create(index: "outbox_on_queuedAt", on: "outbox", columns: ["queuedAt"])
        }
        return m
    }

    // MARK: - Lesen

    func page(id: String) async throws -> StoredPage? {
        try await dbQueue.read { db in
            try StoredPage.fetchOne(db, key: id)
        }
    }

    func list(bookId: Int?) async throws -> [PageSummary] {
        // Schlanke Übersicht ohne HTML-Body → nur die Picker-Spalten selektieren.
        let columns = "id, title, pageName, bookId, chapterId, updatedAt"
        return try await dbQueue.read { db in
            if let bookId {
                return try PageSummary.fetchAll(
                    db,
                    sql: "SELECT \(columns) FROM page WHERE bookId = ? ORDER BY updatedAt DESC",
                    arguments: [bookId])
            }
            return try PageSummary.fetchAll(
                db,
                sql: "SELECT \(columns) FROM page ORDER BY updatedAt DESC")
        }
    }

    func pendingOutbox() async throws -> [OutboxEntry] {
        try await dbQueue.read { db in
            try OutboxEntry
                .order(Column("queuedAt").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Schreiben (local-first)

    func save(id: String, html: String, baseUpdatedAt: Double?) async throws -> StoredPage {
        let now = Self.nowMillis()
        return try await dbQueue.write { db in
            let existing = try StoredPage.fetchOne(db, key: id)
            // No-op-Guard: ist das HTML byte-identisch zum bereits gespeicherten Stand,
            // erzeugt der Save KEINEN Outbox-Eintrag (und bumpt updatedAt nicht). Der
            // Editor-Autosave feuert entprellt auch ohne echte Inhaltsänderung (Timer,
            // Fokuswechsel, Cursor-Bewegung) — ohne diesen Guard ginge dafür jedes Mal
            // ein redundanter Push raus (Server bumpt updated_at → Pull echot zurück).
            // Liegt bereits ein ungepushter Eintrag vor, trägt er per Upsert dasselbe
            // HTML, ist also ebenfalls unberührt. (Datenverlust-Schutz: wir verwerfen
            // nichts, wir überspringen nur einen inhaltsgleichen Schreibvorgang.)
            if let existing, existing.html == html { return existing }
            // Basis übernehmen: explizit übergebene Basis gewinnt, sonst bisherige behalten.
            let base = baseUpdatedAt ?? existing?.baseUpdatedAt
            let title = PageTitle.derive(from: html) ?? existing?.title
            // Buch-/Kapitel-Zuordnung bleibt erhalten (lokaler Save ändert nur Inhalt).
            let page = StoredPage(id: id,
                                  html: html,
                                  title: title,
                                  pageName: existing?.pageName,
                                  bookId: existing?.bookId,
                                  chapterId: existing?.chapterId,
                                  updatedAt: now,
                                  baseUpdatedAt: base)
            try page.save(db)

            // Outbox: einen Eintrag pro Seite (save = upsert auf pageId).
            let entry = OutboxEntry(pageId: id, html: html, baseUpdatedAt: base, queuedAt: now)
            try entry.save(db)
            return page
        }
    }

    @discardableResult
    func markPushed(id: String, queuedAt: Double, serverUpdatedAtMillis: Double) async throws -> Bool {
        try await dbQueue.write { db in
            // Match-Prüfung + Löschen + Basis-Update atomar in EINER Transaktion.
            // Nur quittieren, wenn der Outbox-Eintrag unverändert seit dem Push ist.
            guard let entry = try OutboxEntry.fetchOne(db, key: id), entry.queuedAt == queuedAt else {
                // Inzwischen neuerer Eintrag (oder keiner) → Basis NICHT vorrücken,
                // Eintrag NICHT löschen (s. Protokoll: Datenverlust-Schutz).
                return false
            }
            try entry.delete(db)
            // Server-Basis übernehmen (Inhalt/updatedAt bleiben unangetastet).
            if var page = try StoredPage.fetchOne(db, key: id) {
                page.baseUpdatedAt = serverUpdatedAtMillis
                try page.update(db)
            }
            return true
        }
    }

    func applyServerPage(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws {
        try await dbQueue.write { db in
            try Self.writeServerPage(db, id: id, html: html, pageName: pageName,
                                     bookId: bookId, chapterId: chapterId,
                                     serverUpdatedAtMillis: serverUpdatedAtMillis)
        }
    }

    @discardableResult
    func applyServerPageIfClean(id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) async throws -> Bool {
        try await dbQueue.write { db in
            // Outbox-Check + Write atomar: liegt eine lokal ungepushte Änderung
            // vor, NICHT überschreiben (der Push/409-Merge löst die Divergenz auf).
            if try OutboxEntry.fetchOne(db, key: id) != nil { return false }
            try Self.writeServerPage(db, id: id, html: html, pageName: pageName,
                                     bookId: bookId, chapterId: chapterId,
                                     serverUpdatedAtMillis: serverUpdatedAtMillis)
            return true
        }
    }

    /// Gemeinsamer Server-Stand-Write (Pull erzeugt KEINEN Outbox-Eintrag).
    /// `nonisolated`, weil GRDB die Closure im DB-Writer-Thread ausführt.
    nonisolated private static func writeServerPage(_ db: Database, id: String, html: String, pageName: String?, bookId: Int?, chapterId: Int?, serverUpdatedAtMillis: Double) throws {
        let existing = try StoredPage.fetchOne(db, key: id)
        let derived = PageTitle.derive(from: html) ?? existing?.title
        let page = StoredPage(id: id,
                              html: html,
                              title: derived,
                              pageName: pageName ?? existing?.pageName,
                              bookId: bookId ?? existing?.bookId,
                              chapterId: chapterId ?? existing?.chapterId,
                              updatedAt: serverUpdatedAtMillis,
                              baseUpdatedAt: serverUpdatedAtMillis)
        try page.save(db)
    }

    func deletePage(id: String) async throws {
        try await dbQueue.write { db in
            _ = try StoredPage.deleteOne(db, key: id)
            _ = try OutboxEntry.deleteOne(db, key: id)
        }
    }

    func pageIdsWithoutBook() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM page WHERE bookId IS NULL")
        }
    }

    func assignBook(pageId: String, bookId: Int, chapterId: Int?) async throws {
        try await dbQueue.write { db in
            // Nur Metadaten korrigieren — Inhalt/Stempel bleiben unangetastet.
            guard var page = try StoredPage.fetchOne(db, key: pageId) else { return }
            page.bookId = bookId
            if let chapterId { page.chapterId = chapterId }
            try page.update(db)
        }
    }

    // MARK: - Hilfen

    /// Epoch-Millisekunden — gleiche Einheit wie `Date.now()` in der WebView.
    private static func nowMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    /// Standard-DB-Pfad: Application Support / schreibwerkstatt-focuseditor /
    /// servers/<slug>/localstore.sqlite (Per-Server-Namespace). Migriert eine
    /// evtl. noch global abgelegte Alt-DB einmalig in den aktuellen Namespace.
    private static func defaultURL() throws -> URL {
        AppSupport.migrateLegacyFileIfNeeded(named: "localstore.sqlite")
        return AppSupport.serverDir().appendingPathComponent("localstore.sqlite")
    }
}

// MARK: - GRDB-Record-Konformität
//
// Die Domänen-Typen sind bereits Codable; GRDB leitet Fetch/Persist daraus ab.
// Spaltennamen == Property-Namen (siehe Migration oben).

extension StoredPage: nonisolated FetchableRecord, nonisolated PersistableRecord {
    nonisolated static let databaseTableName = "page"
}

extension OutboxEntry: nonisolated FetchableRecord, nonisolated PersistableRecord {
    nonisolated static let databaseTableName = "outbox"
}

extension PageSummary: nonisolated FetchableRecord {}
