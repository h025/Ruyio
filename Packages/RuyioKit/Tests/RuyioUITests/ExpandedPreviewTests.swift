import AppKit
import RuyioCore
import RuyioProtocol
@testable import RuyioUI
import Testing

@MainActor
struct ExpandedPreviewTests {
    private let strings = SchemaStrings(submit: "Save", cancel: "Cancel", undo: "Undo", loading: "Loading", choose: "Choose")

    @Test func imageSchemasFromOlderPluginsStillDecodeWithoutAnOriginalReference() throws {
        let legacy = Data(#"{"blobID":"small-image","pixelWidth":2400,"pixelHeight":1600,"accessibilityLabel":"Photo"}"#.utf8)
        let image = try JSONDecoder().decode(ImageSpec.self, from: legacy)
        #expect(image.originalBlobID == nil)
        #expect(image.pixelWidth == 2400)
    }

    @Test func originalScalePreservesDecodedOrientationAfterDownsampling() {
        let portrait = ExpandedImageSizing.pointSize(decodedSize: CGSize(width: 768, height: 1024),
                                                     pixelWidth: 4032, pixelHeight: 3024, displayScale: 2)
        #expect(portrait == CGSize(width: 1512, height: 2016))
        let landscape = ExpandedImageSizing.pointSize(decodedSize: CGSize(width: 1024, height: 640),
                                                      pixelWidth: 4000, pixelHeight: 2500, displayScale: 1)
        #expect(landscape == CGSize(width: 4000, height: 2500))
        let legacy = ExpandedImageSizing.pointSize(decodedSize: CGSize(width: 800, height: 500),
                                                   pixelWidth: nil, pixelHeight: nil, displayScale: 2)
        #expect(legacy == CGSize(width: 400, height: 250))
    }

    @Test func largeImagesNeverReplaceOrAccumulateInTheThumbnailCache() async {
        var thumbnailLoads = 0
        var previewLoads = 0
        let thumbnail = NSImage(size: NSSize(width: 100, height: 100))
        let preview = NSImage(size: NSSize(width: 4000, height: 4000))
        let context = SchemaContext(pluginID: PluginID("org.example.preview"), document: ViewDocument(viewID: "history", revision: 1, root: .loading),
                                    strings: strings, sendEvent: { _, _ in }, loadBlob: { _ in thumbnailLoads += 1; return thumbnail },
                                    loadPreviewBlob: { _ in previewLoads += 1; return preview })
        #expect(await context.image("image") === thumbnail)
        #expect(await context.previewImage("image") === preview)
        #expect(await context.previewImage("image") === preview)
        #expect(await context.image("image") === thumbnail)
        #expect(thumbnailLoads == 1)
        #expect(previewLoads == 2)
    }

    @Test func contextsWithoutALargeImageLoaderReuseTheirExistingImage() async {
        var loads = 0
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let context = SchemaContext(pluginID: PluginID("org.example.preview"), document: ViewDocument(viewID: "history", revision: 1, root: .loading),
                                    strings: strings, sendEvent: { _, _ in }, loadBlob: { _ in loads += 1; return image })
        #expect(await context.image("image") === image)
        #expect(await context.previewImage("image") === image)
        #expect(loads == 1)
    }
}
