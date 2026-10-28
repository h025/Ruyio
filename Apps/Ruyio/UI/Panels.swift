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
        // While an input method is composing (pinyin, kana…), Return, Esc and arrows belong to it.
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
        if event.type == .keyDown, !composing, let handler = onKeyDown, handler(event) { return }
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
        // Letter shortcuts follow the active layout (⌘Z is Z on QWERTZ too); named keys use key codes.
        if flags == [.command], let letter = event.charactersIgnoringModifiers?.lowercased() {
            switch letter {
            case "y": self = .commandY; return
            case "d": self = .commandD; return
            case "z": self = .commandZ; return
            default: break
            }
        }
        switch (event.keyCode, flags) {
        case (126, []): self = .up
        case (125, []): self = .down
        case (36, []), (76, []): self = .enter
        case (36, [.option]), (76, [.option]): self = .optionEnter
        case (36, [.command]), (76, [.command]): self = .commandEnter
        case (53, []): self = .escape
        case (51, [.command]): self = .commandDelete
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
    private var subscription: UUID?
    private var pendingDocument: ViewDocument?
    private var pendingSubmission: [String: JSONValue]?
    private var presentationID = UUID()
    private var lifecycleTask: Task<Void, Never>?
    weak var palette: CommandPaletteController?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(pluginID: PluginID, viewID: String) {
        if isVisible, current?.0 == pluginID, current?.1 == viewID { close(); return }
        open(pluginID: pluginID, viewID: viewID)
    }

    func open(pluginID: PluginID, viewID: String) {
        palette?.close()
        close()
        PasteService.shared.rememberFrontmostApp()
        let ticket = presentationID
        let previous = lifecycleTask
        lifecycleTask = Task {
            await previous?.value
            guard presentationID == ticket else { return }
            observeUpdates(pluginID: pluginID, viewID: viewID, ticket: ticket)
            do {
                let document = try await model.engine.openView(pluginID: pluginID, viewID: viewID)
                guard presentationID == ticket else {
                    await model.engine.closeView(pluginID: pluginID, viewID: viewID)
                    return
                }
                present(document: document, pluginID: pluginID)
            } catch let error as RuyioError {
                guard presentationID == ticket else { return }
                clearSubscription()
                model.show(model.l.errorText(error))
            } catch {
                guard presentationID == ticket else { return }
                clearSubscription()
                model.show(error.localizedDescription)
            }
        }
    }

    fileprivate func present(document: ViewDocument, pluginID: PluginID) {
        let l = model.l
        let engine = model.engine
        let ticket = presentationID
        let context = SchemaContext(
            pluginID: pluginID, document: document,
            strings: SchemaStrings(submit: l.done, cancel: l.cancel, undo: l.t("撤销", "Undo"), loading: l.t("正在加载…", "Loading…"), choose: "…",
                                   preview: l.t("预览", "Preview"), moreActions: l.t("更多操作", "More Actions")),
            sendEvent: { [weak self] event, revision in await self?.send(event, revision: revision, ticket: ticket) },
            loadBlob: { blobID in await Self.loadBlob(engine: engine, pluginID: pluginID, blobID: blobID) })
        context.dismiss = { [weak self] in if self?.presentationID == ticket { self?.close() } }
        if let summary = model.summary(pluginID), !summary.isDefault {
            context.source = l.fromPlugin(summary.displayName) + (summary.teamID.map { " · Team \($0)" } ?? "")
        }
        self.context = context
        current = (pluginID, document.viewID)
        if subscription == nil { observeUpdates(pluginID: pluginID, viewID: document.viewID, ticket: ticket) }
        if let pendingDocument { context.apply(pendingDocument); self.pendingDocument = nil }
        let panel = FloatingPanel(size: NSSize(width: 780, height: 520), minSize: NSSize(width: 640, height: 420), resizable: true)
        panel.contentView = NSHostingView(rootView: OverlayRoot(context: context).environment(\.locale, Locale(identifier: model.language)))
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in
            // Clicking outside closes the overlay unless a confirmation or system sheet is up.
            Task { @MainActor in
                guard let self, self.presentationID == ticket, NSApp.modalWindow == nil else { return }
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
        presentationID = UUID()
        clearSubscription()
        panel?.orderOut(nil)
        let current = current
        self.panel = nil
        self.context = nil
        self.current = nil
        if let current {
            let previous = lifecycleTask
            lifecycleTask = Task {
                await previous?.value
                await model.engine.closeView(pluginID: current.0, viewID: current.1)
            }
        }
    }

    private func clearSubscription() {
        if let subscription { model.viewUpdates.remove(subscription) }
        subscription = nil
        pendingDocument = nil
        pendingSubmission = nil
    }

    private func observeUpdates(pluginID: PluginID, viewID: String, ticket: UUID) {
        subscription = model.viewUpdates.observe(pluginID: pluginID, viewID: viewID) { [weak self] document in
            Task { @MainActor in
                guard let self, self.presentationID == ticket else { return }
                if let context = self.context { context.apply(document) }
                else if document.revision >= (self.pendingDocument?.revision ?? Int.min) { self.pendingDocument = document }
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let context else { return false }
        if context.collection == nil {
            if KeyCommand(event) == .escape { close(); return true }
            return false
        }
        switch KeyCommand(event) {
        case .up, .down:
            context.moveSelection(KeyCommand(event) == .up ? -1 : 1)
            // Selection changes are announced while focus stays in the search field (R31 / interaction §19).
            if let title = context.collection?.list.items.first(where: { $0.id == context.localSelection }).map({ $0.accessibilityLabel ?? $0.title }) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            return true
        case .escape:
            if context.compactPreviewVisible { context.compactPreviewVisible = false; return true }
            // First Escape clears the search, the second closes (PRD §19.15).
            if let search = context.collection?.searchText, !search.isEmpty {
                context.send(.searchChanged(""))
                NotificationCenter.default.post(name: .ruyioClearSearch, object: nil)
            } else {
                close()
            }
            return true
        default: break
        }
        // Plugin shortcuts need a modifier (Return aside): a bare letter, Space or ⌫ always edits the search.
        if let shortcut = HotkeyManager.shortcut(from: event), shortcut.key == "return" || !shortcut.modifiers.subtracting(.shift).isEmpty,
           let action = context.invocation(shortcut: shortcut) {
            context.send(action)
            return true
        }
        switch KeyCommand(event) {
        case .enter:
            if let action = context.invocation() { context.send(action); return true }
        case .commandY:
            if context.collection?.preview != nil {
                if (panel?.contentView?.bounds.width ?? 780) < 700 { context.compactPreviewVisible.toggle() }
                else { context.previewVisible.toggle() }
                return true
            }
        case .commandZ:
            if let undo = context.collection?.undo, undo.expiresAt > Date() { context.send(.undo(token: undo.token)); return true }
        default: break
        }
        return false
    }

    private func send(_ event: ViewEvent, revision: Int, ticket: UUID) async {
        guard presentationID == ticket, let (pluginID, viewID) = current else { return }
        if case .invoke(let action, _) = event, action.hasPrefix("host.") {
            if action == "host.open-privacy-settings" { SystemSettings.openPasteboardPrivacy() }
            return
        }
        if case .submit(let values) = event { pendingSubmission = values }
        do {
            let reply = try await model.engine.viewEvent(pluginID: pluginID, viewID: viewID, revision: revision, event: event)
            guard presentationID == ticket else { return }
            if let document = reply.document { context?.apply(document) }
            // A saved form (directly or after its confirmation) adopts the plugin's normalized values.
            switch reply.effect {
            case .none, .notice, .close:
                if let values = pendingSubmission {
                    context?.acknowledgeSubmission(values, document: reply.document)
                    pendingSubmission = nil
                }
            default: break
            }
            // Only a deliberate invoke (Return, click, menu) may close the panel and paste; a reply to
            // typing or selection can never send keystrokes to another app.
            var userInvoked = false
            if case .invoke = event { userInvoked = true }
            await handle(reply.effect, pluginID: pluginID, userInvoked: userInvoked, ticket: ticket)
        } catch let error as RuyioError {
            guard presentationID == ticket else { return }
            model.show(model.l.errorText(error))
        } catch {
            guard presentationID == ticket else { return }
            model.show(error.localizedDescription)
        }
    }

    private func handle(_ effect: ViewEffect, pluginID: PluginID, userInvoked: Bool, ticket: UUID) async {
        switch effect {
        case .none: break
        case .close: close()
        case .notice(let text): model.show(text)
        case .confirm(let spec):
            guard userInvoked else { return }
            let alert = NSAlert()
            alert.messageText = spec.title
            // Host-drawn provenance: a plugin can never pose as Ruyio or macOS (plan §9 source bar).
            alert.informativeText = model.l.fromPlugin(model.summary(pluginID)?.displayName ?? pluginID.rawValue) + "\n\n" + spec.message
            // The safe action keeps default focus; destructive buttons are never default (PRD §18.3).
            alert.addButton(withTitle: model.l.cancel)
            let confirm = alert.addButton(withTitle: spec.confirmTitle)
            confirm.hasDestructiveAction = spec.isDestructive
            if alert.runModal() == .alertSecondButtonReturn {
                await send(.invoke(actionID: spec.confirmActionID, itemID: nil), revision: context?.document.revision ?? 0, ticket: ticket)
            }
        case .closeAndPaste(_, let autoPaste):
            guard userInvoked else { return }
            close()
            if PasteService.shared.deliverInApp() { return }
            // Synthesized ⌘V requires the plugin to declare paste.automatic (PRD §10.2); otherwise copy only.
            let declared = model.summary(pluginID)?.manifest.permissions.contains(.pasteAutomatic) == true
            var wantsAuto = autoPaste && declared
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
    func setCompactPreviewForGallery(_ visible: Bool) { context?.compactPreviewVisible = visible }
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
        VStack(alignment: .leading, spacing: 0) {
            // Collections draw the source line in their own header; other views get it on top.
            if let source = context.source, context.collection == nil {
                Label(source, systemImage: "puzzlepiece.extension").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 14)
            }
            SchemaNodeView(node: context.document.root, context: context)
        }
        .keyWindowControls()
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
