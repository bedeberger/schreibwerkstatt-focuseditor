//
//  SettingsView.swift
//  schreibwerkstatt-focuseditor
//
//  Natives Einstellungen-Fenster (⌘,). Bündelt die drei konfigurierbaren
//  Dinge an einem Ort, die sonst über Login-Screen, Toolbar und Menüleiste
//  verstreut sind:
//   • Server-Adresse  (sonst nur im Login editierbar)
//   • Lieblingsbuch   (= aktives Buch, sonst nur im Toolbar-Picker)
//   • Darstellung     (Hell/Dunkel/System, sonst nur in der Menüleiste)
//
//  TabView-Layout im macOS-Standard (Allgemein / Darstellung).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }

            AppearanceSettingsTab()
                .tabItem { Label("Darstellung", systemImage: "paintbrush") }
        }
        .frame(width: 460)
    }
}

// MARK: - Allgemein (Server + Lieblingsbuch)

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var library: LibraryStore

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
            Section("Server") {
                TextField("Server-Adresse", text: $serverDraft, prompt: Text("https://…"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                Text("Ein Serverwechsel meldet dich ab — das Gerätetoken gilt nur für einen Server. Lokale Inhalte bleiben erhalten; melde dich danach am neuen Server neu an.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Übernehmen") { showServerSwitchAlert = true }
                        .disabled(!serverChanged || !serverValid)
                }
            }

            Section("Lieblingsbuch") {
                Picker("Buch", selection: bookSelection) {
                    if library.books.isEmpty {
                        Text(library.isLoadingBooks ? "Lade Bücher …" : "Keine Bücher")
                            .tag(Int?.none)
                    } else {
                        ForEach(library.books, id: \.id) { book in
                            Text(book.name ?? "Buch \(book.id)").tag(Int?.some(book.id))
                        }
                    }
                }
                .disabled(library.books.isEmpty)

                Text("Das Lieblingsbuch wird beim Start geöffnet und steuert den Seiten-Picker. Du kannst es auch jederzeit über die Toolbar wechseln.")
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
        .alert("Server wechseln?", isPresented: $showServerSwitchAlert) {
            Button("Abbrechen", role: .cancel) {}
            Button("Wechseln & abmelden", role: .destructive) { applyServerChange() }
        } message: {
            Text("Du wirst abgemeldet und musst dich am neuen Server neu anmelden. Lokale, noch nicht synchronisierte Inhalte bleiben erhalten.")
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
    }
}

// MARK: - Darstellung (Hell/Dunkel/System)

private struct AppearanceSettingsTab: View {
    @EnvironmentObject private var appearance: AppearanceController
    @EnvironmentObject private var focus: FocusController

    var body: some View {
        Form {
            Section("Darstellung") {
                Picker("Modus", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Text("„Automatisch“ folgt dem System; Hell/Dunkel erzwingt das Aussehen für Shell und Editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Fokus") {
                Picker("Granularität", selection: $focus.granularity) {
                    ForEach(FocusGranularity.allCases) { g in
                        Text(g.label).tag(g)
                    }
                }
                .pickerStyle(.inline)

                Text("Bestimmt, wie stark der Editor die Umgebung des aktiven Absatzes abblendet. Die Änderung wirkt sofort im offenen Editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
