//
//  EnergyPage.swift
//  SystemInfo
//

import SwiftUI
import Charts

/// Energy used in the visible time span: totals, cost, and a bar chart split into awake and asleep.
struct EnergyPage: View {
    let store: HistoryStore

    @AppStorage(SettingsKey.pricePerKWh) private var pricePerKWh = 0.0
    @Environment(\.openSettings) private var openSettings
    @State private var hover = ChartHover()

    var body: some View {
        let snapshot = store.snapshot

        if !store.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let energy = snapshot.energy {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    cards(energy)
                    chart(snapshot)
                    notes(snapshot, energy: energy)
                }
                .padding(20)
            }
        } else if snapshot.isEmpty {
            HistoryEmptyView(hasAnyHistory: snapshot.earliest != nil)
        } else {
            ContentUnavailableView(
                "No Power Data",
                systemImage: "bolt.slash",
                description: Text("No power consumption was recorded in this time span. Power values need a Mac that reports its power consumption to macOS.")
            )
        }
    }

    /// Without a price, the Cost card shows a button, so all cards keep that row free.
    private var needsPrice: Bool { pricePerKWh <= 0 }

    private func cards(_ energy: EnergySummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "Energy Used",
                systemImage: "powerplug.fill",
                tint: .orange,
                value: formattedEnergy(energy.totalWattHours),
                detail: "Awake and asleep together",
                showsAccessory: needsPrice
            ) { EmptyView() }

            MetricCard(
                title: "Cost",
                systemImage: "banknote",
                tint: .green,
                value: pricePerKWh > 0 ? formattedCost(wattHours: energy.totalWattHours, pricePerKWh: pricePerKWh) : "–",
                detail: pricePerKWh > 0
                    ? "At \(pricePerKWh.formatted(.number.precision(.fractionLength(0...4)))) \(Locale.current.currency?.identifier ?? "EUR") per kWh"
                    : "No electricity price set",
                showsAccessory: needsPrice
            ) {
                if pricePerKWh <= 0 {
                    Button("Set Price…") {
                        openSettings()
                        AppWindows.bringToFront(AppWindows.settingsIdentifier)
                    }
                    .controlSize(.small)
                }
            }

            MetricCard(
                title: "While Awake",
                systemImage: "bolt.fill",
                tint: .orange,
                value: formattedEnergy(energy.awakeWattHours),
                detail: energy.awakeAverageWatts.map { "\(formattedPower($0)) on average" } ?? "No power recorded",
                showsAccessory: needsPrice
            ) { EmptyView() }

            MetricCard(
                title: "While Asleep",
                systemImage: "moon.zzz.fill",
                tint: .indigo,
                value: energy.asleepSeconds > 0 ? formattedEnergy(energy.asleepWattHours) : "–",
                detail: energy.asleepAverageWatts.map { "\(formattedPower($0)) on average" } ?? "No sleep with known power",
                showsAccessory: needsPrice
            ) { EmptyView() }
        }
    }

    private func chart(_ snapshot: HistorySnapshot) -> some View {
        let bars = snapshot.energyBars
        // Show kilowatt-hours once the bars get large enough.
        let usesKilowattHours = (bars.map(\.totalWattHours).max() ?? 0) >= 1000
        let scale = usesKilowattHours ? 0.001 : 1.0
        let unit = usesKilowattHours ? "kWh" : "Wh"
        // The same time span as the other pages, widened so the first and last bar are fully visible.
        let domain = min(bars.first?.interval.start ?? .distantFuture, snapshot.domain.lowerBound)...max(bars.last?.interval.end ?? .distantPast, snapshot.domain.upperBound)

        return VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Energy per \(snapshot.energyGranularity.unitName)")
            } icon: {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.orange)
            }
            .font(.headline)

            Chart {
                ForEach(bars) { bar in
                    barMarks(bar, scale: scale)
                }

                if let date = hover.date, let bar = bars.first(where: { $0.interval.start <= date && date < $0.interval.end }) {
                    RuleMark(x: .value("Selected", bar.interval.start.addingTimeInterval(bar.interval.duration / 2)))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                            ChartTooltip {
                                Text(snapshot.energyGranularity.label(for: bar.interval))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formattedEnergy(bar.totalWattHours))
                                    .font(.callout.weight(.semibold))
                                if bar.asleepWattHours > 0 {
                                    Text("Awake \(formattedEnergy(bar.awakeWattHours)) · asleep \(formattedEnergy(bar.asleepWattHours))")
                                        .font(.caption)
                                }
                                if pricePerKWh > 0 {
                                    Text("Cost \(formattedCost(wattHours: bar.totalWattHours, pricePerKWh: pricePerKWh))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                }
            }
            .chartForegroundStyleScale(["Awake": Color.orange, "Asleep": Color.indigo])
            .chartXScale(domain: domain)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(number.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        MouseTrackingView(onMove: { point in
                            hover.date = point.flatMap { proxy.value(atX: $0.x - plot.minX, as: Date.self) }
                        })
                    }
                }
            }
            .frame(height: 280)
        }
    }

    /// One bar: the awake part at the bottom and the asleep part stacked on top.
    @ChartContentBuilder
    private func barMarks(_ bar: EnergyBar, scale: Double) -> some ChartContent {
        // Leave a little air between neighbouring bars.
        let inset = bar.interval.duration * 0.1
        let start = bar.interval.start.addingTimeInterval(inset)
        let end = bar.interval.end.addingTimeInterval(-inset)

        if bar.awakeWattHours > 0 {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", end),
                yStart: .value("Energy", 0.0),
                yEnd: .value("Energy", bar.awakeWattHours * scale)
            )
            .foregroundStyle(by: .value("State", "Awake"))
        }
        if bar.asleepWattHours > 0 {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", end),
                yStart: .value("Energy", bar.awakeWattHours * scale),
                yEnd: .value("Energy", bar.totalWattHours * scale)
            )
            .foregroundStyle(by: .value("State", "Asleep"))
        }
    }

    private func notes(_ snapshot: HistorySnapshot, energy: EnergySummary) -> some View {
        let span = snapshot.domain.upperBound.timeIntervalSince(snapshot.domain.lowerBound)
        let isPartial = energy.coveredSeconds < span * 0.95

        return VStack(alignment: .leading, spacing: 6) {
            if isPartial {
                Text("Power was recorded for \(formattedSpan(energy.coveredSeconds)) out of the \(formattedSpan(span)) shown. The totals only cover the recorded time.")
            }
            Text("Energy includes the time your Mac was asleep. Sleep energy is only known for sleeps of at least 15 minutes.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
