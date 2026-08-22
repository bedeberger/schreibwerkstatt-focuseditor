//
//  BookExportController.swift
//  schreibwerkstatt-focuseditor
//
//  Ablage ▸ „Buch exportieren …" (⌘⇧E): schreibt das aktive Buch als EINE
//  Markdown-Datei.
//
//  Warum es das gibt: der lokale Spiegel hat das ganze Manuskript, aber es kam
//  bisher nur über den Server wieder heraus. Für eine offline-first-App ist das
//  eine Lücke im Vertrauen — wer offline schreibt, will sein Buch auch offline
//  in der Hand halten können. Kein Sync-Ersatz, ein Auszug.
//
//  Sandbox: `NSSavePanel` erteilt dem Prozess das Schreibrecht für genau die
//  gewählte Datei (`files.user-selected` steht in beiden Entitlement-Wegen —
//  DMG-Datei wie MAS-Synthese). Es wird nirgendwo sonst hin geschrieben.
//
//  Der Zusammenbau selbst liegt pur in BookExport.swift; hier stehen nur das
//  Einsammeln aus den Stores, das Panel und der Fortschritts-/Fehlerzustand.
//

import AppKit
import Combine
import UniformTypeIdentifiers
import os

@MainActor
final class BookExportController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case collecting
        /// Fertig — Datei geschrieben; `missing` = Seiten ohne lokalen Body.
        case done(url: URL, pages: Int, missing: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let store: any LocalStore
    private let library: LibraryStore
    private let log = AppLog.export

    init(store: any LocalStore, library: LibraryStore) {
        self.store = store
        self.library = library
    }

    /// Kann exportiert werden? (aktives Buch mit mindestens einer Seite)
    var canExport: Bool {
        library.activeBookId != nil && !library.pages.isEmpty && phase != .collecting
    }

    /// Sammelt die Seiten des aktiven Buchs, fragt nach dem Ziel und schreibt.
    /// Reihenfolge zählt: erst der offene Draft in den Store (sonst fehlt im
    /// Export genau der Satz, den der Nutzer eben getippt hat), dann sammeln.
    func exportActiveBook(flushDraft: @escaping () async -> Void) {
        guard phase != .collecting else { return }
        start(flushDraft: flushDraft)
    }

    private func start(flushDraft: @escaping () async -> Void) {
        guard let bookId = library.activeBookId else { return }
        let title = library.activeBookName ?? t("library.bookFallback", ["id": "\(bookId)"])
        let rows = library.pages
        phase = .collecting

        Task {
            await flushDraft()
            var entries: [BookExport.Entry] = []
            entries.reserveCapacity(rows.count)
            for row in rows {
                // Fehler beim Einzel-Lesen wie „nie gepullt" behandeln: eine
                // kaputte Zeile darf den Export der übrigen 300 Seiten nicht
                // kippen — sie wird unten als fehlend ausgewiesen.
                let stored = try? await store.page(id: String(row.id))
                let html = stored?.html
                entries.append(BookExport.Entry(name: row.name,
                                                chapterPath: row.chapterPath,
                                                html: html))
            }
            let result = BookExport.document(bookTitle: title, entries: entries, now: Date())

            guard let url = await Self.askForDestination(suggested: BookExport.suggestedFilename(bookTitle: title)) else {
                phase = .idle   // abgebrochen — kein Fehler
                return
            }
            do {
                try result.markdown.write(to: url, atomically: true, encoding: .utf8)
                phase = .done(url: url, pages: entries.count, missing: result.missingPages.count)
                log.info("Buch exportiert: \(entries.count, privacy: .public) Seiten, \(result.missingPages.count, privacy: .public) ohne lokalen Text")
            } catch {
                phase = .failed(error.localizedDescription)
                log.error("Export fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Zeigt das Speichern-Panel. `nil` = abgebrochen.
    private static func askForDestination(suggested: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested + ".md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = t("export.panelTitle")
            panel.prompt = t("export.panelPrompt")
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Ergebnis wegklicken (Banner-Schliessen).
    func dismiss() { phase = .idle }

    /// Exportierte Datei im Finder zeigen.
    func revealInFinder() {
        guard case .done(let url, _, _) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
