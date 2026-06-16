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
    @EnvironmentObject private var writingStats: WritingStatsStore
    @EnvironmentObject private var windowChrome: WindowChromeController

    /// Steuert den beschwörbaren Seiten-Picker (⌘O) im Host.
    @Binding var pickerOpen: Bool

    /// Öffnet die Konflikt-Auflösungs-Ansicht im Host (Sheet).
    var onInspectConflict: (SyncEngine.Conflict) -> Void = { _ in }

    /// Hover-Zustand des Überlauf-Menüs (Material-Highlight).
    @State private var overflowHover = false

    /// Gemessene Breite der Leiste — treibt das responsive Zusammenfalten des
    /// Breadcrumbs auf schmalen Fenstern (s. `showChapter`).
    @State private var toolbarWidth: CGFloat = 0

    /// Das Kapitel-Segment des Breadcrumbs nur zeigen, wenn die Leiste breit
    /// genug ist — sonst kollidiert es auf schmalen Fenstern mit dem
    /// Status-Cluster und wird hart abgeschnitten. Der Seitenname (wichtiger)
    /// bleibt immer. `0` = noch nicht gemessen → zunächst zeigen.
    private var showChapter: Bool { toolbarWidth == 0 || toolbarWidth >= 900 }

    var body: some View {
        HStack(spacing: 14) {
            BookPicker()

            if showChapter, let chapter = library.openChapterName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                Text(chapter)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
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

            // ⌘O liegt am Menübefehl „Seite öffnen" (Ablage) — die kanonische,
            // im Menü sichtbare Stelle. Hier nur der Klick-Einstieg, kein zweiter
            // (kollidierender) Shortcut.
            ToolbarIconButton(systemName: "doc.text.magnifyingglass",
                              help: t("toolbar.openPageHelp"),
                              accessibilityLabel: t("toolbar.openPage")) {
                pickerOpen.toggle()
            }

            // Seite schliessen — nur sichtbar, wenn eine Seite offen ist. Schliesst
            // die Seite (lokal gesichert) und öffnet den Picker für die nächste Wahl.
            if library.openPageId != nil {
                ToolbarIconButton(systemName: "xmark",
                                  help: t("toolbar.closePageHelp"),
                                  accessibilityLabel: t("toolbar.closePage")) {
                    library.closePage()
                }
            }

            // ── Status-Cluster (rechts) — von den Navigations-/Aktionselementen
            // durch einen feinen Trenner abgesetzt: links „wo bin ich / was tue
            // ich", rechts „Zustand" (gesichert / Wörter / Sync). Save-Indikator
            // und Schreibstatistik beziehen sich auf die offene Seite — ohne Seite
            // sind sie sinnlos („0 Wörter") und bleiben darum ausgeblendet; nur der
            // (globale) Sync-Status steht dann rechts. Der Trenner erscheint nur,
            // wenn links davon ein seitenbezogenes Element sitzt.
            if library.openPageId != nil {
                ToolbarSeparator()

                SaveStateLabel(dirty: library.openPageDirty)

                if writingStats.showStats {
                    WritingStatsLabel(words: writingStats.words,
                                      wordsToday: writingStats.wordsToday,
                                      readingMinutes: writingStats.readingMinutes,
                                      goal: writingStats.pageGoalWords,
                                      progress: writingStats.goalProgress)
                }
            }

            SyncStatusLabel(status: sync.status,
                            conflicts: sync.conflicts,
                            lastSyncedAt: sync.lastSyncedAt,
                            onInspect: onInspectConflict)

            // Fokus-Stufe + Darstellung direkt in der Leiste (statt zwei Klicks
            // tief im Überlauf): immer sichtbar — auch im nativen Vollbild, wo die
            // Menüleiste weg ist. Direktwahl per Inline-Picker mit Häkchen.
            FocusMenuButton()
            AppearanceMenuButton()

            overflowMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        // Breite messen (treibt `showChapter`); Color.clear ist unsichtbar.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ToolbarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ToolbarWidthKey.self) { toolbarWidth = $0 }
        // Im Vollbild auch den Leisten-INHALT (Icons, Breadcrumb, Status) dezent
        // durchscheinen lassen — nicht nur den Hintergrund. Die Deckkraft sitzt
        // VOR den Hintergrund-Ebenen, fadet also nur den Vordergrund; die
        // Materialschicht behält ihre eigene (ohnehin schon niedrige) Opazität.
        .opacity(windowChrome.isNativeFullscreen ? 0.55 : 1)
        .background(WindowDragArea())          // leere Flächen ziehen das Fenster
        // Sichtbar abgesetzte Leiste: `.regularMaterial` ist das eigentlich
        // sichtbare, klar vom Editor abgehobene Frosted-Panel (im Dark Mode
        // deutlich heller als der fast schwarze Editor-`bg`); die warme
        // `surface`-Tönung davor gibt ihr den Marken-Papierton.
        // Im (nativen) Vollbild stark zurückgenommen — dünnstes Material + nur
        // ein Hauch Tönung, damit der Editor klar durchscheint und die Leiste
        // kaum noch als Block über dem ablenkungsfreien Schreiben sitzt.
        .background(BrandColor.surface.opacity(windowChrome.isNativeFullscreen ? 0.06 : 0.35))
        .background(windowChrome.isNativeFullscreen ? AnyShapeStyle(.ultraThinMaterial)
                                                    : AnyShapeStyle(.regularMaterial))
        .overlay(alignment: .bottom) {
            Rectangle()
                // Trennlinie im Vollbild fast unsichtbar — sonst bleibt sie als
                // harte Kante über der durchscheinenden Leiste stehen.
                .fill(BrandColor.faint.opacity(windowChrome.isNativeFullscreen ? 0.25 : 0.9))
                .frame(height: 1)
        }
    }

    /// Überlauf: selten gebrauchte Aktionen gebündelt — hält die Leiste ruhig.
    /// Darstellung + Fokus sitzen jetzt als eigene Inline-Knöpfe in der Leiste
    /// (direkt erreichbar, auch im Vollbild) — der Überlauf trägt nur noch die
    /// selten gebrauchten Einstiege (Einstellungen, manueller Sync, Abmelden).
    private var overflowMenu: some View {
        Menu {
            // Natives Einstellungen-Fenster (⌘,). `SettingsLink` öffnet die
            // `Settings`-Scene direkt — ohne Selector-Gefrickel.
            SettingsLink {
                Label(t("toolbar.settings"), systemImage: "gearshape")
            }

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

/// Feiner vertikaler Trenner — gruppiert den Status-Cluster (rechts) optisch
/// gegen die Navigation/Aktionen und gibt der sonst flachen, gleich-lauten Reihe
/// eine Hierarchie.
private struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(BrandColor.faint.opacity(0.7))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

/// Misst die Breite der Toolbar — Quelle für das responsive Zusammenfalten des
/// Breadcrumbs (`AppToolbar.showChapter`).
private struct ToolbarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Inline-Knopf für die Fokus-Stufe (Direktwahl per Häkchen-Picker). Sitzt fest
/// in der Leiste, damit die häufig gewechselte Einstellung auch im Vollbild ohne
/// Umweg übers Menü erreichbar bleibt. Stiltreu zum `ToolbarIconButton`.
private struct FocusMenuButton: View {
    @EnvironmentObject private var focus: FocusController
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker(t("menu.focus"), selection: $focus.granularity) {
                ForEach(FocusGranularity.allCases) { g in
                    Text(g.label).tag(g)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "scope")
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? BrandColor.faint.opacity(0.25) : .clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(t("toolbar.focusControlHelp"))
        .accessibilityLabel(t("toolbar.focusControl"))
    }
}

/// Inline-Knopf für Hell/Dunkel/System (Direktwahl per Häkchen-Picker). Das Icon
/// spiegelt den aktiven Modus, damit der Zustand ohne Öffnen ablesbar ist.
private struct AppearanceMenuButton: View {
    @EnvironmentObject private var appearance: AppearanceController
    @State private var hovering = false

    private var icon: String {
        switch appearance.mode {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var body: some View {
        Menu {
            Picker(t("menu.appearance"), selection: $appearance.mode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(BrandColor.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? BrandColor.faint.opacity(0.25) : .clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(t("toolbar.appearanceHelp"))
        .accessibilityLabel(t("toolbar.appearance"))
    }
}

/// Lokaler Save-Zustand der offenen Seite (local-first) — bewusst getrennt vom
/// Server-Sync (`SyncStatusLabel`). Beantwortet die für eine Offline-Schreib-App
/// zentrale Frage „ist mein Text sicher?": `dirty` = Änderung offen, wird gleich
/// automatisch lokal gesichert; sonst = lokal gesichert. Sehr dezent (Icon +
/// Tooltip), um beim Schreiben nicht abzulenken.
struct SaveStateLabel: View {
    let dirty: Bool

    var body: some View {
        Image(systemName: dirty ? "circlebadge.fill" : "checkmark")
            .font(.system(size: dirty ? 9 : 11, weight: .semibold))
            // Offene Änderung → Marken-Gold (es passiert gleich etwas);
            // gesichert → ruhig zurückgenommen.
            .foregroundStyle(dirty ? BrandColor.accent : BrandColor.faint)
            .frame(width: 16)
            .help(dirty ? t("save.tip.dirty") : t("save.tip.saved"))
            .accessibilityLabel(dirty ? t("save.dirty") : t("save.saved"))
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
                    // Ziel erreicht → Marken-Gold (Akzent) statt generischem Grün;
                    // darunter dezent gedämpft.
                    .tint(progress >= 1 ? BrandColor.accent : BrandColor.muted)
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
    let conflicts: [SyncEngine.Conflict]
    let lastSyncedAt: Date?
    /// Öffnet die Konflikt-Auflösungs-Ansicht (Nebeneinander-Diff) für eine Seite.
    /// Die eigentliche lokal/server-Wahl trifft der Nutzer dort informiert.
    var onInspect: (SyncEngine.Conflict) -> Void = { _ in }

    /// Reservierter Mindest-Slot: hält die Nachbarn (Fokus-/Darstellungs-Knopf,
    /// Überlauf) ruhig, wenn der häufige idle↔syncing-Wechsel kurz den Spinner
    /// einblendet. Bemessen am Spinner; die selteneren, anhaltenden Text-Zustände
    /// (offline / „Server nicht erreichbar") dürfen ihn nach links überschreiten.
    private static let slotWidth: CGFloat = 22

    var body: some View {
        Group {
            if !conflicts.isEmpty {
                conflictMenu
            } else if status == .idle {
                // „Alles ok" zeigt bewusst NICHTS — kein Dauer-Häkchen (weniger
                // Chrome). Nur syncing/offline/Fehler/Konflikte sind sichtbar.
                Color.clear.frame(width: 0, height: 0)
            } else {
                statusLabel
            }
        }
        .frame(minWidth: Self.slotWidth, alignment: .trailing)
    }

    /// Klickbares Konflikt-Menü: pro betroffener Seite öffnet ein Klick die
    /// Auflösungs-Ansicht (Nebeneinander-Diff) — statt blinder lokal/server-Wahl.
    private var conflictMenu: some View {
        Menu {
            ForEach(conflicts) { c in
                Button(t("conflict.inspect", ["page": c.pageName ?? c.pageId])) {
                    // macOS-SwiftUI: ein `.sheet` direkt aus der Menu-Aktion heraus
                    // präsentieren schlägt fehl (das schließende NSMenu schluckt das
                    // Event) — darum einen Runloop-Tick verschieben.
                    DispatchQueue.main.async { onInspect(c) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(tn(conflicts.count, "toolbar.conflicts"))
            }
            .font(BrandFont.sans(11))
            .foregroundStyle(BrandColor.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(t("toolbar.tip.conflicts"))
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            switch status {
            case .syncing:
                // Nur ein dezenter Spinner an der Stelle des Idle-Icons —
                // kein Text, damit das ~3s-Polling die Toolbar nicht ständig
                // umbricht/flackert. Der Tooltip nennt weiterhin den Zustand.
                ProgressView().controlSize(.small)
            case .offline:
                Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                Text(t("sync.state.offline"))
            case .serverUnreachable:
                // Netz da, aber Server antwortet nicht — deutlich (orange)
                // anzeigen, damit es nicht wie ein sauberer Sync-Zustand wirkt.
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                Text(t("sync.state.serverUnreachable"))
            case .idle:
                // Wird via `body` nie erreicht (idle = unsichtbar); nur für die
                // Vollständigkeit des Switch.
                EmptyView()
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .help(tooltip)
    }

    /// „Zuletzt synchronisiert“ als relative Zeit, sonst der aktuelle Zustand.
    private var tooltip: String {
        // Server-Unerreichbarkeit ist ein aktiver Fehlerzustand — auch wenn früher
        // schon einmal erfolgreich synchronisiert wurde, geht sie der „zuletzt
        // synchronisiert"-Meldung vor.
        if status == .serverUnreachable { return t("toolbar.tip.serverUnreachable") }
        if status == .offline { return t("toolbar.tip.offline") }
        if let last = lastSyncedAt {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: L10nStore.shared.localeCode)
            return t("toolbar.tip.lastSynced", ["rel": rel.localizedString(for: last, relativeTo: Date())])
        }
        return t("toolbar.tip.notSynced")
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
