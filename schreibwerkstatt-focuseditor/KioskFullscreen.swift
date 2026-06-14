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

    private weak var window: NSWindow?

    // Gesicherter Zustand fürs Wiederherstellen beim Verlassen.
    private var savedFrame: NSRect?
    private var savedStyleMask: NSWindow.StyleMask?
    private var savedTitleVisibility: NSWindow.TitleVisibility?
    private var savedTitlebarTransparent = false
    private var escMonitor: Any?

    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Vom `WindowAccessor` gereicht, sobald das NSWindow existiert.
    func bind(_ window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
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
