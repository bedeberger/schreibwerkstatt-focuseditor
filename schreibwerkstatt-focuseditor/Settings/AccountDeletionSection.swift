//
//  AccountDeletionSection.swift
//  schreibwerkstatt-focuseditor
//
//  „Konto löschen" im Einstellungen-Tab „Konto" (App-Store-Guideline 5.1.1(v)).
//  Zwei Stufen, damit nichts versehentlich passiert: Abschnitt mit Knopf →
//  Sheet mit ausformulierten Folgen + Tipp-Bestätigung (Wort aus dem Katalog).
//
//  Die eigentliche Arbeit macht `AccountDeletionController` (Server-Call) und
//  `AppCore.purgeLocalDataForCurrentServer()` (lokales Aufräumen). Hier nur die
//  Oberfläche und die Zustandsanzeige.
//

import SwiftUI

// MARK: - Abschnitt im Konto-Tab

struct AccountDeletionSection: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var core: AppCore
    @State private var showSheet = false

    var body: some View {
        Section(t("settings.account.deleteSection")) {
            HStack {
                Spacer()
                Button(t("settings.account.deleteButton"), role: .destructive) {
                    core.accountDeletion.reset()
                    showSheet = true
                }
                .disabled(auth.state != .signedIn)
            }
            Text(t("settings.account.deleteHint", ["server": serverName]))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showSheet) {
            // Den Controller explizit als `@ObservedObject` weiterreichen: über
            // `AppCore` (nur ein `let`) kämen seine Zustandswechsel nicht in der
            // View an.
            AccountDeletionSheet(deletion: core.accountDeletion, isPresented: $showSheet)
        }
    }

    /// Host des konfigurierten Servers — benennt im Hinweis konkret, welches
    /// Konto verschwindet (die App kann gegen mehrere Server laufen).
    private var serverName: String {
        ServerConfig.baseURL?.host ?? ServerConfig.baseURLString
    }
}

// MARK: - Bestätigungs-Sheet

private struct AccountDeletionSheet: View {
    @ObservedObject var deletion: AccountDeletionController
    @Environment(\.openURL) private var openURL
    @Binding var isPresented: Bool
    @State private var typed = ""

    /// Zu tippendes Bestätigungswort (lokalisiert; der Protokollwert im Request
    /// ist davon unabhängig, s. `AccountDeletionController.confirmToken`).
    private var confirmWord: String { t("settings.account.deleteConfirmWord") }

    private var confirmed: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(confirmWord) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch deletion.phase {
            case .done(let purgeAt):
                doneContent(purgeAt: purgeAt)
            case .unsupported:
                unsupportedContent
            default:
                confirmContent
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    // Stufe 1: Folgen benennen, Tipp-Bestätigung verlangen.
    @ViewBuilder
    private var confirmContent: some View {
        Text(t("settings.account.deleteSheetTitle"))
            .font(.headline)
        Text(t("settings.account.deleteSheetBody"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(t("settings.account.deleteSheetLocalNote"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text(t("settings.account.deleteConfirmPrompt", ["word": confirmWord]))
                .font(.callout)
            TextField(confirmWord, text: $typed)
                .textFieldStyle(.roundedBorder)
                .disabled(deletion.isDeleting)
        }

        if case .failed(let message) = deletion.phase {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(BrandColor.error)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            if deletion.isDeleting {
                ProgressView().controlSize(.small)
                Text(t("settings.account.deleting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(t("general.cancel"), role: .cancel) { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(deletion.isDeleting)
            Button(t("settings.account.deleteConfirmButton"), role: .destructive) {
                Task { await deletion.deleteAccount() }
            }
            .disabled(!confirmed || deletion.isDeleting)
        }
    }

    // Stufe 2a: erledigt — Konto weg, lokal aufgeräumt, abgemeldet.
    @ViewBuilder
    private func doneContent(purgeAt: String?) -> some View {
        Text(t("settings.account.deleteDoneTitle"))
            .font(.headline)
        Text(t("settings.account.deleteDoneBody"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let purgeAt, !purgeAt.isEmpty {
            Text(t("settings.account.deleteDoneScheduled", ["date": formatted(purgeAt)]))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button(t("general.done")) { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    // Stufe 2b: Server ohne Selbst-Löschung (älterer Stand) → Browser-Fallback,
    // damit der Weg zur Löschung nie in einer Sackgasse endet.
    @ViewBuilder
    private var unsupportedContent: some View {
        Text(t("settings.account.deleteUnsupportedTitle"))
            .font(.headline)
        Text(t("settings.account.deleteUnsupportedBody"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(t("general.cancel"), role: .cancel) { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(t("settings.account.deleteOpenWeb")) {
                openURL(ServerConfig.pageURL(onServer: ServerConfig.baseURLString,
                                             fragment: "profil"))
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// ISO-Zeitstempel des Servers menschenlesbar machen; bleibt roh, falls das
    /// Format unerwartet ist (nie eine leere Angabe zeigen).
    private func formatted(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: L10nStore.shared.localeCode)
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}
