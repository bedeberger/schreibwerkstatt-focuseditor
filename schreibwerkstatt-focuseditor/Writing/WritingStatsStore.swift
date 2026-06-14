//
//  WritingStatsStore.swift
//  schreibwerkstatt-focuseditor
//
//  Lebende Schreibstatistik der offenen Seite (Wort-/Zeichenzahl, Lesezeit) und
//  das optionale Schreibziel. Die App fokussiert bewusst auf GENAU EINE Seite
//  (CLAUDE.md, „ablenkungsfreies Schreiben auf genau einer Seite"), darum ist
//  das Ziel pro Seite definiert — gut messbar, kein geräteübergreifendes
//  Baseline-Buchhalten nötig.
//
//  Die Zählung passiert in der WebView (sie kennt den gerenderten Text) und wird
//  über die Bridge-Op `reportStats` an Swift gemeldet — kein direkter DOM-Zugriff
//  aus Swift, kein Editor-Fork. Einstellungen (Anzeige an/aus, Zielwert) sind
//  LOKAL (UserDefaults).
//

import Foundation
import Combine

@MainActor
final class WritingStatsStore: ObservableObject {
    enum Key {
        static let showStats = "writing.showStats"
        static let pageGoal = "writing.pageGoalWords"
    }

    /// Wörter der aktuell offenen Seite (aus der WebView gemeldet).
    @Published private(set) var words: Int = 0
    /// Zeichen (inkl. Leerzeichen) der aktuell offenen Seite.
    @Published private(set) var characters: Int = 0

    /// Stats-Anzeige in der Toolbar ein-/ausblenden.
    @Published var showStats: Bool {
        didSet { UserDefaults.standard.set(showStats, forKey: Key.showStats) }
    }
    /// Wort-Ziel pro Seite (0 = kein Ziel → keine Fortschrittsanzeige).
    @Published var pageGoalWords: Int {
        didSet { UserDefaults.standard.set(pageGoalWords, forKey: Key.pageGoal) }
    }

    init() {
        let d = UserDefaults.standard
        showStats = (d.object(forKey: Key.showStats) as? Bool) ?? true
        pageGoalWords = d.integer(forKey: Key.pageGoal)   // Default 0 = aus
    }

    /// Geschätzte Lesezeit in Minuten (200 Wörter/Min, min. 1 bei Inhalt).
    var readingMinutes: Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / 200.0).rounded()))
    }

    /// Fortschritt zum Seitenziel in [0, 1] — `nil`, wenn kein Ziel gesetzt.
    var goalProgress: Double? {
        guard pageGoalWords > 0 else { return nil }
        return min(1.0, Double(words) / Double(pageGoalWords))
    }

    /// Koppelt den Store an die Bridge: eingehende `reportStats` aktualisieren
    /// die Live-Zahlen. Schwach gehalten — AppCore besitzt die Bridge.
    func attach(to bridge: EditorBridge) {
        bridge.onStats = { [weak self] words, chars in
            self?.words = words
            self?.characters = chars
        }
    }
}
