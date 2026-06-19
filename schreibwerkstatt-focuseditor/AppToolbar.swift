//
//  AppToolbar.swift
//  schreibwerkstatt-focuseditor
//
//  Eigene, markengerechte Toolbar-Leiste — eine schlanke Papier-Leiste mit
//  feiner Trennlinie. Sie wird als natives Titelleisten-Accessory gehostet
//  (s. `WindowChromeController`), als vollbreiter Streifen direkt unter den
//  Ampel-Buttons — NICHT mehr als oberste Content-Leiste (das verschluckte im
//  Vollbild die Klicks auf die Icons). Geteilter Zustand mit dem Editor-Host
//  läuft über `ToolbarUIState` (getrennte SwiftUI-Bäume über die AppKit-Grenze).
//
//  Inhalt: Buch-Picker (links), Öffnen (⌘O), Sync-Status und ein Überlauf-Menü
//  rechts. Im Fenster immer sichtbar; im Vollbild blendet macOS sie samt
//  Titelleiste aus und zeigt sie beim Hochfahren der Maus wieder.
//
//  Diese Datei trägt die Shell (`ToolbarUIState` + `AppToolbar`); die Sub-Views
//  liegen ausgelagert: Bedien-Elemente in `AppToolbar+Controls.swift`, der
//  Status-Cluster (Save/Stats/Sync) in `AppToolbar+Status.swift`.
//

import SwiftUI
import AppKit
import Combine

/// Geteilter UI-Zustand der Toolbar, seit sie als natives Titelleisten-Accessory
/// (statt als Content-Leiste) gehostet wird: Der Editor-Host und die im
/// `NSTitlebarAccessoryViewController` gehostete `AppToolbar` leben in getrennten
/// SwiftUI-Bäumen — gemeinsamer Zustand (offener Seiten-Picker, zu prüfender
/// Konflikt) läuft darum über dieses geteilte ObservableObject statt über
/// `@State`/`@Binding`.
@MainActor
final class ToolbarUIState: ObservableObject {
    /// Sichtbarkeit des beschwörbaren Seiten-Pickers (⌘O).
    @Published var pickerOpen = false
    /// Aktuell im Auflösungs-Sheet geprüfter Konflikt (`nil` = zu).
    @Published var inspectingConflict: SyncEngine.Conflict?
}

struct AppToolbar: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var writingStats: WritingStatsStore
    /// Geteilter UI-Zustand mit dem Editor-Host (Seiten-Picker + Konflikt-Sheet) —
    /// nötig, weil die Toolbar jetzt in einem eigenen, vom Host getrennten
    /// SwiftUI-Baum (Titelleisten-Accessory) lebt.
    @EnvironmentObject private var toolbarUI: ToolbarUIState

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
                    .accessibilityHidden(true)   // dekorativer Breadcrumb-Trenner
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
                    .accessibilityHidden(true)   // dekorativer Breadcrumb-Trenner
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
                toolbarUI.pickerOpen.toggle()
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
                                      characters: writingStats.characters,
                                      wordsToday: writingStats.wordsToday,
                                      charactersToday: writingStats.charactersToday,
                                      readingMinutes: writingStats.readingMinutes,
                                      goal: writingStats.pageGoalWords,
                                      progress: writingStats.goalProgress)
                }
            }

            SyncStatusLabel(status: sync.status,
                            conflicts: sync.conflicts,
                            lastSyncedAt: sync.lastSyncedAt,
                            onInspect: { toolbarUI.inspectingConflict = $0 })

            // Fokus-Stufe + Darstellung direkt in der Leiste (statt zwei Klicks
            // tief im Überlauf): immer sichtbar — auch im nativen Vollbild, wo die
            // Menüleiste weg ist. Direktwahl per Inline-Picker mit Häkchen.
            FocusMenuButton()
            AppearanceMenuButton()

            overflowMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        // Pfeil-Cursor über der ganzen Leiste erzwingen — sonst drückt die
        // darunterliegende Editor-WebView am unteren Rand ihren I-Beam durch
        // (sichtbar, wenn man von der Schreibfläche hochfährt). An die View
        // gebunden, daher zuverlässiger als ein transientes `NSCursor.set()`.
        .pointerStyle(.default)
        // Breite messen (treibt `showChapter`); Color.clear ist unsichtbar.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ToolbarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ToolbarWidthKey.self) { toolbarWidth = $0 }
        // Leere Flächen ziehen das Fenster (auch im Titelleisten-Accessory).
        .background(WindowDragArea())
        // Nur eine dezente Marken-Papier-Tönung — KEIN `.regularMaterial`-Frosted
        // mehr: die Toolbar sitzt jetzt im nativen Titelleisten-Bereich
        // (NSTitlebarAccessory), der schon eine eigene Vibrancy mitbringt; eine
        // zweite Materialschicht wirkte doppelt/zu schwer. Im Vollbild blendet
        // macOS die Leiste samt Titelleiste automatisch aus.
        .background(BrandColor.surface.opacity(0.35))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.faint.opacity(0.9))
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
