import AppKit
import RuyioCore
import RuyioHostKit
import RuyioProtocol
import RuyioUI
import SwiftUI

/// Non-activating floating panel: the previous app stays frontmost, full-screen Spaces are not
/// switched (plan §12.3). Keyboard commands are intercepted before the search field sees them.
final class FloatingPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(size: NSSize, minSize: NSSize, resizable: Bool) {
        // Borderless and transparent: the SwiftUI root draws the glass shape, as Spotlight and Maps panels do.
        var style: NSWindow.StyleMask = [.nonactivatingPanel, .borderless]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        self.minSize = minSize
        animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler = onKeyDown, handler(event) { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Centered on the screen under the mouse (interaction §3).
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return center() }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + visible.height * 0.08))
    }
}

enum KeyCommand: Equatable {
    case up, down, enter, optionEnter, commandEnter, escape, commandY, commandD, commandDelete, commandZ, other

    init(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (126, []): self = .up
        case (125, []): self = .down
        case (36, []), (76, []): self = .enter
        case (36, [.option]), (76, [.option]): self = .optionEnter
        case (36, [.command]), (76, [.command]): self = .commandEnter
        case (53, []): self = .escape
        case (16, [.command]): self = .commandY
        case (2, [.command]): self = .commandD
        case (51, [.command]): self = .commandDelete
        case (6, [.command]): self = .commandZ
        default: self = .other
        }
    }
}

// MARK: - HUD

/// Non-focus-stealing feedback for background entries (R31 / interaction §16); announced to VoiceOver.
@MainActor
final class HUD {
    static let shared = HUD()
    fileprivate var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, duration: Double = 2.5) {
        hideTask?.cancel()
        let label = NSHostingView(rootView: Text(text).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .frame(maxWidth: 440)
            .ruyioGlass(in: Capsule())
            .padding(10))
        let size = label.fittingSize
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return p
        }()
        panel.contentView = label
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

// MARK: - Plugin view overlay (clipboard history)

@MainActor
final class OverlayController {
    private let model: AppModel
    fileprivate var panel: FloatingPanel?
    private var context: SchemaContext?
    private var current: (PluginID, String)?
    weak var palette: CommandPaletteController?

    init(model: AppModel) {
        self.model = model
        model.engine.onViewUpdate { [weak self] pluginID, document in
            Task { @MainActor in
                guard let self, let current = self.current, current.0 == pluginID, current.1 == document.viewID else { return }
                self.context?.apply(document)
            }
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(pluginID: PluginID, viewID: String) {
        if isVisible, current?.0 == pluginID, current?.1 == viewID { close(); return }
        open(pluginID: pluginID, viewID: viewID)
    }

    func open(pluginID: PluginID, viewID: String) {
        palette?.close()
        if isVisible { close() }
        PasteService.shared.rememberFrontmostApp()
        Task {
            do {
                let document = try await model.engine.openView(pluginID: pluginID, viewID: viewID)
                present(document: document, pluginID: pluginID)
            } catch let error as RuyioError {
                model.show(model.l.errorText(error))
            } catch {
                model.show(error.localizedDescription)
            }
        }
    }

    fileprivate func present(document: ViewDocument, pluginID: PluginID) {
        let l = model.l
        let engine = model.engine
        let context = SchemaContext(
            pluginID: pluginID, document: document,
            strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: l.t("撤销", "Undo"), loading: l.t("正在加载…", "Loading…"), choose: "…"),
            sendEvent: { [weak self] event, revision in await self?.send(event, revision: revision) },
            loadBlob: { blobID in await Self.loadBlob(engine: engine, pluginID: pluginID, blobID: blobID) })
        context.dismiss = { [weak self] in self?.close() }
        self.context = context
        current = (pluginID, document.viewID)
        let panel = FloatingPanel(size: NSSize(width: 780, height: 520), minSize: NSSize(width: 640, height: 420), resizable: true)
        panel.contentView = NSHostingView(rootView: OverlayRoot(context: context).environment(\.locale, Locale(identifier: model.language)))
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in
            // Clicking outside closes the overlay unless a confirmation or system sheet is up.
            Task { @MainActor in
                guard let self, NSApp.modalWindow == nil else { return }
                if NSApp.keyWindow !== self.panel { self.close() }
            }
        }
        panel.setFrameAutosaveName("RuyioOverlay.\(document.viewID)")
        panel.centerOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    static func loadBlob(engine: HostEngine, pluginID: PluginID, blobID: String) async -> NSImage? {
        guard let record = await engine.registry.record(pluginID),
              let store = try? engine.services.stores.store(pluginID: pluginID, generation: record.dataGeneration, development: record.isDevelopment),
              let data = try? store.blobData(blobID, maxBytes: 8 << 20) else { return nil }
        // Decoding happens in the sandboxed media decoder service, never in the host (R43).
        return await MediaDecoderClient.shared.image(from: data)
    }

    func close() {
        guard let panel, let current else { return }
        panel.orderOut(nil)
        self.panel = nil
        self.context = nil
        self.current = nil
        Task { await model.engine.closeView(pluginID: current.0, viewID: current.1) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let context else { return false }
        let selection = context.localSelection
        switch KeyCommand(event) {
        case .up, .down:
            context.moveSelection(KeyCommand(event) == .up ? -1 : 1)
            // Selection changes are announced while focus stays in the search field (R31 / interaction §19).
            if let title = context.collection?.list.items.first(where: { $0.id == context.localSelection }).map({ $0.accessibilityLabel ?? $0.title }) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            return true
        case .enter: context.send(.invoke(actionID: "paste", itemID: selection)); return true
        case .optionEnter: context.send(.invoke(actionID: "paste-plain", itemID: selection)); return true
        case .commandEnter: context.send(.invoke(actionID: "copy-only", itemID: selection)); return true
        case .commandY: context.previewVisible.toggle(); return true
        case .commandD: context.send(.invoke(actionID: "favorite", itemID: selection)); return true
        case .commandDelete: context.send(.invoke(actionID: "delete", itemID: selection)); return true
        case .commandZ:
            if let token = context.collection?.undo?.token { context.send(.undo(token: token)); return true }
            return false
        case .escape:
            // First Escape clears the search, the second closes (PRD §19.15).
            if let search = context.collection?.searchText, !search.isEmpty {
                context.send(.searchChanged(""))
                NotificationCenter.default.post(name: .ruyioClearSearch, object: nil)
            } else {
                close()
            }
            return true
        case .other:
            return false
        }
    }

    private func send(_ event: ViewEvent, revision: Int) async {
        guard let (pluginID, viewID) = current else { return }
        if case .invoke(let action, _) = event, action.hasPrefix("host.") {
            if action == "host.open-privacy-settings" { SystemSettings.openPasteboardPrivacy() }
            return
        }
        do {
            let reply = try await model.engine.viewEvent(pluginID: pluginID, viewID: viewID, revision: revision, event: event)
            if let document = reply.document { context?.apply(document) }
            await handle(reply.effect)
        } catch let error as RuyioError {
            model.show(model.l.errorText(error))
        } catch {
            model.show(error.localizedDescription)
        }
    }

    private func handle(_ effect: ViewEffect) async {
        switch effect {
        case .none: break
        case .close: close()
        case .notice(let text): model.show(text)
        case .confirm(let spec):
            let alert = NSAlert()
            alert.messageText = spec.title
            alert.informativeText = spec.message
            // The safe action keeps default focus; destructive buttons are never default (PRD §18.3).
            alert.addButton(withTitle: model.l.cancel)
            let confirm = alert.addButton(withTitle: spec.confirmTitle)
            confirm.hasDestructiveAction = spec.isDestructive
            if alert.runModal() == .alertSecondButtonReturn {
                await send(.invoke(actionID: spec.confirmActionID, itemID: nil), revision: context?.document.revision ?? 0)
            }
        case .closeAndPaste(_, let autoPaste):
            close()
            if PasteService.shared.deliverInApp() { return }
            var wantsAuto = autoPaste
            if wantsAuto && !AXIsProcessTrusted() {
                wantsAuto = PasteService.shared.requestAccessibilityIfAppropriate(model: model)
            }
            let outcome = await PasteService.shared.pasteIntoPreviousApp(autoPaste: wantsAuto)
            if case .copiedOnly = outcome { model.show(model.l.copiedPasteManually) }
        }
    }
}

#if DEBUG
extension OverlayController {
    func presentForGallery(document: ViewDocument, pluginID: PluginID) { present(document: document, pluginID: pluginID) }
    var galleryWindow: NSWindow? { panel }
}

extension HUD {
    var galleryWindow: NSWindow? { panel }
}
#endif

extension Notification.Name {
    static let ruyioClearSearch = Notification.Name("app.ruyio.clearSearch")
}

struct OverlayRoot: View {
    @ObservedObject var context: SchemaContext
    var body: some View {
        SchemaNodeView(node: context.document.root, context: context)
            .frame(minWidth: 640, minHeight: 420)
            .ruyioGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .ignoresSafeArea()
    }
}

// MARK: - File conflict sheet (PRD §19.19)

final class ConflictResolver: FileBrokerDelegate, @unchecked Sendable {
    weak var model: AppModel?

    func resolveConflict(_ info: ConflictInfo) async -> ConflictResolution {
        await MainActor.run {
            let l = model?.l ?? L10n("en")
            let alert = NSAlert()
            alert.messageText = l.conflictTitle(info.fileName)
            var lines: [String] = []
            if let size = info.existingSize {
                let date = info.existingModified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
                lines.append("\(l.existingFile)  \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(date)")
            }
            if let size = info.newSize { lines.append("\(l.newFile)  \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: l.keepBoth)
            alert.addButton(withTitle: l.skipItem)
            let replace = alert.addButton(withTitle: l.replaceItem)
            replace.hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: l.cancel)
            cancel.keyEquivalent = "\u{1b}"
            if info.remainingCount > 0 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = l.applyToRemaining(info.remainingCount)
            }
            NSApp.activate()
            let response = alert.runModal()
            let all = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn: return ConflictResolution(.keepBoth, applyToAll: all)
            case .alertSecondButtonReturn: return ConflictResolution(.skip, applyToAll: all)
            case .alertThirdButtonReturn: return ConflictResolution(.replace, applyToAll: all)
            default: return ConflictResolution(.cancel)
            }
        }
    }
}
