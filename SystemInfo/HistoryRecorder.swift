//
//  HistoryRecorder.swift
//  SystemInfo
//

import AppKit
import SwiftData

/// How long recorded history is kept.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case day, week, month, threeMonths, year, unlimited

    static let storageKey = "history.retention"

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "1 Day"
        case .week: "1 Week"
        case .month: "1 Month"
        case .threeMonths: "3 Months"
        case .year: "1 Year"
        case .unlimited: "Unlimited"
        }
    }

    /// How far back samples are kept, or `nil` to keep them forever.
    var duration: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .day: return day
        case .week: return 7 * day
        case .month: return 30 * day
        case .threeMonths: return 90 * day
        case .year: return 365 * day
        case .unlimited: return nil
        }
    }

    static var current: HistoryRetention {
        UserDefaults.standard.string(forKey: storageKey).flatMap(HistoryRetention.init) ?? .month
    }
}

/// Collects the live metrics into per-minute samples and keeps the history database small.
///
/// Storage is bounded even with unlimited retention: older samples are condensed into
/// coarser averages (see `compactionTiers`), the total sample count is capped, and recording
/// pauses while the disk is nearly full.
@Observable
@MainActor
final class HistoryRecorder {
    let monitor = SystemMonitor()
    let container: ModelContainer

    /// `true` while recording is paused because free disk space is low.
    private(set) var isPausedForLowDiskSpace = false
    private(set) var sampleCount = 0
    private(set) var storeSize: Int64 = 0

    /// Fresh samples cover 30 seconds and are kept at that detail for the first compaction tier's age.
    static let sampleResolution = 30
    /// Samples older than `age` are merged into averages covering `resolution` seconds.
    private static let compactionTiers: [(age: TimeInterval, resolution: Int)] = [
        (age: 7 * 86_400, resolution: 15 * 60),
        (age: 90 * 86_400, resolution: 60 * 60),
    ]
    /// Safety net on top of compaction; at ~150 bytes per row this stays well below 100 MB.
    private static let maximumSampleCount = 500_000
    private static let minimumFreeDiskSpace: Int64 = 1_000_000_000

    @ObservationIgnored private var pending: [SystemMonitor.Snapshot] = []
    @ObservationIgnored private var pendingInterval: Date?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: SystemMonitor.Snapshot?

    /// Set between the "will sleep" and "did wake" notifications.
    @ObservationIgnored private var sleepStart: Date?
    @ObservationIgnored private var telemetryBeforeSleep: SystemMonitor.PowerTelemetry?
    @ObservationIgnored private var sleepPowerTask: Task<Void, Never>?

    /// Sleep power is only estimated for sleeps at least this long, so the awake minutes around
    /// the sleep (the telemetry is only refreshed every so often) don't distort the result.
    private static let minimumSleepForPowerEstimate: TimeInterval = 15 * 60

    private var context: ModelContext { container.mainContext }

    init() {
        do {
            container = try ModelContainer(for: MetricSample.self)
        } catch {
            // Keep the app usable even if the store can't be opened; history just won't persist.
            container = try! ModelContainer(for: MetricSample.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        monitor.onUpdate = { [weak self] snapshot in
            self?.record(snapshot)
        }

        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.performMaintenance()
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        // Save the partially collected interval so no data is lost when quitting.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }

        // Apps don't run while the Mac sleeps, so sleep periods are recorded around the sleep instead.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillSleep()
            }
        }
        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDidWake()
            }
        }
    }

    // MARK: - Sleep

    private func handleWillSleep() {
        flush()
        sleepStart = .now
        telemetryBeforeSleep = monitor.readPowerTelemetry()
    }

    private func handleDidWake() {
        monitor.resetCPUBaseline()
        guard let sleepStart else { return }
        self.sleepStart = nil

        let duration = Date.now.timeIntervalSince(sleepStart)
        guard duration >= Double(Self.sampleResolution), let last = lastSnapshot else { return }

        // The Mac does nothing visible while asleep; memory and disk keep their last values.
        let sample = MetricSample(
            timestamp: sleepStart,
            resolution: Int(duration),
            cpuUsage: 0,
            memoryUsed: last.memoryUsed,
            memoryTotal: last.memoryTotal,
            diskUsed: last.diskUsed,
            diskTotal: last.diskTotal,
            powerWatts: nil,
            isSleep: true
        )
        context.insert(sample)
        try? context.save()
        refreshStorageInfo()

        if let before = telemetryBeforeSleep, duration >= Self.minimumSleepForPowerEstimate {
            estimateSleepPower(for: sample, duration: duration, before: before)
        }
        telemetryBeforeSleep = nil
    }

    /// Fills in the sample's average power during sleep from the battery controller's running totals.
    ///
    /// The telemetry in the IORegistry is only refreshed periodically, so right after waking it may
    /// still show the pre-sleep values. Retry for a few minutes until it has caught up.
    private func estimateSleepPower(for sample: MetricSample, duration: TimeInterval, before: SystemMonitor.PowerTelemetry) {
        sleepPowerTask?.cancel()
        sleepPowerTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(20))
                // Stop if the sample was removed in the meantime (e.g. history was cleared).
                guard let self, !Task.isCancelled, sample.modelContext != nil else { return }
                guard let after = self.monitor.readPowerTelemetry() else { return }

                let readings = after.sampleCount - before.sampleCount
                // The controller adds about one reading per second, also during sleep (measured on a Mac mini:
                // ~100,500 readings over ~27.9 h of uptime that included 30 sleeps). This works on Macs without
                // a battery too. If the count barely rose, it only reflects the awake minutes around the sleep,
                // which must not be reported as sleep power — so keep waiting (or give up).
                guard readings >= duration * 0.25 else { continue }

                sample.powerWatts = (after.accumulatedLoad - before.accumulatedLoad) / readings / 1000
                try? self.context.save()
                return
            }
        }
    }

    // MARK: - Recording

    private func record(_ snapshot: SystemMonitor.Snapshot) {
        // Ignore anything delivered during brief maintenance wakes while the Mac is asleep.
        guard sleepStart == nil else { return }
        lastSnapshot = snapshot

        let resolution = Double(Self.sampleResolution)
        let interval = Date(timeIntervalSinceReferenceDate: floor(Date.now.timeIntervalSinceReferenceDate / resolution) * resolution)
        if let pendingInterval, pendingInterval != interval {
            flush()
        }
        pendingInterval = interval
        pending.append(snapshot)
    }

    /// Stores the snapshots collected during the last interval as one averaged sample.
    private func flush() {
        defer {
            pending.removeAll()
            pendingInterval = nil
        }
        guard let pendingInterval, let last = pending.last else { return }

        isPausedForLowDiskSpace = last.diskTotal - last.diskUsed < Self.minimumFreeDiskSpace
        guard !isPausedForLowDiskSpace else { return }

        func mean(_ value: (SystemMonitor.Snapshot) -> Double) -> Double {
            pending.reduce(0) { $0 + value($1) } / Double(pending.count)
        }
        let powerValues = pending.compactMap(\.powerWatts)

        context.insert(MetricSample(
            timestamp: pendingInterval,
            resolution: Self.sampleResolution,
            cpuUsage: mean(\.cpuUsage),
            memoryUsed: Int64(mean { Double($0.memoryUsed) }),
            memoryTotal: last.memoryTotal,
            diskUsed: last.diskUsed,
            diskTotal: last.diskTotal,
            powerWatts: powerValues.isEmpty ? nil : powerValues.reduce(0, +) / Double(powerValues.count)
        ))
        try? context.save()
        refreshStorageInfo()
    }

    // MARK: - Maintenance

    /// Applies the retention setting, condenses old samples, and enforces the storage cap.
    func performMaintenance() {
        let now = Date.now

        if let duration = HistoryRetention.current.duration {
            let cutoff = now.addingTimeInterval(-duration)
            try? context.delete(model: MetricSample.self, where: #Predicate { $0.timestamp < cutoff })
        }

        for tier in Self.compactionTiers {
            compact(olderThan: tier.age, into: tier.resolution, now: now)
        }

        enforceSampleLimit()
        try? context.save()
        refreshStorageInfo()
    }

    func clearHistory() {
        try? context.delete(model: MetricSample.self)
        try? context.save()
        refreshStorageInfo()
    }

    private func compact(olderThan age: TimeInterval, into targetResolution: Int, now: Date) {
        let bucketLength = Double(targetResolution)
        // Align the cutoff to a bucket boundary so only complete buckets get merged.
        let cutoff = Date(timeIntervalSinceReferenceDate: floor((now.timeIntervalSinceReferenceDate - age) / bucketLength) * bucketLength)
        let descriptor = FetchDescriptor<MetricSample>(
            predicate: #Predicate { $0.timestamp < cutoff && $0.resolution < targetResolution && !$0.isSleep }
        )
        guard let samples = try? context.fetch(descriptor), !samples.isEmpty else { return }

        let buckets = Dictionary(grouping: samples) { floor($0.timestamp.timeIntervalSinceReferenceDate / bucketLength) }
        for (bucket, group) in buckets {
            let start = Date(timeIntervalSinceReferenceDate: bucket * bucketLength)
            context.insert(MetricSample.average(of: group, timestamp: start, resolution: targetResolution))
            group.forEach(context.delete)
        }
    }

    private func enforceSampleLimit() {
        let count = (try? context.fetchCount(FetchDescriptor<MetricSample>())) ?? 0
        guard count > Self.maximumSampleCount else { return }

        var oldest = FetchDescriptor<MetricSample>(sortBy: [SortDescriptor(\.timestamp)])
        oldest.fetchLimit = count - Self.maximumSampleCount
        (try? context.fetch(oldest))?.forEach(context.delete)
    }

    private func refreshStorageInfo() {
        sampleCount = (try? context.fetchCount(FetchDescriptor<MetricSample>())) ?? 0

        // SQLite keeps data in the main file plus write-ahead log files next to it.
        guard let url = container.configurations.first?.url else { return }
        storeSize = ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = url.path(percentEncoded: false) + suffix
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + (attributes?[.size] as? Int64 ?? 0)
        }
    }
}
