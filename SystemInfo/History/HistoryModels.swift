//
//  HistoryModels.swift
//  SystemInfo
//
//  Plain value types the history window works with. They are `nonisolated` and `Sendable`
//  so they can be built off the main thread by `HistoryLoader`.
//

import SwiftUI

/// The time span shown in the history viewer.
nonisolated enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month, year, all

    var id: Self { self }

    var title: String {
        switch self {
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        case .year: "1Y"
        case .all: "All"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        case .all: nil
        }
    }
}

/// A time span during which the Mac was asleep.
nonisolated struct SleepPeriod: Identifiable, Sendable {
    var id: Date { start }
    let start: Date
    let end: Date
    /// Average power draw during sleep, if it could be determined.
    let powerWatts: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Total energy used during this sleep, in watt-hours.
    var energyWattHours: Double? {
        powerWatts.map { $0 * duration / 3600 }
    }

    /// Non-optional stand-ins so the sleep table can sort by these columns; unknown values sort first.
    var energySortKey: Double { energyWattHours ?? -1 }
    var powerSortKey: Double { powerWatts ?? -1 }

    func contains(_ date: Date) -> Bool {
        start <= date && date <= end
    }

    /// The part of this sleep that falls inside `domain`, in seconds.
    func duration(within domain: ClosedRange<Date>) -> TimeInterval {
        max(min(end, domain.upperBound).timeIntervalSince(max(start, domain.lowerBound)), 0)
    }

    /// Formats a sleep duration like "6 hours, 12 minutes".
    static func format(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }
}

/// A chart-ready value, combined from one or more stored samples.
nonisolated struct HistoryPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    /// Consecutive points share a segment; a gap (e.g. the Mac was asleep) starts a new one so lines aren't drawn across it.
    var segment = 0
    let cpuUsage: Double
    /// Lowest and highest CPU usage inside this point's time span.
    let cpuMin: Double
    let cpuMax: Double
    let memoryUsed: Int64
    let memoryTotal: Int64
    let diskUsed: Int64
    let diskTotal: Int64
    let powerWatts: Double?
    let powerMin: Double?
    let powerMax: Double?
}

/// The metrics the history window can show, with how each is read and formatted.
nonisolated enum HistoryMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, power, disk

    var id: Self { self }

    /// The metrics drawn as charts. Disk changes too slowly for a chart and is shown as a card only.
    static let charted: [HistoryMetric] = [.cpu, .power, .memory]

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .disk: "Disk"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .power: "bolt.fill"
        case .disk: "internaldrive"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .memory: .green
        case .power: .orange
        case .disk: .purple
        }
    }

    func value(_ point: HistoryPoint) -> Double? {
        switch self {
        case .cpu: point.cpuUsage
        case .memory: Double(point.memoryUsed)
        case .power: point.powerWatts
        case .disk: Double(point.diskUsed)
        }
    }

    /// The lowest and highest value inside a point's time span, for metrics that record them.
    func band(_ point: HistoryPoint) -> ClosedRange<Double>? {
        switch self {
        case .cpu:
            return point.cpuMin <= point.cpuMax ? point.cpuMin...point.cpuMax : nil
        case .power:
            guard let low = point.powerMin, let high = point.powerMax, low <= high else { return nil }
            return low...high
        case .memory, .disk:
            return nil
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu: value.formatted(.percent.precision(.fractionLength(0)))
        case .memory: Int64(value).formatted(.byteCount(style: .memory))
        case .power: formattedPower(value)
        case .disk: Int64(value).formatted(.byteCount(style: .file))
        }
    }
}

/// Lowest, average, highest and most recent value of one metric in the visible time span.
nonisolated struct MetricStats: Sendable {
    let minimum: Double
    let average: Double
    let maximum: Double
    let latest: Double
}

/// The size of one bar in the energy chart.
nonisolated enum EnergyGranularity: Sendable {
    case fiveMinutes, hour, day, month

    /// Picks a bar size that gives a readable number of bars for a time span of `length` seconds.
    static func forSpan(_ length: TimeInterval) -> EnergyGranularity {
        if length <= 3 * 3_600 { return .fiveMinutes }
        if length <= 3 * 86_400 { return .hour }
        if length <= 100 * 86_400 { return .day }
        return .month
    }

    /// The bar that `date` falls into.
    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component
        switch self {
        case .fiveMinutes:
            let start = floor(date.timeIntervalSinceReferenceDate / 300) * 300
            return DateInterval(start: Date(timeIntervalSinceReferenceDate: start), duration: 300)
        case .hour: component = .hour
        case .day: component = .day
        case .month: component = .month
        }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 3_600)
    }

    /// A name for one bar, like "Nov 24, 9 AM" or "November 2026".
    func label(for interval: DateInterval) -> String {
        switch self {
        case .fiveMinutes:
            "\(interval.start.formatted(date: .omitted, time: .shortened)) – \(interval.end.formatted(date: .omitted, time: .shortened))"
        case .hour:
            interval.start.formatted(.dateTime.month(.abbreviated).day().hour())
        case .day:
            interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .month:
            interval.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The word used in "Energy per …".
    var unitName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .hour: "hour"
        case .day: "day"
        case .month: "month"
        }
    }
}

/// Energy used during one bar of the energy chart, split into awake and asleep.
nonisolated struct EnergyBar: Identifiable, Sendable {
    var id: Date { interval.start }
    let interval: DateInterval
    var awakeWattHours = 0.0
    var asleepWattHours = 0.0

    var totalWattHours: Double { awakeWattHours + asleepWattHours }
}

/// Energy used in the visible time span.
nonisolated struct EnergySummary: Sendable {
    var awakeWattHours = 0.0
    var asleepWattHours = 0.0
    /// How long power was recorded while awake, and how long the Mac slept with a known power draw.
    var awakeSeconds = 0.0
    var asleepSeconds = 0.0

    var totalWattHours: Double { awakeWattHours + asleepWattHours }
    var coveredSeconds: Double { awakeSeconds + asleepSeconds }
    var awakeAverageWatts: Double? { awakeSeconds > 0 ? awakeWattHours / (awakeSeconds / 3600) : nil }
    var asleepAverageWatts: Double? { asleepSeconds > 0 ? asleepWattHours / (asleepSeconds / 3600) : nil }
}

/// Everything the history window shows for one time span. Built by `HistoryLoader`.
nonisolated struct HistorySnapshot: Sendable {
    var domain: ClosedRange<Date>
    /// The oldest recorded sample, used to stop paging back past the start of the history.
    var earliest: Date?
    var points: [HistoryPoint] = []
    var sleepPeriods: [SleepPeriod] = []
    /// How many seconds each chart point represents.
    var pointDuration: TimeInterval = 30
    var stats: [HistoryMetric: MetricStats] = [:]
    /// `nil` if no power was recorded in the time span.
    var energy: EnergySummary?
    var energyBars: [EnergyBar] = []
    var energyGranularity = EnergyGranularity.hour
    /// Disk usage at the start of the time span, to show how much it changed.
    var diskUsedAtStart: Int64?
    var diskUsedLatest: Int64?
    var diskTotal: Int64?
    /// The squeezed time axis used when gaps are hidden; `nil` without data.
    var timeline: GapTimeline?

    static var empty: HistorySnapshot {
        HistorySnapshot(domain: Date.now.addingTimeInterval(-60)...Date.now)
    }

    var isEmpty: Bool { points.isEmpty && sleepPeriods.isEmpty }

    /// Total time asleep inside the visible time span.
    var sleepDuration: TimeInterval {
        sleepPeriods.reduce(0) { $0 + $1.duration(within: domain) }
    }

    /// The chart point closest to `date`, or `nil` if none is near (e.g. inside a gap).
    func point(near date: Date) -> HistoryPoint? {
        guard !points.isEmpty else { return nil }
        // Points are sorted by date: find the first one at or after `date`, then compare with its predecessor.
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].date < date { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { points.indices.contains($0) }.map { points[$0] }
        guard let nearest = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return nil }
        return abs(nearest.date.timeIntervalSince(date)) <= max(3 * pointDuration, 90) ? nearest : nil
    }
}

// MARK: - Formatting

/// Formats energy like "3.25 Wh" or "1.42 kWh". An average power in watts equals the energy used per hour.
nonisolated func formattedEnergy(_ wattHours: Double) -> String {
    if wattHours >= 1000 {
        let kWh = wattHours / 1000
        return "\(kWh.formatted(.number.precision(.fractionLength(kWh < 10 ? 2 : 1)))) kWh"
    }
    return "\(wattHours.formatted(.number.precision(.fractionLength(wattHours < 10 ? 2 : 1)))) Wh"
}

/// Formats what `wattHours` cost at `pricePerKWh`, in the user's currency.
nonisolated func formattedCost(wattHours: Double, pricePerKWh: Double) -> String {
    let currency = Locale.current.currency?.identifier ?? "EUR"
    return (wattHours / 1000 * pricePerKWh).formatted(.currency(code: currency))
}

/// Formats a length of time like "15 minutes" or "2 hours, 30 minutes".
nonisolated func formattedSpan(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
}
