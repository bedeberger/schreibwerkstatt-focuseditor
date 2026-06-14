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
/// book_order-Reihenfolge. `chapterName` ist das direkt umschließende Kapitel
/// (nil für Top-Level-Seiten); `depth` erlaubt eine eingerückte Darstellung.
struct PagePickerRow: Identifiable, Equatable {
    let id: Int
    let name: String
    let chapterName: String?
    let depth: Int
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
    /// identische Semantik zu `flattenTree` im Hauptrepo (Top-Level-Kapitel
    /// auf depth 1, deren Seiten tragen den Kapitelnamen; Top-Pages depth 0).
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
    static func flatten(_ tree: BookTreeDTO) -> [PagePickerRow] {
        var rows: [PagePickerRow] = []

        func walk(_ chapters: [TreeChapterDTO], depth: Int) {
            for ch in chapters {
                for p in ch.pages {
                    rows.append(PagePickerRow(id: p.id,
                                              name: p.name ?? "Ohne Titel",
                                              chapterName: ch.name,
                                              depth: depth))
                }
                walk(ch.subchapters, depth: depth + 1)
            }
        }

        walk(tree.chapters, depth: 1)
        for p in tree.topPages {
            rows.append(PagePickerRow(id: p.id,
                                      name: p.name ?? "Ohne Titel",
                                      chapterName: nil,
                                      depth: 0))
        }
        return rows
    }
}
