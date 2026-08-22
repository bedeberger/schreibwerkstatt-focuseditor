//
//  ServerSeededChoice.swift
//  schreibwerkstatt-focuseditor
//
//  Die Regel „lokale Wahl gewinnt, sonst folgt der Server" — für die
//  Einstellungen, die es sowohl gerätelokal als auch im Server-Profil gibt
//  (Fokus-Granularität, App-Sprache).
//
//  Der knifflige Teil ist nicht der Vergleich, sondern die Unterdrückung der
//  Persistenz WÄHREND des Seedings: schriebe der eingespielte Server-Wert einen
//  UserDefaults-Eintrag, gälte er ab sofort als lokale Wahl und die Einstellung
//  folgte dem Server nie wieder. Diese Falle stand zweimal im Code — hier steht
//  sie einmal, mit ihrer Begründung.
//
//  Bewusst KEIN Protokoll mit Default-Implementierung: die zwei Controller
//  unterscheiden sich in Werttyp und Server-Abbildung (die Sprache normalisiert
//  „de-CH" auf „de"), nur der Seed-Mechanismus ist gemeinsam. Ein kleines
//  Hilfsobjekt hält genau ihn — den Rest behält jeder Controller.
//

import Foundation

@MainActor
final class ServerSeededChoice {
    private let storageKey: String

    /// Läuft gerade ein Seed? Solange schreibt `persist(_:)` nicht.
    private(set) var isSeeding = false

    init(storageKey: String) {
        self.storageKey = storageKey
    }

    /// Hat der Nutzer lokal gewählt? Genau dann liegt ein UserDefaults-Eintrag
    /// vor — Server-Seeding ist dann dauerhaft gesperrt.
    var hasLocalOverride: Bool {
        UserDefaults.standard.object(forKey: storageKey) != nil
    }

    /// Persistiert die Wahl des Nutzers. Während eines Seeds ein No-op, damit ein
    /// eingespielter Server-Wert nicht als lokale Wahl zählt.
    func persist(_ value: String) {
        guard !isSeeding else { return }
        UserDefaults.standard.set(value, forKey: storageKey)
    }

    /// Spielt einen Server-Wert ein. `apply` setzt die `@Published`-Eigenschaft
    /// wie gewohnt (UI aktualisiert sich, der Wert wird live weitergereicht) —
    /// nur die Persistenz bleibt aus.
    func seed(_ apply: () -> Void) {
        isSeeding = true
        apply()
        isSeeding = false
    }
}
