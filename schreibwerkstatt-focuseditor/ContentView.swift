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
        .animation(.easeOut(duration: 0.18), value: library.openPageId)
        .task { await editorBundle.ensureReady() }
        .task { await library.loadBooks() }
        // Beim Ausschalten von Auto-Hide die Toolbar wieder dauerhaft zeigen.
        .onChange(of: autoHideToolbar) { _, on in
            if !on { hideTask?.cancel(); toolbarRevealed = true }
        }
        // Buchwechsel: die LibraryStore schliesst die offene Seite und signalisiert
        // hier, den Seiten-Picker zu öffnen (Seite des neuen Buchs wählen).
        .onChange(of: library.pickerOpenRequest) { _, _ in
            pickerOpen = true
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

                // Ruhiger Leerzustand: keine Seite offen und kein Picker — statt
                // der schwarzen WebView-Fläche eine zentrierte Karte mit Kontext
                // (Buch) und dem klaren nächsten Schritt (Seite öffnen / zuletzt
                // fortsetzen). Deckt die WebView voll ab, damit nichts durchscheint.
                if library.openPageId == nil && !pickerOpen {
                    EmptyEditorView(openPicker: { pickerOpen = true })
                        .transition(.opacity)
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

/// Ruhiger Leerzustand, wenn keine Seite geöffnet ist (z. B. nach „Seite
/// schliessen" und Abbruch des Pickers). Bewusst still und markengerecht — kein
/// Dashboard: nur Buchkontext und der nächste Schritt. Zwei Wege zurück ins
/// Schreiben: die zuletzt bearbeitete Seite fortsetzen (primär, wenn bekannt)
/// oder den Seiten-Picker öffnen (⌘O greift parallel über die Toolbar).
private struct EmptyEditorView: View {
    @EnvironmentObject private var library: LibraryStore
    let openPicker: () -> Void

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "book.closed")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(BrandColor.faint)

                VStack(spacing: 5) {
                    if let book = library.activeBookName {
                        Text(book)
                            .font(BrandFont.serif(17))
                            .foregroundStyle(BrandColor.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(t("empty.noPageOpen"))
                        .font(BrandFont.sans(13))
                        .foregroundStyle(BrandColor.faint)
                }

                VStack(spacing: 10) {
                    if let last = library.lastOpenPageRow {
                        EmptyStateButton(title: t("empty.continueLast", ["name": last.name]),
                                         prominent: true) {
                            library.openPage(last)
                        }
                    }
                    EmptyStateButton(title: t("empty.openPage"),
                                     shortcut: "⌘O",
                                     prominent: library.lastOpenPageRow == nil,
                                     action: openPicker)
                }
                .frame(maxWidth: 320)
            }
            .padding(40)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Knopf des Leerzustands: ein prominenter Akzent-Knopf (primärer Weg zurück
/// ins Schreiben) oder eine zurückgenommene Variante; optional mit Kürzel-Chip.
private struct EmptyStateButton: View {
    let title: String
    var shortcut: String? = nil
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(BrandFont.sans(13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let shortcut {
                    Text(shortcut)
                        .font(BrandFont.sans(11))
                        .foregroundStyle(prominent ? BrandColor.bg.opacity(0.7) : BrandColor.faint)
                }
            }
            .foregroundStyle(prominent ? BrandColor.bg : BrandColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(prominent ? .clear : BrandColor.faint.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if prominent {
            return hovering ? BrandColor.accent.opacity(0.85) : BrandColor.accent
        }
        return hovering ? BrandColor.faint.opacity(0.25) : .clear
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
