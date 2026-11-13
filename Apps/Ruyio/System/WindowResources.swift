import AppKit
import Darwin

/// Preserve small navigation values rather than a hidden hierarchy. Offsets are constrained when the
/// document size changes, and are only restored by the main controller for the same navigation route.
@MainActor
enum WindowScrollOffsets {
    static func capture(in root: NSView?) -> [NSPoint] { scrollViews(in: root).map { $0.contentView.bounds.origin } }

    static func restore(_ offsets: [NSPoint], in root: NSView?) {
        for (view, offset) in zip(scrollViews(in: root), offsets) {
            var bounds = view.contentView.bounds
            bounds.origin = offset
            view.contentView.scroll(to: view.contentView.constrainBoundsRect(bounds).origin)
            view.reflectScrolledClipView(view.contentView)
        }
    }

    private static func scrollViews(in root: NSView?) -> [NSScrollView] {
        guard let root else { return [] }
        return (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap { scrollViews(in: $0) }
    }
}

/// Closed windows must not keep SwiftUI trees, field editors or toolbar hosts alive in the menu-bar app.
@MainActor
enum WindowResources {
    static func release(_ window: NSWindow) {
        if let panel = window as? FloatingPanel {
            panel.onKeyDown = nil
            panel.onKeyEquivalent = nil
            panel.onResignKey = nil
        }
        window.makeFirstResponder(nil)
        window.toolbar = nil
        window.contentViewController = nil
        window.contentView = nil
        IdleMemoryReclaimer.schedule()
    }
}

/// One coalesced pass after windows close, not a repeating background timer. The allocator only returns
/// unused pages; live images, plugin state and visible windows are never discarded by this call.
@MainActor
enum IdleMemoryReclaimer {
    private static var pending: Task<Void, Never>?
    #if DEBUG
    private(set) static var completedPasses = 0
    #endif

    static func schedule() {
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            await Task.detached(priority: .utility) {
                _ = malloc_zone_pressure_relief(nil, 0)
            }.value
            #if DEBUG
            completedPasses += 1
            #endif
        }
    }
}
