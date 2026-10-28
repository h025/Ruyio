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
