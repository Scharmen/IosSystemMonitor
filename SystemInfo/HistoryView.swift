//
//  HistoryView.swift
//  SystemInfo
//

import SwiftUI
import SwiftData
import Charts

/// The time span shown in the history viewer.
enum HistoryRange: String, CaseIterable, Identifiable {
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

/// A fixed look-back period for the total energy use and cost, independent of the chart range.
enum EnergyPeriod: CaseIterable, Identifiable {
    case day, week, month, halfYear, year

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "24 Hours"
        case .week: "7 Days"
        case .month: "1 Month"
        case .halfYear: "6 Months"
        case .year: "12 Months"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .halfYear: 182 * 86_400
        case .year: 365 * 86_400
        }
    }
}

/// Energy used in one `EnergyPeriod`, summed from the recorded power samples.
struct EnergyTotal: Identifiable {
    let period: EnergyPeriod
    let wattHours: Double
    /// How much of the period has recorded power data, so partial totals can be recognised.
    let coveredDuration: TimeInterval

    var id: EnergyPeriod { period }
    var kilowattHours: Double { wattHours / 1000 }
    var isComplete: Bool { coveredDuration >= period.duration * 0.95 }
}

/// A time span during which the Mac was asleep.
struct SleepPeriod: Identifiable {
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

    init(_ sample: MetricSample) {
        start = sample.timestamp
        end = sample.timestamp.addingTimeInterval(Double(sample.resolution))
        powerWatts = sample.powerWatts
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date <= end
    }

    /// Formats a sleep duration like "6 hours, 12 minutes".
    static func format(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }
}

/// Formats energy like "3.25 Wh". An average power in watts equals the energy used per hour,
/// so this is also used for "per hour" values.
private func formattedEnergy(_ wattHours: Double) -> String {
    "\(wattHours.formatted(.number.precision(.fractionLength(wattHours < 10 ? 2 : 1)))) Wh"
}

/// A chart-ready value, averaged from one or more stored samples.
struct HistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    /// Consecutive points share a segment; a gap (e.g. the Mac was asleep) starts a new one so lines aren't drawn across it.
    var segment = 0
    let cpuUsage: Double
    let memoryUsed: Int64
    let memoryTotal: Int64
    let diskUsed: Int64
    let diskTotal: Int64
    let powerWatts: Double?

    /// The time span each chart point covers; never finer than the recording interval.
    static func bucketLength(from start: Date, to end: Date, maxPoints: Int) -> TimeInterval {
        max(end.timeIntervalSince(start) / Double(maxPoints), Double(HistoryRecorder.sampleResolution))
    }

    /// Reduces samples to at most `maxPoints` buckets so charts stay fast for long ranges.
    static func downsample(_ samples: [MetricSample], from start: Date, to end: Date, maxPoints: Int) -> [HistoryPoint] {
        guard !samples.isEmpty else { return [] }
        let bucketLength = bucketLength(from: start, to: end, maxPoints: maxPoints)
        let buckets = Dictionary(grouping: samples) { floor($0.timestamp.timeIntervalSince(start) / bucketLength) }

        var points = buckets.keys.sorted().compactMap { key -> (HistoryPoint, Int)? in
            guard let group = buckets[key], let first = group.first else { return nil }
            let merged = MetricSample.average(of: group, timestamp: first.timestamp, resolution: 0)
            let point = HistoryPoint(
                date: first.timestamp,
                cpuUsage: merged.cpuUsage,
                memoryUsed: merged.memoryUsed,
                memoryTotal: merged.memoryTotal,
                diskUsed: merged.diskUsed,
                diskTotal: merged.diskTotal,
                powerWatts: merged.powerWatts
            )
            return (point, group.map(\.resolution).max() ?? 60)
        }

        var segment = 0
        for index in points.indices.dropFirst() {
            let gap = points[index].0.date.timeIntervalSince(points[index - 1].0.date)
            if gap > 3 * max(bucketLength, Double(points[index].1)) {
                segment += 1
            }
            points[index].0.segment = segment
        }
        return points.map(\.0)
    }
}

/// Describes how one metric is read, scaled, and formatted in the viewer.
private struct HistoryMetric: Identifiable {
    let title: String
    let systemImage: String
    let color: Color
    let value: (HistoryPoint) -> Double?
    let upperBound: ([HistoryPoint]) -> Double
    let format: (Double) -> String

    var id: String { title }

    static let all: [HistoryMetric] = [
        HistoryMetric(
            title: "CPU", systemImage: "cpu", color: .blue,
            value: { $0.cpuUsage },
            upperBound: { _ in 1 },
            format: { $0.formatted(.percent.precision(.fractionLength(0))) }
        ),
        HistoryMetric(
            title: "Memory", systemImage: "memorychip", color: .green,
            value: { Double($0.memoryUsed) },
            upperBound: { Double($0.map(\.memoryTotal).max() ?? 1) },
            format: { Int64($0).formatted(.byteCount(style: .memory)) }
        ),
        HistoryMetric(
            title: "Power", systemImage: "bolt.fill", color: .orange,
            value: { $0.powerWatts },
            upperBound: { max(($0.compactMap(\.powerWatts).max() ?? 0) * 1.1, 1) },
            format: formattedPower
        ),
        HistoryMetric(
            title: "Disk", systemImage: "internaldrive", color: .purple,
            value: { Double($0.diskUsed) },
            upperBound: { Double($0.map(\.diskTotal).max() ?? 1) },
            format: { Int64($0).formatted(.byteCount(style: .file)) }
        ),
    ]
}

struct HistoryView: View {
    static let windowID = "history"

    @Environment(\.modelContext) private var modelContext
    @Environment(HistoryRecorder.self) private var recorder
    @AppStorage(HistoryRetention.storageKey) private var retention = HistoryRetention.month

    @State private var range = HistoryRange.day
    /// A sub-range picked by dragging across a chart; replaces `range` while set.
    @State private var zoomedRange: ClosedRange<Date>?
    @State private var points: [HistoryPoint] = []
    @State private var sleepPeriods: [SleepPeriod] = []
    @State private var domain = Date.now...Date.now.addingTimeInterval(60)
    /// How many seconds each chart point represents for the current view.
    @State private var pointDuration: TimeInterval = 30
    @State private var selectedDate: Date?
    @State private var dragRange: ClosedRange<Date>?
    @State private var isConfirmingClear = false
    @State private var energyTotals: [EnergyTotal] = []
    @AppStorage("electricityPricePerKWh") private var pricePerKWh = 0.0

    private static let maxChartPoints = 500

    private struct LoadRequest: Hashable {
        let range: HistoryRange
        let zoomedRange: ClosedRange<Date>?
    }

    private var selectedPoint: HistoryPoint? {
        guard let selectedDate, selectedSleep == nil else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var selectedSleep: SleepPeriod? {
        guard let selectedDate else { return nil }
        return sleepPeriods.first { $0.contains(selectedDate) }
    }

    /// Metrics that have data in the current range (power is missing on Macs without a battery).
    private var visibleMetrics: [HistoryMetric] {
        HistoryMetric.all.filter { metric in points.contains { metric.value($0) != nil } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if points.isEmpty {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("A sample is recorded every 30 seconds while SystemInfo is running.")
                    )
                } else {
                    detailBar
                    summary
                    ForEach(visibleMetrics) { metric in
                        MetricChart(
                            metric: metric,
                            points: points,
                            sleepPeriods: sleepPeriods,
                            domain: domain,
                            selectedPoint: selectedPoint,
                            selectedSleep: selectedSleep,
                            selectedDate: $selectedDate,
                            dragRange: $dragRange,
                            onZoom: zoom
                        )
                    }
                }

                if energyTotals.contains(where: { $0.wattHours > 0 }) {
                    energyCost
                }

                if !sleepPeriods.isEmpty {
                    sleepList
                }

                storageSettings
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 600)
        .task(id: LoadRequest(range: range, zoomedRange: zoomedRange)) {
            // Reload regularly so the viewer follows newly recorded samples.
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: range) {
            zoomedRange = nil
        }
        .onChange(of: retention) {
            recorder.performMaintenance()
            load()
        }
    }

    // MARK: - Sections

    /// Shows the zoomed time span and how detailed the charts currently are.
    private var detailBar: some View {
        HStack {
            if let zoomedRange {
                Label("\(zoomedRange.lowerBound.formatted(date: .abbreviated, time: .shortened)) – \(zoomedRange.upperBound.formatted(date: .abbreviated, time: .shortened))", systemImage: "plus.magnifyingglass")
                Button("Reset Zoom") {
                    self.zoomedRange = nil
                }
            } else {
                Text("Drag across a chart to zoom in.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Each point: \(Duration.seconds(pointDuration).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var summary: some View {
        GroupBox("Summary") {
            VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Minimum")
                    Text("Average")
                    Text("Maximum")
                    Text("Latest")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ForEach(visibleMetrics) { metric in
                    let values = points.compactMap(metric.value)
                    GridRow {
                        Label(metric.title, systemImage: metric.systemImage)
                            .foregroundStyle(metric.color)
                        Text(values.min().map(metric.format) ?? "–")
                        Text(values.isEmpty ? "–" : metric.format(values.reduce(0, +) / Double(values.count)))
                        Text(values.max().map(metric.format) ?? "–")
                        Text(values.last.map(metric.format) ?? "–")
                    }
                    .monospacedDigit()
                }
            }

            if !sleepPeriods.isEmpty {
                sleepSummary
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// Total sleep time in the visible range and the average power while asleep.
    private var sleepSummary: some View {
        // Only count the part of each sleep that falls inside the visible range.
        let clipped = sleepPeriods.map { period in
            (period, max(min(period.end, domain.upperBound).timeIntervalSince(max(period.start, domain.lowerBound)), 0))
        }
        let totalSleep = clipped.reduce(0) { $0 + $1.1 }
        let measured = clipped.compactMap { period, duration in period.powerWatts.map { ($0, duration) } }
        let measuredDuration = measured.reduce(0) { $0 + $1.1 }
        let energy = measured.reduce(0) { $0 + $1.0 * $1.1 / 3600 }
        let perHour = measuredDuration > 0 ? energy / (measuredDuration / 3600) : nil

        return Label {
            if let perHour {
                Text("Asleep for \(SleepPeriod.format(totalSleep)) · used \(formattedEnergy(energy)) · average \(formattedEnergy(perHour)) per hour of sleep")
            } else {
                Text("Asleep for \(SleepPeriod.format(totalSleep)) · power during sleep not available")
            }
        } icon: {
            Image(systemName: "moon.zzz.fill")
        }
        .foregroundStyle(.indigo)
    }

    /// Total energy used over fixed periods, with the cost at the user's electricity price.
    private var energyCost: some View {
        let currency = Locale.current.currency?.identifier ?? "EUR"
        return GroupBox("Energy & Cost") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Electricity price per kWh") {
                    HStack(spacing: 4) {
                        TextField("Price", value: $pricePerKWh, format: .number.precision(.fractionLength(0...4)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(currency)
                            .foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Energy")
                        Text("Cost")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    ForEach(energyTotals) { total in
                        GridRow {
                            Text(total.isComplete ? total.period.title : "\(total.period.title)*")
                            Text("\(total.kilowattHours.formatted(.number.precision(.fractionLength(total.kilowattHours < 10 ? 2 : 1)))) kWh")
                            Text(pricePerKWh > 0 ? (total.kilowattHours * pricePerKWh).formatted(.currency(code: currency)) : "–")
                        }
                        .monospacedDigit()
                    }
                }

                Text("Includes the time your Mac was asleep. \(energyTotals.contains { !$0.isComplete } ? "* Not enough history recorded for the whole period yet, or your history setting keeps less data; the total only covers what was recorded. " : "")Enter your price per kWh to see costs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// Every sleep in the visible range, newest first, with its energy use.
    private var sleepList: some View {
        GroupBox("Sleep Periods") {
            Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Asleep").gridColumnAlignment(.leading)
                    Text("Woke Up")
                    Text("Duration")
                    Text("Energy Used")
                    Text("Per Hour")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ForEach(sleepPeriods.reversed()) { period in
                    GridRow {
                        Text(period.start.formatted(date: .abbreviated, time: .shortened))
                        Text(period.end.formatted(date: .abbreviated, time: .shortened))
                        Text(SleepPeriod.format(period.duration))
                        Text(period.energyWattHours.map(formattedEnergy) ?? "–")
                        Text(period.powerWatts.map(formattedEnergy) ?? "–")
                    }
                    .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)

            Text("Energy is only calculated for sleeps of at least 15 minutes and appears 1–3 minutes after waking.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var storageSettings: some View {
        GroupBox("History Storage") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Keep history for", selection: $retention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                .fixedSize()

                LabeledContent("Database size") {
                    Text("\(recorder.storeSize.formatted(.byteCount(style: .file))) · \(recorder.sampleCount.formatted()) samples")
                        .monospacedDigit()
                }

                Text("To keep storage small, older data is condensed automatically: 30-second values for the last 7 days, 15-minute averages up to 90 days, and hourly averages beyond that. Recording pauses when less than 1 GB of disk space is free.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if recorder.isPausedForLowDiskSpace {
                    Label("Recording is paused because your disk is almost full.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Button("Clear History…", role: .destructive) {
                    isConfirmingClear = true
                }
                .confirmationDialog("Delete all recorded history?", isPresented: $isConfirmingClear) {
                    Button("Clear History", role: .destructive) {
                        recorder.clearHistory()
                        load()
                    }
                } message: {
                    Text("This can't be undone.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Loading

    private func load() {
        let start: Date
        let end: Date
        if let zoomedRange {
            start = zoomedRange.lowerBound
            end = zoomedRange.upperBound
        } else if let duration = range.duration {
            end = .now
            start = end.addingTimeInterval(-duration)
        } else {
            var oldest = FetchDescriptor<MetricSample>(sortBy: [SortDescriptor(\.timestamp)])
            oldest.fetchLimit = 1
            end = .now
            start = (try? modelContext.fetch(oldest).first?.timestamp) ?? end
        }

        let descriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end && !$0.isSleep },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        domain = start...max(end, start.addingTimeInterval(60))
        points = HistoryPoint.downsample(samples, from: start, to: end, maxPoints: Self.maxChartPoints)

        // A sleep can begin before the visible range and still overlap it, so filter by end time in memory.
        // There are only a few sleep samples per day, so fetching all up to `end` is cheap.
        let sleepDescriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.isSleep && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        sleepPeriods = ((try? modelContext.fetch(sleepDescriptor)) ?? [])
            .map(SleepPeriod.init)
            .filter { $0.end >= start }

        loadEnergyTotals()

        // Older data may be stored coarser than the chart buckets, so report whichever is larger.
        let bucketLength = HistoryPoint.bucketLength(from: start, to: end, maxPoints: Self.maxChartPoints)
        pointDuration = max(bucketLength, Double(samples.map(\.resolution).max() ?? 0)).rounded()
    }

    /// Sums power over the fixed energy periods: each sample's watts times the seconds it covers.
    private func loadEnergyTotals() {
        let now = Date.now
        let longest = now.addingTimeInterval(-(EnergyPeriod.allCases.map(\.duration).max() ?? 0))
        let descriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.timestamp >= longest && $0.powerWatts != nil },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        energyTotals = EnergyPeriod.allCases.map { period in
            let start = now.addingTimeInterval(-period.duration)
            var wattHours = 0.0
            var covered = 0.0
            for sample in samples where sample.timestamp >= start {
                guard let watts = sample.powerWatts else { continue }
                let seconds = Double(sample.resolution)
                wattHours += watts * seconds / 3600
                covered += seconds
            }
            return EnergyTotal(period: period, wattHours: wattHours, coveredDuration: covered)
        }
    }

    /// Zooms into a dragged range; very short drags are treated as clicks and ignored.
    private func zoom(to range: ClosedRange<Date>) {
        let clamped = max(range.lowerBound, domain.lowerBound)...min(range.upperBound, domain.upperBound)
        guard clamped.upperBound.timeIntervalSince(clamped.lowerBound) >= 2 * Double(HistoryRecorder.sampleResolution) else { return }
        zoomedRange = clamped
    }
}

/// A line chart for one metric. Hovering shows exact values (shared across all charts);
/// dragging selects a time span to zoom into.
private struct MetricChart: View {
    let metric: HistoryMetric
    let points: [HistoryPoint]
    let sleepPeriods: [SleepPeriod]
    let domain: ClosedRange<Date>
    let selectedPoint: HistoryPoint?
    let selectedSleep: SleepPeriod?
    @Binding var selectedDate: Date?
    @Binding var dragRange: ClosedRange<Date>?
    let onZoom: (ClosedRange<Date>) -> Void

    private var isPowerChart: Bool { metric.title == "Power" }

    private func sleepDescription(_ period: SleepPeriod) -> String {
        let time = "Asleep \(period.start.formatted(date: .abbreviated, time: .shortened)) – \(period.end.formatted(date: .omitted, time: .shortened)) (\(SleepPeriod.format(period.duration)))"
        guard isPowerChart else { return time }
        guard let watts = period.powerWatts, let energy = period.energyWattHours else { return "\(time) · power unknown" }
        return "\(time) · \(formattedEnergy(energy)) used · \(formattedEnergy(watts)) per hour"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(metric.title, systemImage: metric.systemImage)
                    .font(.headline)
                Spacer()
                if let selectedSleep {
                    Text(sleepDescription(selectedSleep))
                        .foregroundStyle(.indigo)
                        .monospacedDigit()
                } else if let selectedPoint, let value = metric.value(selectedPoint) {
                    Text("\(selectedPoint.date.formatted(date: .abbreviated, time: .standard)) · \(metric.format(value))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Chart {
                // Shade sleep periods behind the data, clipped to the visible range.
                ForEach(sleepPeriods) { period in
                    let start = max(period.start, domain.lowerBound)
                    let end = min(period.end, domain.upperBound)
                    RectangleMark(xStart: .value("Sleep Start", start), xEnd: .value("Sleep End", end))
                        .foregroundStyle(.indigo.opacity(selectedSleep?.id == period.id ? 0.2 : 0.1))

                    if isPowerChart, let watts = period.powerWatts {
                        RuleMark(xStart: .value("Sleep Start", start), xEnd: .value("Sleep End", end), y: .value("Sleep Power", watts))
                            .foregroundStyle(.indigo)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                }

                ForEach(points) { point in
                    if let value = metric.value(point) {
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value(metric.title, value),
                            series: .value("Segment", point.segment)
                        )
                        .foregroundStyle(metric.color.opacity(0.15))

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(metric.title, value),
                            series: .value("Segment", point.segment)
                        )
                        .foregroundStyle(metric.color)
                    }
                }

                if let dragRange {
                    RectangleMark(xStart: .value("Start", dragRange.lowerBound), xEnd: .value("End", dragRange.upperBound))
                        .foregroundStyle(.gray.opacity(0.2))
                }

                if let selectedPoint, let value = metric.value(selectedPoint) {
                    RuleMark(x: .value("Selected", selectedPoint.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(x: .value("Time", selectedPoint.date), y: .value(metric.title, value))
                        .foregroundStyle(metric.color)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...metric.upperBound(points))
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(metric.format(number))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    // Gesture locations are relative to the overlay; the proxy expects plot-area coordinates.
                    let originX = proxy.plotFrame.map { geometry[$0].origin.x } ?? 0

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                selectedDate = proxy.value(atX: location.x - originX, as: Date.self)
                            case .ended:
                                selectedDate = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if let start = proxy.value(atX: value.startLocation.x - originX, as: Date.self),
                                       let current = proxy.value(atX: value.location.x - originX, as: Date.self) {
                                        dragRange = min(start, current)...max(start, current)
                                    }
                                }
                                .onEnded { _ in
                                    if let dragRange {
                                        onZoom(dragRange)
                                    }
                                    dragRange = nil
                                }
                        )
                }
            }
            .frame(height: 140)
        }
    }
}
