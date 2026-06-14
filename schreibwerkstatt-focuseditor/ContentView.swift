//
//  ContentView.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()

            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .accessibilityLabel("Schreibwerkstatt")

                VStack(spacing: 6) {
                    Text("Schreibwerkstatt")
                        .font(BrandFont.serif(34, weight: .semibold))
                        .foregroundStyle(BrandColor.text)

                    Text("Focus-Editor")
                        .font(BrandFont.sans(15, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(BrandColor.accent)
                }

                Text("Ablenkungsfreies Schreiben — voll offline.")
                    .font(BrandFont.sans(13))
                    .foregroundStyle(BrandColor.muted)
                    .padding(.top, 2)
            }
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

#Preview {
    ContentView()
}
