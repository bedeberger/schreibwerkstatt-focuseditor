//
//  SettingsView.swift
//  schreibwerkstatt-focuseditor
//
//  Natives Einstellungen-Fenster (⌘,). TabView-Shell — die einzelnen Tabs liegen
//  thematisch gruppiert in eigenen Dateien (`SettingsTabs+General/+Editor/+System`),
//  damit keine Datei über das Zeilen-Limit wächst. Alle Werte sind gerätelokal
//  (UserDefaults/Controller); editor-wirksame Werte fliessen über die Bridge als
//  CSS — kein Editor-Fork.
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
