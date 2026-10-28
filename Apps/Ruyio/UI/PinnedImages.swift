import AppKit
import UniformTypeIdentifiers

/// Pinned images for plugins with `windows.pin`: host-drawn panels above other apps that only ever show a
/// bitmap decoded out of process, so a plugin cannot use them to draw its own UI. Hovering names the
/// plugin. Interaction follows Snipaste-style pins: drag to move, scroll or pinch to zoom. A pin stays until
/// the user closes it with its close button or menu; Escape never closes it, and a new pin does not take
/// keyboard focus from the app in front.
@MainActor
final class PinnedImages {
    static let shared = PinnedImages()
    static let limit = 32
    private var panels: [PinPanel] = []

    func pin(_ image: NSImage, scale: Double, pluginName: String, l: L10n) {
        if panels.count >= Self.limit { panels.first?.close() }
        let size = NSSize(width: max(8, image.size.width / scale), height: max(8, image.size.height / scale))
        let panel = PinPanel(image: image, pointSize: size, pluginName: pluginName, l: l)
        panel.onClose = { [weak self, weak panel] in self?.panels.removeAll { $0 === panel } }
        panel.onCloseAll = { [weak self] in self?.closeAll() }
        panel.setFrameOrigin(Self.origin(for: size))
        panels.append(panel)
        panel.orderFrontRegardless()
    }

    func closeAll() {
        for panel in panels { panel.close() }
    }

    /// Centred on the pointer, where the selection just ended, and kept on that screen.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        return origin
    }
}

final class PinPanel: NSPanel {
    var onClose: (() -> Void)?
    var onCloseAll: (() -> Void)?
    private let image: NSImage
    private let baseSize: NSSize
    private let l: L10n
    private var zoom: CGFloat = 1

    init(image: NSImage, pointSize: NSSize, pluginName: String, l: L10n) {
        self.image = image
        self.baseSize = pointSize
        self.l = l
        super.init(contentRect: NSRect(origin: .zero, size: pointSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        title = l.pinTitle(pluginName)

        let view = PinContentView(frame: NSRect(origin: .zero, size: pointSize), image: image, l: l)
        view.toolTip = l.pinTooltip(pluginName)
        view.setAccessibilityLabel(l.pinTitle(pluginName))
        view.menu = makeMenu()
        view.closeButton.target = self
        view.closeButton.action = #selector(closeFromMenu(_:))
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    /// Escape must not close a pin.
    override func cancelOperation(_ sender: Any?) {}

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case "c": copyImage(nil)
        case "s": saveImage(nil)
        case "0": actualSize(nil)
        case "=", "+": zoomIn(nil)
        case "-": zoomOut(nil)
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        setZoom(zoom * (1 + delta), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    /// Keeps the point under the pointer fixed while resizing.
    private func setZoom(_ value: CGFloat, anchor: NSPoint) {
        let next = min(max(value, 0.1), 8)
        let old = frame
        let size = NSSize(width: baseSize.width * next, height: baseSize.height * next)
        guard size.width >= 8, size.height >= 8 else { return }
        let fx = old.width > 0 ? (anchor.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (anchor.y - old.minY) / old.height : 0.5
        let origin = NSPoint(x: anchor.x - fx * size.width, y: anchor.y - fy * size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        zoom = next
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        menu.addItem(item(l.copy, #selector(copyImage(_:)), "c"))
        menu.addItem(item(l.saveAs, #selector(saveImage(_:)), "s"))
        menu.addItem(.separator())
        menu.addItem(item(l.actualSize, #selector(actualSize(_:)), "0"))
        menu.addItem(item(l.zoomIn, #selector(zoomIn(_:)), "="))
        menu.addItem(item(l.zoomOut, #selector(zoomOut(_:)), "-"))
        let opacity = NSMenuItem(title: l.opacity, action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for percent in [100, 80, 60, 40] {
            let level = item("\(percent)%", #selector(setOpacity(_:)))
            level.tag = percent
            levels.addItem(level)
        }
        opacity.submenu = levels
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(item(l.close, #selector(closeFromMenu(_:))))
        menu.addItem(item(l.closeAllPins, #selector(closeAllFromMenu(_:))))
        return menu
    }

    @objc private func copyImage(_ sender: Any?) {
        guard let png = pngData() else { return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @objc private func saveImage(_ sender: Any?) {
        guard let png = pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(l.screenshotFileName) \(formatter.string(from: Date())).png"
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url, options: .atomic)
        }
    }

    @objc private func actualSize(_ sender: Any?) { setZoom(1, anchor: NSPoint(x: frame.midX, y: frame.midY)) }
    @objc private func zoomIn(_ sender: Any?) { setZoom(zoom * 1.25, anchor: NSPoint(x: frame.midX, y: frame.midY)) }
    @objc private func zoomOut(_ sender: Any?) { setZoom(zoom / 1.25, anchor: NSPoint(x: frame.midX, y: frame.midY)) }
    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closeFromMenu(_ sender: Any?) { close() }
    @objc private func closeAllFromMenu(_ sender: Any?) { onCloseAll?() }

    private func pngData() -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// Draws the image, moves the window on drag and reveals a native close button on hover (the way
/// Picture in Picture and notifications do), so the close control never covers the capture otherwise.
private final class PinContentView: NSView {
    let closeButton: NSButton
    private let cgImage: CGImage?
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: NSImage, l: L10n) {
        cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: l.close) ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)

        if #available(macOS 26.0, *) {
            closeButton.bezelStyle = .glass
        } else {
            closeButton.bezelStyle = .circular
        }
        closeButton.controlSize = .small
        closeButton.toolTip = l.close
        closeButton.setAccessibilityLabel(l.close)
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = cgImage
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.separatorColor.cgColor
    }

    override var mouseDownCanMoveWindow: Bool { true }

    /// The whole image is a drag handle; the close button takes its own clicks, and Control-click still
    /// opens the menu.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setCloseButtonVisible(true) }
    override func mouseExited(with event: NSEvent) { setCloseButtonVisible(false) }

    private func setCloseButtonVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            closeButton.animator().alphaValue = visible ? 1 : 0
        }
    }
}
