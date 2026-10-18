//
//  MenuBarLabel.swift
//  SystemInfo
//

import SwiftUI

/// The content shown directly in the menu bar, based on the user's selection.
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    @AppStorage(MenuBarSettingsKey.showCPU) private var showCPU = true
    @AppStorage(MenuBarSettingsKey.showMemory) private var showMemory = true
    @AppStorage(MenuBarSettingsKey.memoryStyle) private var memoryStyle = MemoryDisplayStyle.percentage
    @AppStorage(MenuBarSettingsKey.showDisk) private var showDisk = false
    @AppStorage(MenuBarSettingsKey.showPower) private var showPower = true

    var body: some View {
        Image(nsImage: renderedImage)
            .accessibilityLabel(segments.isEmpty ? "System Info" : segments.map(\.text).joined(separator: ", "))
    }

    private var segments: [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        if showCPU {
            segments.append(MenuBarSegment(symbol: "cpu", text: monitor.cpuUsage.formatted(.percent.precision(.fractionLength(0)))))
        }
        if showMemory {
            segments.append(MenuBarSegment(symbol: "memorychip", text: memoryStyle.format(used: monitor.memoryUsed, total: monitor.memoryTotal)))
        }
        if showDisk {
            let fraction = monitor.diskTotal > 0 ? Double(monitor.diskUsed) / Double(monitor.diskTotal) : 0
            segments.append(MenuBarSegment(symbol: "internaldrive", text: fraction.formatted(.percent.precision(.fractionLength(0)))))
        }
        if showPower, let watts = monitor.powerWatts {
            segments.append(MenuBarSegment(symbol: "bolt.fill", text: formattedPower(watts)))
        }
        return segments
    }

    /// The menu bar only reliably shows a single image or text, so all segments are
    /// rendered into one template image (which macOS tints for light/dark menu bars).
    private var renderedImage: NSImage {
        let renderer = ImageRenderer(content: MenuBarSegmentsView(segments: segments))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}

private struct MenuBarSegment: Hashable {
    let symbol: String
    let text: String
}

private struct MenuBarSegmentsView: View {
    let segments: [MenuBarSegment]

    var body: some View {
        HStack(spacing: 8) {
            if segments.isEmpty {
                // Keep something visible so the panel can still be opened.
                Image(systemName: "gauge.with.dots.needle.33percent")
            } else {
                ForEach(segments, id: \.self) { segment in
                    HStack(spacing: 3) {
                        Image(systemName: segment.symbol)
                        Text(segment.text)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .foregroundStyle(.black)
    }
}

/// Formats a wattage like "10.5 W".
func formattedPower(_ watts: Double) -> String {
    Measurement(value: watts, unit: UnitPower.watts)
        .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
}
