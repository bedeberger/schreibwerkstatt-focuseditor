//
//  BookExportBanner.swift
//  schreibwerkstatt-focuseditor
//
//  Ergebnis des Buch-Exports über der Schreibfläche — stiltreu zum
//  Lektorats-Banner (gleiche Höhe, gleiche Kanten), damit der Stapel aus
//  Save-Fehler / Lektorat / Widerrufen / Export eine Linie hält.
//
//  Die Meldung nennt bewusst die Zahl der Seiten OHNE lokalen Text: ein Export
//  mit Lücken darf nicht wie ein vollständiges Backup aussehen (s. BookExport).
//

import SwiftUI

struct BookExportBanner: View {
    @EnvironmentObject private var export: BookExportController

    var body: some View {
        NoticeBanner(
            tone: isFailure ? .failure : .success,
            icon: icon,
            title: title,
            message: detail,
            dismiss: { export.dismiss() }
        ) {
            if case .done = export.phase {
                Button(t("export.reveal")) { export.revealInFinder() }
                    .buttonStyle(.link)
                    .font(BrandFont.sans(12))
                    .pointerLink()
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = export.phase { return true }
        return false
    }

    private var icon: String {
        isFailure ? "exclamationmark.triangle.fill" : "square.and.arrow.down"
    }

    private var title: String {
        switch export.phase {
        case .done(_, let pages, let missing):
            let base = tn(pages, "export.bannerPages")
            return missing == 0 ? base : base + " · " + tn(missing, "export.bannerMissing")
        case .failed(let message):
            return message
        case .idle, .collecting:
            return ""
        }
    }

    private var detail: String? {
        guard case .done(let url, _, _) = export.phase else { return nil }
        return url.path(percentEncoded: false)
    }
}
