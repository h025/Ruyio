import CoreGraphics
import Foundation

/// Where a pinned capture goes: back over the region it was taken from. The system's interactive capture
/// returns only the image, so the region is worked out from what the host saw meanwhile.
public enum CapturePlacement {
    /// One press of the mouse button during a capture.
    public struct Press: Sendable, Equatable {
        public var start: CGPoint
        public var end: CGPoint?
        public var endedAt: Date?

        public init(start: CGPoint, end: CGPoint? = nil, endedAt: Date? = nil) {
            self.start = start
            self.end = end
            self.endedAt = endedAt
        }
    }

    /// Adds a mouse-down (a new press) or mouse-up (ending the open one) to the presses seen so far.
    public static func record(_ presses: inout [Press], down: Bool, at point: CGPoint, time: Date) {
        if down {
            presses.append(Press(start: point))
        } else if let last = presses.indices.last, presses[last].end == nil {
            presses[last].end = point
            presses[last].endedAt = time
        }
    }

    /// The press that made the selection: the last one to end before the image was written. Clicks while
    /// the helper finishes come later, a stray click before the crosshair appeared comes earlier.
    public static func selection(in presses: [Press], writtenAt written: Date?) -> Press? {
        let ended = presses.filter { $0.end != nil }
        if let written, let press = ended.last(where: { ($0.endedAt ?? .distantFuture) <= written.addingTimeInterval(0.02) }) {
            return press
        }
        return ended.last
    }

    /// The capture's screen frame, in AppKit screen coordinates (origin at the bottom left), or nil when
    /// it cannot be told.
    ///
    /// - `start`, `end`: where the mouse went down and up during the capture.
    /// - `size`: the capture in points.
    /// - `windows`: on-screen window frames, front to back, in the same coordinates.
    /// - `screen`: the frame of the display the selection began on.
    ///
    /// A selection moved back past its starting point while dragging (Space) or with an edge locked (Shift)
    /// ends with the pointer off the corner this assumes; such pins land offset by the selection's size.
    public static func frame(start: CGPoint?, end: CGPoint?, size: CGSize, windows: [CGRect], screen: CGRect? = nil,
                             tolerance: CGFloat = 3) -> CGRect? {
        func fits(_ rect: CGRect) -> Bool { abs(rect.width - size.width) <= tolerance && abs(rect.height - size.height) <= tolerance }
        let moved = start.flatMap { start in end.map { hypot($0.x - start.x, $0.y - start.y) } } ?? 0
        // A click on a window of the capture's size: a window capture. A trackpad click can wobble a few points.
        if moved < 12, let point = end ?? start, let window = windows.first(where: { $0.contains(point) && fits($0) }) {
            return CGRect(origin: window.origin, size: size)
        }
        guard let start, let end, moved > 4 else { return nil }
        // Anchored at the corner under the pointer when the selection ended, with the capture's exact size.
        // The release point is the precise one, and it stays the corner even when the selection was moved
        // while dragging (Space); the drag's direction tells which corner it is.
        var x = end.x >= start.x ? end.x - size.width : end.x
        var y = end.y >= start.y ? end.y - size.height : end.y
        // The selection stays on the display it began on, though the pointer may go on to the next one.
        if let screen, size.width <= screen.width, size.height <= screen.height {
            x = min(max(x, screen.minX), screen.maxX - size.width)
            y = min(max(y, screen.minY), screen.maxY - size.height)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Converts a Core Graphics window rectangle (origin at the top left of the primary display, y down)
    /// to AppKit screen coordinates.
    public static func appKitRect(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
