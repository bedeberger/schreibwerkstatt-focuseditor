//
//  PagePickerOverlay.swift
//  schreibwerkstatt-focuseditor
//
//  Beschwörbarer Seiten-Picker (⌘O) — ein schwebendes Such-/Listen-Overlay über
//  dem Editor, das nach der Auswahl wieder verschwindet. Maximal ablenkungsfrei:
//  keine dauerhafte Sidebar, kein Chrome beim Schreiben.
//
//  Bedienung: Tippen filtert, ⏎ öffnet den ersten Treffer, ⎋ oder Klick auf den
//  Hintergrund schliesst. Die Auswahl hebt die Seite über die Bridge (`openPage`)
//  in die WebView.
//

import SwiftUI
import AppKit

struct PagePickerOverlay: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var isOpen: Bool

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Index der per Tastatur/Hover markierten Zeile in `filtered`.
    @State private var selected = 0
    /// Ziel für den Auto-Scroll. Wird NUR von der Tastatur-Navigation gesetzt,
    /// nicht vom Hover — sonst entsteht eine Rückkopplung (Hover → Scroll → Zeilen
    /// rutschen unter den Cursor → neuer Hover → …), die als Flackern sichtbar ist.
    @State private var scrollTarget: Int?
    /// Lokaler Key-Monitor für ↑/↓/⏎ — fängt die Tasten ab, bevor das fokussierte
    /// Suchfeld sie als Cursor-Bewegung/Submit schluckt.
    @State private var keyMonitor: Any?

    private var filtered: [PagePickerRow] {
        guard !query.isEmpty else { return library.pages }
        return library.pages.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || ($0.chapterName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Eine Seitenzeile samt ihrem flachen Index in `filtered` — der Index ist die
    /// Brücke zur Tastatur-/Hover-Auswahl (`selected`) und zum Auto-Scroll-`.id`.
    private struct IndexedRow: Identifiable {
        let index: Int
        let row: PagePickerRow
        var id: Int { row.id }
    }

    /// Ein Kapitelblock: zusammenhängender Lauf gleicher `chapterName` in der
    /// depth-first-Reihenfolge (Top-Level-Seiten → `header == nil`, kein Titel).
    private struct PickerGroup: Identifiable {
        let id: Int          // erster Index im Lauf (stabil pro Filterung)
        let header: String?
        let depth: Int
        let rows: [IndexedRow]
    }

    /// Gruppiert `filtered` in Kapitelblöcke. Da `pickerRows` depth-first abflacht
    /// (alle Seiten eines Kapitels stehen am Stück), genügt das Aufbrechen bei
    /// jedem Wechsel des Kapitelnamens — Unterkapitel werden zu eigenen Blöcken,
    /// ihre `depth` rückt Header + Zeilen ein.
    private var groups: [PickerGroup] {
        var result: [PickerGroup] = []
        var current: [IndexedRow] = []
        var currentHeader: String?
        var groupStart = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(PickerGroup(id: groupStart,
                                      header: currentHeader,
                                      depth: current.first?.row.depth ?? 0,
                                      rows: current))
            current = []
        }

        for (index, row) in filtered.enumerated() {
            let header = (row.chapterName?.isEmpty ?? true) ? nil : row.chapterName
            if !current.isEmpty && header != currentHeader { flush() }
            if current.isEmpty { currentHeader = header; groupStart = index }
            current.append(IndexedRow(index: index, row: row))
        }
        flush()
        return result
    }

    var body: some View {
        ZStack {
            // Abdunkelnder Hintergrund — Klick schliesst.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .frame(width: 460, height: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandColor.muted.opacity(0.2))
            )
            .shadow(radius: 30, y: 8)
        }
        .onExitCommand { close() }               // ⎋
        .onAppear {
            focusSearchField()
            installKeyMonitor()
            Task { await library.refreshPages() } // beim Öffnen frisch ziehen
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { _, _ in                  // neue Suche → oben anfangen
            selected = 0
            scrollTarget = 0
        }
    }

    // MARK: Teile

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BrandColor.muted)
            TextField(t("picker.searchPage"), text: $query)
                .textFieldStyle(.plain)
                .font(BrandFont.sans(14))
                .focused($searchFocused)
                .onSubmit(openSelected)         // ⏎ (Fallback; Monitor fängt i. d. R. ab)

            if !library.pages.isEmpty {
                Text("\(filtered.count)")
                    .font(BrandFont.sans(11))
                    .monospacedDigit()
                    .foregroundStyle(BrandColor.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if library.isLoadingPages && library.pages.isEmpty {
            centered { ProgressView() }
        } else if filtered.isEmpty {
            centered {
                Text(library.activeBookId == nil ? t("picker.noBookSelected") : t("picker.noPages"))
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, row in
                            rowButton(row, isSelected: index == selected)
                                .id(index)
                                .onHover { if $0 { selected = index } }
                            Divider().opacity(0.4)
                        }
                    }
                }
                .onChange(of: scrollTarget) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private func rowButton(_ row: PagePickerRow, isSelected: Bool) -> some View {
        Button { open(row) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name.isEmpty ? t("picker.untitled") : row.name)
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.text)
                if let chapter = row.chapterName, !chapter.isEmpty {
                    Text(chapter)
                        .font(BrandFont.sans(10))
                        .foregroundStyle(BrandColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.leading, CGFloat(row.depth) * 14 + 14)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
            .background(isSelected ? BrandColor.primary.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Aktionen

    private func open(_ row: PagePickerRow) {
        library.openPage(row)
        close()
    }

    /// Öffnet die aktuell markierte Zeile (Tastatur/Hover); fällt auf den ersten
    /// Treffer zurück, falls der Index durch eine neue Filterung verrutscht ist.
    private func openSelected() {
        guard !filtered.isEmpty else { return }
        let row = filtered.indices.contains(selected) ? filtered[selected] : filtered[0]
        open(row)
    }

    /// Bewegt die Markierung um `delta`, begrenzt auf die Trefferliste.
    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = max(0, min(filtered.count - 1, selected + delta))
        scrollTarget = selected   // nur Tastatur-Nav scrollt mit
    }

    private func close() {
        isOpen = false
    }

    // MARK: Tastatur

    /// Holt den Tastatur-Fokus aufs Suchfeld. Der Editor-`WKWebView` klammert sich
    /// an den First Responder des Fensters; setzt man `searchFocused` nur synchron
    /// im `onAppear`, gewinnt die WebView und man tippt weiter auf der Seite statt
    /// ins Feld. Darum: WebView-First-Responder zuerst lösen (`makeFirstResponder(nil)`),
    /// dann den Fokus DEFERRED setzen — das Suchfeld ist erst im nächsten Runloop
    /// fertig in der Responder-Kette.
    private func focusSearchField() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Fängt ↑/↓/⏎ ab, solange das Overlay offen ist. Das Suchfeld behält den
    /// Fokus fürs Tippen; die Pfeiltasten steuern die Auswahl statt den Cursor.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: moveSelection(1);  return nil   // ↓
            case 126: moveSelection(-1); return nil   // ↑
            case 36, 76: openSelected(); return nil   // ⏎ / Enter
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
