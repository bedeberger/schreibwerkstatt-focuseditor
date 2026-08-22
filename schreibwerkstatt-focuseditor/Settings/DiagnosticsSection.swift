//
//  DiagnosticsSection.swift
//  schreibwerkstatt-focuseditor
//
//  Einstellungen ▸ Konto ▸ „Diagnose kopieren" — sammelt den Zustand aus den
//  Stores und legt ihn als Text in die Zwischenablage.
//
//  Der Bericht selbst (Format + Datenschutz-Grenzen) steht in
//  Diagnostics/DiagnosticsReport.swift; hier ist nur das Einsammeln und der
//  Knopf. Bewusst Zwischenablage statt Datei: der Weg endet ohnehin in einer
//  Mail, und eine Datei bräuchte ein Save-Panel für nichts.
//

import SwiftUI
import AppKit

struct DiagnosticsSection: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var editorBundle: EditorBundleStore
    @EnvironmentObject private var loc: LocalizationController

    /// Kurze Bestätigung am Knopf, damit der Klick nicht ins Leere geht.
    @State private var copiedAt: Date?

    var body: some View {
        Section(t("settings.account.diagnosticsSection")) {
            HStack {
                if copiedAt != nil {
                    Label(t("settings.account.diagnosticsCopied"), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("settings.account.copyDiagnostics")) { copy() }
            }
            Text(t("settings.account.diagnosticsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        let input = DiagnosticsReport.Input(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—",
            channel: Self.channel,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            serverURL: ServerConfig.baseURLString,
            signedIn: auth.state == .signedIn,
            // Nur die Existenz — der Wert verlässt den Keychain nie.
            hasToken: auth.state == .signedIn,
            language: loc.locale,
            bundleCommit: editorBundle.sourceCommit,
            bundleCached: editorBundle.hasCache,
            pollMode: String(describing: sync.pollMode),
            isPaused: sync.isPaused,
            lastSyncedAt: sync.lastSyncedAt,
            pendingCount: sync.pendingCount,
            conflictCount: sync.conflicts.count,
            lastSyncError: sync.lastError,
            bookCount: library.books.count,
            activeBookId: library.activeBookId,
            pageCount: library.pages.count,
            openPageId: library.openPageId,
            logLines: DiagnosticsReport.recentLogLines())

        let text = DiagnosticsReport.text(input, now: Date())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedAt = Date()
    }

    /// Aus welchem Kanal läuft dieser Build — beantwortet die häufigste
    /// Support-Rückfrage („warum kommt bei mir kein Update?") vorab.
    private static var channel: String {
        #if SPARKLE
        return "DMG (Sparkle)"
        #else
        return "App Store"
        #endif
    }
}
