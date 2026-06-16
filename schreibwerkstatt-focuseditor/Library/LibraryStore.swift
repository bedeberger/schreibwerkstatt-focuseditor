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
    @Published private(set) var activeBookId: Int? {
        didSet {
            guard activeBookId != oldValue else { return }
            onWritingContextChange?(activeBookId, openPageId != nil)
        }
    }
    @Published private(set) var pages: [PagePickerRow] = []
    /// Aktuell im Editor geöffnete Seite (von der Bridge gemeldet bzw. per Picker
    /// gewählt) — treibt die Seiten-Anzeige in der Toolbar.
    @Published private(set) var openPageId: Int? {
        didSet {
            guard openPageId != oldValue else { return }
            onWritingContextChange?(activeBookId, openPageId != nil)
        }
    }
    /// Meldet Änderungen am „wo schreibt der Nutzer"-Kontext (aktives Buch + ob
    /// eine Seite offen ist) — Grundlage fürs Schreibzeit-Tracking
    /// ([WritingTimeTracker](../Writing/WritingTimeTracker.swift)). Bewusst ein
    /// schlichter Callback wie `bridge.onStats`/`onOpenPageChange` (kein Combine-
    /// Sink — das Projekt verdrahtet Stores durchweg über Callbacks).
    var onWritingContextChange: ((_ bookId: Int?, _ hasOpenPage: Bool) -> Void)?
    /// Hat die offene Seite ungespeicherte (lokale) Änderungen? Treibt den
    /// Save-Indikator in der Toolbar (von der Bridge via `editorState` gemeldet).
    @Published private(set) var openPageDirty = false
    /// Zähler, der hochzählt, wenn die View den Seiten-Picker öffnen soll —
    /// beim echten Buchwechsel und beim bewussten Schliessen der Seite (damit der
    /// Nutzer direkt die nächste Seite wählt). Reines Event-Signal, kein Zustand.
    @Published private(set) var pickerOpenRequest = 0
    @Published private(set) var isLoadingBooks = false
    @Published private(set) var isLoadingPages = false
    @Published var lastError: String?

    private let content: ContentAPI
    private let store: any LocalStore
    private let bridge: EditorBridge
    private let log = Logger(subsystem: "ch.schreibwerkstatt.focuseditor", category: "library")

    /// Aktives Buch ist server-spezifisch (eine Buch-ID gilt nur am Server, der
    /// sie vergeben hat) → Key pro Server-Namespace. Sonst wählt der Client am
    /// neuen Server eine Buch-ID des alten (→ `NO_BOOK_ACCESS`).
    /// EINE Quelle für den buch-skopierten Key (kein inline-Literal mehr — sonst
    /// driftet ein Aufrufer bei einer Prefix-Änderung still ab).
    private static func bookDefaultsKey() -> String { "library.activeBookId.\(ServerNamespace.currentSlug)" }
    private var defaultsKey: String { Self.bookDefaultsKey() }
    private static let legacyDefaultsKey = "library.activeBookId"

    init(content: ContentAPI, store: any LocalStore, bridge: EditorBridge) {
        self.content = content
        self.store = store
        self.bridge = bridge
        // Alt-Key (global) einmalig in den Namespace des aktuellen Servers ziehen.
        Self.migrateLegacyBookKeyIfNeeded()
        // Aktives Buch wiederherstellen (0 = nicht gesetzt).
        let saved = UserDefaults.standard.integer(forKey: Self.bookDefaultsKey())
        self.activeBookId = saved == 0 ? nil : saved
        // Offene Seite vom Editor übernehmen (per Picker geöffnet oder beim Boot
        // wiederhergestellt) — hält die Toolbar-Anzeige aktuell.
        bridge.onOpenPageChange = { [weak self] pageId in
            guard let self else { return }
            // Der optimistische `openPage`-Write setzt `openPageId` bereits; die
            // spätere `editorState`-Bestätigung darf NICHT erneut publizieren, wenn
            // sich nichts ändert (sonst zweite View-Invalidierung → Flackern des
            // Leerzustands über `.animation(value: openPageId)`).
            let newValue = pageId.flatMap(Int.init)
            if self.openPageId != newValue { self.openPageId = newValue }
        }
        // Dirty-Zustand der offenen Seite → Save-Indikator in der Toolbar.
        bridge.onOpenDirtyChange = { [weak self] dirty in
            guard let self else { return }
            if self.openPageDirty != dirty { self.openPageDirty = dirty }
        }
    }

    /// Anzeigename des aktiven Buchs (für die Toolbar).
    var activeBookName: String? {
        guard let id = activeBookId else { return nil }
        return books.first { $0.id == id }?.name
    }

    /// Name der aktuell offenen Seite (für die Toolbar), aufgelöst über die
    /// Seitenliste des aktiven Buchs. `nil`, solange keine Seite offen ist oder
    /// die Seite (noch) nicht in der Liste steht.
    var openPageName: String? {
        guard let id = openPageId else { return nil }
        return pages.first { $0.id == id }?.name
    }

    /// Kapitelname der aktuell offenen Seite (für die Toolbar, als Kontext links
    /// neben dem Seitennamen). `nil`, wenn keine Seite offen ist oder die Seite
    /// keinem Kapitel zugeordnet ist (bzw. nur der lokale Fallback greift).
    var openChapterName: String? {
        guard let id = openPageId,
              let chapter = pages.first(where: { $0.id == id })?.chapterName,
              !chapter.isEmpty else { return nil }
        return chapter
    }

    /// Die zuletzt gerätelokal geöffnete Seite (pro Server), aufgelöst gegen die
    /// aktuelle Seitenliste — Grundlage für „Zuletzt fortsetzen" im Leerzustand.
    /// `nil`, wenn nie eine Seite geöffnet wurde oder sie nicht (mehr) im aktiven
    /// Buch liegt.
    var lastOpenPageRow: PagePickerRow? {
        // Buch-skopierte Erinnerung (pro aktivem Buch), Fallback auf den globalen
        // Legacy-Wert — beide werden gegen die Seitenliste des aktiven Buchs
        // aufgelöst, sodass nie eine Seite eines anderen Buchs erscheint.
        let raw = activeBookId.flatMap { EditorBridge.lastOpenPageId(forBook: $0) }
            ?? UserDefaults.standard.string(forKey: EditorBridge.lastOpenPageKey)
        guard let raw, let id = Int(raw) else { return nil }
        return pages.first { $0.id == id }
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
    ///
    /// Bei einem echten Wechsel (vorher war schon ein Buch aktiv) wird die offene
    /// Seite zuerst geschlossen — der Editor soll nicht den Text des alten Buchs
    /// weiterzeigen — und anschliessend der Seiten-Picker geöffnet, damit der
    /// Nutzer direkt eine Seite des neuen Buchs wählt. Die initiale Auswahl beim
    /// Start (vorher kein Buch aktiv) lässt den Editor seine erste Seite normal
    /// laden, ohne Picker-Popup.
    func selectBook(_ id: Int) {
        guard id != activeBookId else { return }
        let isSwitch = activeBookId != nil
        activeBookId = id
        UserDefaults.standard.set(id, forKey: defaultsKey)
        guard isSwitch else {
            Task { await refreshPages() }
            return
        }
        // Offene Seite sofort schliessen (Toolbar leert sich), dann den Editor
        // leeren und den Picker mit den Seiten des neuen Buchs öffnen.
        openPageId = nil
        Task {
            await bridge.closePage()
            await refreshPages()
            pickerOpenRequest &+= 1
        }
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
            let rows = try await content.pickerRows(bookId: bookId)
            // Buchwechsel-Race: Während dieses (evtl. langsamen) Tree-Loads kann der
            // Nutzer schon zum nächsten Buch gewechselt haben — eine späte Antwort
            // des ALTEN Buchs darf die Seiten des neuen nicht überschreiben.
            guard bookId == activeBookId else { return }
            pages = rows
            lastError = nil
        } catch {
            guard bookId == activeBookId else { return }
            // Offline / Serverfehler → lokalen Spiegel zeigen (kein Datenverlust,
            // nur ohne Kapitel-Gruppierung/Order).
            log.notice("Tree nicht erreichbar — lokaler Fallback für Buch \(bookId, privacy: .public)")
            pages = await localRows(bookId: bookId)
            // Greift der lokale Spiegel (Seiten vorhanden), still bleiben — der
            // Nutzer kann weiterarbeiten. Ist auch lokal nichts da, würde der
            // Picker fälschlich „keine Seiten“ zeigen → den Fehler vermerken,
            // damit der Leerzustand den wahren Grund (Verbindung) nennt.
            lastError = pages.isEmpty
                ? ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                : nil
        }
    }

    /// Fallback: Picker-Zeilen aus dem lokalen Spiegel (ohne Kapitel/Order).
    private func localRows(bookId: Int) async -> [PagePickerRow] {
        let summaries = (try? await store.list(bookId: bookId)) ?? []
        return summaries.compactMap { s in
            guard let pid = Int(s.id) else { return nil }
            // `updatedAt` im Spiegel ist Epoch-Millis (s. PageSummary).
            return PagePickerRow(id: pid, name: s.displayName, chapterPath: [],
                                 updatedAt: Date(timeIntervalSince1970: s.updatedAt / 1000))
        }
    }

    // MARK: - Öffnen

    /// Hebt die gewählte Seite über die Bridge in den Editor.
    func openPage(_ row: PagePickerRow) {
        openPageId = row.id   // sofortige Toolbar-Anzeige; editorState bestätigt später
        openPageDirty = false // frisch geöffnete Seite ist sauber
        Task {
            let ok = await bridge.openPage(pageId: String(row.id))
            if !ok { log.notice("openPage ohne WebView — Editor noch nicht bereit") }
        }
    }

    /// Schliesst die offene Seite (Toolbar-Aktion „Seite schliessen"). Die WebView
    /// sichert lokal (local-first), leert die Schreibfläche und zeigt die ruhige
    /// Leerfläche; danach öffnen wir den Picker, damit der Nutzer direkt die
    /// nächste Seite wählen kann. Kein Datenverlust — der Stand wurde vor dem
    /// Leeren gespeichert.
    func closePage() {
        guard openPageId != nil else { return }
        openPageId = nil          // Toolbar sofort leeren
        Task {
            await bridge.closePage()
            pickerOpenRequest &+= 1
        }
    }

    /// Bittet die View, den Seiten-Picker einzublenden (Menü-/Toolbar-Einstieg
    /// „Seite öffnen"). Reines Event-Signal über `pickerOpenRequest`, das
    /// [ContentView](../ContentView.swift) beobachtet — der Menübefehl im
    /// `App`-Scope hat keinen Zugriff auf den `pickerOpen`-State der View.
    func requestPicker() {
        pickerOpenRequest &+= 1
    }

    // MARK: - Server-Wechsel

    /// Server-Wechsel: Buch-/Seiten-Zustand des alten Servers verwerfen, das
    /// aktive Buch aus dem Namespace des neuen Servers laden und die Bücherliste
    /// neu ziehen. So zeigt der Picker keine Bücher des alten Servers mehr.
    func reloadForCurrentServer() {
        books = []
        pages = []
        openPageId = nil
        openPageDirty = false
        lastError = nil
        let saved = UserDefaults.standard.integer(forKey: defaultsKey)
        activeBookId = saved == 0 ? nil : saved
        Task { await loadBooks() }
    }

    /// Einmal-Migration: den globalen Alt-Key in den Namespace des aktuell
    /// konfigurierten Servers übertragen, falls dort noch nichts steht. Danach den
    /// Alt-Key entfernen, damit er nicht erneut auf einen anderen Server „leakt".
    private static func migrateLegacyBookKeyIfNeeded() {
        let defaults = UserDefaults.standard
        let legacy = defaults.integer(forKey: legacyDefaultsKey)
        guard legacy != 0 else { return }
        let targetKey = bookDefaultsKey()
        if defaults.integer(forKey: targetKey) == 0 {
            defaults.set(legacy, forKey: targetKey)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
