//
//  ShortcutsHelpView.swift
//  schreibwerkstatt-focuseditor
//
//  Tastaturkürzel-Hilfe. Erreichbar über das Help-Menü (⌘?). Listet die
//  Shortcuts des macOS-Clients und die wichtigsten des OTA-Editors (Focus).
//

import SwiftUI

/// Ein einzelnes Tastenkürzel: Beschreibung + die Tasten-Capsules.
private struct ShortcutRow: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(BrandFont.sans(13))
                .foregroundStyle(BrandColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(BrandFont.sans(12, weight: .medium))
                        .foregroundStyle(BrandColor.muted)
                        .frame(minWidth: 22)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(BrandColor.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(BrandColor.faint.opacity(0.6))
                                )
                        )
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Eine thematische Gruppe von Kürzeln mit Überschrift.
private struct ShortcutSection: View {
    let title: String
    let rows: [(keys: [String], label: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.serif(15, weight: .semibold))
                .foregroundStyle(BrandColor.text)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ShortcutRow(keys: row.keys, label: row.label)
                if row.label != rows.last?.label {
                    Divider().overlay(BrandColor.faint.opacity(0.35))
                }
            }
        }
    }
}

struct ShortcutsHelpView: View {
    /// Sprachwechsel rendert die Hilfe neu (eigenes Fenster).
    @EnvironmentObject private var loc: LocalizationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShortcutSection(title: t("shortcuts.section.app"), rows: [
                    (["⌃", "⌘", "F"], t("shortcuts.fullscreen")),
                    (["⌘", "S"], t("shortcuts.syncNow")),
                    (["⌘", ","], t("shortcuts.openSettings")),
                    (["⌘", "?"], t("shortcuts.thisHelp")),
                ])

                ShortcutSection(title: t("shortcuts.section.pages"), rows: [
                    (["⌘", "O"], t("shortcuts.openPage")),
                    (["⏎"], t("shortcuts.pickerOpenFirst")),
                    (["⎋"], t("shortcuts.pickerClose")),
                ])

                ShortcutSection(title: t("shortcuts.section.editor"), rows: [
                    (["⌘", "⇧", "E"], t("shortcuts.focusToggle")),
                    (["⌘", "L"], t("shortcuts.centerLine")),
                    (["⌘", "⇧", "S"], t("shortcuts.synonyms")),
                    (["⌘", "B"], t("shortcuts.bold")),
                    (["⌘", "I"], t("shortcuts.italic")),
                    (["⌘", "U"], t("shortcuts.underline")),
                    (["⎋"], t("shortcuts.focusExit")),
                ])

                Text(t("shortcuts.legend"))
                    .font(BrandFont.sans(11))
                    .foregroundStyle(BrandColor.faint)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrandColor.bg)
        .frame(width: 380, height: 520)
    }
}

#Preview {
    ShortcutsHelpView()
        .environmentObject(LocalizationController())
}
