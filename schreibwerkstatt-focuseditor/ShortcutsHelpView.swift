//
//  ShortcutsHelpView.swift
//  schreibwerkstatt-focuseditor
//
//  Tastaturkürzel-Hilfe. Erreichbar über das Help-Menü (⌘?). Listet die
//  Shortcuts des macOS-Clients und die wichtigsten des OTA-Editors (Focus).
//
//  Die Liste wird VOLLSTÄNDIG aus [Shortcuts.swift](Shortcuts.swift) gerendert —
//  hier steht kein Kürzel mehr von Hand. Auch die Tasten-Capsules leitet der
//  Katalog aus `key`/`modifiers` ab, sodass Deklaration und Anzeige nicht
//  auseinanderlaufen können (genau das war passiert: ⌘N/⌘⇧R fehlten, und ⌘⇧E
//  stand als Fokus-Umschalter drin, obwohl ein Menübefehl die Taste belegt hatte).
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
private struct ShortcutSectionView: View {
    let section: ShortcutSection

    private var specs: [ShortcutSpec] { Shortcuts.inSection(section) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t(section.titleKey))
                .font(BrandFont.serif(15, weight: .semibold))
                .foregroundStyle(BrandColor.text)
                .padding(.bottom, 2)
            // Trenner über den Index statt über den Label-Vergleich: zwei
            // Einträge dürfen denselben Text tragen (⎋ schliesst den Picker bzw.
            // verlässt den Fokus-Modus), sonst verschwände dort ein Trenner.
            ForEach(Array(specs.enumerated()), id: \.element.id) { index, spec in
                ShortcutRow(keys: spec.glyphs, label: spec.label)
                if index < specs.count - 1 {
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
                ForEach(ShortcutSection.allCases, id: \.self) { section in
                    ShortcutSectionView(section: section)
                }

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
