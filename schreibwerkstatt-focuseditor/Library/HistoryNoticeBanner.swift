//
//  HistoryNoticeBanner.swift
//  schreibwerkstatt-focuseditor
//
//  Kurzer Hinweis über der Schreibfläche, wenn ein Widerrufen (⌘Z) oder
//  Wiederherstellen (⌘⇧Z) nennenswert viel Text bewegt hat.
//
//  Warum es das braucht: Widerrufen macht die native macOS-Funktion (Bearbeiten ▸
//  Widerrufen, WebKits Undo-Stack) — hier ist nichts nachgebaut. Dieser Stack ist
//  aber GROB: gemessen am echten Editor-Bundle fasst WebKit alles seit dem letzten
//  Mausklick in EINEN Schritt zusammen (Pfeiltasten, Enter, Auto-Save und
//  Fokuswechsel trennen nicht). Ein versehentliches ⌘Z entfernt damit unter
//  Umständen einen ganzen Schreib-Abschnitt, und der Auto-Save persistiert das
//  still. Der Hinweis macht es sichtbar und nennt den Rückweg (⌘⇧Z), solange er
//  noch besteht — WebKits Redo verfällt beim nächsten Tastendruck.
//
//  Reine Anzeige: der Banner fasst nie Inhalte an.
//

import SwiftUI

struct HistoryNoticeBanner: View {
    let notice: LibraryStore.HistoryNotice
    let dismiss: () -> Void

    var body: some View {
        NoticeBanner(
            tone: .info,
            icon: notice.isUndo ? "arrow.uturn.backward" : "arrow.uturn.forward",
            title: title,
            message: message,
            dismissLabel: t("history.dismiss"),
            dismiss: dismiss)
    }

    private var title: String {
        notice.isUndo ? t("history.undo.title") : t("history.redo.title")
    }

    /// Umfang + (beim Widerrufen) der Rückweg. Plural über `tn`.
    private var message: String {
        let amount = tn(notice.chars, "history.chars")
        return notice.isUndo
            ? t("history.undo.message", ["amount": amount])
            : t("history.redo.message", ["amount": amount])
    }
}
