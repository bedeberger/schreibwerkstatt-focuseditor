//
//  WindowChromeController.swift
//  schreibwerkstatt-focuseditor
//
//  Fenster-Chrome des randlosen Fensters: hält die Ampel-Buttons trotz
//  `fullSizeContentView` sichtbar (über dem Content), misst ihren Einzug für die
//  eigene Toolbar und beobachtet den **nativen** macOS-Vollbild (grüner Button /
//  View ▸ Vollbild). Im nativen Vollbild blendet die Shell die Toolbar aus →
//  ablenkungsfreies Schreiben (CLAUDE.md). Bewusst KEIN eigener Kiosk-Modus mehr.
//

import SwiftUI
import AppKit
import Combine

/// Verwaltet das Chrome des Editor-Fensters: Ampel-Sichtbarkeit/-Einzug und die
/// Reaktion auf den nativen macOS-Vollbild.
@MainActor
final class WindowChromeController: ObservableObject {
    /// True, solange das Fenster im **nativen** macOS-Vollbild ist. Steuert das
    /// Ausblenden der Toolbar (ablenkungsfrei) in `ContentView`.
    @Published private(set) var isNativeFullscreen = false
    /// Linker Einzug der `AppToolbar`, damit ihr Inhalt rechts neben den
    /// Ampel-Buttons beginnt. Aus der echten Button-Geometrie gelesen (statt
    /// fester Magic-Number) → robust gegen System-/Größenänderungen. Der
    /// Default greift, solange das Fenster noch nicht vermessen ist.
    @Published private(set) var trafficLightInset: CGFloat = 78

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
            // Resize/Key-Wechsel bauen das SwiftUI-Hosting-View neu auf und legen
            // es wieder über die Titelleiste → Ampeln erneut nach vorne holen.
            center.addObserver(forName: NSWindow.didResizeNotification,
                               object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.reassertTitlebarIfNormal(window) } }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                               object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.reassertTitlebarIfNormal(window) } }
            },
        ]
    }

    /// Ampeln nur im normalen Fenster wieder nach vorne holen — im nativen
    /// Vollbild sollen sie ausgeblendet bleiben.
    private func reassertTitlebarIfNormal(_ window: NSWindow) {
        guard !isNativeFullscreen else { return }
        raiseTitlebar(window)
        updateTrafficLightInset(window)
    }

    /// Basis-Chrome des normalen Fensters: randloser Inhalt bis ganz nach oben,
    /// transparente/leere Titelleiste — die eigene `AppToolbar` sitzt direkt
    /// unter den Ampel-Buttons. Idempotent (wird vom WindowAccessor mehrfach
    /// gereicht); die Ampel-Buttons bleiben sichtbar.
    private func applyBaseChrome(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Titled-Stil + randloser Inhalt: ohne `.titled` zeigt macOS keine
        // Ampel-Buttons. Beides setzen, damit die Knöpfe oben links erscheinen.
        window.styleMask.insert([.titled, .fullSizeContentView])
        // Ampel-Buttons im normalen Fenster explizit einblenden (nur der
        // native Vollbild versteckt sie wieder).
        for kind in Self.buttons {
            window.standardWindowButton(kind)?.isHidden = false
        }
        raiseTitlebar(window)
        updateTrafficLightInset(window)

        // Nach dem Aufbau der SwiftUI-Hierarchie erneut nach vorne holen: das
        // randlose `NSHostingView` (Toolbar-Vibrancy/WebView) wird sonst ÜBER
        // den Titelleisten-Container gelegt und verdeckt die Ampel-Buttons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            guard let self, let window else { return }
            self.raiseTitlebar(window)
            self.updateTrafficLightInset(window)
        }
    }

    /// Hebt den Titelleisten-Container (Eltern der Ampel-Buttons) über den
    /// Inhalts-View. Bei `fullSizeContentView` + `.ignoresSafeArea()` legt
    /// SwiftUI das layer-gestützte `NSHostingView` (Toolbar-Vibrancy/WebView)
    /// sonst darüber → die Knöpfe sind unsichtbar. Reines Subview-Umsortieren
    /// überlebt ein SwiftUI-Relayout (z. B. Fenster-Resize) nicht, darum
    /// zusätzlich die Layer-`zPosition` anheben (überlebt das Relayout) und bei
    /// jedem Resize erneut anwenden.
    private func raiseTitlebar(_ window: NSWindow) {
        // `closeButton.superview` ist die `NSTitlebarView` INNERHALB des
        // `NSTitlebarContainerView`; Geschwister des Content-Views im ThemeFrame
        // ist erst der Container — darum eine Ebene höher anheben.
        guard let container = window.standardWindowButton(.closeButton)?.superview?.superview,
              let themeFrame = container.superview else { return }
        // SwiftUI blendet den Titelleisten-Container (inkl. Ampeln) zeitweise
        // aus (isHidden/alpha 0) — wieder sichtbar erzwingen und über den Content
        // legen, damit die Knöpfe trotz `fullSizeContentView` nicht verdeckt sind.
        container.isHidden = false
        container.alphaValue = 1
        themeFrame.addSubview(container, positioned: .above, relativeTo: nil)
        container.wantsLayer = true
        container.layer?.zPosition = 1_000
    }

    /// Liest den rechten Rand des Zoom-Buttons (= breitester Ampel-Knopf) und
    /// leitet daraus den Toolbar-Einzug ab. Fällt still auf den Default zurück,
    /// solange die Knöpfe noch nicht vermessen sind (Frame == 0).
    private func updateTrafficLightInset(_ window: NSWindow) {
        guard let zoom = window.standardWindowButton(.zoomButton) else { return }
        let trailing = zoom.frame.maxX
        if trailing > 0 { trafficLightInset = trailing + 14 }
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
