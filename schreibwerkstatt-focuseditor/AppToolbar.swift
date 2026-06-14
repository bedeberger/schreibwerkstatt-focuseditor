//
//  AppToolbar.swift
//  schreibwerkstatt-focuseditor
//
//  Eigene, markengerechte Toolbar-Leiste im Content — bewusst NICHT die native
//  Fenster-Toolbar (die wirkte wie ein Menü). Eine schlanke Papier-Leiste mit
//  feiner Trennlinie sitzt direkt unter den Ampel-Buttons; das Fenster ist
//  randlos (`fullSizeContentView`), darum die Aussparung links für die Ampeln.
//
//  Inhalt: Buch-Picker (links), Öffnen (⌘O), Sync-Status und ein Überlauf-Menü
//  (Darstellung + Abmelden) rechts. Im ablenkungsfreien/nativen Vollbild wird
//  die Leiste vom Host komplett ausgeblendet.
//

import SwiftUI
import AppKit

struct AppToolbar: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceController
    @EnvironmentObject private var fullscreen: KioskFullscreen
    @EnvironmentObject private var writingStats: WritingStatsStore

    /// Steuert den beschwörbaren Seiten-Picker (⌘O) im Host.
    @Binding var pickerOpen: Bool

    /// Hover-Zustand des Überlauf-Menüs (Material-Highlight).
    @State private var overflowHover = false

    var body: some View {
        HStack(spacing: 14) {
            BookPicker()

            if let chapter = library.openChapterName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                Text(chapter)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            if let page = library.openPageName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                Text(page)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
            }

            Spacer(minLength: 12)

            ToolbarIconButton(systemName: "doc.text.magnifyingglass",
                              help: "Seite öffnen (⌘O)",
                              accessibilityLabel: "Seite öffnen") {
                pickerOpen.toggle()
            }
            .keyboardShortcut("o", modifiers: .command)

            if writingStats.showStats {
                WritingStatsLabel(words: writingStats.words,
                                  wordsToday: writingStats.wordsToday,
                                  readingMinutes: writingStats.readingMinutes,
                                  goal: writingStats.pageGoalWords,
                                  progress: writingStats.goalProgress)
            }

            SyncStatusLabel(status: sync.status,
                            conflicts: sync.conflicts.count,
                            lastSyncedAt: sync.lastSyncedAt)

            overflowMenu
        }
        .padding(.leading, fullscreen.trafficLightInset)
        .padding(.trailing, 16)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())          // leere Flächen ziehen das Fenster
        // Warm getönte Vibrancy: das Papier-Surface über dem Material gibt der
        // Leiste den nativen Blur, ohne die warme Markenfläche zu verlieren.
        .background(BrandColor.surface.opacity(0.7))
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.faint.opacity(0.6))
                .frame(height: 1)
        }
    }

    /// Überlauf: selten gebrauchte Aktionen gebündelt — hält die Leiste ruhig.
    private var overflowMenu: some View {
        Menu {
            Picker("Darstellung", selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Abmelden") { auth.signOut() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(overflowHover ? BrandColor.faint.opacity(0.25) : .clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { overflowHover = $0 }
        .help("Weitere Optionen")
        .accessibilityLabel("Weitere Optionen")
    }
}

/// Ikon-Knopf der Toolbar mit dezentem Hover-Highlight (rundet die Fläche auf
/// und tönt sie) — gibt den sonst reaktionslosen `.plain`-Buttons natives
/// Feedback. Tooltip und VoiceOver-Label getrennt gesetzt.
private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? BrandColor.faint.opacity(0.25) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Lebende Schreibstatistik für die Toolbar: Wortzahl, heute geschriebene Wörter
/// und Lesezeit, plus eine schlanke Fortschrittsleiste, wenn ein Seitenziel
/// gesetzt ist. Der Tooltip nennt zusätzlich die Zeichenzahl bzw. den Zielwert.
struct WritingStatsLabel: View {
    let words: Int
    let wordsToday: Int
    let readingMinutes: Int
    let goal: Int
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.word.spacing")
                .foregroundStyle(BrandColor.muted)
            Text("\(words) \(words == 1 ? "Wort" : "Wörter")")
            Text("· \(signed(wordsToday)) heute")
                .foregroundStyle(wordsToday > 0 ? BrandColor.muted : BrandColor.faint)
            if readingMinutes > 0 {
                Text("· \(readingMinutes) min")
                    .foregroundStyle(BrandColor.faint)
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 48)
                    .tint(progress >= 1 ? .green : BrandColor.muted)
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .fixedSize()
        .help(tooltip)
    }

    /// Vorzeichen-Formatierung wie der Web-Editor: „+120" / „−5" / „±0"
    /// (echtes Minus U+2212).
    private func signed(_ n: Int) -> String {
        if n > 0 { return "+\(n)" }
        if n < 0 { return "−\(abs(n))" }
        return "±0"
    }

    private var tooltip: String {
        let heute = "\(signed(wordsToday)) Wörter heute auf dieser Seite"
        if goal > 0 {
            return "\(words) von \(goal) Wörtern (\(Int(((progress ?? 0) * 100).rounded())) %) · \(heute)"
        }
        return "Wortzahl der offenen Seite · \(heute) · ~\(readingMinutes) min Lesezeit"
    }
}

/// Schlanke Sync-Anzeige (Status + offene Konflikte) für die App-Toolbar.
/// Der Hover-Tooltip nennt den Zeitpunkt der letzten erfolgreichen Synchronisation.
struct SyncStatusLabel: View {
    let status: SyncEngine.Status
    let conflicts: Int
    let lastSyncedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            if conflicts > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(conflicts) Konflikt\(conflicts == 1 ? "" : "e")")
            } else {
                switch status {
                case .syncing:
                    ProgressView().controlSize(.small)
                    Text("Synchronisiere …")
                case .offline:
                    Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                    Text("Offline")
                case .idle:
                    Image(systemName: "checkmark.circle").foregroundStyle(BrandColor.muted)
                }
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .help(tooltip)
    }

    /// „Zuletzt synchronisiert“ als relative Zeit, sonst der aktuelle Zustand.
    private var tooltip: String {
        if conflicts > 0 { return "Ungelöste Konflikte — im Editor auflösen" }
        if let last = lastSyncedAt {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "de")
            return "Zuletzt synchronisiert \(rel.localizedString(for: last, relativeTo: Date()))"
        }
        return status == .offline ? "Offline — keine Verbindung" : "Noch nicht synchronisiert"
    }
}

/// Macht den Hintergrund einer View zur Fenster-Ziehfläche. Steuerelemente
/// (Buttons/Menüs) liegen darüber und fangen ihre Klicks selbst ab — nur leere
/// Bereiche ziehen das randlose Fenster.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
