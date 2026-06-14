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

    /// Steuert den beschwörbaren Seiten-Picker (⌘O) im Host.
    @Binding var pickerOpen: Bool

    /// Breite der Aussparung links für die Fenster-Ampel-Buttons.
    private let trafficLightInset: CGFloat = 78

    var body: some View {
        HStack(spacing: 14) {
            BookPicker()

            if let page = library.openPageName {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BrandColor.faint)
                Text(page)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            Button { pickerOpen.toggle() } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(BrandColor.muted)
            .keyboardShortcut("o", modifiers: .command)
            .help("Seite öffnen (⌘O)")

            SyncStatusLabel(status: sync.status, conflicts: sync.conflicts.count)

            overflowMenu
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 16)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())          // leere Flächen ziehen das Fenster
        .background(BrandColor.surface)
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
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(BrandColor.muted)
        .help("Weitere Optionen")
    }
}

/// Schlanke Sync-Anzeige (Status + offene Konflikte) für die App-Toolbar.
struct SyncStatusLabel: View {
    let status: SyncEngine.Status
    let conflicts: Int

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
