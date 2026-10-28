import AppKit
import SwiftUI

// Liquid Glass on macOS 26+ with material fallbacks on macOS 15, so callers stay free of availability checks.
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

/// AppKit's own search field (magnifier, clear button, Liquid Glass styling) for SwiftUI. Takes focus
/// when it joins a window, since floating panels open straight into typing.
public struct NativeSearchField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    var controlSize: NSControl.ControlSize

    public init(text: Binding<String>, placeholder: String, controlSize: NSControl.ControlSize = .large) {
        _text = text
        self.placeholder = placeholder
        self.controlSize = controlSize
    }

    public func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.controlSize = controlSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        field.setAccessibilityLabel(placeholder)
        field.stringValue = text
        field.isEnabled = isEnabled
        return field
    }

    public func updateNSView(_ field: NSSearchField, context: Context) {
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
        init(text: Binding<String>) { self.text = text }
        public func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }

    final class FocusingSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, window.firstResponder !== self.currentEditor() else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

public extension View {
    /// Floating panels never activate Ruyio (the previous app stays frontmost), which would otherwise draw
    /// every native control in its dimmed inactive state. The panel is the key window, so render it as one.
    func keyWindowControls() -> some View {
        environment(\.controlActiveState, .key)
    }
}
