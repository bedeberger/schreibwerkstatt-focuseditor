//
//  ContentAPI.swift
//  schreibwerkstatt-focuseditor
//
//  Lese-Zugriff auf die Buch-/Kapitel-Struktur des Servers — die Soll-Quelle
//  für Buch- und Seitenauswahl. Zwei Endpoints:
//    • GET /content/books               → Bücherliste (Auswahl)
//    • GET /content/books/:id/tree      → Hierarchie { chapters, topPages }
//
//  Der Tree ist zugleich der Delete-Reconcile-Pfad (CLAUDE.md): `/sync` meldet
//  nur geänderte/neue Seiten, NICHT Löschungen — der Soll-Bestand kommt aus dem
//  Tree. Netzwerk macht ausschließlich der Swift-Kern (APIClient mit Bearer).
//
//  Felder exakt nach Server-Vertrag (lib/content-store: `_chapterRow`,
//  `_pageMetaRow`, `_applyOrder`). `pages`/`subchapters` können fehlen
//  (Roh-Tree ohne angewandte book_order) → defensiv mit `[]` dekodiert.
//

import Foundation

// MARK: - DTOs

/// Seite im Buch-Baum. Reine Metadaten (kein HTML — den liefert der Sync-Pull).
/// Seiten-ID heißt hier `id`.
struct TreePageDTO: Decodable {
    let id: Int
    let chapter_id: Int?
    let name: String?
    let position: Int?
    let updated_at: String?
}

/// Kapitel im Buch-Baum: direkte Seiten (`pages`) + rekursiv Unterkapitel
/// (`subchapters`). Beide Felder sind optional in der Server-Antwort.
struct TreeChapterDTO: Decodable {
    let id: Int
    let name: String?
    let position: Int?
    let parent_chapter_id: Int?
    let pages: [TreePageDTO]
    let subchapters: [TreeChapterDTO]

    private enum CodingKeys: String, CodingKey {
        case id, name, position, parent_chapter_id, pages, subchapters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        position = try c.decodeIfPresent(Int.self, forKey: .position)
        parent_chapter_id = try c.decodeIfPresent(Int.self, forKey: .parent_chapter_id)
        pages = try c.decodeIfPresent([TreePageDTO].self, forKey: .pages) ?? []
        subchapters = try c.decodeIfPresent([TreeChapterDTO].self, forKey: .subchapters) ?? []
    }
}

/// Antwort von `GET /content/books/:id/tree`.
struct BookTreeDTO: Decodable {
    let chapters: [TreeChapterDTO]
    let topPages: [TreePageDTO]

    private enum CodingKeys: String, CodingKey {
        case chapters, topPages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapters = try c.decodeIfPresent([TreeChapterDTO].self, forKey: .chapters) ?? []
        topPages = try c.decodeIfPresent([TreePageDTO].self, forKey: .topPages) ?? []
    }
}

// MARK: - Flache Picker-Zeile

/// Eine Zeile für den Seiten-Picker: depth-first abgeflachter Tree, in
/// book_order-Reihenfolge.
///
/// `chapterPath` ist der VOLLE Kapitelpfad von der Wurzel bis zum direkt
/// umschließenden Kapitel — z. B. `["2026", "Januar"]` für eine Seite im
/// Unterkapitel „Januar" des Jahres-Kapitels „2026". Leer (`[]`) für
/// Top-Level-Seiten ohne Kapitel. Der volle Pfad erlaubt dem Picker, das
/// übergeordnete Kapitel als Breadcrumb anzuzeigen (auch wenn es selbst keine
/// direkten Seiten hat) und gleichnamige Unterkapitel verschiedener Eltern
/// auseinanderzuhalten (sonst verschmelzen z. B. zwei „Januar" zu einer Gruppe).
struct PagePickerRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let chapterPath: [String]
    /// Letzte Änderung (Server-`updated_at`, sonst lokaler Spiegel) — treibt die
    /// dezente Relativ-Zeit pro Picker-Zeile (Orientierung im grossen Buch).
    /// `nil`, wenn kein Zeitstempel vorliegt. Default-Wert hält bestehende
    /// Initializer (ohne Zeitstempel) gültig.
    var updatedAt: Date? = nil

    /// Direkt umschließendes Kapitel (Leaf des Pfads) — `nil` für Top-Level-Seiten.
    var chapterName: String? { chapterPath.last }
    /// Verschachtelungstiefe: 0 = Top-Level-Seite, 1 = Top-Kapitel, 2+ = Unterkapitel.
    var depth: Int { chapterPath.count }
}

// MARK: - API

/// Schmale Lese-Fassade über den `APIClient` für die Inhalts-Struktur.
final class ContentAPI {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Bücherliste für die Buchauswahl.
    func books() async throws -> [BookDTO] {
        try await api.send("/content/books", decode: [BookDTO].self)
    }

    /// Buch-Baum (Soll-Bestand + Reihenfolge) für Picker und Delete-Reconcile.
    func tree(bookId: Int) async throws -> BookTreeDTO {
        try await api.send("/content/books/\(bookId)/tree", decode: BookTreeDTO.self)
    }

    /// Lädt den Tree und flacht ihn depth-first in Picker-Zeilen ab —
    /// Semantik wie `flattenTree`/der Buch-Organizer im Hauptrepo: Top-Level-Seiten
    /// zuerst, danach die Kapitel-Hierarchie depth-first; jede Seite trägt ihren
    /// vollen Kapitelpfad (für Breadcrumb + korrekte Gruppierung).
    func pickerRows(bookId: Int) async throws -> [PagePickerRow] {
        Self.flatten(try await tree(bookId: bookId))
    }

    /// Tree → flache `(Seiten-ID, Kapitel-ID)`-Liste über ALLE Seiten des Buchs
    /// (inkl. Top-Pages). Für Delete-Reconcile (Soll-IDs) und Waisen-Backfill
    /// (Buch-/Kapitel-Zuordnung) — autoritative Seite→Buch-Zuordnung des Servers.
    static func flattenTreePages(_ tree: BookTreeDTO) -> [(id: Int, chapterId: Int?)] {
        var out: [(id: Int, chapterId: Int?)] = []

        func walk(_ chapters: [TreeChapterDTO]) {
            for ch in chapters {
                for p in ch.pages { out.append((id: p.id, chapterId: p.chapter_id ?? ch.id)) }
                walk(ch.subchapters)
            }
        }

        walk(tree.chapters)
        for p in tree.topPages { out.append((id: p.id, chapterId: p.chapter_id)) }
        return out
    }

    /// Tree → depth-first-Liste (Pure-Funktion, für Tests/Wiederverwendung).
    ///
    /// Reihenfolge wie der Buch-Organizer im Hauptrepo
    /// (public/js/book/tree.js: „Seiten ohne Kapitel immer zuerst — danach Kapitel
    /// in Tree-Reihenfolge"): erst die Top-Level-Seiten, dann die Kapitel-Hierarchie
    /// depth-first. Innerhalb eines Kapitels stehen die direkten Seiten vor den
    /// Unterkapiteln. Jede Zeile trägt ihren VOLLEN Kapitelpfad (`chapterPath`),
    /// damit auch Eltern-Kapitel ohne eigene Seiten im Breadcrumb sichtbar bleiben.
    static func flatten(_ tree: BookTreeDTO) -> [PagePickerRow] {
        var rows: [PagePickerRow] = []

        for p in tree.topPages {
            rows.append(PagePickerRow(id: p.id,
                                      name: p.name ?? "Ohne Titel",
                                      chapterPath: [],
                                      updatedAt: date(from: p.updated_at)))
        }

        func walk(_ chapters: [TreeChapterDTO], path: [String]) {
            for ch in chapters {
                let childPath = path + [ch.name ?? "Ohne Titel"]
                for p in ch.pages {
                    rows.append(PagePickerRow(id: p.id,
                                              name: p.name ?? "Ohne Titel",
                                              chapterPath: childPath,
                                              updatedAt: date(from: p.updated_at)))
                }
                walk(ch.subchapters, path: childPath)
            }
        }

        walk(tree.chapters, path: [])
        return rows
    }

    /// Server-ISO-Zeitstempel → `Date` (über `ISOTime`, das auch die Sync-Engine
    /// nutzt). `nil` bei fehlendem/unparsbarem Wert.
    static func date(from iso: String?) -> Date? {
        guard let iso, let ms = ISOTime.millis(iso) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
