//
//  SettingsTabs+General.swift
//  schreibwerkstatt-focuseditor
//
//  Einstellungen-Tabs „Allgemein" (Sprache + Server + Lieblingsbuch) und
//  „Darstellung" (Hell/Dunkel/System + Fokus-Granularität). Gehostet von
//  `SettingsView`.
//

import SwiftUI

// MARK: - Allgemein (Server + Lieblingsbuch)

struct GeneralSettingsTab: View {
    @EnvironmentObject private var core: AppCore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var loc: LocalizationController

    /// Lokaler Entwurf der Server-Adresse; erst „Übernehmen" schreibt sie.
    @State private var serverDraft: String = ServerConfig.baseURLString
    @State private var showServerSwitchAlert = false

    /// Hat sich die eingegebene URL gegenüber der gespeicherten geändert?
    private var serverChanged: Bool {
        let normalized = ServerConfig.normalizedURL(from: serverDraft)?.absoluteString
        return normalized != nil && normalized != ServerConfig.baseURLString
    }

    private var serverValid: Bool {
        ServerConfig.normalizedURL(from: serverDraft) != nil
    }

    var body: some View {
        Form {
            Section(t("settings.language.section")) {
                Picker(t("settings.language.label"), selection: $loc.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                Text(t("settings.language.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.general.serverSection")) {
                TextField(t("settings.general.serverAddress"), text: $serverDraft, prompt: Text("https://…"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disableAutocorrection(true)

                Text(t("settings.general.serverHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button(t("general.apply")) { showServerSwitchAlert = true }
                        .disabled(!serverChanged || !serverValid)
                }
            }

            Section(t("settings.general.favoriteBookSection")) {
                Picker(t("settings.general.book"), selection: bookSelection) {
                    if library.books.isEmpty {
                        Text(library.isLoadingBooks ? t("library.loadingBooks") : t("library.noBooks"))
                            .tag(Int?.none)
                    } else {
                        ForEach(library.books, id: \.id) { book in
                            Text(book.name ?? t("library.bookFallback", ["id": "\(book.id)"])).tag(Int?.some(book.id))
                        }
                    }
                }
                .disabled(library.books.isEmpty)

                Text(t("settings.general.favoriteBookHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            // Beim Öffnen sicherstellen, dass die Bücherliste da ist
            // (falls die Settings vor dem Editor-Host geöffnet werden).
            if library.books.isEmpty { await library.loadBooks() }
        }
        .alert(t("settings.general.switchServerAlertTitle"), isPresented: $showServerSwitchAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.general.switchAndSignOut"), role: .destructive) { applyServerChange() }
        } message: {
            Text(t("settings.general.switchServerAlertMessage"))
        }
    }

    /// Bindung auf das aktive Buch des LibraryStore (Optional-Int).
    private var bookSelection: Binding<Int?> {
        Binding(
            get: { library.activeBookId },
            set: { if let id = $0 { library.selectBook(id) } }
        )
    }

    private func applyServerChange() {
        guard let url = ServerConfig.normalizedURL(from: serverDraft) else { return }
        ServerConfig.baseURLString = url.absoluteString
        serverDraft = url.absoluteString
        // Token ist serverspezifisch → sauberer Re-Login am neuen Server.
        auth.signOut()
        // Lokalen Spiegel, Sync-Zustand und Buchauswahl auf den Namespace des
        // neuen Servers umschalten — sonst pollt der Sync weiter die Buch-IDs des
        // alten Servers (→ `NO_BOOK_ACCESS`). URL ist oben bereits gesetzt.
        Task { await core.switchServer() }
    }
}

// MARK: - Darstellung (Hell/Dunkel/System)

struct AppearanceSettingsTab: View {
    @EnvironmentObject private var appearance: AppearanceController
    @EnvironmentObject private var focus: FocusController

    var body: some View {
        Form {
            Section(t("settings.appearance.section")) {
                Picker(t("settings.appearance.mode"), selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Text(t("settings.appearance.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.appearance.focusSection")) {
                Picker(t("settings.appearance.granularity"), selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)

                Text(t("settings.appearance.focusHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
