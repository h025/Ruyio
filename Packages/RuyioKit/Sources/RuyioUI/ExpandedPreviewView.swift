import AppKit
import RuyioProtocol
import SwiftUI

/// A value snapshot: a later list selection cannot replace the content of an open preview.
public enum ExpandedPreviewContent: Sendable, Hashable {
    case json(String)
    case image(ImageSpec)

    public static func first(in node: UINode) -> Self? {
        switch node {
        case .json(let text): return .json(text)
        case .image(let image): return .image(image)
        case .stack(let stack): return stack.children.lazy.compactMap { first(in: $0) }.first
        default: return nil
        }
    }
}

enum ExpandedImageSizing {
    static func pointSize(decodedSize: CGSize, pixelWidth: Int?, pixelHeight: Int?, displayScale: CGFloat) -> CGSize {
        let decoded = CGSize(width: max(1, decodedSize.width), height: max(1, decodedSize.height))
        let longestDecodedEdge = max(decoded.width, decoded.height)
        var longestOriginalEdge = longestDecodedEdge
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            longestOriginalEdge = CGFloat(max(pixelWidth, pixelHeight))
        }
        // Decoding applies EXIF orientation; stored dimensions may still describe the unrotated file.
        // Preserve the decoded aspect ratio while restoring the original pixel scale after downsampling.
        let ratio = longestOriginalEdge / longestDecodedEdge / max(1, displayScale)
        return CGSize(width: decoded.width * ratio, height: decoded.height * ratio)
    }
}

/// The same JSON renderer as the inline preview, or a bounded-resolution image with native scrolling.
public struct ExpandedPreviewView: View {
    public static let searchIdentifier = "app.ruyio.search.expandedPreview"
    let content: ExpandedPreviewContent
    let strings: SchemaStrings
    let loadImage: (String) async -> NSImage?

    public init(content: ExpandedPreviewContent, strings: SchemaStrings, loadImage: @escaping (String) async -> NSImage?) {
        self.content = content
        self.strings = strings
        self.loadImage = loadImage
    }

    public var body: some View {
        Group {
            switch content {
            case .json(let text):
                ScrollView {
                    JSONTreeView(text: text, strings: strings.json, searchIdentifier: Self.searchIdentifier)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
            case .image(let spec):
                ExpandedImageView(spec: spec, strings: strings, loadImage: loadImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyWindowControls()
        .background(.regularMaterial)
    }
}

private struct ExpandedImageView: View {
    let spec: ImageSpec
    let strings: SchemaStrings
    let loadImage: (String) async -> NSImage?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var failed = false
    @State private var usesThumbnail = false
    @State private var fitsWindow = true
    @State private var scale: CGFloat = 1
    @State private var gestureStart: CGFloat?

    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - (usesThumbnail ? 76 : 48)))
                    let actual = ExpandedImageSizing.pointSize(decodedSize: image.size, pixelWidth: spec.pixelWidth,
                                                               pixelHeight: spec.pixelHeight, displayScale: displayScale)
                    let fit = min(viewport.width / max(1, actual.width), viewport.height / max(1, actual.height), 1)
                    let current = fitsWindow ? fit : scale
                    VStack(spacing: 0) {
                        toolbar(current: current)
                            .frame(height: 47).padding(.horizontal, 14)
                        Divider()
                        if usesThumbnail {
                            Text(strings.imagePreviewOnly).font(.caption).foregroundStyle(.secondary).frame(height: 28)
                        }
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image).resizable().interpolation(.high)
                                .frame(width: actual.width * current, height: actual.height * current)
                                .frame(minWidth: viewport.width, minHeight: viewport.height)
                                .accessibilityLabel(spec.accessibilityLabel)
                        }
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            if gestureStart == nil { gestureStart = current }
                            setScale((gestureStart ?? current) * value)
                        }.onEnded { _ in gestureStart = nil })
                    }
                }
            } else if failed {
                ContentUnavailableView(strings.imageUnavailable, systemImage: "photo.badge.exclamationmark")
            } else {
                ProgressView(strings.loading)
            }
        }
        .task(id: spec) {
            image = nil
            failed = false
            fitsWindow = true
            usesThumbnail = false
            let sourceID = spec.originalBlobID ?? spec.blobID
            var loaded = await loadImage(sourceID)
            guard !Task.isCancelled else { return }
            if loaded == nil, sourceID != spec.blobID {
                loaded = await loadImage(spec.blobID)
                guard !Task.isCancelled else { return }
                usesThumbnail = loaded != nil
            }
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }

    private func toolbar(current: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button { setScale(current / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(strings.zoomOut).accessibilityLabel(strings.zoomOut)
                .disabled(current <= 0.05)
            Slider(value: Binding(get: { min(4, max(0.05, current)) }, set: { value in setScale(value) }), in: 0.05...4)
                .frame(width: 130).accessibilityLabel(strings.zoomIn)
            Button { setScale(current * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(strings.zoomIn).accessibilityLabel(strings.zoomIn)
                .disabled(current >= 4)
            Text("\(Int((current * 100).rounded()))%")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 42)
            Spacer(minLength: 8)
            Button(strings.fitImage) { fitsWindow = true }
            Button("100%") { setScale(1) }.help(strings.actualImageSize).accessibilityLabel(strings.actualImageSize)
        }
        .controlSize(.regular)
    }

    private func setScale(_ value: CGFloat) {
        fitsWindow = false
        scale = min(4, max(0.05, value))
    }
}
