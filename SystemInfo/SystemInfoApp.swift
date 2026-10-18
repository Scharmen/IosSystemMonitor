//
//  SystemInfoApp.swift
//  SystemInfo
//
//  Created by Kevin Krämer on 10/16/26.
//

import SwiftUI
import SwiftData

@main
struct SystemInfoApp: App {
    /// Owns the live `SystemMonitor` and records its values into the history database.
    @State private var recorder = HistoryRecorder()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: recorder.monitor)
        } label: {
            MenuBarLabel(monitor: recorder.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("History", id: HistoryView.windowID) {
            HistoryView()
                .environment(recorder)
        }
        .modelContainer(recorder.container)
        .defaultLaunchBehavior(.suppressed)
    }
}
