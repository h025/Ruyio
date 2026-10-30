import AppKit
import RuyioUI
import SwiftUI

/// A companion to the history panel. It does not activate Ruyio or replace the remembered paste target.
@MainActor
final class ExpandedPreviewController: NSObject, NSWindowDelegate {
    private(set) var window: FloatingPanel?
    private weak var sourceWindow: NSWindow?
    private var content: ExpandedPreviewContent?
    var onClose: (() -> Void)?
    var onResignKey: (() -> Void)?

    func show(_ content: ExpandedPreviewContent, context: SchemaContext, source: NSWindow,
              locale: String, saveFrame: Bool = true) {
        let panel = window ?? FloatingPanel(size: NSSize(width: 1000, height: 720), minSize: NSSize(width: 600, height: 420), resizable: true)
        if window == nil {
            panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.isMovableByWindowBackground = false
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
            panel.minSize = NSSize(width: 600, height: 420)
            panel.delegate = self
            panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
            panel.onKeyEquivalent = { [weak self] event in self?.handleKey(event) ?? false }
            panel.onResignKey = { [weak self] in self?.onResignKey?() }
            if let visible = source.screen?.visibleFrame {
                let size = NSSize(width: min(1000, visible.width - 64), height: min(720, visible.height - 64))
                panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                      width: size.width, height: size.height), display: false)
            }
            if saveFrame {
                panel.setFrameAutosaveName("RuyioExpandedPreview")
                _ = panel.setFrameUsingName("RuyioExpandedPreview")
            }
            window = panel
        }
        self.content = content
        sourceWindow = source
        panel.appearance = source.effectiveAppearance
        switch content {
        case .json: panel.title = "JSON · " + context.strings.preview
        case .image: panel.title = context.strings.preview
        }
        panel.contentView = NSHostingView(rootView: ExpandedPreviewView(content: content, strings: context.strings,
                                                                       loadImage: { [weak context] id in await context?.previewImage(id) })
            .environment(\.locale, Locale(identifier: locale)))
        if panel.parent !== source {
            panel.parent?.removeChildWindow(panel)
            source.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close(returnFocus: Bool = true) {
        guard let panel = window else { return }
        window = nil
        content = nil
        panel.delegate = nil
        sourceWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        if returnFocus, sourceWindow?.isVisible == true { sourceWindow?.makeKeyAndOrderFront(nil) }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "f", case .json? = content {
            NativeSearchField.requestFocus(ExpandedPreviewView.searchIdentifier)
            return true
        }
        if flags.isEmpty, event.keyCode == 53 {
            // The first Escape clears a JSON query; once empty, Escape returns to the history panel.
            if let editor = window?.firstResponder as? NSTextView,
               let field = editor.delegate as? NSTextField,
               field.identifier?.rawValue == ExpandedPreviewView.searchIdentifier, !field.stringValue.isEmpty { return false }
            close()
            return true
        }
        return false
    }
}
