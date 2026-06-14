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

            TypographySettingsTab()
                .tabItem { Label("Typografie", systemImage: "textformat.size") }

            WritingSettingsTab()
                .tabItem { Label("Schreiben", systemImage: "pencil.and.scribble") }

            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            SpellcheckSettingsTab()
                .tabItem { Label("Rechtschreibung", systemImage: "textformat.abc.dottedunderline") }

            AccountSettingsTab()
                .tabItem { Label("Konto", systemImage: "person.crop.circle") }
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
    @AppStorage("kiosk.startInKiosk") private var startInKiosk = false
    @AppStorage("toolbar.autoHide") private var autoHideToolbar = false

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

            Section("Fenster") {
                Toggle("Beim Start in den ablenkungsfreien Vollbild", isOn: $startInKiosk)
                Toggle("Toolbar bei Inaktivität ausblenden", isOn: $autoHideToolbar)
                Text("Der ablenkungsfreie Vollbild blendet Menüleiste und Dock aus (⎋ verlässt ihn). Die Auto-Ausblendung zeigt die Toolbar erst wieder, wenn der Zeiger an den oberen Rand fährt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Typografie (Schriftgrösse, Zeilenhöhe, Spaltenbreite, Familie, Papier)

private struct TypographySettingsTab: View {
    @EnvironmentObject private var typography: TypographyController

    var body: some View {
        Form {
            Section("Schrift") {
                Picker("Schriftart", selection: $typography.fontFamily) {
                    ForEach(EditorFontFamily.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }

                LabeledContent("Schriftgrösse") {
                    HStack {
                        Slider(value: $typography.fontSize,
                               in: TypographyController.fontSizeRange, step: 1)
                        Text("\(Int(typography.fontSize.rounded())) px")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent("Zeilenhöhe") {
                    HStack {
                        Slider(value: $typography.lineHeight,
                               in: TypographyController.lineHeightRange, step: 0.05)
                        Text(String(format: "%.2f", typography.lineHeight))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section("Layout") {
                Toggle("Spaltenbreite begrenzen", isOn: measureEnabled)
                if typography.measure > 0 {
                    LabeledContent("Breite") {
                        HStack {
                            Slider(value: $typography.measure,
                                   in: TypographyController.measureRange, step: 1)
                            Text("\(Int(typography.measure.rounded())) ch")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Text("Begrenzt die Zeilenlänge (in Zeichen) für angenehmeres Lesen. „ch“ ≈ Breite einer Ziffer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Papier") {
                Picker("Hintergrund", selection: $typography.paperTone) {
                    ForEach(PaperTone.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                Text("„System“ folgt Hell/Dunkel. Andere Töne erzwingen eine feste Schreibfläche (z. B. Sepia für warmes Licht).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Auf Standard zurücksetzen") { typography.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Toggle koppelt „begrenzen" an measure==0 (aus) bzw. den letzten Wert.
    private var measureEnabled: Binding<Bool> {
        Binding(
            get: { typography.measure > 0 },
            set: { typography.measure = $0 ? 64 : 0 }
        )
    }
}

// MARK: - Schreiben (Statistik + Seitenziel)

private struct WritingSettingsTab: View {
    @EnvironmentObject private var stats: WritingStatsStore
    /// Auto-Save-Debounce in ms (an mountStandaloneFocus durchgereicht).
    @AppStorage(EditorBehaviorPrefs.autosaveKey) private var autosaveMs = 1500.0

    var body: some View {
        Form {
            Section("Statistik") {
                Toggle("Wortzahl & Lesezeit in der Toolbar zeigen", isOn: $stats.showStats)
            }

            Section("Schreibziel") {
                Toggle("Wort-Ziel pro Seite", isOn: goalEnabled)
                if stats.pageGoalWords > 0 {
                    Stepper(value: $stats.pageGoalWords, in: 50...5000, step: 50) {
                        LabeledContent("Ziel", value: "\(stats.pageGoalWords) Wörter")
                    }
                }
                Text("Zeigt einen Fortschrittsbalken in der Toolbar, bis die offene Seite das Ziel erreicht. Die App ist auf genau eine Seite ausgelegt — das Ziel gilt darum pro Seite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Automatisches Speichern") {
                LabeledContent("Verzögerung") {
                    HStack {
                        Slider(value: $autosaveMs,
                               in: EditorBehaviorPrefs.autosaveRange, step: 250)
                        Text(String(format: "%.2g s", autosaveMs / 1000))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text("Wartezeit nach der letzten Eingabe, bis der Entwurf gespeichert wird. Wirkt beim nächsten Öffnen des Editors. Lokal gespeichert wird trotzdem immer zuerst (kein Datenverlust).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Toggle koppelt „Ziel an" an pageGoalWords==0 (aus) bzw. einen Default.
    private var goalEnabled: Binding<Bool> {
        Binding(
            get: { stats.pageGoalWords > 0 },
            set: { stats.pageGoalWords = $0 ? 500 : 0 }
        )
    }
}

// MARK: - Sync (Poll-Kadenz, Pause, Status)

private struct SyncSettingsTab: View {
    @EnvironmentObject private var sync: SyncEngine

    var body: some View {
        Form {
            Section("Aktualisierung") {
                Picker("Poll-Kadenz", selection: $sync.pollMode) {
                    ForEach(SyncPollMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.inline)

                Text("Wie oft im aktiven Fenster nach Änderungen gesucht wird. „Sparsam“ schont Akku/Daten; „Nur manuell“ synchronisiert ausschliesslich auf Knopfdruck.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Pause") {
                Toggle("Sync pausieren (diese Sitzung)", isOn: $sync.isPaused)
                Text("Hält den automatischen Abgleich an, bis du ihn wieder einschaltest oder die App neu startest. Lokale Änderungen bleiben in der Warteschlange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Status") {
                LabeledContent("Zustand", value: statusText)
                LabeledContent("Zuletzt synchronisiert", value: lastSyncedText)
                if sync.pendingCount > 0 {
                    LabeledContent("Ausstehend", value: "\(sync.pendingCount) Seite\(sync.pendingCount == 1 ? "" : "n")")
                }
                if !sync.conflicts.isEmpty {
                    LabeledContent("Konflikte", value: "\(sync.conflicts.count)")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Jetzt synchronisieren") { sync.syncManually() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch sync.status {
        case .idle:    return sync.isPaused ? "Pausiert" : "Bereit"
        case .syncing: return "Synchronisiere …"
        case .offline: return "Offline"
        }
    }

    private var lastSyncedText: String {
        guard let last = sync.lastSyncedAt else { return "Noch nie" }
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "de")
        return rel.localizedString(for: last, relativeTo: Date())
    }
}

// MARK: - Rechtschreibung (lokale LanguageTool-Overrides)

private struct SpellcheckSettingsTab: View {
    @AppStorage(SpellcheckPrefs.enabledKey) private var localEnabled = true
    @AppStorage(SpellcheckPrefs.languageKey) private var languageRaw = "auto"

    var body: some View {
        Form {
            Section("Rechtschreibprüfung") {
                Toggle("Auf diesem Gerät aktiv", isOn: $localEnabled)
                Text("Die Prüfung läuft über LanguageTool am Server (online-only). Dieser Schalter kann sie zusätzlich pro Gerät abschalten — auch wenn sie serverseitig aktiv ist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sprache") {
                Picker("Prüfsprache", selection: $languageRaw) {
                    ForEach(SpellcheckLanguage.allCases) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
                .disabled(!localEnabled)
                Text("„Automatisch“ überlässt dem Server die Sprache (aus der Buch-Sprache, i. d. R. Deutsch Schweiz). Eine feste Wahl übersteuert das pro Gerät.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Strenge (Picky) und aktive Regeln werden serverseitig verwaltet und lassen sich hier nicht ändern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Konto (Abmelden + Editor-Bundle-Wartung)

private struct AccountSettingsTab: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var editorBundle: EditorBundleStore
    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false

    var body: some View {
        Form {
            Section("Anmeldung") {
                LabeledContent("Server", value: ServerConfig.baseURLString)
                LabeledContent("Status", value: auth.state == .signedIn ? "Angemeldet" : "Nicht angemeldet")
                HStack {
                    Spacer()
                    Button("Abmelden", role: .destructive) { showLogoutAlert = true }
                        .disabled(auth.state != .signedIn)
                }
                Text("Abmelden entfernt nur das Gerätetoken aus dem Schlüsselbund. Lokale, noch nicht synchronisierte Inhalte bleiben erhalten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Editor-Version") {
                LabeledContent("Quelle (Commit)", value: commitShort)
                HStack {
                    if editorBundle.isCheckingUpdate { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Nach Update suchen") {
                        Task { await editorBundle.checkForUpdate() }
                    }
                    .disabled(editorBundle.isCheckingUpdate)
                }
                Text("Ein neueres Editor-Bundle wird heruntergeladen und greift beim nächsten Start (kein Wechsel mitten im Schreiben).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Wartung") {
                HStack {
                    Spacer()
                    Button("Editor-Cache leeren") { showClearCacheAlert = true }
                }
                Text("Lädt die Editor-Assets frisch vom Server. Betrifft nur den Editor — deine Texte (lokaler Spiegel) bleiben unangetastet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert("Abmelden?", isPresented: $showLogoutAlert) {
            Button("Abbrechen", role: .cancel) {}
            Button("Abmelden", role: .destructive) { auth.signOut() }
        } message: {
            Text("Du musst dich danach mit einem Gerätetoken neu anmelden. Lokale Inhalte bleiben erhalten.")
        }
        .alert("Editor-Cache leeren?", isPresented: $showClearCacheAlert) {
            Button("Abbrechen", role: .cancel) {}
            Button("Leeren & neu laden", role: .destructive) {
                Task { await editorBundle.clearEditorCache() }
            }
        } message: {
            Text("Der Editor wird neu vom Server geladen. Ohne Verbindung steht er bis zum nächsten erfolgreichen Download nicht zur Verfügung. Deine Texte bleiben erhalten.")
        }
    }

    private var commitShort: String {
        guard let c = editorBundle.sourceCommit, !c.isEmpty, c != "unknown" else { return "—" }
        return String(c.prefix(10))
    }
}
