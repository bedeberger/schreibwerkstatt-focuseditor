//
//  WindowChromeController.swift
//  schreibwerkstatt-focuseditor
//
//  Fenster-Chrome des Editor-Fensters: hält die Ampel-Buttons sichtbar,
//  hostet die Toolbar als natives Titelleisten-Accessory und beobachtet den
//  **nativen** macOS-Vollbild (grüner Button / View ▸ Vollbild).
//
//  Die Toolbar sitzt als `NSTitlebarAccessoryViewController` (vollbreiter
//  Streifen unter den Ampel-Buttons) im Fenster-Chrome — NICHT mehr als
//  oberste Content-Leiste. Grund: als Content-Leiste verschluckte im Vollbild
//  die auto-ausblendende System-Titelleiste die Klicks auf die Icons. Als
//  echtes Chrome-Element ist die Toolbar im Vollbild bedienbar; macOS blendet
//  sie dort samt Titelleiste automatisch aus und zeigt sie beim Hochfahren der
//  Maus wieder (gewollter ablenkungsfreier Effekt). Im Fenster bleibt sie sichtbar.
//
//  Bewusst KEIN `fullSizeContentView`: der Inhalt (WebView) sitzt verlässlich
//  UNTER Titelleiste + Accessory — kein Overlap, keine Z-Order-Tricks nötig.
//

import SwiftUI
import AppKit
import Combine

/// Verwaltet das Chrome des Editor-Fensters: Ampel-Sichtbarkeit und die
/// Reaktion auf den nativen macOS-Vollbild.
@MainActor
final class WindowChromeController: ObservableObject {
    /// True, solange das Fenster im **nativen** macOS-Vollbild ist.
    @Published private(set) var isNativeFullscreen = false

    private weak var window: NSWindow?

    /// Native Titelleisten-Toolbar (NSTitlebarAccessory): hostet die SwiftUI-
    /// `AppToolbar` im Chrome-Bereich, damit sie auch im Vollbild bedienbar ist.
    private var toolbarAccessory: NSTitlebarAccessoryViewController?

    /// Gewünschte Sichtbarkeit der Toolbar — gemerkt, falls `setToolbarVisible`
    /// feuert, BEVOR der `WindowAccessor` das Accessory installiert hat (sonst
    /// bliebe die Toolbar bei diesem Race verborgen). `installToolbar` wendet ihn an.
    private var toolbarVisible = false

    // Beobachter für die nativen Vollbild-Notifications des Fensters.
    private var fullscreenObservers: [NSObjectProtocol] = []

    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Vom `WindowAccessor` gereicht, sobald das NSWindow existiert. `toolbarHost`
    /// ist die in SwiftUI gebaute Toolbar (NSHostingView); sie wird als
    /// Titelleisten-Accessory installiert (s. `installToolbar`).
    func bind(_ window: NSWindow?, toolbarHost: NSView? = nil) {
        guard window !== self.window else { return }
        teardownFullscreenObservers()
        self.window = window
        guard let window else { return }

        applyBaseChrome(window)
        installToolbar(toolbarHost, in: window)

        let center = NotificationCenter.default
        fullscreenObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.nativeFullscreenChanged(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.nativeFullscreenChanged(false) }
            },
        ]
    }

    /// Basis-Chrome: normale (transparente, titellose) Titelleiste mit sichtbaren
    /// Ampel-Buttons — der Inhalt sitzt darunter. Idempotent (wird vom
    /// WindowAccessor mehrfach gereicht).
    private func applyBaseChrome(_ window: NSWindow) {
        // Native Fenster-Tabs: das globale Abschalten passiert früh im App-`init`
        // (sonst zu spät — Tabs/Menüpunkte sind dann schon installiert). Hier
        // pro Fenster zusätzlich das Zusammenführen in Tab-Gruppen verbieten.
        window.tabbingMode = .disallowed

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Titled-Stil OHNE fullSizeContentView: Inhalt unter der Titelleiste
        // (s. Datei-Kopf — fullSize ließ die WebView die Toolbar verdecken).
        window.styleMask.insert(.titled)
        window.styleMask.remove(.fullSizeContentView)
        for kind in Self.buttons {
            window.standardWindowButton(kind)?.isHidden = false
        }

        // Dienste-Menü entfernen — für eine Ein-Seiten-Schreib-Shell ohne
        // Selektions-/Dokumentdienste sinnlos (erst hier, das App-Menü baut
        // SwiftUI nach dem ersten Fenster auf).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.removeServicesMenu()
        }
    }

    /// Entfernt das „Dienste"/„Services"-Untermenü aus dem App-Menü. SwiftUI
    /// bietet dafür keinen `CommandGroup`, darum direkt über AppKit: die
    /// `servicesMenu`-Zuordnung lösen und den Menüpunkt (samt nun doppeltem
    /// Trenner) aus dem App-Menü ziehen. Idempotent — findet nach dem ersten
    /// Lauf nichts mehr.
    private func removeServicesMenu() {
        let services = NSApp.servicesMenu
        NSApp.servicesMenu = nil
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.submenu === services || $0.title == "Services" || $0.title == "Dienste"
              }) else { return }
        appMenu.removeItem(at: index)
        // Durch das Entfernen können zwei Trenner aufeinandertreffen → einen weg.
        if index < appMenu.items.count, appMenu.items[index].isSeparatorItem,
           index > 0, appMenu.items[index - 1].isSeparatorItem {
            appMenu.removeItem(at: index)
        }
    }

    /// Hängt die (in SwiftUI gebaute) Toolbar als Titelleisten-Accessory ins
    /// Fenster — vollbreiter Streifen direkt unter den Ampel-Buttons. Dadurch
    /// gehört sie zum Fenster-Chrome: im nativen Vollbild blendet macOS sie samt
    /// Titelleiste automatisch aus und zeigt sie beim Hochfahren der Maus wieder,
    /// und Klicks landen — anders als bei der früheren Content-Leiste — nicht
    /// mehr in der auto-ausblendenden System-Titelleiste. Startet verborgen
    /// (Login-/Ladebildschirm); `setToolbarVisible` zeigt sie, sobald der Editor da ist.
    private func installToolbar(_ host: NSView?, in window: NSWindow) {
        guard let host, toolbarAccessory == nil else { return }
        host.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: 50)   // = AppToolbar-Höhe
        host.autoresizingMask = [.width]   // volle Fensterbreite mitwachsen
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = host
        vc.isHidden = !toolbarVisible   // bereits gemeldeten Wunsch-Zustand anwenden
        window.addTitlebarAccessoryViewController(vc)
        toolbarAccessory = vc
    }

    /// Blendet das Toolbar-Accessory ein/aus (vom Editor-Host gesteuert: nur
    /// sichtbar, solange der Editor offen ist — sonst stünde im Login-/Lade-
    /// zustand ein leerer Streifen in der Titelleiste). Vor der Installation
    /// gemeldete Werte merkt sich `toolbarVisible` (s. dort).
    func setToolbarVisible(_ visible: Bool) {
        toolbarVisible = visible
        toolbarAccessory?.isHidden = !visible
    }

    /// Schaltet den nativen macOS-Vollbild um. Pendant zum grünen Ampel-Button /
    /// ⌃⌘F als Menüpunkt — im Vollbild blendet macOS die Toolbar samt Titelleiste
    /// aus (Reveal beim Hochfahren der Maus); der Rückweg ist über das Menü (oder
    /// die enthüllte Titelleiste) erreichbar.
    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func teardownFullscreenObservers() {
        for token in fullscreenObservers { NotificationCenter.default.removeObserver(token) }
        fullscreenObservers.removeAll()
    }

    /// Reaktion auf nativen Vollbild-Wechsel. Im Vollbild verwaltet macOS die
    /// Sichtbarkeit der Titelleiste (samt Toolbar-Accessory) selbst; beim
    /// Verlassen die Ampel-Buttons wieder einblenden.
    private func nativeFullscreenChanged(_ entered: Bool) {
        isNativeFullscreen = entered
        if !entered, let window {
            for kind in Self.buttons {
                window.standardWindowButton(kind)?.isHidden = false
            }
        }
    }
}

/// Reicht das umgebende `NSWindow` einer SwiftUI-View nach außen, damit der
/// AppKit-Controller es ansteuern kann. Liefert nil, solange noch nicht gehängt.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    /// Merkt sich das zuletzt gemeldete Fenster, damit `updateNSView` (feuert bei
    /// JEDER SwiftUI-Invalidierung) nur bei einem ECHTEN Fensterwechsel erneut
    /// meldet — sonst würde der Chrome-Setup (inkl. verzögerter Menü-Mutation)
    /// bei jedem Re-Render unnötig erneut angestoßen.
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { resolve(view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { resolve(nsView.window, context.coordinator) }
    }

    private func resolve(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard window !== coordinator.lastWindow else { return }
        coordinator.lastWindow = window
        onResolve(window)
    }
}
