import AppKit

/// Only document-style windows opt into Dock presence. Transient panels leave the paste target active.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private let windows = NSHashTable<NSWindow>.weakObjects()

    func show(_ window: NSWindow) {
        windows.add(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ window: NSWindow) {
        windows.remove(window)
        // Finish AppKit's close first. A window opened in the meantime keeps the app in the Dock.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windows.allObjects.isEmpty,
                  NSApp.activationPolicy() == .regular else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
