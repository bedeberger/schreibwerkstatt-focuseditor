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

    var body: some View {
        // App-weiter, geteilter Store — dieselbe Instanz, die die SyncEngine bedient.
        FocusWebView(store: core.store)
            .background(BrandColor.bg)
            .frame(minWidth: 640, minHeight: 480)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SyncStatusLabel(status: sync.status, conflicts: sync.conflicts.count)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Abmelden") { auth.signOut() }
                        .font(BrandFont.sans(12))
                }
            }
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
