//
//  DemoData.swift
//  SystemInfo
//
//  Debug builds only. Launch with `-demoHistory` to run on generated history that lives in memory
//  (the real database is never opened), and with `-showHistory` to open the history window at launch.
//  Useful for trying out the history window and for taking screenshots:
//
//      SystemInfo -demoHistory -showHistory -historyPage energy -historyRange week \
//                 -snapshotTo /path/to/folder -snapshotSize 1440x900
//
//  Add `-mouseAt 700,470` (a point from the window's top-left corner) to show the tooltip there.
//  `-snapshotTo` saves a picture of the history window into that folder and quits. It needs a build
//  without the App Sandbox (or a folder inside the app's container).
//

#if DEBUG
import AppKit
import SwiftData

enum DemoData {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoHistory")
    static let showsHistoryAtLaunch = ProcessInfo.processInfo.arguments.contains("-showHistory")

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var initialPage: HistoryView.Page? { argument("-historyPage").flatMap(HistoryView.Page.init) }
    static var initialRange: HistoryRange? { argument("-historyRange").flatMap(HistoryRange.init) }
    /// Where the mouse pretends to hover over the charts, as a fraction of the visible time span.
    static var hoverFraction: Double? { argument("-hoverAt").flatMap(Double.init) }

    /// Saves a picture of the history window once it had time to load, then quits.
    static func saveSnapshotIfRequested() {
        guard let folder = argument("-snapshotTo") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains(HistoryView.windowID) == true }) else {
                NSApplication.shared.terminate(nil)
                return
            }
            let size = (argument("-snapshotSize") ?? "1280x800").split(separator: "x").compactMap { Double($0) }
            if size.count == 2 {
                window.setFrame(NSRect(x: 80, y: 80, width: size[0], height: size[1]), display: true)
            }
            try? await Task.sleep(for: .seconds(4))

            // Pretend the mouse is at a point given from the window's top-left corner, to show a tooltip.
            if let spot = argument("-mouseAt")?.split(separator: ",").compactMap({ Double($0) }), spot.count == 2 {
                let location = NSPoint(x: spot[0], y: window.frame.height - spot[1])
                @MainActor func visit(_ view: NSView) {
                    if let tracking = view as? TrackingNSView, view.convert(view.bounds, to: nil).contains(location),
                       let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        tracking.mouseMoved(with: event)
                    }
                    view.subviews.forEach(visit)
                }
                if let root = window.contentView?.superview ?? window.contentView { visit(root) }
                try? await Task.sleep(for: .milliseconds(500))
            }

            // The frame view includes the toolbar and title bar.
            if let view = window.contentView?.superview ?? window.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = "history-\(argument("-historyPage") ?? "overview")-\(argument("-historyRange") ?? "day").png"
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(filePath: folder).appending(path: name))
            }
            NSApplication.shared.terminate(nil)
        }
    }

    /// An in-memory database filled with 60 days of made-up history.
    static func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: MetricSample.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let now = Date.now
        let calendar = Calendar.current
        var generator = SystemRandomNumberGenerator()

        let memoryTotal: Int64 = 32 * 1_073_741_824
        let diskTotal: Int64 = 494_384_795_648

        /// The Mac "sleeps" from 23:30 to 07:00 every night.
        func isAsleep(_ date: Date) -> Bool {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            return minutes >= 23 * 60 + 30 || minutes < 7 * 60
        }

        func insertSample(at date: Date, resolution: Int) {
            let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
            // Busier around midday, with an occasional burst of work.
            let daily = 0.06 + 0.10 * max(sin((hour - 7) / 16 * .pi), 0)
            let burst = Double.random(in: 0...1, using: &generator) > 0.96 ? Double.random(in: 0.2...0.6, using: &generator) : 0
            let cpu = min(daily + burst + Double.random(in: -0.02...0.03, using: &generator), 1)
            let cpuMax = min(cpu + Double.random(in: 0.02...0.15, using: &generator), 1)
            let cpuMin = max(cpu - Double.random(in: 0.01...0.05, using: &generator), 0.01)
            let age = now.timeIntervalSince(date) / 86_400
            let memory = 17.5 + 2.5 * sin(hour / 24 * 2 * .pi) + Double.random(in: -0.3...0.3, using: &generator)

            context.insert(MetricSample(
                timestamp: date,
                resolution: resolution,
                cpuUsage: max(cpu, 0.01),
                memoryUsed: Int64(memory * 1_073_741_824),
                memoryTotal: memoryTotal,
                diskUsed: Int64((290 - age * 0.25) * 1_000_000_000),
                diskTotal: diskTotal,
                powerWatts: 4 + 55 * cpu,
                cpuMin: cpuMin,
                cpuMax: cpuMax,
                powerMin: 4 + 55 * cpuMin,
                powerMax: 4 + 55 * cpuMax
            ))
        }

        // Same detail levels as the real recorder: 30 seconds for a week, then 15 minutes.
        let tiers: [(from: Double, to: Double, resolution: Int)] = [(60, 7, 900), (7, 0, 30)]
        for tier in tiers {
            let step = Double(tier.resolution)
            var time = floor(now.addingTimeInterval(-tier.from * 86_400).timeIntervalSinceReferenceDate / step) * step
            let end = now.addingTimeInterval(-tier.to * 86_400).timeIntervalSinceReferenceDate
            while time < end {
                let date = Date(timeIntervalSinceReferenceDate: time)
                if !isAsleep(date) {
                    insertSample(at: date, resolution: tier.resolution)
                }
                time += step
            }
        }

        // One sleep sample per night.
        for day in 0..<60 {
            guard let midnight = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) else { continue }
            let start = midnight.addingTimeInterval(-30 * 60)
            let end = midnight.addingTimeInterval(7 * 3_600)
            guard end < now else { continue }
            context.insert(MetricSample(
                timestamp: start,
                resolution: Int(end.timeIntervalSince(start)),
                cpuUsage: 0,
                memoryUsed: Int64(17.5 * 1_073_741_824),
                memoryTotal: memoryTotal,
                diskUsed: 290_000_000_000,
                diskTotal: diskTotal,
                powerWatts: Double.random(in: 0.5...0.9, using: &generator),
                isSleep: true
            ))
        }

        try context.save()
        return container
    }
}
#endif
