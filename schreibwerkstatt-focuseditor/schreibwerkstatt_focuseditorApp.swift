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

        // Tooltip-Verzögerung verkürzen. Die SwiftUI-`.help(…)`-Tooltips hängen am
        // AppKit-`toolTip`-Mechanismus, dessen initiale Verzögerung system-weit bei
        // ~2–3 s liegt — in der schmalen Toolbar fühlt sich das träge an. Der
        // (private, aber seit Jahren stabile) Default `NSInitialToolTipDelay` steuert
        // die Verzögerung in Millisekunden; früh im App-`init` registriert greift er,
        // bevor der erste Tooltip aufgebaut wird. `register` statt `set`, damit eine
        // explizite Nutzer-/System-Einstellung Vorrang behält.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    @StateObject private var core = AppCore()
    @StateObject private var windowChrome = WindowChromeController()
    @StateObject private var appearance = AppearanceController()
    @StateObject private var focus = FocusController()
    @StateObject private var typography = TypographyController()
    @StateObject private var writingStats = WritingStatsStore()
    @StateObject private var loc = LocalizationController()
    @StateObject private var updater = UpdaterController()
    /// Geteilter UI-Zustand zwischen Editor-Host und der im Titelleisten-Accessory
    /// gehosteten Toolbar (Seiten-Picker + Konflikt-Sheet).
    @StateObject private var toolbarUI = ToolbarUIState()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    /// Baut die SwiftUI-`AppToolbar` als AppKit-`NSView` für das Titelleisten-
    /// Accessory. Die App-`@StateObject`s sind hier direkt greifbar und werden
    /// dem isolierten Hosting-Baum als Environment mitgegeben — über die
    /// SwiftUI↔AppKit-Grenze fließen sie sonst NICHT (anders als im normalen
    /// View-Baum der WindowGroup). `windowChrome` braucht die Toolbar nicht mehr.
    @MainActor
    private func makeToolbarHost() -> NSView {
        let root = AppToolbar()
            .environmentObject(core.auth)
            .environmentObject(core.sync)
            .environmentObject(core.library)
            .environmentObject(appearance)
            .environmentObject(focus)
            .environmentObject(writingStats)
            .environmentObject(core.writingTime)
            .environmentObject(toolbarUI)
            .environmentObject(loc)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 50)   // Höhe = AppToolbar.frame(height:)
        host.autoresizingMask = [.width]
        return host
    }

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
                .environmentObject(toolbarUI)
                .background(WindowAccessor { window in
                    windowChrome.bind(window, toolbarHost: makeToolbarHost())
                })
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
            // Schreibzeit zählt nur im aktiven Fenster (wie der Sync-Poll).
            core.writingTime.setActive(phase == .active)
        }
        .commands {
            // „Über …" — Standard-Panel mit eigenem Credits-Text: Kurzbeschreibung
            // der App + klickbare Repo-Links (Mutterprojekt + dieser Client).
            // Name/Version/Copyright zieht das Panel weiter aus der Info.plist.
            // „Über …" plus „Nach Updates suchen…" in derselben App-Menü-Sektion
            // (Standard-Platz direkt unter „Über …"). Beides in EINER CommandGroup,
            // weil der @CommandsBuilder nur 10 Top-Level-Gruppen fasst.
            // `disabled`, solange Sparkle keinen Check zulässt (z. B. während schon
            // einer läuft); Hintergrund-Checks laufen unabhängig (SUEnableAutomaticChecks).
            CommandGroup(replacing: .appInfo) {
                Button(t("menu.about")) {
                    AboutPanel.show()
                }
                Button(t("menu.checkForUpdates")) {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                // Abmelden im App-Menü (Konto-Aktion) — bisher nur im Toolbar-
                // Überlauf. Eigene Sektion, damit es nicht mit „Über …" verschmilzt.
                Divider()
                Button(t("general.signOut")) {
                    core.auth.signOut()
                }
            }

            // „Neu/Neues Fenster" ergibt für eine Ein-Seiten-Schreib-Shell keinen
            // Sinn (kein Dokumentmodell). Die Gruppe stattdessen mit der Seiten-/
            // Buch-Navigation belegen, die sonst nur in der Toolbar sitzt — so ist
            // sie auch über die Menüleiste erreichbar (mit sichtbarem ⌘O). Eigene
            // View, weil die Buchliste/„Seite schliessen"-Aktivierung mitlaufen
            // muss (`AppCore.library` ist ein `let` und republiziert nicht selbst).
            CommandGroup(replacing: .newItem) {
                PageMenuCommands(library: core.library, sync: core.sync)
            }
            CommandGroup(replacing: .saveItem) {}       // Sichern / Sichern unter…
            CommandGroup(replacing: .importExport) {}   // Import / Export
            CommandGroup(replacing: .sidebar) {}        // Seitenleiste ein-/ausblenden

            // Format-Menü (Edit-Menü, nach Ausschneiden/Kopieren/Einfügen): die
            // Inline-Formatierung des Editors (Fett/Kursiv/Unterstrichen) auch über
            // die Menüleiste, mit sichtbaren ⌘B/⌘I/⌘U. Die Befehle laufen über die
            // Bridge (`applyFormat` → `document.execCommand`) — dieselbe Wirkung wie
            // die nativen contenteditable-Shortcuts, nur jetzt menü-getrieben (das
            // Menü fängt das Tastenkürzel vor der WebView ab, darum MUSS die Aktion
            // selbst formatieren). Eigene View für die reaktive „kein-Seite"-Sperre.
            CommandGroup(after: .pasteboard) {
                FormatMenuCommands(library: core.library, bridge: core.bridge)
            }

            // Alle „Darstellung/Editor"-Menüpunkte in EINER Gruppe (nach `.toolbar`):
            // Darstellung, Fokus und Vollbild. Bewusst gebündelt — der
            // @CommandsBuilder fasst nur 10 Top-Level-Gruppen; Divider erhalten
            // die optische Trennung wie zuvor. (Manueller Sync sitzt im Ablage-
            // Menü bei der Seiten-Navigation, s. `PageMenuCommands`.)
            CommandGroup(after: .toolbar) {
                // Manueller Light/Dark/System-Umschalter. Inline-Picker rendert
                // als Menüpunkte mit Häkchen beim aktiven Modus.
                Picker(t("menu.appearance"), selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // Fokus-Granularität — bestimmt, wie stark der Editor die Umgebung
                // des aktiven Absatzes abblendet. Wirkt sofort bei offenem Editor.
                Picker(t("menu.focus"), selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // Vollbild ein/aus. Eigener Menüpunkt als zuverlässiger Einstieg:
                // im Vollbild blendet macOS Ampel-Buttons und Titelleiste (samt
                // Toolbar) aus — ein Menüpunkt ist der verlässliche Rückweg.
                // Label folgt dem Zustand, damit der Rückweg klar benannt ist.
                Button(windowChrome.isNativeFullscreen
                       ? t("menu.exitFullscreen")
                       : t("menu.enterFullscreen")) {
                    windowChrome.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
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
                .environmentObject(updater)
        }
    }
}

/// Ablage-Menü-Befehle: Seiten- und Buch-Navigation (sonst nur in der Toolbar)
/// auch über die Menüleiste, mit sichtbarem ⌘O. Eigene View mit `@ObservedObject`,
/// damit die Buchliste und die „Seite schliessen"-Aktivierung live mitlaufen —
/// der `@CommandsBuilder` im `App`-Scope bekäme sonst keine Änderungs-Pushes vom
/// `LibraryStore` (in `AppCore` nur ein `let`).
private struct PageMenuCommands: View {
    @ObservedObject var library: LibraryStore
    let sync: SyncEngine

    var body: some View {
        Button(t("menu.openPage")) {
            library.requestPicker()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button(t("menu.closePage")) {
            library.closePage()
        }
        .disabled(library.openPageId == nil)

        Divider()

        // Manueller Sync (⌘S) — wirkt auch bei pausiertem/manuellem Modus.
        // ⌘S ist in den meisten Apps „Speichern": `syncManually()` flusht
        // darum zuerst den offenen Draft in den LocalStore und stösst erst
        // danach Push/Pull an → ⌘S speichert UND synchronisiert. Sitzt im
        // Ablage-Menü, weil „Speichern/Synchronisieren" dorthin gehört.
        Button(t("menu.syncNow")) {
            sync.syncManually()
        }
        .keyboardShortcut("s", modifiers: .command)

        Divider()

        Menu(t("menu.book")) {
            if library.books.isEmpty {
                Text(t("library.noBooks"))
            } else {
                ForEach(library.books, id: \.id) { book in
                    Button {
                        library.selectBook(book.id)
                    } label: {
                        let name = book.name ?? t("library.bookFallback", ["id": "\(book.id)"])
                        if book.id == library.activeBookId {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        }
    }
}

/// Format-Menü-Befehle: die Inline-Formatierung des Editors (Fett/Kursiv/
/// Unterstrichen) über die Menüleiste, mit ⌘B/⌘I/⌘U. Die Aktion routet über die
/// Bridge in die WebView (`document.execCommand`) — dieselbe Wirkung wie die
/// nativen contenteditable-Shortcuts. Da das Menü das Tastenkürzel VOR der
/// WebView abfängt, muss die Aktion selbst formatieren. `@ObservedObject library`
/// nur für die reaktive Sperre, solange keine Seite offen ist.
private struct FormatMenuCommands: View {
    @ObservedObject var library: LibraryStore
    let bridge: EditorBridge

    var body: some View {
        Button(t("menu.bold")) { apply("bold") }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(library.openPageId == nil)
        Button(t("menu.italic")) { apply("italic") }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(library.openPageId == nil)
        Button(t("menu.underline")) { apply("underline") }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(library.openPageId == nil)
    }

    private func apply(_ command: String) {
        Task { await bridge.applyFormat(command) }
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
