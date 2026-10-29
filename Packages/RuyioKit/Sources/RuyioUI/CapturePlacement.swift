import CoreGraphics

/// Where a pinned capture goes: back over the region it was taken from. The system's interactive capture
/// returns only the image, so the region is worked out from what the host saw meanwhile.
public enum CapturePlacement {
    /// The capture's screen frame, in AppKit screen coordinates (origin at the bottom left), or nil when
    /// it cannot be told.
    ///
    /// - `start`, `end`: where the mouse went down and up during the capture.
    /// - `size`: the capture in points.
    /// - `windows`: on-screen window frames, front to back, in the same coordinates.
    public static func frame(start: CGPoint?, end: CGPoint?, size: CGSize, windows: [CGRect], tolerance: CGFloat = 3) -> CGRect? {
        func fits(_ rect: CGRect) -> Bool { abs(rect.width - size.width) <= tolerance && abs(rect.height - size.height) <= tolerance }
        if let start, let end, hypot(end.x - start.x, end.y - start.y) > 4 {
            // Anchored at the corner under the pointer when the selection ended, with the capture's exact size.
            // The release point is the precise one, and it stays the corner even when the selection was moved
            // while dragging (Space); the drag's direction tells which corner it is.
            let x = end.x >= start.x ? end.x - size.width : end.x
            let y = end.y >= start.y ? end.y - size.height : end.y
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
        // A click rather than a drag: a window capture. The frontmost window under it with the capture's size.
        if let point = end ?? start, let window = windows.first(where: { $0.contains(point) && fits($0) }) {
            return CGRect(origin: window.origin, size: size)
        }
        return nil
    }

    /// Converts a Core Graphics window rectangle (origin at the top left of the primary display, y down)
    /// to AppKit screen coordinates.
    public static func appKitRect(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
