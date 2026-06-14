//
//  schreibwerkstatt_focuseditorApp.swift
//  schreibwerkstatt-focuseditor
//
//  Created by David Berger on 14.06.2026.
//

import SwiftUI

@main
struct schreibwerkstatt_focuseditorApp: App {
    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .task { await auth.bootstrap() }
        }
    }
}
