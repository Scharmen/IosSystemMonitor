//
//  SystemMonitor.swift
//  SystemInfo
//

import Foundation
import Darwin
import IOKit

/// Periodically samples CPU, memory, disk, and power usage from the system.
@Observable
@MainActor
final class SystemMonitor {
    /// CPU usage across all cores, in the range 0...1.
    private(set) var cpuUsage: Double = 0
    private(set) var memoryUsed: Int64 = 0
    let memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    private(set) var diskUsed: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    /// Total system power draw in watts, or `nil` if the Mac doesn't report it (e.g. desktops without a battery).
    private(set) var powerWatts: Double?

    /// A point-in-time copy of all metrics.
    struct Snapshot {
        let cpuUsage: Double
        let memoryUsed: Int64
        let memoryTotal: Int64
        let diskUsed: Int64
        let diskTotal: Int64
        let powerWatts: Double?
    }

    /// Called after each update once CPU usage can be measured (i.e. from the second sample on).
    @ObservationIgnored var onUpdate: ((Snapshot) -> Void)?

    private let host = mach_host_self()
    private let pageSize = Int64(getpagesize())
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var updateTask: Task<Void, Never>?

    init(interval: Duration = .seconds(2)) {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.update()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func update() {
        let hasCPUBaseline = previousTicks != nil
        updateCPU()
        updateMemory()
        updateDisk()
        updatePower()

        guard hasCPUBaseline else { return }
        onUpdate?(Snapshot(
            cpuUsage: cpuUsage,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            diskUsed: diskUsed,
            diskTotal: diskTotal,
            powerWatts: powerWatts
        ))
    }

    // MARK: - CPU

    private func updateCPU() {
        guard let ticks = readCPUTicks() else { return }
        // CPU ticks are cumulative counters, so usage is the busy share of the delta since the last sample.
        if let previous = previousTicks, ticks.total > previous.total {
            cpuUsage = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
        }
        previousTicks = ticks
    }

    private func readCPUTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Tuple order: CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = UInt64(user) + UInt64(system) + UInt64(nice)
        return (busy, busy + UInt64(idle))
    }

    // MARK: - Memory

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // Mirrors Activity Monitor's "Memory Used": app memory + wired + compressed.
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let usedPages = appPages + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        memoryUsed = usedPages * pageSize
    }

    // MARK: - Disk

    private func updateDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }
        diskTotal = Int64(total)
        diskUsed = Int64(total) - available
    }

    // MARK: - Power

    /// Running totals kept by the battery controller. Dividing the change in `accumulatedLoad`
    /// by the change in `sampleCount` gives the average power (in milliwatts) between two readings.
    struct PowerTelemetry {
        let accumulatedLoad: Double
        let sampleCount: Double
    }

    /// Discards the CPU baseline, e.g. after sleep, so the next value isn't averaged across the sleep.
    func resetCPUBaseline() {
        previousTicks = nil
    }

    func readPowerTelemetry() -> PowerTelemetry? {
        guard let telemetry = readTelemetryData(),
              let load = telemetry["AccumulatedSystemLoad"] as? NSNumber,
              let count = telemetry["SystemLoadAccumulatorCount"] as? NSNumber
        else { return nil }
        return PowerTelemetry(accumulatedLoad: load.doubleValue, sampleCount: count.doubleValue)
    }

    private func updatePower() {
        // "SystemLoad" is the whole system's power draw in milliwatts, whether it's
        // supplied by the power adapter, the battery, or both.
        guard let milliwatts = readTelemetryData()?["SystemLoad"] as? NSNumber else {
            powerWatts = nil
            return
        }
        powerWatts = milliwatts.doubleValue / 1000
    }

    private func readTelemetryData() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        return IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
