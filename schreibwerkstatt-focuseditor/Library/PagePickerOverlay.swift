//
//  PagePickerOverlay.swift
//  schreibwerkstatt-focuseditor
//
//  Beschwörbarer Seiten-Picker (⌘O) — ein schwebendes Such-/Listen-Overlay über
//  dem Editor, das nach der Auswahl wieder verschwindet. Maximal ablenkungsfrei:
//  keine dauerhafte Sidebar, kein Chrome beim Schreiben.
//
//  Bedienung: Tippen filtert, ⏎ öffnet den ersten Treffer, ⎋ oder Klick auf den
//  Hintergrund schliesst. Die Auswahl hebt die Seite über die Bridge (`openPage`)
//  in die WebView.
//
//  Gliederung: Ganz oben die Gruppe „Zuletzt geöffnet" (bis zu fünf Seiten des
//  aktiven Buchs in MRU-Reihenfolge, gerätelokal gemerkt — s.
//  `EditorBridge.recentPageIds` / `LibraryStore.recentPageRows`), darunter der
//  Kapitelbaum. Eine Seite kann darum ZWEIMAL in der Liste stehen; die Zeilen-
//  Identität ist entsprechend sektions-qualifiziert (`RowKey`).
//

import SwiftUI
import AppKit

struct PagePickerOverlay: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var isOpen: Bool

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Index der per Tastatur/Hover markierten Zeile in `filtered`.
    @State private var selected = 0
    /// Ziel für den Auto-Scroll — der `RowKey` der anzusteuernden Zeile (gleiche
    /// Identität wie die `ForEach`-Zeilen), NICHT der Lauf-Index. Wird NUR von der
    /// Tastatur-Navigation/Vorauswahl gesetzt, nicht vom Hover — sonst entsteht eine
    /// Rückkopplung (Hover → Scroll → Zeilen rutschen unter den Cursor → neuer
    /// Hover → …), die als Flackern sichtbar ist.
    @State private var scrollTarget: RowKey?
    /// Lokaler Key-Monitor für ↑/↓/⏎ — fängt die Tasten ab, bevor das fokussierte
    /// Suchfeld sie als Cursor-Bewegung/Submit schluckt.
    @State private var keyMonitor: Any?
    /// Letzte Cursor-Position (Screen-Koordinaten), bei der ein Hover die Auswahl
    /// gesetzt hat. Dient dazu, ECHTE Mausbewegung von „Zeilen rutschen beim
    /// Scrollen unter den ruhenden Cursor" zu unterscheiden — s. `onHover`.
    @State private var lastHoverLocation: NSPoint = .zero

    /// Memoisierte Trefferliste + Kapitel-Gruppierung. BEWUSST in `@State`, NICHT
    /// als computed property: bei einem grossen Buch (Tausende Seiten) wäre die
    /// Filterung + Gruppierung sonst bei JEDER Body-Neuberechnung fällig — und die
    /// triggert schon jeder Hover (`selected` ändert sich). Stattdessen nur bei
    /// echter Eingabe (`query`) oder neuer Seitenliste neu rechnen (`recompute()`),
    /// sodass Hover/Tastatur-Navigation rein über `selected` läuft.
    /// Flache Zeilenfolge in Anzeige-Reihenfolge (Gruppe „Zuletzt geöffnet" zuerst,
    /// dann der Kapitelbaum) — die Brücke zur Tastatur-Auswahl (`selected` ist ein
    /// Index hierin). Eine Seite kann ZWEIMAL vorkommen (oben in den Zuletzt-
    /// Geöffneten und an ihrem Platz im Baum), darum trägt jede Zeile einen
    /// sektions-qualifizierten `RowKey` als Identität statt der reinen Seiten-ID.
    @State private var filtered: [IndexedRow] = []
    @State private var groups: [PickerGroup] = []
    /// Zahl der ECHTEN Treffer im Kapitelbaum (ohne die Zuletzt-Geöffnet-Kopien) —
    /// speist die Trefferzahl im Suchfeld, die sonst durch die Duplikate zu hoch wäre.
    @State private var matchCount = 0
    /// Seiten-IDs, deren INHALT (Body, nicht nur Name) zur aktuellen Suche passt —
    /// async aus dem lokalen Volltext-Index (`library.searchContentIds`) gespeist.
    /// Erweitert die rein synchrone Namens-/Kapitelsuche in `recompute()`.
    @State private var contentMatches: Set<Int> = []
    /// Lief `recompute()` schon mindestens einmal? `filtered`/`groups` sind im
    /// ALLERERSTEN Body-Render noch leer (SwiftUI rendert einmal VOR `onAppear`,
    /// wo recompute läuft) — obwohl der Cache `library.pages` schon gefüllt ist.
    /// Ohne dieses Flag fiele dieser eine Frame auf den `filtered.isEmpty`-Branch
    /// und liesse beim Öffnen kurz den Leerzustand aufblitzen (sichtbares Flackern,
    /// v. a. bei einem gefüllten Buch). Bis zum ersten Rechnen darum NICHT den
    /// Leerzustand zeigen, sondern einen ruhigen leeren Platzhalter — die
    /// Einblend-Transition (opacity+scale) kaschiert ihn vollständig.
    @State private var hasComputed = false

    /// Sektions-qualifizierte Zeilen-/Gruppen-Identität. Eine Seite erscheint
    /// bewusst zweimal (Gruppe „Zuletzt geöffnet" UND ihr Platz im Kapitelbaum) —
    /// die reine Seiten-ID wäre als `ForEach`-/Scroll-Identität also doppelt, was
    /// SwiftUI mit recycelten Zeilen quittiert.
    private struct RowKey: Hashable {
        let section: Section
        let pageId: Int

        enum Section: Hashable { case recent, tree }
    }

    /// Eine Seitenzeile samt ihrem flachen Index in `filtered` — der Index ist die
    /// Brücke zur Tastatur-/Hover-Auswahl (`selected`), der `key` die Identität
    /// für `ForEach` und den Auto-Scroll.
    private struct IndexedRow: Identifiable {
        let index: Int
        let key: RowKey
        let row: PagePickerRow
        var id: RowKey { key }
    }

    /// Ein Block der Liste: entweder die Gruppe „Zuletzt geöffnet" (`isRecent`) oder
    /// ein Kapitelblock — ein zusammenhängender Lauf gleichen `path` in der
    /// depth-first-Reihenfolge (Top-Level-Seiten → leerer Pfad, kein Header).
    private struct PickerGroup: Identifiable {
        // Sektion + erste Seiten-ID im Lauf — eine STABILE, inhaltsgebundene
        // Identität. Bewusst NICHT der Lauf-Index: ein über Filterungen
        // wiederverwendeter Integer (0, 1, …) lässt SwiftUI in der `LazyVStack` mit
        // gepinnten Sektionen die alte (z. B. zuvor oben stehende) Sektion samt
        // Zeilen recyceln, statt sie an den neuen Treffer zu binden — sichtbar als
        // „falsche Seiten unter richtigem Kapitel-Header".
        let id: RowKey
        let isRecent: Bool
        let path: [String]   // voller Kapitelpfad; leer = Top-Level bzw. Zuletzt-Gruppe
        let rows: [IndexedRow]
    }

    /// Rechnet Trefferliste (`filtered`) + Gruppierung (`groups`) neu und legt sie im
    /// State ab: zuerst die zuletzt geöffneten Seiten, dann die Kapitelblöcke. Nur
    /// bei echter Änderung der Eingabe/Seitenliste aufrufen (s. `filtered`-Doku) —
    /// NICHT bei jedem Render.
    ///
    /// Die Kapitelblöcke entstehen als Läufe gleichen VOLLEN Pfads: da `pickerRows`
    /// depth-first abflacht (alle Seiten eines Kapitels stehen am Stück), genügt das
    /// Aufbrechen bei jedem Pfadwechsel — gleichnamige Unterkapitel verschiedener
    /// Eltern (z. B. „Januar" in 2025 und 2026) bleiben so getrennte Blöcke, statt
    /// fälschlich zu verschmelzen.
    private func recompute() {
        let treeRows: [PagePickerRow]
        if query.isEmpty {
            treeRows = library.pages
        } else {
            treeRows = library.pages.filter { row in
                row.name.localizedCaseInsensitiveContains(query)
                // Treffer in JEDEM Pfad-Segment (Jahr ODER Monat), nicht nur im Leaf —
                // so findet „2026" auch die Seiten unter dem Jahres-Kapitel.
                || row.chapterPath.contains { $0.localizedCaseInsensitiveContains(query) }
                // Volltext-Treffer im Seiteninhalt (async nachgeladen, s. contentMatches).
                || contentMatches.contains(row.id)
            }
        }
        // Zuletzt geöffnete Seiten — bei aktiver Suche auf die Treffer eingeschränkt,
        // damit die Gruppe die Ergebnisliste nicht mit Nicht-Treffern verwässert.
        let matchIds = Set(treeRows.map(\.id))
        let recents = library.recentPageRows().filter { matchIds.contains($0.id) }

        var flat: [IndexedRow] = []
        var built: [PickerGroup] = []

        func appendGroup(_ section: RowKey.Section, path: [String], rows: [PagePickerRow]) {
            guard let first = rows.first else { return }
            var entries: [IndexedRow] = []
            for row in rows {
                let entry = IndexedRow(index: flat.count,
                                       key: RowKey(section: section, pageId: row.id),
                                       row: row)
                flat.append(entry)
                entries.append(entry)
            }
            built.append(PickerGroup(id: RowKey(section: section, pageId: first.id),
                                     isRecent: section == .recent,
                                     path: path, rows: entries))
        }

        appendGroup(.recent, path: [], rows: recents)

        var run: [PagePickerRow] = []
        var runPath: [String] = []
        for row in treeRows {
            if !run.isEmpty && row.chapterPath != runPath {
                appendGroup(.tree, path: runPath, rows: run)
                run = []
            }
            if run.isEmpty { runPath = row.chapterPath }
            run.append(row)
        }
        appendGroup(.tree, path: runPath, rows: run)

        filtered = flat
        groups = built
        matchCount = treeRows.count
        hasComputed = true
    }

    var body: some View {
        ZStack {
            // Abdunkelnder Hintergrund — Klick schliesst.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)   // rein dekorativ (⎋ schliesst ebenfalls)

            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .frame(width: 460, height: 420)
            // Pfeil-Cursor für das GANZE Overlay erzwingen. An die View gebunden
            // (nicht das transiente `NSCursor.set()`) → gewinnt zuverlässig über
            // die darunterliegende WebView, die sonst ihren I-Beam durchdrückt
            // (sichtbar v. a. wenn man aus dem Editor in die Liste fährt). Das
            // Suchfeld setzt seinen eigenen Text-Cursor lokal (s. `searchField`).
            .pointerStyle(.default)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandColor.muted.opacity(0.2))
            )
            .shadow(radius: 30, y: 8)
            // Modal: VoiceOver soll nicht in den Editor dahinter wandern, solange
            // der Picker offen ist.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(t("picker.a11y.dialog"))
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { close() }               // ⎋
        .onAppear {
            // Cursor wird über `.pointerStyle(.default)` am Overlay erzwungen —
            // kein manuelles `NSCursor.set()` mehr nötig (war unzuverlässig, die
            // WebView überschrieb es wieder).
            focusSearchField()
            installKeyMonitor()
            recompute()                           // Trefferliste/Gruppen aus dem Cache
            selectOpenPage()                      // falls Seiten schon im Cache stehen
            Task { await library.refreshPages() } // beim Öffnen frisch ziehen
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: library.pages) { _, _ in          // async nachgeladen → springen
            recompute()                                 // neue Liste → Treffer/Gruppen neu
            selectOpenPage()
        }
        .onChange(of: query) { _, newQuery in           // neue Suche → oben anfangen
            recompute()                                 // sofort: Namens-/Kapiteltreffer
            selected = 0
            scrollTarget = filtered.first?.key          // erste Trefferzeile
            runContentSearch(for: newQuery)             // async: Inhaltstreffer nachladen
        }
    }

    /// Stösst die Volltextsuche über den Seiteninhalt an (async, lokaler Index) und
    /// führt nach Eintreffen ein erneutes `recompute()` aus. Erst ab zwei Zeichen,
    /// damit eine Ein-Zeichen-Eingabe nicht das halbe Buch als Inhaltstreffer zieht.
    /// Staleness-Schutz: ein Ergebnis wird nur übernommen, wenn die Eingabe seither
    /// unverändert ist (sonst überschriebe ein langsamer Lauf eine neuere Suche).
    private func runContentSearch(for q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            if !contentMatches.isEmpty { contentMatches = []; recompute() }
            return
        }
        Task {
            let ids = await library.searchContentIds(query: trimmed)
            guard q == query else { return }   // Eingabe inzwischen weiter → verwerfen
            contentMatches = ids
            recompute()
        }
    }

    // MARK: Teile

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BrandColor.muted)
                .accessibilityHidden(true)   // dekorativ; das Textfeld trägt das Label
            TextField(t("picker.searchPage"), text: $query)
                .textFieldStyle(.plain)
                .font(BrandFont.sans(14))
                .focused($searchFocused)
                .onSubmit(openSelected)         // ⏎ (Fallback; Monitor fängt i. d. R. ab)
                // Text-Cursor nur hier — übersteuert das `.default` des Overlays.
                .pointerStyle(.horizontalText)
                .accessibilityLabel(t("picker.searchPage"))
                .accessibilityHint(t("picker.a11y.searchHint"))

            if !library.pages.isEmpty {
                Text("\(matchCount)")
                    .font(BrandFont.sans(11))
                    .monospacedDigit()
                    .foregroundStyle(BrandColor.muted)
                    // Nackte Zahl wäre ohne Kontext vorgelesen.
                    .accessibilityLabel(tn(matchCount, "picker.a11y.matchCount"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if !hasComputed {
            // Erster Frame vor dem ersten recompute() — ruhig leer lassen statt
            // den Leerzustand aufblitzen zu lassen (s. `hasComputed`).
            Color.clear
        } else if library.isLoadingPages && library.pages.isEmpty {
            centered {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(t("picker.loadingPages"))
                        .font(BrandFont.sans(12))
                        .foregroundStyle(BrandColor.muted)
                }
            }
        } else if filtered.isEmpty {
            centered { emptyState }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.rows) { entry in
                                    // KEINE explizite `.id(entry.index)` — der
                                    // Lauf-Index wird über Filterungen wiederverwendet
                                    // und liess SwiftUI alte Zeilen recyceln (falscher
                                    // Seitenname unter richtigem Kapitel). Die `ForEach`-
                                    // Identität ist `IndexedRow.id` = `RowKey` (stabil);
                                    // der Auto-Scroll zielt darum ebenfalls auf den RowKey.
                                    rowButton(entry.row, isSelected: entry.index == selected,
                                              // In der Zuletzt-Gruppe ohne Kapitel-Einzug —
                                              // die Zeilen stehen dort nicht im Baum.
                                              indent: group.isRecent ? 0 : entry.row.depth)
                                        // Hover markiert die Zeile. Der Pfeil-Cursor kommt
                                        // jetzt vom `.pointerStyle(.default)` am Overlay
                                        // (zuverlässiger als das frühere `NSCursor.set()`).
                                        .onHover { hovering in
                                            guard hovering else { return }
                                            // Nur ECHTE Mausbewegung darf die Auswahl
                                            // verschieben. Beim Scrollen ruht der Cursor,
                                            // während die Zeilen unter ihm durchrutschen →
                                            // onHover feuert reihenweise mit GLEICHER
                                            // `mouseLocation`. Würde das `selected` setzen,
                                            // wanderte die Markierung flackernd durch die
                                            // Liste (sichtbar genau beim Scrollen). Position
                                            // unverändert → Hover ignorieren.
                                            let loc = NSEvent.mouseLocation
                                            guard loc != lastHoverLocation else { return }
                                            lastHoverLocation = loc
                                            selected = entry.index
                                        }
                                    Divider().opacity(0.4)
                                }
                            } header: {
                                if group.isRecent {
                                    recentHeader()
                                } else if !group.path.isEmpty {
                                    chapterHeader(group.path)
                                }
                            }
                        }
                    }
                }
                .onChange(of: scrollTarget) { _, new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                // Buchwechsel → komplette Scroll-Subtree neu aufbauen. Trotz
                // inhaltsgebundener Sektions-/Zeilen-IDs hält die `LazyVStack` mit
                // gepinnten Sektionen beim Datentausch (altes Buch → neues Buch)
                // gelegentlich einen recycelten Header der alten Sektion → „neuer
                // Kapitel-Header über alten Seiten". Das buch-gebundene `.id` wirft
                // den alten Baum weg (feuert NUR beim Buchwechsel, nicht bei
                // Hover/Tippen → keine Scroll-Performance-Kosten).
                .id(library.activeBookId)
            }
        }
    }

    /// Leerzustand des Pickers — unterscheidet drei Fälle (Suche ohne Treffer /
    /// kein Buch gewählt / Buch ohne Seiten) mit Icon, klarer Aussage und einem
    /// konkreten nächsten Schritt, statt einer einzelnen kargen Textzeile.
    @ViewBuilder
    private var emptyState: some View {
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
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 280)
    }

    /// Pinned Kapitel-Überschrift als Breadcrumb über den vollen Pfad
    /// (z. B. „2026 › JANUAR"). Eltern-Segmente sind gedimmt, das Blatt-Kapitel
    /// betont — so bleibt das übergeordnete Kapitel sichtbar (auch wenn es selbst
    /// keine Seiten hat) und gleichnamige Kapitel verschiedener Jahre sind
    /// unterscheidbar. Bleibt beim Scrollen oben kleben; bei Platzmangel wird in
    /// der Mitte gekürzt, damit Jahr (vorn) und Monat (hinten) sichtbar bleiben.
    private func chapterHeader(_ path: [String]) -> some View {
        sectionHeader(breadcrumb(path), depth: path.count,
                      a11y: path.joined(separator: " › "))
    }

    /// Überschrift der Gruppe „Zuletzt geöffnet" — gleiche Optik wie ein
    /// Kapitel-Header (gepinnt, gedimmt), aber ein fester Titel statt Breadcrumb.
    private func recentHeader() -> some View {
        let title = t("picker.recentSection")
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

    /// Eine Seitenzeile. `indent` ist die Einzugs-Tiefe (Kapitel-Tiefe im Baum,
    /// 0 in der Zuletzt-Gruppe) — bewusst getrennt von `row.depth`, weil dieselbe
    /// Seite in beiden Gruppen unterschiedlich eingerückt steht.
    private func rowButton(_ row: PagePickerRow, isSelected: Bool, indent: Int) -> some View {
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
                    Text(Self.relative(updated))
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
            parts.append(Self.relative(updated))
        }
        return parts.joined(separator: ", ")
    }

    /// Passt die Zeile NUR über ihren Inhalt (Volltext), nicht über Name oder
    /// Kapitelpfad? Dann trägt sie das „im Text"-Badge. Bei leerer Suche nie.
    private func isContentOnlyMatch(_ row: PagePickerRow) -> Bool {
        guard !query.isEmpty, contentMatches.contains(row.id) else { return false }
        let nameOrChapter = row.name.localizedCaseInsensitiveContains(query)
            || row.chapterPath.contains { $0.localizedCaseInsensitiveContains(query) }
        return !nameOrChapter
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack { Spacer(); inner(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Wiederverwendeter Formatter — `RelativeDateTimeFormatter` ist teuer in der
    /// Erzeugung; bei einem grossen Buch würde ein neuer pro Zeile/Render beim
    /// Scrollen spürbar bremsen. Locale wird vor jeder Nutzung nachgeführt (falls
    /// der Nutzer die App-Sprache umstellt). MainActor-gebunden wie die ganze View.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Letzte Änderung als kurze Relativ-Zeit in der App-Sprache (z. B. „vor 3 Std.").
    private static func relative(_ date: Date) -> String {
        let f = relativeFormatter
        f.locale = Locale(identifier: L10nStore.shared.localeCode)
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Aktionen

    private func open(_ row: PagePickerRow) {
        library.openPage(row)
        close()
    }

    /// Markiert die aktuell geöffnete Seite und scrollt sie ins Bild — damit ein
    /// grosses Buch dort aufgeht, „wo man ist", statt immer oben. Nur ohne aktive
    /// Suche; sobald gefiltert wird, gewinnt der erste Treffer (`onChange(query)`).
    private func selectOpenPage() {
        guard query.isEmpty, !filtered.isEmpty else { return }
        if let openId = library.openPageId,
           // Erstes Vorkommen: steht die offene Seite in der Zuletzt-Gruppe (der
           // Normalfall — sie ist die jüngste), bleibt die Liste damit oben und
           // zeigt die Gruppe „Zuletzt geöffnet"; sonst wird ihre Zeile im
           // Kapitelbaum angesteuert.
           let entry = filtered.first(where: { $0.row.id == openId }) {
            selected = entry.index
            scrollTarget = entry.key   // RowKey (Scroll-Identität), nicht der Index
        } else {
            // Offene Seite gehört nicht in dieses Buch (Buchwechsel) oder es ist
            // keine offen → auf die erste Zeile, statt auf einer veralteten Scroll-
            // Identität des alten Buchs hängenzubleiben (Liste bliebe sonst oben).
            selected = 0
            scrollTarget = filtered.first?.key
        }
    }

    /// Öffnet die aktuell markierte Zeile (Tastatur/Hover); fällt auf den ersten
    /// Treffer zurück, falls der Index durch eine neue Filterung verrutscht ist.
    private func openSelected() {
        guard !filtered.isEmpty else { return }
        let entry = filtered.indices.contains(selected) ? filtered[selected] : filtered[0]
        open(entry.row)
    }

    /// Bewegt die Markierung um `delta`, begrenzt auf die Trefferliste.
    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selected = max(0, min(filtered.count - 1, selected + delta))
        scrollTarget = filtered[selected].key   // RowKey; nur Tastatur-Nav scrollt mit
    }

    private func close() {
        isOpen = false
    }

    // MARK: Tastatur

    /// Holt den Tastatur-Fokus aufs Suchfeld. Der Editor-`WKWebView` klammert sich
    /// an den First Responder des Fensters; setzt man `searchFocused` nur synchron
    /// im `onAppear`, gewinnt die WebView und man tippt weiter auf der Seite statt
    /// ins Feld. Darum: WebView-First-Responder zuerst lösen (`makeFirstResponder(nil)`),
    /// dann den Fokus DEFERRED setzen — das Suchfeld ist erst im nächsten Runloop
    /// fertig in der Responder-Kette.
    private func focusSearchField() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Fängt ↑/↓/⏎ ab, solange das Overlay offen ist. Das Suchfeld behält den
    /// Fokus fürs Tippen; die Pfeiltasten steuern die Auswahl statt den Cursor.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: moveSelection(1);  return nil   // ↓
            case 126: moveSelection(-1); return nil   // ↑
            case 36, 76: openSelected(); return nil   // ⏎ / Enter
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
