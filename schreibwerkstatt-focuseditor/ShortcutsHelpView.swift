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
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 22)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor))
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
                .font(.headline)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ShortcutRow(keys: row.keys, label: row.label)
                if row.label != rows.last?.label {
                    Divider()
                }
            }
        }
    }
}

struct ShortcutsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ShortcutSection(title: "App & Fenster", rows: [
                    (["⌃", "⌘", "F"], "Vollbild ein/aus (ablenkungsfrei)"),
                    (["⌘", "⇧", "S"], "Jetzt synchronisieren"),
                    (["⌘", ","], "Einstellungen öffnen"),
                    (["⌘", "?"], "Diese Tastaturkürzel-Hilfe"),
                ])

                ShortcutSection(title: "Seiten", rows: [
                    (["⌘", "O"], "Seite öffnen (Picker)"),
                    (["⏎"], "Im Picker: ersten Treffer öffnen"),
                    (["⎋"], "Picker schließen"),
                ])

                ShortcutSection(title: "Editor", rows: [
                    (["⌘", "⇧", "E"], "Fokus-Modus ein/aus"),
                    (["⌘", "L"], "Cursor-Zeile mittig zentrieren"),
                    (["⌘", "B"], "Fett"),
                    (["⌘", "I"], "Kursiv"),
                    (["⌘", "U"], "Unterstrichen"),
                    (["⎋"], "Fokus-Modus verlassen / Menü schließen"),
                ])

                Text("⌘ Befehl · ⌃ Control · ⇧ Umschalt · ⏎ Enter · ⎋ Escape")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380, height: 520)
    }
}

#Preview {
    ShortcutsHelpView()
}
