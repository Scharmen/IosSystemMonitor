//
//  ContentView.swift
//  SystemInfo
//
//  Created by Kevin Krämer on 10/16/26.
//

import SwiftUI

/// The popover shown when clicking the menu bar item.
struct ContentView: View {
    let monitor: SystemMonitor

    @Environment(\.openWindow) private var openWindow

    @AppStorage(MenuBarSettingsKey.showCPU) private var showCPU = true
    @AppStorage(MenuBarSettingsKey.showMemory) private var showMemory = true
    @AppStorage(MenuBarSettingsKey.memoryStyle) private var memoryStyle = MemoryDisplayStyle.percentage
    @AppStorage(MenuBarSettingsKey.showDisk) private var showDisk = false
    @AppStorage(MenuBarSettingsKey.showPower) private var showPower = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Info")
                .font(.headline)

            UsageRow(
                title: "CPU",
                systemImage: "cpu",
                fraction: monitor.cpuUsage,
                detail: monitor.cpuUsage.formatted(.percent.precision(.fractionLength(0)))
            )

            UsageRow(
                title: "Memory",
                systemImage: "memorychip",
                fraction: fraction(monitor.memoryUsed, of: monitor.memoryTotal),
                detail: "\(monitor.memoryUsed.formatted(.byteCount(style: .memory))) of \(monitor.memoryTotal.formatted(.byteCount(style: .memory))) · \(MemoryDisplayStyle.available.format(used: monitor.memoryUsed, total: monitor.memoryTotal))"
            )

            UsageRow(
                title: "Disk",
                systemImage: "internaldrive",
                fraction: fraction(monitor.diskUsed, of: monitor.diskTotal),
                detail: "\(monitor.diskUsed.formatted(.byteCount(style: .file))) of \(monitor.diskTotal.formatted(.byteCount(style: .file)))"
            )

            UsageRow(
                title: "Power",
                systemImage: "bolt.fill",
                fraction: nil,
                detail: monitor.powerWatts.map(formattedPower) ?? "Not available"
            )

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Show in Menu Bar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("CPU", isOn: $showCPU)
                HStack {
                    Toggle("RAM", isOn: $showMemory)
                    Spacer()
                    Picker("RAM Display", selection: $memoryStyle) {
                        ForEach(MemoryDisplayStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!showMemory)
                }
                Toggle("Disk", isOn: $showDisk)
                Toggle("Power", isOn: $showPower)
                    .disabled(monitor.powerWatts == nil)
            }

            Divider()

            HStack {
                Button("Show History…") {
                    openWindow(id: HistoryView.windowID)
                    // Menu bar apps aren't active by default, so bring the new window to the front.
                    NSApplication.shared.activate()
                }
                Spacer()
                Button("Quit SystemInfo") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func fraction(_ value: Int64, of total: Int64) -> Double {
        total > 0 ? min(max(Double(value) / Double(total), 0), 1) : 0
    }
}

private struct UsageRow: View {
    let title: String
    let systemImage: String
    /// Fill level of the progress bar; pass `nil` for values without a natural maximum.
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let fraction {
                ProgressView(value: fraction)
            }
        }
    }
}

#Preview {
    ContentView(monitor: SystemMonitor())
}
