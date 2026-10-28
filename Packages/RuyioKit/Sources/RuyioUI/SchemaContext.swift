import AppKit
import Foundation
import RuyioCore
import RuyioProtocol
import SwiftUI

/// Bridges a rendered plugin view to the host: events go out, blob images come in.
/// Plugins never supply view code; everything here is host-owned (plan §9).
@MainActor
public final class SchemaContext: ObservableObject {
    public let pluginID: PluginID
    public let viewID: String
    @Published public private(set) var document: ViewDocument
    @Published public var isBusy = false
    @Published public var previewVisible = true
    @Published public var localSelection: String?
    @Published public private(set) var formSubmissionAcknowledgement: FormSubmissionAcknowledgement?
    /// Host-owned close for floating presentations (close button); plugins cannot trigger it.
    public var dismiss: (() -> Void)?
    /// Host-drawn provenance line for third-party plugins ("From the plugin …, Team …").
    public var source: String?

    private let sendEvent: (ViewEvent, Int) async -> Void
    private let loadBlob: (String) async -> NSImage?
    private var imageCache: [String: NSImage] = [:]
    public var strings: SchemaStrings

    public init(pluginID: PluginID, document: ViewDocument, strings: SchemaStrings,
                sendEvent: @escaping (ViewEvent, Int) async -> Void, loadBlob: @escaping (String) async -> NSImage?) {
        self.pluginID = pluginID
        self.viewID = document.viewID
        self.document = document
        self.strings = strings
        self.sendEvent = sendEvent
        self.loadBlob = loadBlob
        if case .collection(let spec) = document.root { localSelection = spec.list.selection }
    }

    /// Stale revisions never overwrite a newer document (plan §8.2).
    public func apply(_ document: ViewDocument) {
        guard document.viewID == viewID, document.revision >= self.document.revision else { return }
        self.document = document
        if case .collection(let spec) = document.root {
            if localSelection == nil || !spec.list.items.contains(where: { $0.id == localSelection }) {
                localSelection = spec.list.selection ?? spec.list.items.first?.id
            }
        }
    }

    public func send(_ event: ViewEvent) {
        let revision = document.revision
        Task { await sendEvent(event, revision) }
    }

    /// Call only after a successful save (including a confirmed save), never on a failed submission.
    /// A reply without a form accepts the submitted values as-is; it must not reuse the old form.
    public func acknowledgeSubmission(_ values: [String: JSONValue], document: ViewDocument?) {
        if let document {
            guard document.viewID == viewID, document.revision >= self.document.revision else { return }
        }
        let normalized: [String: JSONValue]?
        if let document, case .form(let form) = document.root {
            normalized = Dictionary(form.fields.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        } else {
            normalized = nil
        }
        formSubmissionAcknowledgement = FormSubmissionAcknowledgement(submitted: values, normalized: normalized)
    }

    public func image(_ blobID: String) async -> NSImage? {
        if let cached = imageCache[blobID] { return cached }
        let image = await loadBlob(blobID)
        if let image {
            if imageCache.count > 200 { imageCache.removeAll() }
            imageCache[blobID] = image
        }
        return image
    }

    public var collection: CollectionSpec? {
        if case .collection(let spec) = document.root { return spec }
        return nil
    }

    /// Resolve actions from the current schema, without assuming a clipboard-specific action ID.
    public func invocation(shortcut: KeyShortcut? = nil, itemID: String? = nil) -> ViewEvent? {
        guard let collection else { return nil }
        let selected = itemID ?? localSelection
        let item = collection.list.items.first { $0.id == selected }
        if itemID != nil && item == nil { return nil }
        let matches: (ItemAction) -> Bool = { action in
            if let shortcut { return action.shortcut.flatMap(KeyShortcut.init(manifestString:)) == shortcut }
            return action.isDefault
        }
        if let item, let action = item.actions.first(where: matches) {
            guard !item.isDisabled else { return nil }
            return .invoke(actionID: action.id, itemID: item.id)
        }
        guard let action = collection.footerActions.first(where: matches) else { return nil }
        return footerInvocation(action, itemID: selected)
    }

    public func footerInvocation(_ action: ItemAction, itemID: String? = nil) -> ViewEvent? {
        guard let collection else { return nil }
        let selected = itemID ?? localSelection
        let item = collection.list.items.first { $0.id == selected }
        if itemID != nil && item == nil { return nil }
        let isItemAction = item?.actions.contains { $0.id == action.id } == true
        if isItemAction && item?.isDisabled == true { return nil }
        if item == nil && collection.list.items.contains(where: { $0.actions.contains { $0.id == action.id } }) { return nil }
        return .invoke(actionID: action.id, itemID: isItemAction ? item?.id : nil)
    }

    public func moveSelection(_ delta: Int) {
        guard let items = collection?.list.items, !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == localSelection } ?? -1
        let next = max(0, min(items.count - 1, index + delta))
        localSelection = items[next].id
        send(.selectionChanged(items[next].id))
        if next >= items.count - 5, let cursor = collection?.list.nextCursor { send(.loadNextPage(cursor: cursor)) }
    }

    public func select(_ id: String) {
        localSelection = id
        send(.selectionChanged(id))
    }
}

/// Host-owned UI copy for generic schema chrome.
public struct SchemaStrings: Sendable {
    public var submit: String
    public var cancel: String
    public var undo: String
    public var loading: String
    public var choose: String
    public init(submit: String, cancel: String, undo: String, loading: String, choose: String) {
        self.submit = submit
        self.cancel = cancel
        self.undo = undo
        self.loading = loading
        self.choose = choose
    }
}

/// Decodes host blobs defensively: header check, pixel cap, downsampling (plan §9 resource limits).
public enum SafeImageDecoder {
    public static func image(from data: Data, maxPixel: Int = 1024, maxBytes: Int = 8 << 20) -> NSImage? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "public.tiff", "public.heic"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h <= 40_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
