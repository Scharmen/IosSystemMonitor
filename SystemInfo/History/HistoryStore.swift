//
//  HistoryStore.swift
//  SystemInfo
//

import Foundation
import SwiftData

/// The state of the history window: which time span is shown and the data loaded for it.
@Observable
final class HistoryStore {
    /// The preset range. Picking one returns to the live view that ends now.
    var range = HistoryRange.day {
        didSet {
            guard range != oldValue else { return }
            customRange = nil
            zoomStack = []
            reload()
        }
    }

    /// A time span chosen by zooming, paging or panning; replaces `range` while set.
    private(set) var customRange: ClosedRange<Date>?
    /// The time spans to return to with "Zoom Out", oldest first (`nil` stands for the preset range).
    private(set) var zoomStack: [ClosedRange<Date>?] = []
    private(set) var snapshot = HistorySnapshot.empty
    /// `false` until the first load has finished, so the window can show a spinner instead of "no data".
    private(set) var hasLoaded = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var requestedGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Loading

    /// Loads the current time span in the background. Calls made while a load is running are
    /// combined: only one load runs at a time, and the most recent request always wins.
    func reload() {
        requestedGeneration += 1
        guard loadTask == nil else { return }
        loadTask = Task {
            var loadedGeneration = -1
            while loadedGeneration != requestedGeneration {
                loadedGeneration = requestedGeneration
                let request = HistoryRequest(range: range, customRange: customRange)
                snapshot = await HistoryLoader.load(request, container: container)
                hasLoaded = true
            }
            loadTask = nil
        }
    }

    // MARK: - Navigation

    var isZoomed: Bool { !zoomStack.isEmpty }

    var canPageBack: Bool {
        guard let earliest = snapshot.earliest else { return false }
        return snapshot.domain.lowerBound > earliest
    }

    var canPageForward: Bool {
        guard let customRange else { return false }
        return customRange.upperBound < Date.now.addingTimeInterval(-1)
    }

    /// Zooms into a dragged time span; very short drags are treated as clicks and ignored.
    func zoom(to range: ClosedRange<Date>) {
        let domain = snapshot.domain
        let lower = max(range.lowerBound, domain.lowerBound)
        let upper = min(range.upperBound, domain.upperBound)
        guard upper.timeIntervalSince(lower) >= 2 * Double(HistoryRecorder.sampleResolution) else { return }
        zoomStack.append(customRange)
        customRange = lower...upper
        reload()
    }

    /// Returns to the time span shown before the last zoom.
    func zoomOut() {
        guard let previous = zoomStack.popLast() else { return }
        customRange = previous
        reload()
    }

    /// Moves one full window earlier (`-1`) or later (`1`).
    func page(_ direction: Int) {
        shift(byFraction: Double(direction))
    }

    /// Moves the visible time span by a fraction of its length; negative values go back in time.
    func pan(byFraction fraction: Double) {
        shift(byFraction: fraction)
    }

    private func shift(byFraction fraction: Double) {
        let current = customRange ?? snapshot.domain
        let length = current.upperBound.timeIntervalSince(current.lowerBound)
        guard length > 0, fraction != 0 else { return }
        // Already following "now": there is nothing later to show.
        if fraction > 0, customRange == nil { return }

        var lower = current.lowerBound.addingTimeInterval(fraction * length)
        if fraction < 0, let earliest = snapshot.earliest {
            // Don't move past the oldest recorded sample.
            lower = max(lower, min(earliest, current.lowerBound))
        }
        let now = Date.now
        if lower.addingTimeInterval(length) >= now {
            // Reached the present. Without a zoom, go back to the live view of the preset range.
            if zoomStack.isEmpty, let duration = range.duration, abs(duration - length) < 1 {
                customRange = nil
            } else if range == .all, zoomStack.isEmpty {
                customRange = nil
            } else {
                customRange = now.addingTimeInterval(-length)...now
            }
        } else {
            customRange = lower...lower.addingTimeInterval(length)
        }
        reload()
    }
}
