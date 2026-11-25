//
//  HistoryLoader.swift
//  SystemInfo
//

import Foundation
import SwiftData

/// What the history window wants to see: a preset range ending now, or a custom time span.
nonisolated struct HistoryRequest: Sendable, Equatable {
    var range: HistoryRange
    var customRange: ClosedRange<Date>?
}

/// Reads the history database and prepares everything the history window shows.
/// Runs off the main thread with its own `ModelContext`, so long ranges don't block the UI.
nonisolated enum HistoryLoader {
    /// Charts never get more points than this; longer ranges are averaged into buckets.
    static let maxChartPoints = 500

    @concurrent
    static func load(_ request: HistoryRequest, container: ModelContainer) async -> HistorySnapshot {
        let context = ModelContext(container)
        let now = Date.now

        var oldestDescriptor = FetchDescriptor<MetricSample>(sortBy: [SortDescriptor(\.timestamp)])
        oldestDescriptor.fetchLimit = 1
        let earliest = (try? context.fetch(oldestDescriptor))?.first?.timestamp

        let start: Date
        let end: Date
        if let customRange = request.customRange {
            start = customRange.lowerBound
            end = customRange.upperBound
        } else if let duration = request.range.duration {
            end = now
            start = end.addingTimeInterval(-duration)
        } else {
            end = now
            start = earliest ?? end
        }
        let domain = start...max(end, start.addingTimeInterval(60))
        var snapshot = HistorySnapshot(domain: domain, earliest: earliest)

        let descriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end && !$0.isSleep },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let samples = (try? context.fetch(descriptor)) ?? []

        // A sleep can begin before the visible range and still overlap it, so filter by end time in memory.
        // There are only a few sleep samples per day, so fetching all up to `end` is cheap.
        let sleepDescriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.isSleep && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        snapshot.sleepPeriods = ((try? context.fetch(sleepDescriptor)) ?? [])
            .map { SleepPeriod(start: $0.timestamp, end: $0.timestamp.addingTimeInterval(Double($0.resolution)), powerWatts: $0.powerWatts) }
            .filter { $0.end >= start }

        // Older data may be stored coarser than the chart buckets, so report whichever is larger.
        let bucketLength = max(end.timeIntervalSince(start) / Double(maxChartPoints), Double(HistoryRecorder.sampleResolution))
        snapshot.pointDuration = max(bucketLength, Double(samples.map(\.resolution).max() ?? 0)).rounded()
        snapshot.points = downsample(samples, from: start, bucketLength: bucketLength)
        snapshot.timeline = GapTimeline(points: snapshot.points, pointDuration: snapshot.pointDuration)
        snapshot.stats = stats(for: samples)

        snapshot.diskUsedAtStart = samples.first?.diskUsed
        snapshot.diskUsedLatest = samples.last?.diskUsed
        snapshot.diskTotal = samples.last?.diskTotal

        addEnergy(to: &snapshot, samples: samples)
        return snapshot
    }

    // MARK: - Chart points

    /// Reduces the (sorted) samples to one point per bucket so charts stay fast for long ranges.
    /// Each point keeps the average plus the lowest and highest value, so short spikes stay visible.
    private static func downsample(_ samples: [MetricSample], from start: Date, bucketLength: TimeInterval) -> [HistoryPoint] {
        var points: [HistoryPoint] = []

        var index = 0
        while index < samples.count {
            let bucket = floor(samples[index].timestamp.timeIntervalSince(start) / bucketLength)
            var groupEnd = index
            while groupEnd < samples.count, floor(samples[groupEnd].timestamp.timeIntervalSince(start) / bucketLength) == bucket {
                groupEnd += 1
            }
            let group = samples[index..<groupEnd]
            let first = samples[index]

            var weight = 0.0, cpu = 0.0, memory = 0.0, disk = 0.0
            var cpuMin = Double.infinity, cpuMax = -Double.infinity
            var powerWeight = 0.0, power = 0.0
            var powerMin = Double.infinity, powerMax = -Double.infinity
            for sample in group {
                let seconds = Double(max(sample.resolution, 1))
                weight += seconds
                cpu += sample.cpuUsage * seconds
                memory += Double(sample.memoryUsed) * seconds
                disk += Double(sample.diskUsed) * seconds
                cpuMin = min(cpuMin, sample.cpuMin ?? sample.cpuUsage)
                cpuMax = max(cpuMax, sample.cpuMax ?? sample.cpuUsage)
                if let watts = sample.powerWatts {
                    powerWeight += seconds
                    power += watts * seconds
                    powerMin = min(powerMin, sample.powerMin ?? watts)
                    powerMax = max(powerMax, sample.powerMax ?? watts)
                }
            }

            var point = HistoryPoint(
                date: first.timestamp,
                cpuUsage: cpu / weight,
                cpuMin: cpuMin,
                cpuMax: cpuMax,
                memoryUsed: Int64(memory / weight),
                memoryTotal: group.map(\.memoryTotal).max() ?? 0,
                diskUsed: Int64(disk / weight),
                diskTotal: group.map(\.diskTotal).max() ?? 0,
                powerWatts: powerWeight > 0 ? power / powerWeight : nil,
                powerMin: powerWeight > 0 ? powerMin : nil,
                powerMax: powerWeight > 0 ? powerMax : nil
            )
            let resolution = group.map(\.resolution).max() ?? 60

            // A gap (e.g. the Mac was off) starts a new segment so no line is drawn across it.
            if let previous = points.last {
                let gap = point.date.timeIntervalSince(previous.date)
                point.segment = previous.segment + (gap > 3 * max(bucketLength, Double(resolution)) ? 1 : 0)
            }
            points.append(point)
            index = groupEnd
        }
        return points
    }

    // MARK: - Summary values

    private static func stats(for samples: [MetricSample]) -> [HistoryMetric: MetricStats] {
        var result: [HistoryMetric: MetricStats] = [:]

        func add(_ metric: HistoryMetric, value: (MetricSample) -> Double?, low: (MetricSample) -> Double?, high: (MetricSample) -> Double?) {
            var weight = 0.0, sum = 0.0
            var minimum = Double.infinity, maximum = -Double.infinity
            var latest: Double?
            for sample in samples {
                guard let current = value(sample) else { continue }
                let seconds = Double(max(sample.resolution, 1))
                weight += seconds
                sum += current * seconds
                minimum = min(minimum, low(sample) ?? current)
                maximum = max(maximum, high(sample) ?? current)
                latest = current
            }
            guard weight > 0, let latest else { return }
            result[metric] = MetricStats(minimum: minimum, average: sum / weight, maximum: maximum, latest: latest)
        }

        add(.cpu, value: { $0.cpuUsage }, low: { $0.cpuMin }, high: { $0.cpuMax })
        add(.memory, value: { Double($0.memoryUsed) }, low: { _ in nil }, high: { _ in nil })
        add(.power, value: { $0.powerWatts }, low: { $0.powerMin }, high: { $0.powerMax })
        add(.disk, value: { Double($0.diskUsed) }, low: { _ in nil }, high: { _ in nil })
        return result
    }

    // MARK: - Energy

    /// Sums power into energy: each sample's watts times the seconds it covers, split into the
    /// bars of the energy chart. Sleeps are clipped to the visible time span.
    private static func addEnergy(to snapshot: inout HistorySnapshot, samples: [MetricSample]) {
        let domain = snapshot.domain
        let granularity = EnergyGranularity.forSpan(domain.upperBound.timeIntervalSince(domain.lowerBound))
        let calendar = Calendar.current
        var summary = EnergySummary()
        var bars: [Date: EnergyBar] = [:]
        var cached: DateInterval?

        /// Spreads `wattHours` over the bars that `start..<end` overlaps, by time.
        func distribute(from start: Date, to end: Date, wattHours: Double, asleep: Bool) {
            let total = end.timeIntervalSince(start)
            guard total > 0 else { return }
            var cursor = start
            while cursor < end {
                let interval: DateInterval
                if let cached, cached.start <= cursor, cursor < cached.end {
                    interval = cached
                } else {
                    interval = granularity.interval(containing: cursor, calendar: calendar)
                    cached = interval
                }
                // Guard against a zero-length interval, which would never advance.
                let sliceEnd = min(max(interval.end, cursor.addingTimeInterval(1)), end)
                let share = wattHours * sliceEnd.timeIntervalSince(cursor) / total
                var bar = bars[interval.start] ?? EnergyBar(interval: interval)
                if asleep {
                    bar.asleepWattHours += share
                } else {
                    bar.awakeWattHours += share
                }
                bars[interval.start] = bar
                cursor = sliceEnd
            }
        }

        for sample in samples {
            guard let watts = sample.powerWatts else { continue }
            let seconds = Double(sample.resolution)
            let wattHours = watts * seconds / 3600
            summary.awakeWattHours += wattHours
            summary.awakeSeconds += seconds
            distribute(from: sample.timestamp, to: sample.timestamp.addingTimeInterval(seconds), wattHours: wattHours, asleep: false)
        }

        for period in snapshot.sleepPeriods {
            guard let watts = period.powerWatts else { continue }
            let start = max(period.start, domain.lowerBound)
            let end = min(period.end, domain.upperBound)
            let seconds = end.timeIntervalSince(start)
            guard seconds > 0 else { continue }
            let wattHours = watts * seconds / 3600
            summary.asleepWattHours += wattHours
            summary.asleepSeconds += seconds
            distribute(from: start, to: end, wattHours: wattHours, asleep: true)
        }

        snapshot.energyGranularity = granularity
        snapshot.energyBars = bars.values.sorted { $0.interval.start < $1.interval.start }
        snapshot.energy = summary.coveredSeconds > 0 ? summary : nil
    }
}
