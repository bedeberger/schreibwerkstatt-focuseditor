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
                if library.isLoadingBooks {
                    Text(t("library.loadingBooks"))
                } else if let error = library.lastError {
                    // Leere Liste OHNE Erklärung wirkt wie „kein Buch vorhanden“ —
                    // bei einem Lade-/Verbindungsfehler stattdessen den Grund nennen
                    // und einen erneuten Versuch anbieten.
                    Text(t("library.loadError"))
                    Text(error)
                    Divider()
                    Button(t("content.retry")) { Task { await library.loadBooks() } }
                } else {
                    Text(t("library.noBooks"))
                }
            } else {
                ForEach(library.books, id: \.id) { book in
                    Button {
                        library.selectBook(book.id)
                    } label: {
                        let name = book.name ?? t("library.bookFallback", ["id": "\(book.id)"])
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
                Text(library.activeBookName ?? t("library.chooseBook"))
                    .font(BrandFont.sans(12))
            }
        }
        .menuStyle(.borderlessButton)
        .help(t("library.chooseBook"))
        // Sonst liest VoiceOver „books.vertical, <Buch>“ — stattdessen die Rolle
        // als Buch-Auswahl mit dem aktiven Buch als Wert.
        .accessibilityLabel(t("library.chooseBook"))
        .accessibilityValue(library.activeBookName ?? "")
    }
}
