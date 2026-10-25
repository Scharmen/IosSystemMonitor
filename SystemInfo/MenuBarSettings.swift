//
//  MenuBarSettings.swift
//  SystemInfo
//

import Foundation

/// `UserDefaults` keys for choosing which values appear directly in the menu bar.
enum MenuBarSettingsKey {
    static let showCPU = "menuBar.showCPU"
    static let showMemory = "menuBar.showMemory"
    static let memoryStyle = "menuBar.memoryStyle"
    static let showDisk = "menuBar.showDisk"
    static let showPower = "menuBar.showPower"
    static let compact = "menuBar.compact"
}

/// How RAM usage is presented in the menu bar.
enum MemoryDisplayStyle: String, CaseIterable, Identifiable {
    /// Share of the installed RAM that is in use, e.g. "52 %".
    case percentage
    /// Amount in use, e.g. "8.4 GB".
    case used
    /// Amount in use relative to the installed RAM, e.g. "8.4 GB / 16 GB".
    case usedOfTotal
    /// Amount still available, e.g. "7.6 GB free".
    case available

    var id: Self { self }

    var title: String {
        switch self {
        case .percentage: "Percentage"
        case .used: "Used"
        case .usedOfTotal: "Used / Total"
        case .available: "Available"
        }
    }

    func format(used: Int64, total: Int64) -> String {
        switch self {
        case .percentage:
            let fraction = total > 0 ? Double(used) / Double(total) : 0
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        case .used:
            return used.formatted(.byteCount(style: .memory))
        case .usedOfTotal:
            return "\(used.formatted(.byteCount(style: .memory))) / \(total.formatted(.byteCount(style: .memory)))"
        case .available:
            return "\(max(total - used, 0).formatted(.byteCount(style: .memory))) free"
        }
    }
}
