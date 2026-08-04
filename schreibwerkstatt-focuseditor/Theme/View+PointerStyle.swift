//
//  View+PointerStyle.swift
//  schreibwerkstatt-focuseditor
//
//  `.pointerStyle(…)` gibt es erst ab macOS 15. Das Deployment-Target liegt
//  aber auf 14.0, damit die App im Store für deutlich mehr Leute installierbar
//  ist — der Zeiger-Stil ist das einzige, was dem im Weg stand.
//
//  Darum laufen ALLE Aufrufe über diese drei Hüllen: ab macOS 15 setzen sie den
//  Zeiger wie bisher, auf 14 lassen sie die View unverändert. Rein kosmetisch,
//  keine Funktion hängt daran (auf 14 zeigt macOS den Standardzeiger).
//
//  Regel: im Projekt nie direkt `.pointerStyle(…)` aufrufen, sonst bricht der
//  Build gegen 14.0 wieder.
//

import SwiftUI

extension View {

    /// Normaler Pfeil — überschreibt z. B. den I-Beam, den eine darunter
    /// liegende WebView durchreicht.
    @ViewBuilder
    func pointerDefault() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.default)
        } else {
            self
        }
    }

    /// Zeigehand für klickbare Ziele (Knöpfe, Listenzeilen, Links).
    @ViewBuilder
    func pointerLink() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }

    /// I-Beam für Texteingaben (Suchfeld im Seiten-Picker).
    @ViewBuilder
    func pointerHorizontalText() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.horizontalText)
        } else {
            self
        }
    }
}
