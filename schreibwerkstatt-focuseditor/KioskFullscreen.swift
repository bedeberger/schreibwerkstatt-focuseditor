//
//  KioskFullscreen.swift
//  schreibwerkstatt-focuseditor
//
//  Ablenkungsfreier Vollbild: Menüleiste UND Dock komplett ausgeblendet
//  (kein Einblenden beim Hovern an den Bildschirmrand), Titelleiste/Ampel weg,
//  Fenster deckt den ganzen Screen. Bewusst NICHT der native macOS-Vollbild
//  (eigener Space, Menüleiste klappt beim Hovern aus) — hier geht es um pures
//  Schreiben auf genau einer Seite (CLAUDE.md, „ablenkungsfreies Schreiben").
//

import SwiftUI
import AppKit
import Combine

/// Steuert den kiosk-artigen Vollbildmodus eines Fensters. Hält den
/// vorherigen Fenster-Zustand fest, um ihn beim Verlassen wiederherzustellen.
@MainActor
final class KioskFullscreen: ObservableObject {
    @Published private(set) var isActive = false
    /// True, solange das Fenster im **nativen** macOS-Vollbild ist. Steuert das
    /// Ausblenden der Toolbar (ablenkungsfrei) in `ContentView`.
    @Published private(set) var isNativeFullscreen = false

    private weak var window: NSWindow?

    // Gesicherter Zustand fürs Wiederherstellen beim Verlassen.
    private var savedFrame: NSRect?
    private var savedStyleMask: NSWindow.StyleMask?
    private var savedTitleVisibility: NSWindow.TitleVisibility?
    private var savedTitlebarTransparent = false
    private var escMonitor: Any?

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

        // Nativer Vollbild (grüner Button / View ▸ Vollbild) soll sofort den
        // ablenkungsfreien Modus auslösen: Ampel-Buttons weg, Toolbar aus.
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

    /// Basis-Chrome des normalen Fensters: randloser Inhalt bis ganz nach oben,
    /// transparente/leere Titelleiste — die eigene `AppToolbar` sitzt direkt
    /// unter den Ampel-Buttons. Idempotent (wird vom WindowAccessor mehrfach
    /// gereicht); die Ampel-Buttons bleiben sichtbar.
    private func applyBaseChrome(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }

    private func teardownFullscreenObservers() {
        for token in fullscreenObservers { NotificationCenter.default.removeObserver(token) }
        fullscreenObservers.removeAll()
    }

    /// Reaktion auf nativen Vollbild-Wechsel: Ampel-Buttons aus-/einblenden und
    /// Flag setzen, das die Toolbar in der SwiftUI-Hierarchie versteckt.
    private func nativeFullscreenChanged(_ entered: Bool) {
        if let window {
            for kind in Self.buttons {
                window.standardWindowButton(kind)?.isHidden = entered
            }
        }
        isNativeFullscreen = entered
    }

    func toggle() {
        isActive ? exit() : enter()
    }

    func enter() {
        guard !isActive, let window, let screen = window.screen ?? NSScreen.main else { return }

        savedFrame = window.frame
        savedStyleMask = window.styleMask
        savedTitleVisibility = window.titleVisibility
        savedTitlebarTransparent = window.titlebarAppearsTransparent

        // Titelleiste + Ampel-Buttons verstecken, Inhalt bis ganz nach oben.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        for kind in Self.buttons {
            window.standardWindowButton(kind)?.isHidden = true
        }

        // Menüleiste + Dock vollständig aus — kein Einblenden beim Hovern.
        // (`.hideMenuBar` ist nur zusammen mit `.hideDock` zulässig.)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        // Fenster deckt den ganzen Screen (inkl. Menüleisten-Bereich).
        window.setFrame(screen.frame, display: true)

        // Escape verlässt den Modus — es gibt keine sichtbare Menüleiste mehr.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // 53 = Escape
            self?.exit()
            return nil
        }

        isActive = true
    }

    func exit() {
        guard isActive, let window else { return }

        NSApp.presentationOptions = []

        if let mask = savedStyleMask { window.styleMask = mask }
        if let vis = savedTitleVisibility { window.titleVisibility = vis }
        window.titlebarAppearsTransparent = savedTitlebarTransparent
        for kind in Self.buttons {
            window.standardWindowButton(kind)?.isHidden = false
        }
        if let frame = savedFrame { window.setFrame(frame, display: true) }

        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }

        isActive = false
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
