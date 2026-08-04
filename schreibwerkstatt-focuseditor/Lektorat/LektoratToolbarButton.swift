//
//  LektoratToolbarButton.swift
//  schreibwerkstatt-focuseditor
//
//  Toolbar-Einstieg für das serverseitige Seiten-Lektorat (`LektoratJobStore`)
//  und das Ergebnis-Banner über der Schreibfläche. Stiltreu zum
//  `ToolbarIconButton`, aber mit eigenem Zustand: während des Laufs ein Spinner
//  (Klick = Abbrechen), danach das Banner mit der Anzahl der Beanstandungen und
//  dem Weg in die Web-App, wo sie gelesen/übernommen werden.
//

import SwiftUI

/// Ikon-Knopf „Lektorat": startet den Server-Job für die offene Seite; während
/// des Laufs zeigt er einen Spinner und bricht auf Klick ab. Nur sichtbar, wenn
/// eine Seite offen ist (Aufrufer prüft das) — ohne Seite gäbe es nichts zu prüfen.
struct LektoratToolbarButton: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var lektorat: LektoratJobStore

    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            icon
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? BrandColor.faint.opacity(0.25) : .clear)
                )
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(t("toolbar.lektorat"))
    }

    @ViewBuilder
    private var icon: some View {
        if lektorat.isBusy {
            // Unbestimmter Spinner, der Fortschritt steht im Tooltip: ein
            // bestimmter Ring in 28×28 wäre in der schmalen Leiste unlesbar.
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
        }
    }

    private var helpText: String {
        switch lektorat.phase {
        case .preparing:
            return t("lektorat.tip.preparing")
        case .running:
            let pct = lektorat.progressPercent ?? 0
            return t("lektorat.tip.running", ["pct": "\(pct)"])
        case .idle, .done, .failed:
            return t("toolbar.lektoratHelp")
        }
    }

    private func tap() {
        if lektorat.isBusy {
            lektorat.cancel()
            return
        }
        guard let pageId = library.openPageId else { return }
        lektorat.start(pageId: pageId,
                       bookId: library.activeBookId,
                       pageName: library.openPageName)
    }
}

/// Banner über der Schreibfläche, sobald ein Lektorats-Lauf terminal ist:
/// Anzahl der Beanstandungen (bzw. die Fehlermeldung) und der Weg in die
/// Web-App, wo die Findings stehen. Bewusst zurückgenommen (Papier-Ton statt
/// Warnfarbe — es ist ein Ergebnis, kein Datenverlust) und manuell schliessbar.
struct LektoratResultBanner: View {
    @EnvironmentObject private var lektorat: LektoratJobStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.system(size: 14))
                .foregroundStyle(isFailure ? BrandColor.error : BrandColor.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(BrandFont.sans(13, weight: .semibold))
                    .foregroundStyle(BrandColor.text)
                Text(message)
                    .font(BrandFont.sans(11))
                    .foregroundStyle(BrandColor.muted)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title): \(message)")

            Spacer(minLength: 8)

            // Nur im Erfolgsfall: die Beanstandungen selbst leben serverseitig
            // (Lektorats-Karte der Web-App) — dieser Client ist die reine
            // Schreib-Hülle und zeigt sie nicht.
            if !isFailure, let url = lektorat.resultWebURL {
                Button(t("lektorat.banner.open")) { openURL(url) }
                    .buttonStyle(.link)
                    .font(BrandFont.sans(12))
                    .pointerLink()
            }

            Button(action: { lektorat.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BrandColor.muted)
            }
            .buttonStyle(.plain)
            .pointerLink()
            .accessibilityLabel(t("lektorat.dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(BrandColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BrandColor.faint.opacity(0.9), lineWidth: 1)
        )
        .shadow(radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: 520)
    }

    private var isFailure: Bool {
        if case .failed = lektorat.phase { return true }
        return false
    }

    private var title: String {
        isFailure ? t("lektorat.banner.failedTitle") : t("lektorat.banner.doneTitle")
    }

    /// Ergebnis-Zeile: Seitenname (falls bekannt) + Befund bzw. Fehlermeldung.
    private var message: String {
        let detail: String
        switch lektorat.phase {
        case .failed(let msg):
            detail = msg
        case .done(let count):
            detail = count == 0 ? t("lektorat.findings.none") : tn(count, "lektorat.findings")
        case .idle, .preparing, .running:
            detail = ""
        }
        guard let page = lektorat.pageName, !page.isEmpty else { return detail }
        return t("lektorat.banner.result", ["page": page, "detail": detail])
    }
}
