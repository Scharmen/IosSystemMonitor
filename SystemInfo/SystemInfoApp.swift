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

    private var showsHistoryAtLaunch: Bool {
        #if DEBUG
        DemoData.showsHistoryAtLaunch
        #else
        false
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: recorder.monitor)
        } label: {
            MenuBarLabel(monitor: recorder.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("History", id: HistoryView.windowID) {
            HistoryView(container: recorder.container)
                .environment(recorder)
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(showsHistoryAtLaunch ? .presented : .suppressed)

        Settings {
            SettingsView()
                .environment(recorder)
        }
    }
}
