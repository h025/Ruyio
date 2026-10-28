import AppKit
import RuyioCore
import RuyioProtocol
import SwiftUI

/// Renders any `UINode`. Layout, spacing, focus and destructive styling are decided here, not by plugins.
public struct SchemaNodeView: View {
    let node: UINode
    @ObservedObject var context: SchemaContext

    public init(node: UINode, context: SchemaContext) {
        self.node = node
        self.context = context
    }

    public var body: some View {
        switch node {
        case .stack(let spec):
            if spec.axis == .horizontal {
                HStack(alignment: .top, spacing: 12) { ForEach(Array(spec.children.enumerated()), id: \.offset) { SchemaNodeView(node: $0.element, context: context) } }
            } else {
                VStack(alignment: .leading, spacing: 12) { ForEach(Array(spec.children.enumerated()), id: \.offset) { SchemaNodeView(node: $0.element, context: context) } }
            }
        case .text(let spec):
            styledText(spec).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .markdown(let text):
            // Markdown without HTML, scripts or network resources (plan §9). Links are shown as text only:
            // opening URLs goes through the host's checked capability, never a click in rendered content.
            Text(Self.inertMarkdown(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .code(let text):
            Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .json(let text):
            Text(JSONFormatting.highlighted(JSONFormatting.indented(text)))
                .font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .image(let spec):
            BlobImageView(blobID: spec.blobID, context: context, label: spec.accessibilityLabel, maxHeight: 360)
        case .keyValue(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.key).foregroundStyle(.secondary).font(.callout)
                        Text(row.value).font(row.monospaced ? .system(.callout, design: .monospaced) : .callout).textSelection(.enabled)
                    }
                }
            }
        case .form(let spec):
            SchemaFormView(spec: spec, context: context)
        case .list(let spec):
            SchemaListView(spec: spec, context: context)
        case .collection(let spec):
            CollectionPanelView(spec: spec, context: context)
        case .empty(let spec):
            EmptyStateView(spec: spec, context: context)
        case .error(let spec):
            VStack(alignment: .leading, spacing: 8) {
                Label(spec.title, systemImage: "exclamationmark.triangle").font(.headline)
                if let message = spec.message { Text(message).foregroundStyle(.secondary) }
                HStack { ForEach(spec.actions, id: \.id) { action in Button(action.title) { context.send(.invoke(actionID: action.id, itemID: nil)) } } }
            }
        case .progress(let spec):
            VStack(alignment: .leading, spacing: 6) {
                Text(spec.label).foregroundStyle(.secondary)
                if let fraction = spec.fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                if spec.cancellable { Button(context.strings.cancel) { context.send(.cancel) } }
            }
        case .loading:
            ProgressView(context.strings.loading).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func inertMarkdown(_ text: String) -> AttributedString {
        var parsed = (try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in parsed.runs where run.link != nil { parsed[run.range].link = nil }
        return parsed
    }

    @ViewBuilder
    func styledText(_ spec: TextSpec) -> some View {
        switch spec.style {
        case .title: Text(spec.text).font(.title3.weight(.semibold))
        case .headline: Text(spec.text).font(.headline)
        case .body: Text(spec.text).font(.body)
        case .secondary: Text(spec.text).foregroundStyle(.secondary)
        case .caption: Text(spec.text).font(.caption).foregroundStyle(.secondary)
        case .monospaced: Text(spec.text).font(.system(.callout, design: .monospaced))
        }
    }
}

struct BlobImageView: View {
    let blobID: String
    @ObservedObject var context: SchemaContext
    let label: String
    var maxHeight: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).aspectRatio(16.0 / 10.0, contentMode: .fit)
            }
        }
        .frame(maxHeight: maxHeight)
        .accessibilityLabel(label)
        .task(id: blobID) { image = await context.image(blobID) }
    }
}

struct EmptyStateView: View {
    let spec: EmptySpec
    @ObservedObject var context: SchemaContext
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: spec.action == nil ? "tray" : "magnifyingglass")
                .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(spec.title).font(.title3.weight(.semibold))
            if let message = spec.message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let action = spec.action {
                Button(action.title) { context.send(.invoke(actionID: action.id, itemID: nil)) }.ruyioGlassButton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Host-rendered settings / parameter form. Text input keeps a local draft until submit (plan §9).
public struct SchemaFormView: View {
    let spec: FormSpec
    @ObservedObject var context: SchemaContext
    @State private var draft = FormDraft()
    var onSubmit: (([String: JSONValue]) -> Void)?

    public init(spec: FormSpec, context: SchemaContext, onSubmit: (([String: JSONValue]) -> Void)? = nil) {
        self.spec = spec
        self.context = context
        self.onSubmit = onSubmit
    }

    public var body: some View {
        Form {
            ForEach(spec.fields, id: \.id) { field in
                FieldView(field: field, value: binding(field))
            }
            if let footnote = spec.footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(spec.submitTitle ?? context.strings.submit) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(context.isBusy || spec.fields.contains { $0.isRequired && (draft.values[$0.id]?.stringValue ?? $0.value.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty && $0.kind == .textField })
            }
        }
        .formStyle(.grouped)
        .disabled(context.isBusy)
        .onAppear { draft.update(fields: spec.fields) }
        .onChange(of: FormInput(spec: spec, acknowledgement: context.formSubmissionAcknowledgement)) { _, input in
            draft.update(fields: input.spec.fields, acknowledgement: input.acknowledgement)
        }
    }

    func binding(_ field: FieldSpec) -> Binding<JSONValue> {
        Binding(get: { draft.values[field.id] ?? field.value }, set: { draft.set($0, for: field.id) })
    }

    func submit() {
        let result = draft.prepareSubmission(fields: spec.fields)
        if let onSubmit { onSubmit(result) } else { context.send(.submit(result)) }
    }

    private struct FormInput: Equatable {
        var spec: FormSpec
        var acknowledgement: FormSubmissionAcknowledgement?
    }
}

struct FieldView: View {
    let field: FieldSpec
    @Binding var value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let error = field.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityLabel(error)
            } else if let help = field.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var control: some View {
        switch field.kind {
        case .textField:
            BaseNameTextField(label: field.label, text: stringBinding, placeholder: field.placeholder ?? "", selectsBaseName: field.selectsBaseName)
        case .textEditor:
            VStack(alignment: .leading) {
                Text(field.label)
                TextEditor(text: stringBinding).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
            }
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { value.boolValue ?? false }, set: { value = .bool($0) }))
        case .picker:
            Picker(field.label, selection: stringBinding) {
                ForEach(field.options ?? [], id: \.id) { Text($0.title).tag($0.id) }
            }
        case .slider:
            Slider(value: sliderBinding, in: Self.range(field.minimum, field.maximum, default: 0...1)) { Text(field.label) }
        case .stepper:
            let range = Self.range(field.minimum, field.maximum, default: 0...1_000_000)
            let step = field.step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            Stepper(value: doubleBinding, in: range, step: step) {
                HStack {
                    Text(field.label)
                    Spacer()
                    Text(Self.displayNumber(value.doubleValue ?? range.lowerBound)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        case .fileChooser, .directoryChooser, .applicationChooser:
            HStack {
                Text(field.label)
                Spacer()
                Text(value.stringValue.map { ($0 as NSString).lastPathComponent } ?? "—").foregroundStyle(.secondary)
                Button("…") { choose() }
            }
        }
    }

    var stringBinding: Binding<String> { Binding(get: { value.stringValue ?? "" }, set: { value = .string($0) }) }
    var doubleBinding: Binding<Double> { Binding(get: { value.doubleValue ?? 0 }, set: { value = .number($0.rounded()) }) }
    var sliderBinding: Binding<Double> { Binding(get: { value.doubleValue ?? 0 }, set: { value = .number($0) }) }

    /// Plugin-supplied bounds are untrusted: an inverted or non-finite range must never trap the host.
    static func range(_ minimum: Double?, _ maximum: Double?, default fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        let low = minimum.flatMap { $0.isFinite ? $0 : nil } ?? fallback.lowerBound
        let high = maximum.flatMap { $0.isFinite ? $0 : nil } ?? fallback.upperBound
        return low <= high ? low...high : fallback
    }

    static func displayNumber(_ number: Double) -> String {
        guard number.isFinite else { return "—" }
        if let exact = Int(exactly: number.rounded()) { return String(exact) }
        return number.formatted(.number.notation(.compactName))
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = field.kind == .directoryChooser
        panel.canChooseFiles = field.kind != .directoryChooser
        if field.kind == .applicationChooser {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        if panel.runModal() == .OK, let url = panel.url {
            if field.kind == .applicationChooser, let id = Bundle(url: url)?.bundleIdentifier { value = .string(id) } else { value = .string(url.path) }
        }
    }
}

/// Text field that pre-selects the base name (without extension) on appear (PRD §19.18).
struct BaseNameTextField: NSViewRepresentable {
    let label: String
    @Binding var text: String
    let placeholder: String
    let selectsBaseName: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        if selectsBaseName {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                let base = (field.stringValue as NSString).deletingPathExtension
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

struct SchemaListView: View {
    let spec: ListSpec
    @ObservedObject var context: SchemaContext
    var body: some View {
        if spec.items.isEmpty, let empty = spec.empty {
            EmptyStateView(spec: empty, context: context)
        } else {
            List(spec.items, selection: Binding(get: { context.localSelection }, set: { context.localSelection = $0; context.send(.selectionChanged($0)) })) { item in
                ItemRow(item: item, context: context).tag(item.id)
            }
        }
    }
}

/// One plugin-provided row; selection, emphasis and hover come from the native List.
struct ItemRow: View {
    let item: ListItem
    @ObservedObject var context: SchemaContext

    var body: some View {
        HStack(spacing: 12) {
            if let blob = item.thumbnailBlobID {
                BlobImageView(blobID: blob, context: context, label: item.title, maxHeight: 30)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let symbol = item.symbol {
                SymbolBadge(symbol, color: SymbolBadge.color(for: symbol), size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if item.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("★") }
            if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel ?? item.title)
        .contextMenu {
            ForEach(item.actions, id: \.id) { action in
                Button(role: action.isDestructive ? .destructive : nil) { context.send(.invoke(actionID: action.id, itemID: item.id)) } label: {
                    Text(action.title)
                }
            }
        }
    }
}
