//
//  OverviewPage.swift
//  SystemInfo
//

import SwiftUI
import Charts

/// The main page of the history window: key values as cards, then one chart per metric.
struct OverviewPage: View {
    let store: HistoryStore
    let hideGaps: Bool

    @AppStorage(SettingsKey.pricePerKWh) private var pricePerKWh = 0.0
    @State private var hover = ChartHover()
    @State private var scrollMonitor: Any?

    var body: some View {
        let snapshot = store.snapshot

        Group {
            if !store.hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.isEmpty {
                HistoryEmptyView(hasAnyHistory: snapshot.earliest != nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        cards(snapshot)

                        ForEach(HistoryMetric.charted.filter { snapshot.stats[$0] != nil }) { metric in
                            MetricChart(
                                metric: metric,
                                snapshot: snapshot,
                                timeline: hideGaps ? snapshot.timeline : nil,
                                hover: hover,
                                onZoom: store.zoom
                            )
                        }

                        Text("Each point covers \(formattedSpan(snapshot.pointDuration)). The lighter band shows the lowest and highest value in that time. Drag across a chart to zoom in, or swipe sideways with two fingers to move through time.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                }
            }
        }
        #if DEBUG
        .onChange(of: store.hasLoaded) {
            if let fraction = DemoData.hoverFraction {
                let domain = store.snapshot.domain
                hover.date = domain.lowerBound.addingTimeInterval(fraction * domain.upperBound.timeIntervalSince(domain.lowerBound))
            }
        }
        #endif
        .onAppear(perform: startPanning)
        .onDisappear(perform: stopPanning)
    }

    // MARK: - Cards

    private func cards(_ snapshot: HistorySnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            ForEach([HistoryMetric.cpu, .memory, .power].filter { snapshot.stats[$0] != nil }) { metric in
                if let stats = snapshot.stats[metric] {
                    MetricCard(
                        title: metric.title,
                        systemImage: metric.systemImage,
                        tint: metric.color,
                        value: metric.format(stats.average),
                        detail: "\(metric.format(stats.minimum)) – \(metric.format(stats.maximum)) · average"
                    ) {
                        Sparkline(values: snapshot.points.compactMap(metric.value), color: metric.color)
                    }
                }
            }

            if let energy = snapshot.energy {
                MetricCard(
                    title: "Energy",
                    systemImage: "powerplug.fill",
                    tint: .orange,
                    value: formattedEnergy(energy.totalWattHours),
                    detail: pricePerKWh > 0
                        ? "Cost \(formattedCost(wattHours: energy.totalWattHours, pricePerKWh: pricePerKWh))"
                        : "Set a price in Settings to see the cost"
                ) {
                    EmptyView()
                }
            }

            if let used = snapshot.diskUsedLatest, let total = snapshot.diskTotal, total > 0 {
                MetricCard(
                    title: HistoryMetric.disk.title,
                    systemImage: HistoryMetric.disk.systemImage,
                    tint: HistoryMetric.disk.color,
                    value: HistoryMetric.disk.format(Double(used)),
                    detail: diskDetail(used: used, total: total, atStart: snapshot.diskUsedAtStart)
                ) {
                    ProgressView(value: min(max(Double(used) / Double(total), 0), 1))
                        .tint(HistoryMetric.disk.color)
                }
            }

            if !snapshot.sleepPeriods.isEmpty {
                MetricCard(
                    title: "Asleep",
                    systemImage: "moon.zzz.fill",
                    tint: .indigo,
                    value: SleepPeriod.format(snapshot.sleepDuration),
                    detail: snapshot.energy?.asleepAverageWatts.map {
                        "\(formattedPower($0)) on average · \(formattedEnergy(snapshot.energy?.asleepWattHours ?? 0))"
                    } ?? "Power during sleep not available"
                ) {
                    EmptyView()
                }
            }
        }
    }

    private func diskDetail(used: Int64, total: Int64, atStart: Int64?) -> String {
        let free = "\(max(total - used, 0).formatted(.byteCount(style: .file))) free"
        guard let atStart, abs(used - atStart) >= 100_000_000 else { return free }
        let change = abs(used - atStart).formatted(.byteCount(style: .file))
        return "\(free) · \(used > atStart ? "+" : "−")\(change)"
    }

    // MARK: - Panning

    /// SwiftUI has no scroll gesture, so sideways trackpad scrolling over a chart is picked up here
    /// and turned into moving through time. Vertical scrolling is left to the page.
    private func startPanning() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hover.date != nil, hover.plotWidth > 1,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return event }
            store.pan(byFraction: -Double(event.scrollingDeltaX) / Double(hover.plotWidth))
            return nil
        }
    }

    private func stopPanning() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
        hover.date = nil
    }
}

/// Shown when the visible time span has no data.
struct HistoryEmptyView: View {
    /// `true` if there is history, just not in the visible time span.
    let hasAnyHistory: Bool

    var body: some View {
        if hasAnyHistory {
            ContentUnavailableView(
                "Nothing Recorded Here",
                systemImage: "chart.xyaxis.line",
                description: Text("There is no data in this time span. Pick another range or move through time with the arrows.")
            )
        } else {
            ContentUnavailableView(
                "No History Yet",
                systemImage: "chart.xyaxis.line",
                description: Text("A sample is recorded every 30 seconds while SystemInfo is running.")
            )
        }
    }
}

/// One key value: a large number with a short explanation and an optional small graphic.
struct MetricCard<Accessory: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let detail: String
    /// Whether to keep a row free for the graphic. Cards in one row should agree on this, so they are the same height.
    var showsAccessory = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            .font(.subheadline)

            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(2, reservesSpace: true)

            if showsAccessory {
                ZStack(alignment: .leading) {
                    accessory
                }
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A tiny line chart without axes, to show the shape of a metric at a glance.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    /// At most ~80 values, averaged, so the cards stay cheap to draw.
    private var reduced: [Double] {
        let step = max(values.count / 80, 1)
        guard step > 1 else { return values }
        return stride(from: 0, to: values.count, by: step).map { start in
            let slice = values[start..<min(start + step, values.count)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    var body: some View {
        let values = reduced
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.1, abs(high) * 0.01, 0.0001)

        Chart(Array(values.enumerated()), id: \.offset) { item in
            LineMark(x: .value("Index", item.offset), y: .value("Value", item.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (low - padding)...(high + padding))
        .accessibilityHidden(true)
    }
}
