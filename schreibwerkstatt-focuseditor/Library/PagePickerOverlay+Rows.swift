//
//  PagePickerOverlay+Rows.swift
//  schreibwerkstatt-focuseditor
//
//  Darstellung der Picker-Bestandteile: Seitenzeile (Name, Badges, Relativ-Zeit),
//  gepinnte Kapitel-Überschriften samt Breadcrumb, die Gruppen-Überschrift
//  „Zuletzt geöffnet" und der Leerzustand.
//
//  Reines Layout — welche Zeilen in welcher Gruppe stehen, entscheidet
//  [PagePickerModel](PagePickerModel.swift); der State liegt in
//  [PagePickerOverlay](PagePickerOverlay.swift).
//

import SwiftUI

extension PagePickerOverlay {

    // MARK: - Zeile

    /// Eine Seitenzeile. `indent` ist die Einzugs-Tiefe (Kapitel-Tiefe im Baum,
    /// 0 in der Zuletzt-Gruppe) — bewusst getrennt von `row.depth`, weil dieselbe
    /// Seite in beiden Gruppen unterschiedlich eingerückt steht.
    func rowButton(_ row: PagePickerRow, isSelected: Bool, indent: Int) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 6) {
                Text(row.name.isEmpty ? t("picker.untitled") : row.name)
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.id == library.openPageId {
                    Text(t("picker.openBadge"))
                        .font(BrandFont.sans(9, weight: .semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(BrandColor.primary.opacity(0.12),
                                    in: Capsule())
                } else if isContentOnlyMatch(row) {
                    // Erklärt, warum diese Zeile auftaucht, obwohl der Name nicht
                    // zur Suche passt: der Treffer steckt im Seitentext.
                    Text(t("picker.textMatch"))
                        .font(BrandFont.sans(9, weight: .semibold))
                        .foregroundStyle(BrandColor.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(BrandColor.muted.opacity(0.12),
                                    in: Capsule())
                }
                Spacer(minLength: 8)
                // Dezente Relativ-Zeit der letzten Änderung — Orientierung im
                // grossen Buch („woran habe ich zuletzt geschrieben?").
                if let updated = row.updatedAt {
                    Text(RelativeTime.string(for: updated))
                        .font(BrandFont.sans(10))
                        .monospacedDigit()
                        .foregroundStyle(BrandColor.faint)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.leading, CGFloat(indent) * 14 + 14)
            .padding(.trailing, 14)
            .contentShape(Rectangle())
            // Tastatur-/Hover-Fokus → Marken-Navy (primary). Gold bleibt dem
            // „etwas passiert gerade"-Zustand vorbehalten (ungespeichert /
            // Ziel erreicht); die Auswahl ist Navigation, kein Zustandswechsel.
            .background(isSelected ? BrandColor.primary.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        // Zeile ist ein klickbares Ziel → Zeigehand statt des Pfeil-Cursors, den das
        // `.pointerStyle(.default)` am Overlay sonst über allen Listenzeilen
        // erzwingt (sichtbar „nicht sinnig" über den Buttons). View-gebunden wie die
        // anderen klickbaren Ziele im Projekt (s. ContentView SwiftBar-Knopf).
        .pointerStyle(.link)
        // Eine Zeile = EIN VoiceOver-Element. Sonst liest der Screenreader Name,
        // Badge und Relativ-Zeit als drei zusammenhanglose Fragmente vor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel(row))
        .accessibilityHint(t("picker.a11y.openHint"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Vorlese-Text einer Zeile: Seitenname, Kapitelpfad, Zustand („geöffnet" /
    /// Volltext-Treffer) und die letzte Änderung — in dieser Reihenfolge, damit
    /// das Wichtigste zuerst kommt.
    private func rowLabel(_ row: PagePickerRow) -> String {
        var parts = [row.name.isEmpty ? t("picker.untitled") : row.name]
        if !row.chapterPath.isEmpty {
            parts.append(row.chapterPath.joined(separator: " › "))
        }
        if row.id == library.openPageId {
            parts.append(t("picker.openBadge"))
        } else if isContentOnlyMatch(row) {
            parts.append(t("picker.textMatch"))
        }
        if let updated = row.updatedAt {
            parts.append(RelativeTime.string(for: updated))
        }
        return parts.joined(separator: ", ")
    }

    /// Trägt die Zeile das „im Text"-Badge? Die Regel selbst (und damit die
    /// Deckung mit dem Filter) steht in `PagePickerModel`.
    private func isContentOnlyMatch(_ row: PagePickerRow) -> Bool {
        PagePickerModel.isContentOnlyMatch(row, query: query, contentMatches: contentMatches)
    }

    // MARK: - Überschriften

    /// Pinned Kapitel-Überschrift als Breadcrumb über den vollen Pfad
    /// (z. B. „2026 › JANUAR"). Eltern-Segmente sind gedimmt, das Blatt-Kapitel
    /// betont — so bleibt das übergeordnete Kapitel sichtbar (auch wenn es selbst
    /// keine Seiten hat) und gleichnamige Kapitel verschiedener Jahre sind
    /// unterscheidbar. Bleibt beim Scrollen oben kleben; bei Platzmangel wird in
    /// der Mitte gekürzt, damit Jahr (vorn) und Monat (hinten) sichtbar bleiben.
    func chapterHeader(_ path: [String]) -> some View {
        sectionHeader(breadcrumb(path), depth: path.count,
                      a11y: path.joined(separator: " › "))
    }

    /// Überschrift der Gruppe „Zuletzt geöffnet" — gleiche Optik wie ein
    /// Kapitel-Header (gepinnt, gedimmt), aber ein fester Titel statt Breadcrumb.
    func recentHeader() -> some View {
        fixedHeader(t("picker.recentSection"))
    }

    /// Überschrift der kapitellosen Seiten (Top-Level des Buchs). Ohne sie stünde
    /// dieser Block als EINZIGE Gruppe ohne Überschrift direkt unter der gepinnten
    /// Zeile „Zuletzt geöffnet" — die kapitellosen Seiten (typisch: „Vorwort")
    /// lasen sich dann als weitere zuletzt geöffnete Seiten, obwohl sie nie
    /// geöffnet wurden (gemeldet 2026-08-03). `ContentAPI.flatten` stellt die
    /// Top-Level-Seiten immer VOR die Kapitel, der Block ist also stets der erste
    /// des Baums — genau an der Nahtstelle zur Zuletzt-Gruppe.
    func topLevelHeader() -> some View {
        fixedHeader(t("picker.topLevelSection"))
    }

    /// Gepinnte Überschrift mit festem Titel (Zuletzt-Gruppe / kapitellose Seiten)
    /// — dieselbe Optik wie ein Kapitel-Header, nur ohne Breadcrumb.
    private func fixedHeader(_ title: String) -> some View {
        var styled = AttributedString(title.uppercased())
        styled.font = BrandFont.sans(10, weight: .semibold)
        styled.foregroundColor = BrandColor.muted
        styled.tracking = 0.5
        return sectionHeader(Text(styled), depth: 1, a11y: title)
    }

    /// Gemeinsames Gewand aller gepinnten Überschriften (Kapitel + Zuletzt-Gruppe).
    private func sectionHeader(_ label: Text, depth: Int, a11y: String) -> some View {
        label
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(max(0, depth - 1)) * 14 + 14)
            .padding(.trailing, 14)
            .background(.regularMaterial)
            // Der gepinnte Header schwebt beim Scrollen über den Zeilen darunter.
            // Sein Material-Hintergrund würde sonst die Klicks auf die verdeckte
            // Zeile schlucken → diese Seite liesse sich nicht mehr per Klick öffnen
            // (sichtbar als „manche Treffer nicht auswählbar"). Der Header ist rein
            // dekorativ (kein Button) → für Klicks transparent schalten, damit sie
            // an den darunterliegenden Zeilen-Button durchgehen.
            .allowsHitTesting(false)
            // Für VoiceOver eine echte Überschrift (Rotor-Navigation über die
            // Kapitel), statt der aufgesplitteten Breadcrumb-Fragmente.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11y)
            .accessibilityAddTraits(.isHeader)
    }

    /// Baut den Breadcrumb-`Text` aus dem Kapitelpfad: Trennzeichen „›" und
    /// Eltern-Segmente gedimmt, das letzte Segment (aktuelles Kapitel) betont.
    private func breadcrumb(_ path: [String]) -> Text {
        var out = AttributedString()
        for (i, segment) in path.enumerated() {
            if i > 0 {
                var sep = AttributedString(" › ")
                sep.font = BrandFont.sans(10)
                sep.foregroundColor = BrandColor.faint
                out += sep
            }
            let isLeaf = i == path.count - 1
            var seg = AttributedString(segment.uppercased())
            seg.font = BrandFont.sans(10, weight: isLeaf ? .semibold : .regular)
            seg.foregroundColor = isLeaf ? BrandColor.muted : BrandColor.faint
            seg.tracking = 0.5
            out += seg
        }
        return Text(out)
    }

    // MARK: - Leerzustand

    /// Leerzustand des Pickers — unterscheidet drei Fälle (Suche ohne Treffer /
    /// kein Buch gewählt / Buch ohne Seiten) mit Icon, klarer Aussage und einem
    /// konkreten nächsten Schritt, statt einer einzelnen kargen Textzeile.
    @ViewBuilder
    var emptyState: some View {
        let searching = !query.isEmpty
        // Ein Lade-/Verbindungsfehler (von refreshPages vermerkt, sobald auch der
        // lokale Spiegel leer ist) geht der „keine Seiten“-Aussage vor — sonst
        // sähe ein Offline-Zustand wie ein leeres Buch aus. Bei aktiver Suche
        // bleibt es bei „keine Treffer“.
        let loadError = searching ? nil : library.lastError
        let noBook = library.activeBookId == nil
        let icon = searching ? "magnifyingglass"
            : (loadError != nil ? "exclamationmark.icloud" : (noBook ? "books.vertical" : "doc.text"))
        let title = searching ? t("picker.noMatches")
            : (loadError != nil ? t("picker.loadError")
               : (noBook ? t("picker.noBookSelected") : t("picker.noPages")))
        let hint: String? = searching ? nil
            : (loadError != nil ? t("picker.loadErrorHint")
               : (noBook ? t("picker.noBookHint") : t("picker.noPagesHint")))

        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(loadError != nil ? Color.orange : BrandColor.faint)
                .accessibilityHidden(true)   // dekorativ; der Titel-Text trägt die Aussage
            Text(title)
                .font(BrandFont.sans(13))
                .foregroundStyle(BrandColor.muted)
            if let hint {
                Text(hint)
                    .font(BrandFont.sans(11))
                    .foregroundStyle(BrandColor.faint)
                    .multilineTextAlignment(.center)
            }
            if loadError != nil {
                Button(t("content.retry")) { Task { await library.refreshPages() } }
                    .buttonStyle(.plain)
                    .font(BrandFont.sans(11, weight: .semibold))
                    .foregroundStyle(BrandColor.primary)
                    .pointerStyle(.link)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 280)
    }

    /// Vertikal + horizontal zentrierter Inhalt (Lade-/Leerzustand).
    func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
