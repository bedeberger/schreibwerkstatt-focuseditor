//
//  WindowChromeController.swift
//  schreibwerkstatt-focuseditor
//
//  Fenster-Chrome des Editor-Fensters: hält die Ampel-Buttons sichtbar und
//  beobachtet den **nativen** macOS-Vollbild (grüner Button / View ▸ Vollbild).
//  Die Toolbar bleibt **immer** sichtbar — auch im Vollbild; ablenkungsfreies
//  Ausblenden macht allein die Auto-Hide-Option (Toolbar bei Inaktivität).
//
//  Bewusst KEIN `fullSizeContentView` mehr: damit lag die schwere, transparente
//  `WKWebView` über der eigenen Toolbar und verschluckte sie optisch (nur ein
//  paar Pixel der Leiste blieben sichtbar). Mit normaler Titelleiste sitzt der
//  Inhalt (Toolbar + WebView) verlässlich UNTER der Titelleiste — kein Overlap,
//  keine Z-Order-Tricks nötig. Die Ampel-Buttons stehen in der Titelleiste, die
//  eigene Leiste direkt darunter.
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

    // Beobachter für die nativen Vollbild-Notifications des Fensters.
    private var fullscreenObservers: [NSObjectProtocol] = []

    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Vom `WindowAccessor` gereicht, sobald das NSWindow existiert.
    func bind(_ window: NSWindow?) {
        guard window !== self.window else { return }
        teardownFullscreenObservers()
        self.window = window
        guard let window else { return }

        applyBaseChrome(window)

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

    /// Schaltet den nativen macOS-Vollbild um. Pendant zum grünen Ampel-Button /
    /// ⌃⌘F als Menüpunkt — die Toolbar bleibt im Vollbild sichtbar, der Rückweg
    /// in die normale Fensteransicht ist also auch über das Menü erreichbar.
    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func teardownFullscreenObservers() {
        for token in fullscreenObservers { NotificationCenter.default.removeObserver(token) }
        fullscreenObservers.removeAll()
    }

    /// Reaktion auf nativen Vollbild-Wechsel. Die Toolbar bleibt auch im Vollbild
    /// sichtbar (CLAUDE.md); beim Verlassen die Ampel-Buttons wieder einblenden.
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
