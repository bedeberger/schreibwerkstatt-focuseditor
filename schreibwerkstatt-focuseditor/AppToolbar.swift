//
//  AppToolbar.swift
//  schreibwerkstatt-focuseditor
//
//  Eigene, markengerechte Toolbar-Leiste im Content — bewusst NICHT die native
//  Fenster-Toolbar (die wirkte wie ein Menü). Eine schlanke Papier-Leiste mit
//  feiner Trennlinie sitzt am oberen Rand des Inhalts, direkt unter der
//  (transparenten, titellosen) Fenster-Titelleiste mit den Ampel-Buttons.
//
//  Inhalt: Buch-Picker (links), Öffnen (⌘O), Sync-Status und ein Überlauf-Menü
//  (Darstellung + Abmelden) rechts. Die Leiste bleibt immer sichtbar (auch im
//  Vollbild); nur die Auto-Hide-Option blendet sie bei Inaktivität aus.
//

import SwiftUI
import AppKit

struct AppToolbar: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appearance: AppearanceController
    @EnvironmentObject private var focus: FocusController
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
                              help: t("toolbar.openPageHelp"),
                              accessibilityLabel: t("toolbar.openPage")) {
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
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())          // leere Flächen ziehen das Fenster
        // Sichtbar abgesetzte Leiste: `.regularMaterial` ist das eigentlich
        // sichtbare, klar vom Editor abgehobene Frosted-Panel (im Dark Mode
        // deutlich heller als der fast schwarze Editor-`bg`); die warme
        // `surface`-Tönung davor gibt ihr den Marken-Papierton.
        .background(BrandColor.surface.opacity(0.35))
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.faint.opacity(0.9))
                .frame(height: 1)
        }
    }

    /// Überlauf: selten gebrauchte Aktionen gebündelt — hält die Leiste ruhig.
    /// Die hier gebündelten Aktionen sind sonst nur über die Menüleiste
    /// erreichbar — die im nativen Vollbild aber ausgeblendet ist. Darum sitzen
    /// die im Schreibmodus wichtigen Einstiege (Einstellungen, Darstellung,
    /// Fokus, manueller Sync) zusätzlich in dieser immer sichtbaren Leiste.
    private var overflowMenu: some View {
        Menu {
            // Natives Einstellungen-Fenster (⌘,). `SettingsLink` öffnet die
            // `Settings`-Scene direkt — ohne Selector-Gefrickel.
            SettingsLink {
                Label(t("toolbar.settings"), systemImage: "gearshape")
            }

            Divider()

            Picker(t("toolbar.appearance"), selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Picker(t("menu.focus"), selection: $focus.granularity) {
                ForEach(FocusGranularity.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.inline)

            Divider()

            // Manueller Sync — sitzt bewusst neben der Sync-Status-Anzeige.
            Button(t("menu.syncNow")) { sync.syncManually() }

            Divider()

            Button(t("general.signOut")) { auth.signOut() }
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
        .help(t("toolbar.moreOptions"))
        .accessibilityLabel(t("toolbar.moreOptions"))
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
            Text(tn(words, "toolbar.words"))
            Text(t("toolbar.today", ["n": signed(wordsToday)]))
                .foregroundStyle(wordsToday > 0 ? BrandColor.muted : BrandColor.faint)
            if readingMinutes > 0 {
                Text(t("toolbar.minutes", ["n": "\(readingMinutes)"]))
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
        let heute = t("toolbar.tip.todayWords", ["n": signed(wordsToday)])
        if goal > 0 {
            let pct = "\(Int(((progress ?? 0) * 100).rounded()))"
            return t("toolbar.tip.goal", ["words": "\(words)", "goal": "\(goal)", "pct": pct, "today": heute])
        }
        return t("toolbar.tip.noGoal", ["today": heute, "min": "\(readingMinutes)"])
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
                Text(tn(conflicts, "toolbar.conflicts"))
            } else {
                switch status {
                case .syncing:
                    // Nur ein dezenter Spinner an der Stelle des Idle-Icons —
                    // kein Text, damit das ~3s-Polling die Toolbar nicht ständig
                    // umbricht/flackert. Der Tooltip nennt weiterhin den Zustand.
                    ProgressView().controlSize(.small)
                case .offline:
                    Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                    Text(t("sync.state.offline"))
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
        if conflicts > 0 { return t("toolbar.tip.conflicts") }
        if let last = lastSyncedAt {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: L10nStore.shared.localeCode)
            return t("toolbar.tip.lastSynced", ["rel": rel.localizedString(for: last, relativeTo: Date())])
        }
        return status == .offline ? t("toolbar.tip.offline") : t("toolbar.tip.notSynced")
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
