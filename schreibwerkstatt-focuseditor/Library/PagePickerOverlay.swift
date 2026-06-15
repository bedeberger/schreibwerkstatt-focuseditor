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
        return library.pages.filter { row in
            row.name.localizedCaseInsensitiveContains(query)
            // Treffer in JEDEM Pfad-Segment (Jahr ODER Monat), nicht nur im Leaf —
            // so findet „2026" auch die Seiten unter dem Jahres-Kapitel.
            || row.chapterPath.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Eine Seitenzeile samt ihrem flachen Index in `filtered` — der Index ist die
    /// Brücke zur Tastatur-/Hover-Auswahl (`selected`) und zum Auto-Scroll-`.id`.
    private struct IndexedRow: Identifiable {
        let index: Int
        let row: PagePickerRow
        var id: Int { row.id }
    }

    /// Ein Kapitelblock: zusammenhängender Lauf gleichen `path` in der
    /// depth-first-Reihenfolge (Top-Level-Seiten → leerer Pfad, kein Header).
    private struct PickerGroup: Identifiable {
        let id: Int          // erster Index im Lauf (stabil pro Filterung)
        let path: [String]   // voller Kapitelpfad; leer = Top-Level
        let rows: [IndexedRow]
        var depth: Int { path.count }
    }

    /// Gruppiert `filtered` in Kapitelblöcke. Da `pickerRows` depth-first abflacht
    /// (alle Seiten eines Kapitels stehen am Stück), genügt das Aufbrechen bei
    /// jedem Wechsel des VOLLEN Pfads — gleichnamige Unterkapitel verschiedener
    /// Eltern (z. B. „Januar" in 2025 und 2026) bleiben so getrennte Blöcke, statt
    /// fälschlich zu verschmelzen.
    private var groups: [PickerGroup] {
        var result: [PickerGroup] = []
        var current: [IndexedRow] = []
        var currentPath: [String] = []
        var groupStart = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(PickerGroup(id: groupStart, path: currentPath, rows: current))
            current = []
        }

        for (index, row) in filtered.enumerated() {
            if !current.isEmpty && row.chapterPath != currentPath { flush() }
            if current.isEmpty { currentPath = row.chapterPath; groupStart = index }
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
            selectOpenPage()                      // falls Seiten schon im Cache stehen
            Task { await library.refreshPages() } // beim Öffnen frisch ziehen
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: library.pages) { _, _ in          // async nachgeladen → springen
            selectOpenPage()
        }
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
            centered {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(t("picker.loadingPages"))
                        .font(BrandFont.sans(12))
                        .foregroundStyle(BrandColor.muted)
                }
            }
        } else if filtered.isEmpty {
            centered { emptyState }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.rows) { entry in
                                    rowButton(entry.row, isSelected: entry.index == selected)
                                        .id(entry.index)
                                        .onHover { if $0 { selected = entry.index } }
                                    Divider().opacity(0.4)
                                }
                            } header: {
                                if !group.path.isEmpty {
                                    chapterHeader(group.path)
                                }
                            }
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

    /// Leerzustand des Pickers — unterscheidet drei Fälle (Suche ohne Treffer /
    /// kein Buch gewählt / Buch ohne Seiten) mit Icon, klarer Aussage und einem
    /// konkreten nächsten Schritt, statt einer einzelnen kargen Textzeile.
    @ViewBuilder
    private var emptyState: some View {
        let searching = !query.isEmpty
        let noBook = library.activeBookId == nil
        let icon = searching ? "magnifyingglass" : (noBook ? "books.vertical" : "doc.text")
        let title = searching ? t("picker.noMatches")
            : (noBook ? t("picker.noBookSelected") : t("picker.noPages"))
        let hint: String? = searching ? nil : (noBook ? t("picker.noBookHint") : t("picker.noPagesHint"))

        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(BrandColor.faint)
            Text(title)
                .font(BrandFont.sans(13))
                .foregroundStyle(BrandColor.muted)
            if let hint {
                Text(hint)
                    .font(BrandFont.sans(11))
                    .foregroundStyle(BrandColor.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 280)
    }

    /// Pinned Kapitel-Überschrift als Breadcrumb über den vollen Pfad
    /// (z. B. „2026 › JANUAR"). Eltern-Segmente sind gedimmt, das Blatt-Kapitel
    /// betont — so bleibt das übergeordnete Kapitel sichtbar (auch wenn es selbst
    /// keine Seiten hat) und gleichnamige Kapitel verschiedener Jahre sind
    /// unterscheidbar. Bleibt beim Scrollen oben kleben; bei Platzmangel wird in
    /// der Mitte gekürzt, damit Jahr (vorn) und Monat (hinten) sichtbar bleiben.
    private func chapterHeader(_ path: [String]) -> some View {
        breadcrumb(path)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(max(0, path.count - 1)) * 14 + 14)
            .padding(.trailing, 14)
            .background(.regularMaterial)
    }

    /// Baut den Breadcrumb-`Text` aus dem Kapitelpfad: Trennzeichen „›" und
    /// Eltern-Segmente gedimmt, das letzte Segment (aktuelles Kapitel) betont.
    private func breadcrumb(_ path: [String]) -> Text {
        var out = AttributedString()
        for (i, segment) in path.enumerated() {
            if i > 0 {
                var sep = AttributedString(" › ")
                sep.font = BrandFont.sans(10)
                sep.foregroundColor = BrandColor.faint
                out += sep
            }
            let isLeaf = i == path.count - 1
            var seg = AttributedString(segment.uppercased())
            seg.font = BrandFont.sans(10, weight: isLeaf ? .semibold : .regular)
            seg.foregroundColor = isLeaf ? BrandColor.muted : BrandColor.faint
            seg.tracking = 0.5
            out += seg
        }
        return Text(out)
    }

    private func rowButton(_ row: PagePickerRow, isSelected: Bool) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 6) {
                Text(row.name.isEmpty ? t("picker.untitled") : row.name)
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.id == library.openPageId {
                    Text(t("picker.openBadge"))
                        .font(BrandFont.sans(9, weight: .semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(BrandColor.primary.opacity(0.12),
                                    in: Capsule())
                }
                Spacer(minLength: 8)
                // Dezente Relativ-Zeit der letzten Änderung — Orientierung im
                // grossen Buch („woran habe ich zuletzt geschrieben?").
                if let updated = row.updatedAt {
                    Text(Self.relative(updated))
                        .font(BrandFont.sans(10))
                        .monospacedDigit()
                        .foregroundStyle(BrandColor.faint)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.leading, CGFloat(row.depth) * 14 + 14)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
            // Tastatur-/Hover-Fokus → Marken-Gold (Akzent); hebt sich klar vom
            // Navy „offen"-Badge ab.
            .background(isSelected ? BrandColor.accent.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Letzte Änderung als kurze Relativ-Zeit in der App-Sprache (z. B. „vor 3 Std.").
    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10nStore.shared.localeCode)
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Aktionen

    private func open(_ row: PagePickerRow) {
        library.openPage(row)
        close()
    }

    /// Markiert die aktuell geöffnete Seite und scrollt sie ins Bild — damit ein
    /// grosses Buch dort aufgeht, „wo man ist", statt immer oben. Nur ohne aktive
    /// Suche; sobald gefiltert wird, gewinnt der erste Treffer (`onChange(query)`).
    private func selectOpenPage() {
        guard query.isEmpty,
              let openId = library.openPageId,
              let idx = filtered.firstIndex(where: { $0.id == openId }) else { return }
        selected = idx
        scrollTarget = idx
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
