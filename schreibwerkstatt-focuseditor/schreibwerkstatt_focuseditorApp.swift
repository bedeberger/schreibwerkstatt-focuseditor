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
    @StateObject private var fullscreen = KioskFullscreen()
    @StateObject private var appearance = AppearanceController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(core)
                .environmentObject(core.auth)
                .environmentObject(core.sync)
                .environmentObject(core.library)
                .environmentObject(core.editorBundle)
                .environmentObject(fullscreen)
                .environmentObject(appearance)
                .background(WindowAccessor { fullscreen.bind($0) })
                .task { await core.bootstrap() }
        }
        // Polling nur solange das Fenster aktiv ist; im Hintergrund pausieren,
        // beim Reaktivieren sofort ein Tick (CLAUDE.md, Cross-Session-Frische).
        .onChange(of: scenePhase, initial: true) { _, phase in
            core.sync.setActive(phase == .active)
        }
        .commands {
            // Ablenkungsfreier Vollbild per ⌘⌃F (Menüleiste/Dock komplett aus);
            // Escape verlässt ihn ebenfalls (KioskFullscreen).
            CommandGroup(after: .windowArrangement) {
                Button(fullscreen.isActive ? "Ablenkungsfreien Vollbild verlassen"
                                           : "Ablenkungsfreier Vollbild") {
                    fullscreen.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }

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
        }
    }
}
