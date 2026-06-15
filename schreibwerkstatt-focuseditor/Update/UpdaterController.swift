//
//  UpdaterController.swift
//  schreibwerkstatt-focuseditor
//
//  Dünne Hülle um Sparkles `SPUStandardUpdaterController` — die EINZIGE Stelle,
//  an der die App das Auto-Update ansteuert. Sparkle zieht die Konfiguration aus
//  der Info.plist (SUFeedURL → GitHub-„latest"-Appcast, SUPublicEDKey →
//  EdDSA-Verifikation, SUEnableAutomaticChecks → Hintergrund-Prüfung). Hier wird
//  nichts davon dupliziert; der Controller bietet nur den manuellen Check fürs
//  Menü/Settings und spiegelt `canCheckForUpdates` für die Button-Aktivierung.
//
//  Distribution: notarisiertes .dmg als GitHub-Release-Asset; das passende
//  appcast.xml erzeugt + signiert `scripts/release-dmg.sh` (generate_appcast)
//  und lädt es als „latest"-Asset hoch. Kein Server-Kontakt nötig.
//

import Foundation
import Combine
import Sparkle

/// Besitzt den Sparkle-Updater und macht ihn SwiftUI-tauglich. Wird im App-Scope
/// als `@StateObject` gehalten; `startingUpdater: true` startet die automatische
/// Prüfung sofort beim App-Start (gemäß SUEnableAutomaticChecks).
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Treibt den `.disabled`-Zustand des Menü-/Settings-Buttons: Sparkle erlaubt
    /// keinen zweiten Check, solange schon einer läuft.
    @Published var canCheckForUpdates = false

    init() {
        // Kein eigener Delegate nötig — die Standard-UI (Update-Dialog,
        // Fortschritt, Neustart) übernimmt Sparkles `SPUStandardUserDriver`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manuelle Prüfung (Menü „Nach Updates suchen…" / Settings → Konto). Zeigt
    /// bei vorhandenem Update den Standard-Dialog, sonst „Sie sind aktuell".
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
