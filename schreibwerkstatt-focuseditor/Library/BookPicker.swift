//
//  BookPicker.swift
//  schreibwerkstatt-focuseditor
//
//  Buchauswahl als schlankes Toolbar-Menü. Selten gebraucht (Buch wechselt man
//  kaum mitten im Schreiben), darum bewusst kein eigener UI-Layer — ein Popover
//  reicht. Das gewählte Buch persistiert der LibraryStore.
//

import SwiftUI

struct BookPicker: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Menu {
            if library.books.isEmpty {
                Text(library.isLoadingBooks ? "Lade Bücher …" : "Keine Bücher")
            } else {
                ForEach(library.books, id: \.id) { book in
                    Button {
                        library.selectBook(book.id)
                    } label: {
                        let name = book.name ?? "Buch \(book.id)"
                        if book.id == library.activeBookId {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                Text(library.activeBookName ?? "Buch wählen")
                    .font(BrandFont.sans(12))
            }
        }
        .menuStyle(.borderlessButton)
        .help("Buch wählen")
    }
}
