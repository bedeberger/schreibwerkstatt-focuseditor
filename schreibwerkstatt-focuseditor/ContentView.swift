//
//  ContentView.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthStore
    /// Beobachtet die App-Sprache: ein Sprachwechsel rendert den ganzen Baum neu
    /// (frische `t()`-Werte), ohne den Editor-WebView neu zu laden.
    @EnvironmentObject private var loc: LocalizationController

    var body: some View {
        switch auth.state {
        case .unknown:
            LoadingView()
        case .validating:
            // Beim Erst-Login zeigt LoginView selbst einen Spinner;
            // hier nur der Bootstrap-Fall (Token wird geprüft).
            auth.hasStoredToken ? AnyView(LoadingView()) : AnyView(LoginView())
        case .signedOut:
            LoginView()
        case .signedIn:
            EditorHostView()
        }
    }
}

/// Schlichter Lade-Zustand während Bootstrap/Token-Prüfung.
private struct LoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

/// Editor-Host nach erfolgreichem Login: hostet die WKWebView (Focus-Editor
/// bzw. Bridge-Harness) full-bleed auf der Brand-Fläche. Der lokale Speicher
/// wird hier instanziiert und in die Bridge gereicht — eine Instanz pro Fenster.
/// Abmelden liegt in der Toolbar, damit das Schreiben ablenkungsfrei bleibt.
private struct EditorHostView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var core: AppCore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var windowChrome: WindowChromeController
    @EnvironmentObject private var editorBundle: EditorBundleStore
    /// Sichtbarkeit des beschwörbaren Seiten-Pickers (⌘O).
    @State private var pickerOpen = false

    /// „Toolbar bei Inaktivität ausblenden" (gerätelokal, gleicher Key wie der
    /// Darstellungs-Tab der Settings).
    @AppStorage("toolbar.autoHide") private var autoHideToolbar = false
    /// Steuert die eingeblendete Toolbar im Auto-Hide-Modus.
    @State private var toolbarRevealed = true
    @State private var hideTask: Task<Void, Never>?

    /// Die Toolbar wird **immer** gezeigt — auch im nativen Vollbild. Das
    /// ablenkungsfreie Ausblenden übernimmt ausschließlich die „Toolbar bei
    /// Inaktivität ausblenden"-Option (Auto-Hide), nicht mehr der Vollbild.
    private var chromeAllowed: Bool { true }

    var body: some View {
        Group {
            switch editorBundle.state {
            case .ready:
                editorReady
            case .failed(let message):
                BundleUnavailableView(message: message) {
                    Task { await editorBundle.refresh(silent: false) }
                }
            case .idle, .refreshing:
                BundleLoadingView()
            }
        }
        .animation(.easeOut(duration: 0.12), value: pickerOpen)
        .animation(.easeOut(duration: 0.18), value: toolbarRevealed)
        .task { await editorBundle.ensureReady() }
        .task { await library.loadBooks() }
        // Beim Ausschalten von Auto-Hide die Toolbar wieder dauerhaft zeigen.
        .onChange(of: autoHideToolbar) { _, on in
            if !on { hideTask?.cancel(); toolbarRevealed = true }
        }
    }

    /// Editor + Toolbar im Ready-Zustand. Zwei Layouts:
    ///  • normal     — Toolbar oben im Fluss, WebView darunter (keine Overlap-
    ///    Probleme: das Fenster nutzt KEIN `fullSizeContentView` mehr, die WebView
    ///    sitzt sauber unter der Titelleiste — s. `WindowChromeController`).
    ///  • Auto-Hide  — Toolbar als Overlay über der WebView, das bei Inaktivität
    ///    weggeblendet wird; sie bleibt IMMER im Baum, damit ⌘O & Co. greifen.
    ///    Ein dünner Hover-Streifen am oberen Rand blendet sie wieder ein.
    @ViewBuilder
    private var editorReady: some View {
        let autoHideActive = autoHideToolbar && chromeAllowed
        VStack(spacing: 0) {
            if chromeAllowed && !autoHideActive {
                AppToolbar(pickerOpen: $pickerOpen)
            }
            ZStack(alignment: .top) {
                // App-weiter, geteilter Store — dieselbe Instanz, die die SyncEngine bedient.
                FocusWebView(bridge: core.bridge, webRoot: editorBundle.webRoot)
                    .background(BrandColor.bg)
                    .frame(minWidth: 640, minHeight: 480)

                if autoHideActive {
                    // Hover-Fangstreifen am oberen Rand (über der WebView).
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active = phase { revealToolbar() }
                        }
                    AppToolbar(pickerOpen: $pickerOpen)
                        .opacity(toolbarRevealed ? 1 : 0)
                        .offset(y: toolbarRevealed ? 0 : -52)
                        .allowsHitTesting(toolbarRevealed)
                        .onHover { if $0 { revealToolbar() } }
                }

                if pickerOpen {
                    PagePickerOverlay(isOpen: $pickerOpen)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
    }

    /// Blendet die Toolbar ein und plant das erneute Ausblenden nach Inaktivität.
    private func revealToolbar() {
        if !toolbarRevealed { toolbarRevealed = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            if autoHideToolbar && chromeAllowed { toolbarRevealed = false }
        }
    }
}

/// Erst-Download/Refresh des Editor-Bundles ohne vorhandenen Cache.
private struct BundleLoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(t("content.loadingEditor"))
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Kein Cache UND Download fehlgeschlagen (typisch: erster Start offline).
private struct BundleUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(BrandColor.muted)
                Text(t("content.editorUnavailableTitle"))
                    .font(BrandFont.serif(18))
                Text(message)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button(t("content.retry"), action: retry)
            }
            .padding(40)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore())
        .environmentObject(LocalizationController())
}
