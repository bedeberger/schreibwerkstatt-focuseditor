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

struct PagePickerOverlay: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var isOpen: Bool

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [PagePickerRow] {
        guard !query.isEmpty else { return library.pages }
        return library.pages.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || ($0.chapterName?.localizedCaseInsensitiveContains(query) ?? false)
        }
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
            searchFocused = true
            Task { await library.refreshPages() } // beim Öffnen frisch ziehen
        }
    }

    // MARK: Teile

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BrandColor.muted)
            TextField("Seite suchen …", text: $query)
                .textFieldStyle(.plain)
                .font(BrandFont.sans(14))
                .focused($searchFocused)
                .onSubmit(openFirst)            // ⏎
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
                Text(library.activeBookId == nil ? "Kein Buch gewählt" : "Keine Seiten")
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { row in
                        rowButton(row)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func rowButton(_ row: PagePickerRow) -> some View {
        Button { open(row) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name.isEmpty ? "Ohne Titel" : row.name)
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

    private func openFirst() {
        if let first = filtered.first { open(first) }
    }

    private func close() {
        isOpen = false
    }
}
