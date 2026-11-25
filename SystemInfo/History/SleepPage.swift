//
//  SleepPage.swift
//  SystemInfo
//

import SwiftUI

/// Every sleep in the visible time span as a sortable table, with totals on top.
struct SleepPage: View {
    let store: HistoryStore

    @State private var sortOrder = [KeyPathComparator(\SleepPeriod.start, order: .reverse)]

    var body: some View {
        let snapshot = store.snapshot

        if !store.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot.sleepPeriods.isEmpty {
            ContentUnavailableView(
                "No Sleep in This Time Span",
                systemImage: "moon.zzz",
                description: Text("Every time your Mac sleeps, it's listed here with its duration and energy use.")
            )
        } else {
            VStack(alignment: .leading, spacing: 16) {
                cards(snapshot)

                Table(snapshot.sleepPeriods.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Fell Asleep", value: \.start) { period in
                        Text(period.start.formatted(date: .abbreviated, time: .shortened))
                    }
                    TableColumn("Woke Up", value: \.end) { period in
                        Text(period.end.formatted(date: .abbreviated, time: .shortened))
                    }
                    TableColumn("Duration", value: \.duration) { period in
                        Text(SleepPeriod.format(period.duration))
                    }
                    TableColumn("Energy Used", value: \.energySortKey) { period in
                        Text(period.energyWattHours.map(formattedEnergy) ?? "–")
                    }
                    TableColumn("Average Power", value: \.powerSortKey) { period in
                        Text(period.powerWatts.map(formattedPower) ?? "–")
                    }
                }
                .monospacedDigit()

                Text("Energy is only calculated for sleeps of at least 15 minutes and appears 1–3 minutes after waking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func cards(_ snapshot: HistorySnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "Sleeps",
                systemImage: "moon.zzz.fill",
                tint: .indigo,
                value: snapshot.sleepPeriods.count.formatted(),
                detail: "In this time span",
                showsAccessory: false
            ) { EmptyView() }

            MetricCard(
                title: "Time Asleep",
                systemImage: "clock",
                tint: .indigo,
                value: SleepPeriod.format(snapshot.sleepDuration),
                detail: "Inside this time span",
                showsAccessory: false
            ) { EmptyView() }

            MetricCard(
                title: "Energy Asleep",
                systemImage: "powerplug.fill",
                tint: .orange,
                value: snapshot.energy.flatMap { $0.asleepSeconds > 0 ? formattedEnergy($0.asleepWattHours) : nil } ?? "–",
                detail: "Sleeps with known power",
                showsAccessory: false
            ) { EmptyView() }

            MetricCard(
                title: "Average Power Asleep",
                systemImage: "bolt.fill",
                tint: .orange,
                value: snapshot.energy?.asleepAverageWatts.map(formattedPower) ?? "–",
                detail: "Sleeps with known power",
                showsAccessory: false
            ) { EmptyView() }
        }
    }
}
