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
    /// Sprachwechsel rendert die Tabs neu (frische `t()`-Werte).
    @EnvironmentObject private var loc: LocalizationController

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(t("settings.tab.general"), systemImage: "gearshape") }

            AppearanceSettingsTab()
                .tabItem { Label(t("settings.tab.appearance"), systemImage: "paintbrush") }

            TypographySettingsTab()
                .tabItem { Label(t("settings.tab.typography"), systemImage: "textformat.size") }

            WritingSettingsTab()
                .tabItem { Label(t("settings.tab.writing"), systemImage: "pencil.and.scribble") }

            SyncSettingsTab()
                .tabItem { Label(t("settings.tab.sync"), systemImage: "arrow.triangle.2.circlepath") }

            SpellcheckSettingsTab()
                .tabItem { Label(t("settings.tab.spellcheck"), systemImage: "textformat.abc.dottedunderline") }

            AccountSettingsTab()
                .tabItem { Label(t("settings.tab.account"), systemImage: "person.crop.circle") }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - Allgemein (Server + Lieblingsbuch)

private struct GeneralSettingsTab: View {
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

private struct AppearanceSettingsTab: View {
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

// MARK: - Typografie (Schriftgrösse, Zeilenhöhe, Spaltenbreite, Familie, Papier)

private struct TypographySettingsTab: View {
    @EnvironmentObject private var typography: TypographyController
    @State private var showResetAlert = false

    var body: some View {
        Form {
            Section(t("settings.typo.fontSection")) {
                Picker(t("settings.typo.fontFamily"), selection: $typography.fontFamily) {
                    ForEach(EditorFontFamily.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }

                LabeledContent(t("settings.typo.fontSize")) {
                    HStack {
                        Slider(value: $typography.fontSize,
                               in: TypographyController.fontSizeRange, step: 1)
                        Text("\(Int(typography.fontSize.rounded())) px")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                LabeledContent(t("settings.typo.lineHeight")) {
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

            Section(t("settings.typo.layoutSection")) {
                Toggle(t("settings.typo.limitMeasure"), isOn: measureEnabled)
                if typography.measure > 0 {
                    LabeledContent(t("settings.typo.width")) {
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
                Text(t("settings.typo.measureHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.typo.paperSection")) {
                Picker(t("settings.typo.background"), selection: $typography.paperTone) {
                    ForEach(PaperTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                Text(t("settings.typo.paperHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.typo.dimSection")) {
                Toggle(t("settings.typo.dimCustom"), isOn: $typography.focusDimEnabled)
                if typography.focusDimEnabled {
                    LabeledContent(t("settings.typo.dimAmount")) {
                        HStack {
                            // Slider von „dezent" (hohe Opazität) nach „stark"
                            // (niedrige Opazität) — invertiert, damit rechts = stärker.
                            Slider(value: dimStrength, in: 0...1)
                            Text(String(format: "%.0f %%", (1 - typography.focusDimOpacity) * 100))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Text(t("settings.typo.dimHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Spacer()
                    // Bestätigung wie bei den anderen Einklick-Destruktiven (Abmelden,
                    // Cache leeren, Server-Wechsel) — ein versehentlicher Klick würde
                    // sonst alle Typografie-Einstellungen auf einmal verwerfen.
                    Button(t("settings.typo.reset")) { showResetAlert = true }
                }
            }
        }
        .formStyle(.grouped)
        .alert(t("settings.typo.resetAlertTitle"), isPresented: $showResetAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.typo.resetConfirm"), role: .destructive) {
                typography.resetToDefaults()
            }
        } message: {
            Text(t("settings.typo.resetAlertMessage"))
        }
    }

    /// Slider 0…1 (links dezent, rechts stark) ⇄ Opazität (0.6…0.05).
    private var dimStrength: Binding<Double> {
        let range = TypographyController.focusDimRange
        return Binding(
            get: { (range.upperBound - typography.focusDimOpacity) / (range.upperBound - range.lowerBound) },
            set: { typography.focusDimOpacity = range.upperBound - $0 * (range.upperBound - range.lowerBound) }
        )
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
    /// Synonym-Hilfe (Cmd+Shift+S) gerätelokal an/aus.
    @AppStorage(SynonymPrefs.enabledKey) private var synonymsEnabled = true

    var body: some View {
        Form {
            Section(t("settings.writing.statsSection")) {
                Toggle(t("settings.writing.showStats"), isOn: $stats.showStats)
            }

            Section(t("settings.writing.synonymSection")) {
                Toggle(t("settings.writing.synonymToggle"), isOn: $synonymsEnabled)
                Text(t("settings.writing.synonymHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.writing.goalSection")) {
                Toggle(t("settings.writing.goalToggle"), isOn: goalEnabled)
                if stats.pageGoalWords > 0 {
                    Stepper(value: $stats.pageGoalWords, in: 50...5000, step: 50) {
                        LabeledContent(t("settings.writing.goal"),
                                       value: t("settings.writing.goalWords", ["n": "\(stats.pageGoalWords)"]))
                    }
                }
                Text(t("settings.writing.goalHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.writing.autosaveSection")) {
                LabeledContent(t("settings.writing.autosaveDelay")) {
                    HStack {
                        Slider(value: $autosaveMs,
                               in: EditorBehaviorPrefs.autosaveRange, step: 250)
                        Text(String(format: "%.2g s", autosaveMs / 1000))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text(t("settings.writing.autosaveHint"))
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
            Section(t("settings.sync.updateSection")) {
                Picker(t("settings.sync.pollCadence"), selection: $sync.pollMode) {
                    ForEach(SyncPollMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.inline)

                Text(t("settings.sync.cadenceHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.sync.pauseSection")) {
                Toggle(t("settings.sync.pauseToggle"), isOn: $sync.isPaused)
                Text(t("settings.sync.pauseHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.sync.statusSection")) {
                LabeledContent(t("settings.sync.state"), value: statusText)
                LabeledContent(t("settings.sync.lastSynced"), value: lastSyncedText)
                if sync.pendingCount > 0 {
                    LabeledContent(t("settings.sync.pending"),
                                   value: tn(sync.pendingCount, "settings.sync.pendingValue"))
                }
                if !sync.conflicts.isEmpty {
                    LabeledContent(t("settings.sync.conflicts"), value: "\(sync.conflicts.count)")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(t("settings.sync.syncNow")) { sync.syncManually() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch sync.status {
        case .idle:    return sync.isPaused ? t("sync.state.paused") : t("sync.state.ready")
        case .syncing: return t("sync.state.syncing")
        case .offline: return t("sync.state.offline")
        case .serverUnreachable: return t("sync.state.serverUnreachable")
        }
    }

    private var lastSyncedText: String {
        guard let last = sync.lastSyncedAt else { return t("sync.lastSynced.never") }
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: L10nStore.shared.localeCode)
        return rel.localizedString(for: last, relativeTo: Date())
    }
}

// MARK: - Rechtschreibung (lokale LanguageTool-Overrides)

private struct SpellcheckSettingsTab: View {
    @AppStorage(SpellcheckPrefs.enabledKey) private var localEnabled = true
    @AppStorage(SpellcheckPrefs.languageKey) private var languageRaw = "auto"

    var body: some View {
        Form {
            Section(t("settings.spell.section")) {
                Toggle(t("settings.spell.deviceToggle"), isOn: $localEnabled)
                Text(t("settings.spell.deviceHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.spell.languageSection")) {
                Picker(t("settings.spell.checkLanguage"), selection: $languageRaw) {
                    ForEach(SpellcheckLanguage.allCases) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
                .disabled(!localEnabled)
                Text(t("settings.spell.languageHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(t("settings.spell.serverNote"))
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
    @EnvironmentObject private var updater: UpdaterController
    @Environment(\.openURL) private var openURL
    @State private var showLogoutAlert = false
    @State private var showClearCacheAlert = false

    var body: some View {
        Form {
            Section(t("settings.account.signinSection")) {
                LabeledContent(t("settings.account.server"), value: ServerConfig.baseURLString)
                LabeledContent(t("settings.account.status"),
                               value: auth.state == .signedIn ? t("settings.account.signedIn") : t("settings.account.signedOut"))
                HStack {
                    Spacer()
                    Button(t("general.signOut"), role: .destructive) { showLogoutAlert = true }
                        .disabled(auth.state != .signedIn)
                }
                Text(t("settings.account.signOutHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // App-Update (Sparkle) — betrifft die native App selbst, getrennt
            // vom Editor-Bundle (Content) weiter unten. Hintergrund-Checks laufen
            // automatisch; dieser Button stösst eine manuelle Prüfung an.
            Section(t("settings.account.appUpdateSection")) {
                LabeledContent(t("settings.account.appVersion"), value: appVersion)
                HStack {
                    Spacer()
                    Button(t("settings.account.checkAppUpdate")) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                Text(t("settings.account.appUpdateHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.account.editorVersionSection")) {
                LabeledContent(t("settings.account.sourceCommit"), value: commitShort)
                HStack {
                    if editorBundle.isCheckingUpdate { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(t("settings.account.checkUpdate")) {
                        Task { await editorBundle.checkForUpdate() }
                    }
                    .disabled(editorBundle.isCheckingUpdate)
                }
                Text(t("settings.account.updateHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(t("settings.account.maintenanceSection")) {
                HStack {
                    Spacer()
                    Button(t("settings.account.clearCache")) { showClearCacheAlert = true }
                }
                Text(t("settings.account.clearCacheHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Datenschutz/Datenhaltung — in-app dokumentiert (keine externe URL).
            // Teilt den Wortlaut mit dem Login-Onboarding (`login.privacyBody`),
            // damit die Aussage an beiden Stellen identisch und wartbar bleibt.
            Section(t("settings.account.privacySection")) {
                Text(t("login.privacyBody"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(t("login.privacyShowFull")) {
                        openURL(ServerConfig.pageURL(onServer: ServerConfig.baseURLString,
                                                     path: "datenschutz"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(t("settings.account.signOutAlertTitle"), isPresented: $showLogoutAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("general.signOut"), role: .destructive) { auth.signOut() }
        } message: {
            Text(t("settings.account.signOutAlertMessage"))
        }
        .alert(t("settings.account.clearCacheAlertTitle"), isPresented: $showClearCacheAlert) {
            Button(t("general.cancel"), role: .cancel) {}
            Button(t("settings.account.clearAndReload"), role: .destructive) {
                Task { await editorBundle.clearEditorCache() }
            }
        } message: {
            Text(t("settings.account.clearCacheAlertMessage"))
        }
    }

    private var commitShort: String {
        guard let c = editorBundle.sourceCommit, !c.isEmpty, c != "unknown" else { return "—" }
        return String(c.prefix(10))
    }

    /// Sichtbare App-Version aus der Info.plist (CFBundleShortVersionString,
    /// gespeist aus MARKETING_VERSION in Version.xcconfig).
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "v\($0)" } ?? "—"
    }
}
