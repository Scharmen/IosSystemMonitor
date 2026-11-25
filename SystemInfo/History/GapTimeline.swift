//
//  GapTimeline.swift
//  SystemInfo
//

import Foundation

/// Squeezes out the stretches without data (Mac asleep or shut down) so charts only show recorded time.
/// Each removed stretch stays visible as a narrow band, so it's clear where the gaps were.
nonisolated struct GapTimeline: Sendable {
    struct Span: Sendable {
        let start: Date
        let end: Date
        /// Where this span starts on the squeezed time axis, in seconds from `origin`.
        let offset: TimeInterval
        var length: TimeInterval { end.timeIntervalSince(start) }
    }

    let spans: [Span]
    /// Width of the band standing in for each removed gap, in seconds on the squeezed axis.
    let gapWidth: TimeInterval
    let origin: Date

    /// Builds the timeline from chart points; returns `nil` without data. Gaps shorter than `minimumGap` are kept.
    init?(points: [HistoryPoint], pointDuration: TimeInterval, minimumGap: TimeInterval = 600) {
        guard let first = points.first else { return nil }
        let threshold = max(3 * pointDuration, minimumGap)

        var ranges: [(start: Date, end: Date)] = []
        var start = first.date
        var last = first.date
        for point in points.dropFirst() {
            if point.date.timeIntervalSince(last) > threshold {
                ranges.append((start, last.addingTimeInterval(pointDuration)))
                start = point.date
            }
            last = point.date
        }
        ranges.append((start, last.addingTimeInterval(pointDuration)))

        // Never let a span run into the next one.
        let ends = ranges.indices.map { index in
            index + 1 < ranges.count ? min(ranges[index].end, ranges[index + 1].start) : ranges[index].end
        }
        let total = zip(ranges, ends).reduce(0) { $0 + $1.1.timeIntervalSince($1.0.start) }
        let width = max(total * 0.015, 1)

        var offset = 0.0
        var spans: [Span] = []
        for (range, end) in zip(ranges, ends) {
            spans.append(Span(start: range.start, end: end, offset: offset))
            offset += end.timeIntervalSince(range.start) + width
        }
        self.spans = spans
        self.gapWidth = width
        self.origin = first.date
    }

    var isCollapsed: Bool { spans.count > 1 }

    var virtualDomain: ClosedRange<Date> {
        let last = spans[spans.count - 1]
        return origin...max(origin.addingTimeInterval(last.offset + last.length), origin.addingTimeInterval(1))
    }

    /// The position of a real date on the squeezed axis; dates inside a gap land inside that gap's band.
    func virtual(_ date: Date) -> Date {
        guard date > spans[0].start else { return origin }
        for (index, span) in spans.enumerated() {
            if date <= span.end {
                if date >= span.start {
                    return origin.addingTimeInterval(span.offset + date.timeIntervalSince(span.start))
                }
                let previous = spans[index - 1]
                let gapLength = max(span.start.timeIntervalSince(previous.end), 1)
                let fraction = date.timeIntervalSince(previous.end) / gapLength
                return origin.addingTimeInterval(previous.offset + previous.length + gapWidth * fraction)
            }
        }
        return virtualDomain.upperBound
    }

    /// The real date for a position on the squeezed axis.
    func real(_ virtual: Date) -> Date {
        let t = virtual.timeIntervalSince(origin)
        guard t > 0 else { return spans[0].start }
        for (index, span) in spans.enumerated() {
            if t <= span.offset + span.length {
                return span.start.addingTimeInterval(max(t - span.offset, 0))
            }
            if index + 1 < spans.count, t < spans[index + 1].offset {
                let next = spans[index + 1]
                let fraction = (t - (span.offset + span.length)) / gapWidth
                return span.end.addingTimeInterval(fraction * next.start.timeIntervalSince(span.end))
            }
        }
        return spans[spans.count - 1].end
    }

    /// The bands that stand in for removed gaps, on the squeezed axis.
    var gapBands: [ClosedRange<Date>] {
        spans.dropFirst().map { span in
            let begin = origin.addingTimeInterval(span.offset - gapWidth)
            return begin...origin.addingTimeInterval(span.offset)
        }
    }

    /// Axis tick positions: the start of up to five spans, spread evenly.
    /// Ticks too close to the previous one are left out, so their labels don't overlap.
    var tickDates: [Date] {
        let count = min(spans.count, 5)
        guard count > 0, let last = spans.last else { return [] }
        let minimumDistance = (last.offset + last.length) * 0.16
        var offsets: [TimeInterval] = []
        for step in 0..<count {
            let index = count == 1 ? 0 : step * (spans.count - 1) / (count - 1)
            let offset = spans[index].offset
            if let previous = offsets.last, offset - previous < minimumDistance { continue }
            offsets.append(offset)
        }
        return offsets.map(origin.addingTimeInterval)
    }
}
