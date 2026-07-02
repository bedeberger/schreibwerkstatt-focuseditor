//
//  AppToolbar+Status.swift
//  schreibwerkstatt-focuseditor
//
//  Der Status-Cluster der `AppToolbar` (rechts): lokaler Save-Zustand, lebende
//  Schreibstatistik und Server-Sync-Status. Ausgelagert aus `AppToolbar.swift`,
//  damit die Shell-Datei schlank bleibt.
//

import SwiftUI

/// Lokaler Save-Zustand der offenen Seite (local-first) — bewusst getrennt vom
/// Server-Sync (`SyncStatusLabel`). Beantwortet die für eine Offline-Schreib-App
/// zentrale Frage „ist mein Text sicher?": `dirty` = Änderung offen, wird gleich
/// automatisch lokal gesichert; sonst = lokal gesichert. Sehr dezent (Icon +
/// Tooltip), um beim Schreiben nicht abzulenken.
struct SaveStateLabel: View {
    let dirty: Bool

    var body: some View {
        Image(systemName: dirty ? "circlebadge.fill" : "checkmark")
            .font(.system(size: dirty ? 9 : 11, weight: .semibold))
            // Offene Änderung → Marken-Gold (es passiert gleich etwas);
            // gesichert → ruhig zurückgenommen.
            .foregroundStyle(dirty ? BrandColor.accent : BrandColor.faint)
            // Sanfter Symbol-Wechsel dirty↔gesichert statt hartem Umspringen.
            .contentTransition(.symbolEffect(.replace))
            .animation(.easeInOut(duration: 0.2), value: dirty)
            .frame(width: 16)
            .help(dirty ? t("save.tip.dirty") : t("save.tip.saved"))
            .accessibilityLabel(dirty ? t("save.dirty") : t("save.saved"))
    }
}

/// Lebende Schreibstatistik für die Toolbar: Wort- und Zeichenzahl der offenen
/// Seite, heute auf ihr geschriebene Wörter UND Zeichen (Tages-Delta, überlebt
/// Neustart über die persistierte Baseline im `WritingStatsStore`) und Lesezeit,
/// plus eine schlanke Fortschrittsleiste, wenn ein Seitenziel gesetzt ist.
/// Format spiegelt den Focus-Counter des Mutterprojekts („… Wörter · … Zeichen"
/// / „… Wörter · … Zeichen heute", `editor.focus.counterTotal/counterToday`).
struct WritingStatsLabel: View {
    let words: Int
    let characters: Int
    let wordsToday: Int
    let charactersToday: Int
    let readingMinutes: Int
    let goal: Int
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.word.spacing")
                .foregroundStyle(BrandColor.muted)
            Text(t("toolbar.chars", ["n": "\(characters)"]))
            // Tages-Delta: nur Zeichen („… heute") — Zeichen sind die führende Metrik.
            Text(t("toolbar.todayChars", ["c": signed(charactersToday)]))
                .foregroundStyle(charactersToday != 0 ? BrandColor.muted : BrandColor.faint)
            if readingMinutes > 0 {
                Text(t("toolbar.minutes", ["n": "\(readingMinutes)"]))
                    .foregroundStyle(BrandColor.faint)
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 48)
                    // Ziel erreicht → Marken-Gold (Akzent) statt generischem Grün;
                    // darunter dezent gedämpft.
                    .tint(progress >= 1 ? BrandColor.accent : BrandColor.muted)
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .fixedSize()
        .help(tooltip)
        // Sonst liest VoiceOver die Fragmente einzeln vor (Icon, „1234 Wörter",
        // „+120", „5 Min") — stattdessen die fertige Tooltip-Zusammenfassung als
        // ein Element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    /// Vorzeichen-Formatierung wie der Web-Editor: „+120" / „−5" / „±0"
    /// (echtes Minus U+2212).
    private func signed(_ n: Int) -> String {
        if n > 0 { return "+\(n)" }
        if n < 0 { return "−\(abs(n))" }
        return "±0"
    }

    private var tooltip: String {
        let heute = t("toolbar.tip.todayChars", ["c": signed(charactersToday)])
        if goal > 0 {
            let pct = "\(Int(((progress ?? 0) * 100).rounded()))"
            return t("toolbar.tip.goal", ["words": "\(words)", "goal": "\(goal)", "pct": pct, "today": heute])
        }
        return t("toolbar.tip.noGoal", ["today": heute, "min": "\(readingMinutes)"])
    }
}

/// Schlanke Sync-Anzeige (Status + offene Konflikte) für die App-Toolbar.
/// Der Hover-Tooltip nennt den Zeitpunkt der letzten erfolgreichen Synchronisation.
struct SyncStatusLabel: View {
    let status: SyncEngine.Status
    let conflicts: [SyncEngine.Conflict]
    let lastSyncedAt: Date?
    /// Anzahl lokal noch nicht gepushter Seiten (Outbox) — im idle-Zustand dezent
    /// sichtbar, damit „X Seiten warten auf Upload" nicht nur im Settings-Tab steht.
    var pendingCount: Int = 0
    /// Letzter Sync-Fehler (Server erreicht, aber Push/Pull scheiterte, z. B. 5xx).
    /// Ein solcher Zustand endet als `.idle`, würde also sonst still verschluckt —
    /// hier als dezenter Hinweis sichtbar gemacht.
    var lastError: String?
    /// Öffnet die Konflikt-Auflösungs-Ansicht (Nebeneinander-Diff) für eine Seite.
    /// Die eigentliche lokal/server-Wahl trifft der Nutzer dort informiert.
    var onInspect: (SyncEngine.Conflict) -> Void = { _ in }

    /// Reservierter Mindest-Slot: hält die Nachbarn (Fokus-/Darstellungs-Knopf,
    /// Überlauf) ruhig, wenn der häufige idle↔syncing-Wechsel kurz den Spinner
    /// einblendet. Bemessen am Spinner; die selteneren, anhaltenden Text-Zustände
    /// (offline / „Server nicht erreichbar") dürfen ihn nach links überschreiten.
    private static let slotWidth: CGFloat = 22

    var body: some View {
        Group {
            if !conflicts.isEmpty {
                conflictMenu
            } else if status == .idle {
                idleContent
            } else {
                statusLabel
            }
        }
        .frame(minWidth: Self.slotWidth, alignment: .trailing)
    }

    /// idle = kein laufender Sync. Vollständig sauber (nichts offen, kein Fehler)
    /// zeigt bewusst NICHTS — kein Dauer-Häkchen (weniger Chrome, ruhige Leiste).
    /// Sichtbar wird nur eine Abweichung: ein wiederholter Sync-Fehler (Server
    /// erreicht, aber 5xx o. Ä. → sonst still verschluckt) oder ungepushte Seiten
    /// in der Outbox.
    @ViewBuilder
    private var idleContent: some View {
        if lastError != nil {
            syncErrorLabel
        } else if pendingCount > 0 {
            pendingLabel
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Ungepushte Seiten (Outbox) — dezenter Aufwärtspfeil + Zahl. Signalisiert
    /// „lokal gesichert, wartet auf Upload" ohne Alarm (Marken-Muted, kein Rot).
    private var pendingLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.circle")
            Text("\(pendingCount)")
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .fixedSize()
        .help(tn(pendingCount, "toolbar.tip.pending"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tn(pendingCount, "toolbar.tip.pending"))
    }

    /// Anhaltender Sync-Fehler bei erreichtem Server (endet als `.idle`) — dezent
    /// im Warn-Ton, damit die stille Degradierung sichtbar wird. Details im Tooltip.
    private var syncErrorLabel: some View {
        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            .font(.system(size: 12))
            .foregroundStyle(BrandColor.warning)
            .fixedSize()
            .help(t("toolbar.tip.syncError", ["msg": lastError ?? ""]))
            .accessibilityLabel(t("toolbar.tip.syncError", ["msg": lastError ?? ""]))
    }

    /// Klickbares Konflikt-Menü: pro betroffener Seite öffnet ein Klick die
    /// Auflösungs-Ansicht (Nebeneinander-Diff) — statt blinder lokal/server-Wahl.
    private var conflictMenu: some View {
        Menu {
            ForEach(conflicts) { c in
                Button(t("conflict.inspect", ["page": c.pageName ?? c.pageId])) {
                    // macOS-SwiftUI: ein `.sheet` direkt aus der Menu-Aktion heraus
                    // präsentieren schlägt fehl (das schließende NSMenu schluckt das
                    // Event) — darum einen Runloop-Tick verschieben.
                    DispatchQueue.main.async { onInspect(c) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(BrandColor.warning)
                Text(tn(conflicts.count, "toolbar.conflicts"))
            }
            .font(BrandFont.sans(11))
            .foregroundStyle(BrandColor.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(t("toolbar.tip.conflicts"))
        .accessibilityLabel(t("toolbar.tip.conflicts"))
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            switch status {
            case .syncing:
                // Nur ein dezenter Spinner an der Stelle des Idle-Icons —
                // kein Text, damit das ~3s-Polling die Toolbar nicht ständig
                // umbricht/flackert. Der Tooltip nennt weiterhin den Zustand.
                ProgressView().controlSize(.small)
            case .offline:
                Image(systemName: "wifi.slash").foregroundStyle(BrandColor.muted)
                Text(t("sync.state.offline"))
            case .serverUnreachable:
                // Netz da, aber Server antwortet nicht — deutlich (orange)
                // anzeigen, damit es nicht wie ein sauberer Sync-Zustand wirkt.
                Image(systemName: "exclamationmark.icloud").foregroundStyle(BrandColor.warning)
                Text(t("sync.state.serverUnreachable"))
            case .idle:
                // Wird via `body` nie erreicht (idle = unsichtbar); nur für die
                // Vollständigkeit des Switch.
                EmptyView()
            }
        }
        .font(BrandFont.sans(11))
        .foregroundStyle(BrandColor.muted)
        .help(tooltip)
        // Icon (wifi.slash / icloud) ist dekorativ — als ein Element mit der
        // Tooltip-Beschreibung vorlesen statt Icon + Text getrennt.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    /// „Zuletzt synchronisiert“ als relative Zeit, sonst der aktuelle Zustand.
    private var tooltip: String {
        // Server-Unerreichbarkeit ist ein aktiver Fehlerzustand — auch wenn früher
        // schon einmal erfolgreich synchronisiert wurde, geht sie der „zuletzt
        // synchronisiert"-Meldung vor.
        if status == .serverUnreachable { return t("toolbar.tip.serverUnreachable") }
        if status == .offline { return t("toolbar.tip.offline") }
        if let last = lastSyncedAt {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: L10nStore.shared.localeCode)
            return t("toolbar.tip.lastSynced", ["rel": rel.localizedString(for: last, relativeTo: Date())])
        }
        return t("toolbar.tip.notSynced")
    }
}
