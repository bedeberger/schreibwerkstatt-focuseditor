//
//  schreibwerkstatt_focuseditorApp.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI

@main
struct schreibwerkstatt_focuseditorApp: App {
    @StateObject private var core = AppCore()
    @StateObject private var windowChrome = WindowChromeController()
    @StateObject private var appearance = AppearanceController()
    @StateObject private var focus = FocusController()
    @StateObject private var typography = TypographyController()
    @StateObject private var writingStats = WritingStatsStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(core)
                .environmentObject(core.auth)
                .environmentObject(core.sync)
                .environmentObject(core.library)
                .environmentObject(core.editorBundle)
                .environmentObject(windowChrome)
                .environmentObject(appearance)
                .environmentObject(focus)
                .environmentObject(typography)
                .environmentObject(writingStats)
                .background(WindowAccessor { windowChrome.bind($0) })
                .task {
                    // Fokus- + Typografie-Controller an die app-weite Bridge
                    // koppeln (Push der Live-Umschaltung), Stats-Kanal anhängen,
                    // dann Auth/Sync hochfahren.
                    focus.bind(core.bridge)
                    typography.bind(core.bridge)
                    writingStats.attach(to: core.bridge)
                    await core.bootstrap()
                }
                // Nach dem Anmelden den Server-Default der Fokus-Stufe ziehen
                // (solange lokal nichts gewählt ist). `onReceive` abonniert den
                // Publisher direkt → greift zuverlässig bei Start-mit-Token UND
                // frischem Login (der `/config`-Request braucht das Token).
                .onReceive(core.auth.$state) { state in
                    if state == .signedIn {
                        Task { await focus.seedFromServerIfNeeded() }
                    }
                }
        }
        // Polling nur solange das Fenster aktiv ist; im Hintergrund pausieren,
        // beim Reaktivieren sofort ein Tick (CLAUDE.md, Cross-Session-Frische).
        .onChange(of: scenePhase, initial: true) { _, phase in
            core.sync.setActive(phase == .active)
        }
        .commands {
            // Standard-Menüpunkte entfernen, die für eine Ein-Fenster-/Ein-Seiten-
            // Schreib-Shell sinnlos sind: kein Dokumentmodell (kein „Neu"/„Sichern"),
            // kein Import/Export (Inhalte fließen nur über Sync), keine Seitenleiste.
            CommandGroup(replacing: .newItem) {}        // Neu / Neues Fenster
            CommandGroup(replacing: .saveItem) {}       // Sichern / Sichern unter…
            CommandGroup(replacing: .importExport) {}   // Import / Export
            CommandGroup(replacing: .sidebar) {}        // Seitenleiste ein-/ausblenden

            // Manueller Light/Dark/System-Umschalter. Inline-Picker rendert
            // als Menüpunkte mit Häkchen beim aktiven Modus.
            CommandGroup(after: .toolbar) {
                Picker("Darstellung", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            // Fokus-Granularität — bestimmt, wie stark der Editor die Umgebung
            // des aktiven Absatzes abblendet. Wirkt sofort bei offenem Editor.
            CommandGroup(after: .toolbar) {
                Picker("Fokus", selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)
            }

            // Vollbild ein/aus (ablenkungsfrei). Eigener Menüpunkt, weil im
            // Vollbild Toolbar UND Ampel-Buttons ausgeblendet sind → ohne
            // sichtbaren Einstieg bliebe nur die auto-versteckte Menüleiste.
            // Label folgt dem Zustand, damit der Rückweg klar benannt ist.
            CommandGroup(after: .toolbar) {
                Button(windowChrome.isNativeFullscreen
                       ? "Vollbild verlassen (Fensteransicht)"
                       : "Vollbild (ablenkungsfrei)") {
                    windowChrome.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }

            // Manueller Sync (⌘⇧S) — wirkt auch bei pausiertem/manuellem Modus.
            CommandGroup(after: .toolbar) {
                Button("Jetzt synchronisieren") {
                    core.sync.syncManually()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Help-Menü: die Standard-„App-Hilfe" (toter Help-Book-Eintrag)
            // durch unsere Tastaturkürzel-Hilfe ersetzen (⌘?).
            CommandGroup(replacing: .help) {
                Button("Tastaturkürzel") {
                    openWindow(id: "shortcuts-help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Tastaturkürzel-Hilfe als eigenes, einfaches Fenster.
        Window("Tastaturkürzel", id: "shortcuts-help") {
            ShortcutsHelpView()
        }
        .windowResizability(.contentSize)

        // Natives Einstellungen-Fenster (⌘,). Environment-Objects fließen NICHT
        // automatisch aus der WindowGroup hierher → explizit weiterreichen.
        Settings {
            SettingsView()
                .environmentObject(core)
                .environmentObject(core.auth)
                .environmentObject(core.library)
                .environmentObject(core.editorBundle)
                .environmentObject(core.sync)
                .environmentObject(appearance)
                .environmentObject(focus)
                .environmentObject(typography)
                .environmentObject(writingStats)
        }
    }
}
