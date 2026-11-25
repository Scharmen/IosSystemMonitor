//
//  MouseTrackingView.swift
//  SystemInfo
//

import AppKit
import SwiftUI

/// Reports mouse movement and drags over a view, in that view's own coordinates (origin top-left).
///
/// The charts use this instead of SwiftUI's `onContinuousHover` and `DragGesture`: AppKit converts the
/// mouse position into this view's coordinates itself, so the position can't be thrown off by what
/// surrounds the chart (sidebar, scroll view, toolbar).
struct MouseTrackingView: NSViewRepresentable {
    /// The mouse position, or `nil` once it leaves the view.
    var onMove: (CGPoint?) -> Void
    /// Called while dragging, with the point where the drag began and the current point.
    var onDrag: (CGPoint, CGPoint) -> Void = { _, _ in }
    var onDragEnd: () -> Void = {}

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: TrackingNSView, context: Context) {
        view.handlers = self
    }
}

final class TrackingNSView: NSView {
    var handlers: MouseTrackingView?
    private var dragStart: CGPoint?
    private var isDragging = false

    /// Drags shorter than this are treated as clicks.
    private static let minimumDragDistance: CGFloat = 4

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: SystemInfo is a menu bar app and often isn't the active app while its window is visible.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        handlers?.onMove(location(event))
    }

    override func mouseMoved(with event: NSEvent) {
        handlers?.onMove(location(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        handlers?.onMove(nil)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = location(event)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = location(event)
        if !isDragging, abs(current.x - dragStart.x) >= Self.minimumDragDistance {
            isDragging = true
        }
        if isDragging {
            handlers?.onDrag(dragStart, current)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            handlers?.onDragEnd()
        }
        dragStart = nil
        isDragging = false
        // The mouse may have left the view during the drag.
        handlers?.onMove(bounds.contains(location(event)) ? location(event) : nil)
    }
}
