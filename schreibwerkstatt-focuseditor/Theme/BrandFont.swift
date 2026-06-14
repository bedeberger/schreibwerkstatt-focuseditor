//
//  BrandFont.swift
//  schreibwerkstatt-focuseditor
//
//  Native Entsprechung der Typografie-Tokens
//  (public/css/tokens/typography.css). Das Web-Bundle nutzt self-hosted
//  Inter (Sans) + Source Serif 4 (Headings/Reading). In der nativen Shell
//  greifen wir auf die System-Pendants zu: SF (Sans) und den .serif-Design
//  als Stellvertreter für Source Serif 4 — wie die CSS-Fallback-Stacks.
//

import SwiftUI

enum BrandFont {
    /// Serif (editorial) — Headings, Wordmark, Reading-Frame.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Sans (UI) — Buttons, Labels, dichte Bedienelemente.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
