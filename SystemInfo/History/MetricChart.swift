//
//  MetricChart.swift
//  SystemInfo
//

import SwiftUI
import Charts

/// What the mouse is doing over the charts. Shared by all charts, so their crosshairs line up.
@Observable
final class ChartHover {
    /// The real date under the mouse; shared by all charts so their crosshairs line up.
    var date: Date?
    /// The time span being dragged out to zoom into.
    var dragRange: ClosedRange<Date>?
    /// Width of the hovered chart's plot area, to turn scroll distances into time.
    @ObservationIgnored var plotWidth: CGFloat = 1
}

/// A line chart for one metric. Hovering shows the exact value next to the mouse;
/// dragging selects a time span to zoom into.
struct MetricChart: View {
    let metric: HistoryMetric
    let snapshot: HistorySnapshot
    /// When set, time without data is squeezed out of the chart.
    let timeline: GapTimeline?
    let hover: ChartHover
    let onZoom: (ClosedRange<Date>) -> Void

    private var points: [HistoryPoint] { snapshot.points }

    /// Real date → chart position (identical unless gaps are hidden).
    private func x(_ date: Date) -> Date { timeline?.virtual(date) ?? date }
    private var chartDomain: ClosedRange<Date> { timeline?.virtualDomain ?? snapshot.domain }

    /// The band between lowest and highest value is only worth drawing if it differs from the average line.
    private var showsBand: Bool {
        points.contains { point in
            guard let band = metric.band(point), let value = metric.value(point) else { return false }
            return band.upperBound - band.lowerBound > max(abs(value) * 0.02, 0.0001)
        }
    }

    /// A Y axis that fits the data, so small changes stay readable.
    private var yDomain: ClosedRange<Double> {
        let values = points.compactMap(metric.value)
        let highs = points.compactMap { metric.band($0)?.upperBound } + values
        let sleepPower = metric == .power ? snapshot.sleepPeriods.compactMap(\.powerWatts) : []
        let highest = (highs + sleepPower).max() ?? 1
        switch metric {
        case .cpu:
            return 0...min(max(highest * 1.15, 0.1), 1)
        case .power:
            return 0...max(highest * 1.15, 1)
        case .memory, .disk:
            // These hardly ever get near zero, so zoom in on the range that is actually used.
            let lowest = values.min() ?? 0
            let total = Double(points.map(metric == .memory ? \.memoryTotal : \.diskTotal).max() ?? 0)
            let padding = max((highest - lowest) * 0.25, total * 0.02, 1)
            return max(lowest - padding, 0)...max(highest + padding, 1)
        }
    }

    /// Round tick values for memory and disk, which the automatic ticks can't find in raw bytes.
    private func byteTicks(in domain: ClosedRange<Double>) -> [Double]? {
        let unit: Double
        switch metric {
        case .memory: unit = 1_073_741_824
        case .disk: unit = 1_000_000_000
        case .cpu, .power: return nil
        }
        let span = (domain.upperBound - domain.lowerBound) / unit
        let step = [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512].first { span / $0 <= 4 } ?? 1024
        let first = (domain.lowerBound / unit / step).rounded(.up)
        let last = (domain.upperBound / unit / step).rounded(.down)
        guard first <= last else { return nil }
        return stride(from: first, through: last, by: 1).map { $0 * step * unit }
    }

    /// The same width for every chart's Y axis labels, so the time axes of all charts line up.
    private static let yLabelWidth: CGFloat = 62

    var body: some View {
        let yDomain = yDomain
        let showsBand = showsBand
        let yTicks = byteTicks(in: yDomain)
        // The crosshair, tooltip and drag selection are drawn by the chart itself (as marks),
        // so they are always placed with exactly the same scale as the data.
        let hoverDate = hover.date
        let hoveredSleep = hoverDate.flatMap { date in snapshot.sleepPeriods.first { $0.contains(date) } }
        let hoveredPoint = hoveredSleep == nil ? hoverDate.flatMap(snapshot.point(near:)) : nil

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(metric.title)
                } icon: {
                    Image(systemName: metric.systemImage)
                        .foregroundStyle(metric.color)
                }
                .font(.headline)
                Spacer()
                if let stats = snapshot.stats[metric] {
                    Text("Average \(metric.format(stats.average)) · highest \(metric.format(stats.maximum))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Chart {
                if let timeline {
                    ForEach(Array(timeline.gapBands.enumerated()), id: \.offset) { _, band in
                        RectangleMark(xStart: .value("Gap Start", band.lowerBound), xEnd: .value("Gap End", band.upperBound))
                            .foregroundStyle(.gray.opacity(0.15))
                    }
                }

                // Shade sleep periods behind the data, clipped to the visible range.
                ForEach(snapshot.sleepPeriods) { period in
                    let start = x(max(period.start, snapshot.domain.lowerBound))
                    let end = x(min(period.end, snapshot.domain.upperBound))
                    RectangleMark(xStart: .value("Sleep Start", start), xEnd: .value("Sleep End", end))
                        .foregroundStyle(.indigo.opacity(0.1))

                    if metric == .power, let watts = period.powerWatts {
                        RuleMark(xStart: .value("Sleep Start", start), xEnd: .value("Sleep End", end), y: .value("Sleep Power", watts))
                            .foregroundStyle(.indigo)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                }

                ForEach(points) { point in
                    if let value = metric.value(point) {
                        if showsBand, let band = metric.band(point) {
                            AreaMark(
                                x: .value("Time", x(point.date)),
                                yStart: .value("Lowest", band.lowerBound),
                                yEnd: .value("Highest", band.upperBound),
                                series: .value("Segment", point.segment)
                            )
                            .foregroundStyle(metric.color.opacity(0.22))
                        } else if !showsBand {
                            AreaMark(
                                x: .value("Time", x(point.date)),
                                yStart: .value("Baseline", yDomain.lowerBound),
                                yEnd: .value(metric.title, value),
                                series: .value("Segment", point.segment)
                            )
                            .foregroundStyle(LinearGradient(
                                colors: [metric.color.opacity(0.28), metric.color.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                        }

                        LineMark(
                            x: .value("Time", x(point.date)),
                            y: .value(metric.title, value),
                            series: .value("Segment", point.segment)
                        )
                        .foregroundStyle(metric.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }

                if let dragRange = hover.dragRange {
                    RectangleMark(xStart: .value("Start", x(dragRange.lowerBound)), xEnd: .value("End", x(dragRange.upperBound)))
                        .foregroundStyle(.gray.opacity(0.2))
                }

                if let hoverDate, let hoveredSleep {
                    RuleMark(x: .value("Selected", x(hoverDate)))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            ChartTooltip {
                                sleepDescription(hoveredSleep)
                            }
                        }
                } else if let hoveredPoint, let value = metric.value(hoveredPoint) {
                    RuleMark(x: .value("Selected", x(hoveredPoint.date)))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            ChartTooltip {
                                Text(hoveredPoint.date.formatted(date: .abbreviated, time: snapshot.pointDuration < 60 ? .standard : .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(metric.format(value))
                                    .font(.callout.weight(.semibold))
                                if let band = metric.band(hoveredPoint), band.upperBound - band.lowerBound > 0 {
                                    Text("\(metric.format(band.lowerBound)) – \(metric.format(band.upperBound))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    PointMark(x: .value("Time", x(hoveredPoint.date)), y: .value(metric.title, value))
                        .foregroundStyle(metric.color)
                        .symbolSize(40)
                }
            }
            .chartXScale(domain: chartDomain)
            .chartXAxis {
                if let timeline {
                    AxisMarks(values: timeline.tickDates) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(timeline.real(date).formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            }
                        }
                    }
                } else {
                    AxisMarks()
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                if let yTicks {
                    AxisMarks(values: yTicks) { value in
                        AxisGridLine()
                        yLabel(value)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        yLabel(value)
                    }
                }
            }
            .chartOverlay { proxy in
                ChartInteractionLayer(timeline: timeline, proxy: proxy, hover: hover, onZoom: onZoom)
            }
            .frame(height: 150)
        }
    }
}

extension MetricChart {
    @ViewBuilder
    private func sleepDescription(_ period: SleepPeriod) -> some View {
        Label("Asleep", systemImage: "moon.zzz.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.indigo)
        Text("\(period.start.formatted(date: .abbreviated, time: .shortened)) – \(period.end.formatted(date: .omitted, time: .shortened))")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(SleepPeriod.format(period.duration))
            .font(.caption)
        if metric == .power {
            if let watts = period.powerWatts, let energy = period.energyWattHours {
                Text("\(formattedEnergy(energy)) used · \(formattedPower(watts)) on average")
                    .font(.caption)
            } else {
                Text("Power during sleep unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func yLabel(_ value: AxisValue) -> some AxisMark {
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(metric.format(number))
                    .frame(width: Self.yLabelWidth, alignment: .leading)
            }
        }
    }
}

/// Tracks hovering and dragging over a chart and turns mouse positions into dates.
private struct ChartInteractionLayer: View {
    let timeline: GapTimeline?
    let proxy: ChartProxy
    let hover: ChartHover
    let onZoom: (ClosedRange<Date>) -> Void

    private func real(_ chartDate: Date) -> Date { timeline?.real(chartDate) ?? chartDate }

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                // Mouse positions are relative to the overlay; the proxy expects plot-area coordinates.
                let plot = geometry[anchor]

                MouseTrackingView(
                    onMove: { point in
                        guard let point else {
                            hover.date = nil
                            return
                        }
                        hover.plotWidth = plot.width
                        hover.date = proxy.value(atX: point.x - plot.minX, as: Date.self).map(real)
                    },
                    onDrag: { start, current in
                        if let from = proxy.value(atX: start.x - plot.minX, as: Date.self),
                           let to = proxy.value(atX: current.x - plot.minX, as: Date.self) {
                            hover.dragRange = real(min(from, to))...real(max(from, to))
                        }
                    },
                    onDragEnd: {
                        if let dragRange = hover.dragRange {
                            onZoom(dragRange)
                        }
                        hover.dragRange = nil
                    }
                )
            }
        }
    }
}

/// The small box shown next to the crosshair.
struct ChartTooltip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .fixedSize()
    }
}
