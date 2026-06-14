//
//  LibraryStore.swift
//  schreibwerkstatt-focuseditor
//
//  Zustand für Buch- und Seitenauswahl. Hält die Bücherliste, das aktive Buch
//  (persistiert) und die Seiten des aktiven Buchs für den Picker. „Seite öffnen"
//  läuft über die WebView-Bridge (`openPage`).
//
//  Offline-first: Die Seitenliste kommt bevorzugt aus dem Server-Tree
//  (autoritative Reihenfolge + Kapitelnamen). Ist der Server nicht erreichbar,
//  fällt sie auf den lokalen Spiegel (`LocalStore.list(bookId:)`) zurück — was
//  schon gesynct wurde, bleibt auswählbar.
//
//  Das aktive Buch ist KEIN Geheimnis (nur eine ID) → Persistenz in
//  UserDefaults ist zulässig (im Gegensatz zum Device-Token, das nur in die
//  Keychain gehört).
//

import Foundation
import Combine
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [BookDTO] = []
    @Published private(set) var activeBookId: Int?
    @Published private(set) var pages: [PagePickerRow] = []
    @Published private(set) var isLoadingBooks = false
    @Published private(set) var isLoadingPages = false
    @Published var lastError: String?

    private let content: ContentAPI
    private let store: any LocalStore
    private let bridge: EditorBridge
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "library")

    private let defaultsKey = "library.activeBookId"

    init(content: ContentAPI, store: any LocalStore, bridge: EditorBridge) {
        self.content = content
        self.store = store
        self.bridge = bridge
        // Aktives Buch wiederherstellen (0 = nicht gesetzt).
        let saved = UserDefaults.standard.integer(forKey: defaultsKey)
        self.activeBookId = saved == 0 ? nil : saved
    }

    /// Anzeigename des aktiven Buchs (für die Toolbar).
    var activeBookName: String? {
        guard let id = activeBookId else { return nil }
        return books.first { $0.id == id }?.name
    }

    // MARK: - Laden

    /// Bücherliste vom Server holen. Ohne aktives Buch wird das erste gewählt.
    func loadBooks() async {
        isLoadingBooks = true
        defer { isLoadingBooks = false }
        do {
            let fetched = try await content.books()
            books = fetched
            lastError = nil
            // Aktives Buch validieren / Default setzen.
            if let id = activeBookId, fetched.contains(where: { $0.id == id }) {
                await refreshPages()
            } else if let first = fetched.first {
                selectBook(first.id)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Bücher laden fehlgeschlagen: \(self.lastError ?? "?", privacy: .public)")
        }
    }

    /// Buch wählen: persistieren + Seitenliste neu laden.
    func selectBook(_ id: Int) {
        guard id != activeBookId else { return }
        activeBookId = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        Task { await refreshPages() }
    }

    /// Seitenliste des aktiven Buchs aktualisieren (Server-Tree, sonst lokal).
    func refreshPages() async {
        guard let bookId = activeBookId else {
            pages = []
            return
        }
        isLoadingPages = true
        defer { isLoadingPages = false }
        do {
            pages = try await content.pickerRows(bookId: bookId)
            lastError = nil
        } catch {
            // Offline / Serverfehler → lokalen Spiegel zeigen (kein Datenverlust,
            // nur ohne Kapitel-Gruppierung/Order).
            log.notice("Tree nicht erreichbar — lokaler Fallback für Buch \(bookId, privacy: .public)")
            pages = await localRows(bookId: bookId)
        }
    }

    /// Fallback: Picker-Zeilen aus dem lokalen Spiegel (ohne Kapitel/Order).
    private func localRows(bookId: Int) async -> [PagePickerRow] {
        let summaries = (try? await store.list(bookId: bookId)) ?? []
        return summaries.compactMap { s in
            guard let pid = Int(s.id) else { return nil }
            return PagePickerRow(id: pid, name: s.displayName, chapterName: nil, depth: 0)
        }
    }

    // MARK: - Öffnen

    /// Hebt die gewählte Seite über die Bridge in den Editor.
    func openPage(_ row: PagePickerRow) {
        Task {
            let ok = await bridge.openPage(pageId: String(row.id))
            if !ok { log.notice("openPage ohne WebView — Editor noch nicht bereit") }
        }
    }
}
