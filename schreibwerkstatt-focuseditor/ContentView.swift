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
    @State private var store: any LocalStore = InMemoryLocalStore()

    var body: some View {
        FocusWebView(store: store)
            .background(BrandColor.bg)
            .frame(minWidth: 640, minHeight: 480)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Abmelden") { auth.signOut() }
                        .font(BrandFont.sans(12))
                }
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore())
}
