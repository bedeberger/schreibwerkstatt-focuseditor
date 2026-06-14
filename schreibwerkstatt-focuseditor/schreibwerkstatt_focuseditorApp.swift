//
//  schreibwerkstatt_focuseditorApp.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI
import AppKit

@main
struct schreibwerkstatt_focuseditorApp: App {
    init() {
        // Native Fenster-Tabs komplett abschalten — und zwar VOR der ersten
        // Fenstererzeugung. Spät gesetzt (im WindowChromeController, nach
        // Fensteraufbau) installiert AppKit den „Tab-Leiste einblenden"-
        // Menüpunkt und das automatische Tabbing bereits → Tabs tauchen wieder
        // auf. Im App-`init` greift es früh genug, damit die View-Menüpunkte
        // („Tab-Leiste einblenden", „Alle Tabs zeigen", „Fenster zusammenführen")
        // gar nicht erst erscheinen. Ablenkungsfreies Schreiben auf genau einer
        // Seite (CLAUDE.md) verträgt keine Tab-Leiste.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @StateObject private var core = AppCore()
    @StateObject private var windowChrome = WindowChromeController()
    @StateObject private var appearance = AppearanceController()
    @StateObject private var focus = FocusController()
    @StateObject private var typography = TypographyController()
    @StateObject private var writingStats = WritingStatsStore()
    @StateObject private var loc = LocalizationController()
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
                .environmentObject(loc)
                .background(WindowAccessor { windowChrome.bind($0) })
                .task {
                    // Fokus- + Typografie-Controller an die app-weite Bridge
                    // koppeln (Push der Live-Umschaltung), Stats-Kanal anhängen,
                    // dann Auth/Sync hochfahren.
                    focus.bind(core.bridge)
                    typography.bind(core.bridge)
                    loc.bind(core.bridge)
                    writingStats.attach(to: core.bridge)
                    await core.bootstrap()
                }
                // Nach dem Anmelden den Server-Default der Fokus-Stufe ziehen
                // (solange lokal nichts gewählt ist). `onReceive` abonniert den
                // Publisher direkt → greift zuverlässig bei Start-mit-Token UND
                // frischem Login (der `/config`-Request braucht das Token).
                .onReceive(core.auth.$state) { state in
                    if state == .signedIn {
                        Task {
                            // Falls die Server-URL im Login geändert wurde: Stores
                            // auf den neuen Namespace umschalten, BEVOR der Sync
                            // (bzw. die Server-Seeds) loslaufen — sonst pollt er die
                            // Buch-IDs des alten Servers (→ `NO_BOOK_ACCESS`).
                            await core.switchServerIfNeeded()
                            await focus.seedFromServerIfNeeded()
                            await loc.seedFromServerIfNeeded()
                        }
                    }
                }
        }
        // Polling nur solange das Fenster aktiv ist; im Hintergrund pausieren,
        // beim Reaktivieren sofort ein Tick (CLAUDE.md, Cross-Session-Frische).
        .onChange(of: scenePhase, initial: true) { _, phase in
            core.sync.setActive(phase == .active)
        }
        .commands {
            // „Über …" — Standard-Panel mit eigenem Credits-Text: Kurzbeschreibung
            // der App + klickbare Repo-Links (Mutterprojekt + dieser Client).
            // Name/Version/Copyright zieht das Panel weiter aus der Info.plist.
            CommandGroup(replacing: .appInfo) {
                Button(t("menu.about")) {
                    AboutPanel.show()
                }
            }

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
                Picker(t("menu.appearance"), selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            // Fokus-Granularität — bestimmt, wie stark der Editor die Umgebung
            // des aktiven Absatzes abblendet. Wirkt sofort bei offenem Editor.
            CommandGroup(after: .toolbar) {
                Picker(t("menu.focus"), selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)
            }

            // Vollbild ein/aus. Eigener Menüpunkt als zuverlässiger Einstieg:
            // im Vollbild sind die Ampel-Buttons ausgeblendet; die Toolbar bleibt
            // zwar sichtbar, hat aber keinen eigenen Vollbild-Knopf.
            // Label folgt dem Zustand, damit der Rückweg klar benannt ist.
            CommandGroup(after: .toolbar) {
                Button(windowChrome.isNativeFullscreen
                       ? t("menu.exitFullscreen")
                       : t("menu.enterFullscreen")) {
                    windowChrome.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }

            // Manueller Sync (⌘S) — wirkt auch bei pausiertem/manuellem Modus.
            CommandGroup(after: .toolbar) {
                Button(t("menu.syncNow")) {
                    core.sync.syncManually()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            // Help-Menü: die Standard-„App-Hilfe" (toter Help-Book-Eintrag)
            // durch unsere Tastaturkürzel-Hilfe ersetzen (⌘?).
            CommandGroup(replacing: .help) {
                Button(t("menu.shortcuts")) {
                    openWindow(id: "shortcuts-help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Tastaturkürzel-Hilfe als eigenes, einfaches Fenster.
        Window(t("window.shortcutsTitle"), id: "shortcuts-help") {
            ShortcutsHelpView()
                .environmentObject(loc)
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
                .environmentObject(loc)
        }
    }
}

/// Eigenes „Über …"-Panel: nutzt das native macOS-About-Panel und reicht nur
/// einen Credits-Text nach (Kurzbeschreibung + klickbare Repo-Links). Name,
/// Version und Copyright kommen weiter aus der Info.plist (CFBundleName,
/// CFBundleShortVersionString, NSHumanReadableCopyright) — nicht hier doppeln.
enum AboutPanel {
    @MainActor
    static func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }

    private static var credits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6

        let s = NSMutableAttributedString()

        func line(_ text: String, font: NSFont = body) {
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .paragraphStyle: para,
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        func link(_ label: String, _ url: String) {
            s.append(NSAttributedString(string: label + "\n", attributes: [
                .font: body,
                .paragraphStyle: para,
                .link: url,
            ]))
        }

        line(t("about.tagline"), font: bold)
        line(t("about.body"))
        line(" ")
        line(t("about.motherProject"), font: bold)
        link("github.com/bedeberger/schreibwerkstatt",
             "https://github.com/bedeberger/schreibwerkstatt")

        return s
    }
}
