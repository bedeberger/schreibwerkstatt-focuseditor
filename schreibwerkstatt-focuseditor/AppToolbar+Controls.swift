//
//  AppToolbar+Controls.swift
//  schreibwerkstatt-focuseditor
//
//  Bedien-Elemente der `AppToolbar`: der generische Ikon-Knopf, der vertikale
//  Trenner, der Breiten-PreferenceKey, die Inline-Knöpfe für Fokus-Stufe und
//  Darstellung sowie die Fenster-Ziehfläche. Ausgelagert aus `AppToolbar.swift`,
//  damit die Shell-Datei schlank bleibt.
//

import SwiftUI
import AppKit

/// Ikon-Knopf der Toolbar mit dezentem Hover-Highlight (rundet die Fläche auf
/// und tönt sie) — gibt den sonst reaktionslosen `.plain`-Buttons natives
/// Feedback. Tooltip und VoiceOver-Label getrennt gesetzt.
struct ToolbarIconButton: View {
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
                // Hover-Highlight sanft ein-/ausblenden statt hart umschalten.
                .animation(.easeOut(duration: 0.12), value: hovering)
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
struct ToolbarSeparator: View {
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
struct ToolbarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Inline-Knopf für die Fokus-Stufe (Direktwahl per Häkchen-Picker). Sitzt fest
/// in der Leiste, damit die häufig gewechselte Einstellung auch im Vollbild ohne
/// Umweg übers Menü erreichbar bleibt. Stiltreu zum `ToolbarIconButton`.
struct FocusMenuButton: View {
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
                .animation(.easeOut(duration: 0.12), value: hovering)
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
struct AppearanceMenuButton: View {
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
                // Moderner Symbol-Wechsel beim Umschalten Hell/Dunkel/System.
                .contentTransition(.symbolEffect(.replace))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? BrandColor.faint.opacity(0.25) : .clear)
                )
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeInOut(duration: 0.2), value: icon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(t("toolbar.appearanceHelp"))
        .accessibilityLabel(t("toolbar.appearance"))
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
