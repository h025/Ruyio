import AppKit
import SwiftUI

// Liquid Glass on macOS 26+ with material fallbacks on macOS 14 and 15, so callers stay free of availability checks.
// Glass is for the floating control layer (panels, bars, buttons); content sits on quiet cards (HIG Materials).

public extension View {
    @ViewBuilder
    func ruyioGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func ruyioGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Grouped-row card for content placed on glass (Maps-style inset groups).
    func ruyioCard(radius: CGFloat = 16) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

/// Lets neighbouring glass shapes blend and morph together on macOS 26+.
public struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.6))
        )
    }
}

/// Shortcut keycap used in hint bars; symbols are never translated (plan §17.1).
public struct KeyCap: View {
    let text: String
    var inverted = false

    public init(_ text: String, inverted: Bool = false) {
        self.text = text
        self.inverted = inverted
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(inverted ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// White symbol on a coloured circle, as in Maps and Reminders rows.
public struct SymbolBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat

    public init(_ symbol: String, color: Color, size: CGFloat = 28) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }

    /// Stable colours for the content kinds plugins use most.
    public static func color(for symbol: String) -> Color {
        switch symbol {
        case "link": return .teal
        case "photo": return .purple
        case "doc", "folder": return .orange
        case "doc.richtext": return .indigo
        case "star", "star.fill": return .yellow
        default: return .blue
        }
    }
}

/// AppKit's own search field (magnifier, clear button, Liquid Glass styling) for SwiftUI. The panel's main
/// field takes focus when it joins a window, since floating panels open straight into typing. A field
/// inside a preview (`previewIdentifier`) waits to be clicked or asked for (⌘F), handles its own Return,
/// arrows and Escape, and hands focus back to the main field on Escape when empty.
public struct NativeSearchField: NSViewRepresentable {
    public enum Command { case next, previous }
    public static let previewIdentifier = "app.ruyio.search.preview"
    public static let primaryIdentifier = "app.ruyio.search.primary"
    /// Posted with a field identifier as the object: that field takes keyboard focus.
    public static let focusRequest = Notification.Name("app.ruyio.search.focusRequest")

    /// A request that found no field yet: a preview still parsing creates its search field later.
    @MainActor static var pendingFocus: (identifier: String, at: Date)?

    /// Focuses the field with `identifier`, now or when it appears within two seconds.
    @MainActor public static func requestFocus(_ identifier: String) {
        pendingFocus = (identifier, Date())
        NotificationCenter.default.post(name: focusRequest, object: identifier)
    }

    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    var controlSize: NSControl.ControlSize
    var identifier: String
    var focusOnAppear: Bool
    /// False inside a shape that already draws the field (a glass capsule): a plain borderless text field,
    /// with the magnifier and clear button left to that shape. AppKit's search field keeps room for its
    /// magnifier only while bezeled; without the bezel, typing overlapped the icon.
    var bordered: Bool
    var onCommand: ((Command) -> Void)?

    public init(text: Binding<String>, placeholder: String, controlSize: NSControl.ControlSize = .large,
                identifier: String = NativeSearchField.primaryIdentifier, focusOnAppear: Bool = true, bordered: Bool = true,
                onCommand: ((Command) -> Void)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.controlSize = controlSize
        self.identifier = identifier
        self.focusOnAppear = focusOnAppear
        self.bordered = bordered
        self.onCommand = onCommand
    }

    public func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        if bordered {
            let search = FocusingSearchField()
            search.focusOnAppear = focusOnAppear
            search.sendsSearchStringImmediately = true
            field = search
        } else {
            let plain = FocusingTextField()
            plain.focusOnAppear = focusOnAppear
            plain.isBezeled = false
            plain.isBordered = false
            plain.drawsBackground = false
            plain.focusRingType = .none
            plain.cell?.isScrollable = true
            plain.cell?.wraps = false
            field = plain
        }
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = controlSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        field.setAccessibilityLabel(placeholder)
        field.stringValue = text
        field.isEnabled = isEnabled
        return field
    }

    public func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommand = onCommand
        if field.stringValue != text { field.stringValue = text }
        guard field.isEnabled != isEnabled else { return }
        // AppKit draws its field editor above SwiftUI overlays. Relinquish it while a preview
        // covers the search field, and restore typing when that preview closes.
        if !isEnabled, let window = field.window,
           window.firstResponder === field.currentEditor() || window.firstResponder === field {
            context.coordinator.restoreFocus = true
            window.makeFirstResponder(nil)
        }
        field.isEnabled = isEnabled
        if isEnabled, context.coordinator.restoreFocus {
            context.coordinator.restoreFocus = false
            DispatchQueue.main.async { [weak field] in
                guard let field, field.isEnabled, let window = field.window, window.isVisible else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    public final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var restoreFocus = false
        var onCommand: ((Command) -> Void)?
        init(text: Binding<String>) { self.text = text }
        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // An input method still composing ("ni" on the way to 你) is not a query yet; committing it
            // changes the text again.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            text.wrappedValue = field.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let onCommand else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                onCommand(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previous : .next)
            case #selector(NSResponder.moveDown(_:)): onCommand(.next)
            case #selector(NSResponder.moveUp(_:)): onCommand(.previous)
            case #selector(NSResponder.cancelOperation(_:)):
                if control.stringValue.isEmpty {
                    NotificationCenter.default.post(name: NativeSearchField.focusRequest, object: NativeSearchField.primaryIdentifier)
                } else {
                    control.stringValue = ""
                    text.wrappedValue = ""
                }
            default: return false
            }
            return true
        }
    }

    // Selector-based observation ends with the field, even when its panel goes away without first
    // removing it from the window.
    final class FocusingSearchField: NSSearchField, FocusRequestable {
        var focusOnAppear = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            joinedWindow(observing: #selector(focusRequested(_:)))
        }
        @objc func focusRequested(_ note: Notification) { takeFocus(for: note) }
    }

    final class FocusingTextField: NSTextField, FocusRequestable {
        var focusOnAppear = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            joinedWindow(observing: #selector(focusRequested(_:)))
        }
        @objc func focusRequested(_ note: Notification) { takeFocus(for: note) }
    }
}

/// Focus on joining a window (the panel's main field), on `NativeSearchField.focusRequest` for its
/// identifier, and on a request made just before the field appeared.
@MainActor
protocol FocusRequestable: NSTextField {
    var focusOnAppear: Bool { get }
}

extension FocusRequestable {
    func joinedWindow(observing selector: Selector) {
        NotificationCenter.default.removeObserver(self, name: NativeSearchField.focusRequest, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: selector, name: NativeSearchField.focusRequest, object: nil)
        if let pending = NativeSearchField.pendingFocus, pending.identifier == identifier?.rawValue {
            NativeSearchField.pendingFocus = nil
            if Date().timeIntervalSince(pending.at) < 2 {
                DispatchQueue.main.async { [weak self] in self?.focus() }
                return
            }
        }
        guard focusOnAppear else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window.firstResponder !== self.currentEditor() else { return }
            self.focus()
        }
    }

    func takeFocus(for note: Notification) {
        guard note.object as? String == identifier?.rawValue, focus() else { return }
        NativeSearchField.pendingFocus = nil
    }

    @discardableResult
    func focus() -> Bool {
        guard isEnabled, let window else { return false }
        return window.makeFirstResponder(self)
    }
}

public extension View {
    /// Floating panels never activate Ruyio (the previous app stays frontmost), which would otherwise draw
    /// every native control in its dimmed inactive state. The panel is the key window, so render it as one.
    func keyWindowControls() -> some View {
        environment(\.controlActiveState, .key)
    }
}
