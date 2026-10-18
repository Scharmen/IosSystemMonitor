//
//  MetricSample.swift
//  SystemInfo
//

import Foundation
import SwiftData

/// One stored history entry: averaged system metrics over `resolution` seconds starting at `timestamp`.
@Model
final class MetricSample {
    #Index<MetricSample>([\.timestamp])

    var timestamp: Date
    /// Number of seconds this sample covers (30 for fresh samples, larger once condensed or for sleep periods).
    var resolution: Int
    var cpuUsage: Double
    var memoryUsed: Int64
    var memoryTotal: Int64
    var diskUsed: Int64
    var diskTotal: Int64
    var powerWatts: Double?
    /// `true` if this sample covers a period the Mac was asleep. Sleep samples are never merged
    /// with regular ones; their `powerWatts` is the average draw during sleep, if it could be determined.
    var isSleep: Bool = false

    init(timestamp: Date, resolution: Int, cpuUsage: Double, memoryUsed: Int64, memoryTotal: Int64, diskUsed: Int64, diskTotal: Int64, powerWatts: Double?, isSleep: Bool = false) {
        self.timestamp = timestamp
        self.resolution = resolution
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.powerWatts = powerWatts
        self.isSleep = isSleep
    }

    /// Combines samples into one, weighting each by the time span it covers.
    static func average(of samples: [MetricSample], timestamp: Date, resolution: Int) -> MetricSample {
        let weights = samples.map { Double($0.resolution) }
        let totalWeight = max(weights.reduce(0, +), 1)

        func mean(_ value: (MetricSample) -> Double) -> Double {
            zip(samples, weights).reduce(0) { $0 + value($1.0) * $1.1 } / totalWeight
        }

        let powered = zip(samples, weights).compactMap { sample, weight in sample.powerWatts.map { ($0, weight) } }
        let powerWeight = powered.reduce(0) { $0 + $1.1 }

        return MetricSample(
            timestamp: timestamp,
            resolution: resolution,
            cpuUsage: mean(\.cpuUsage),
            memoryUsed: Int64(mean { Double($0.memoryUsed) }),
            memoryTotal: samples.map(\.memoryTotal).max() ?? 0,
            diskUsed: Int64(mean { Double($0.diskUsed) }),
            diskTotal: samples.map(\.diskTotal).max() ?? 0,
            powerWatts: powerWeight > 0 ? powered.reduce(0) { $0 + $1.0 * $1.1 } / powerWeight : nil
        )
    }
}
