//
//  ContentView.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var auth: AuthStore

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
    @EnvironmentObject private var fullscreen: KioskFullscreen
    @EnvironmentObject private var editorBundle: EditorBundleStore
    /// Sichtbarkeit des beschwörbaren Seiten-Pickers (⌘O).
    @State private var pickerOpen = false

    var body: some View {
        ZStack {
            switch editorBundle.state {
            case .ready:
                // App-weiter, geteilter Store — dieselbe Instanz, die die SyncEngine bedient.
                FocusWebView(bridge: core.bridge, webRoot: editorBundle.webRoot)
                    .background(BrandColor.bg)
                    .frame(minWidth: 640, minHeight: 480)
                    .ignoresSafeArea()

                if pickerOpen {
                    PagePickerOverlay(isOpen: $pickerOpen)
                        .transition(.opacity)
                }
            case .failed(let message):
                BundleUnavailableView(message: message) {
                    Task { await editorBundle.refresh(silent: false) }
                }
            case .idle, .refreshing:
                BundleLoadingView()
            }
        }
        .animation(.easeOut(duration: 0.12), value: pickerOpen)
        .task { await editorBundle.ensureReady() }
        // Im nativen Vollbild Toolbar komplett aus — pures, ablenkungsfreies
        // Schreiben (kein Einblenden beim Hovern an den oberen Rand).
        .toolbar(fullscreen.isNativeFullscreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                BookPicker()
            }
            ToolbarItem(placement: .automatic) {
                Button { pickerOpen.toggle() } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Seite öffnen (⌘O)")
            }
            ToolbarItem(placement: .automatic) {
                SyncStatusLabel(status: sync.status, conflicts: sync.conflicts.count)
            }
            ToolbarItem(placement: .automatic) {
                Button("Abmelden") { auth.signOut() }
                    .font(BrandFont.sans(12))
            }
        }
        .task { await library.loadBooks() }
    }
}

/// Erst-Download/Refresh des Editor-Bundles ohne vorhandenen Cache.
private struct BundleLoadingView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Editor wird geladen …")
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
                Text("Editor konnte nicht geladen werden")
                    .font(BrandFont.serif(18))
                Text(message)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Erneut versuchen", action: retry)
            }
            .padding(40)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Schlanke Sync-Anzeige in der Toolbar (Status + offene Konflikte).
private struct SyncStatusLabel: View {
    let status: SyncEngine.Status
    let conflicts: Int

    var body: some View {
        HStack(spacing: 6) {
            if conflicts > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(conflicts) Konflikt\(conflicts == 1 ? "" : "e")")
            } else {
                switch status {
                case .syncing:
                    ProgressView().controlSize(.small)
                    Text("Synchronisiere …")
                case .offline:
                    Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                    Text("Offline")
                case .idle:
                    Image(systemName: "checkmark.circle").foregroundStyle(BrandColor.muted)
                }
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore())
}
