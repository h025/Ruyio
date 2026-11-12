import AppKit
import RuyioCore
import RuyioProtocol
@testable import RuyioUI
import Testing

@MainActor
struct SchemaImageCacheTests {
    private let strings = SchemaStrings(submit: "Save", cancel: "Cancel", undo: "Undo", loading: "Loading", choose: "Choose")

    private func context(load: @escaping (String) async -> NSImage?) -> SchemaContext {
        SchemaContext(pluginID: PluginID("org.example.image-cache"),
                      document: ViewDocument(viewID: "images", revision: 1, root: .loading),
                      strings: strings, sendEvent: { _, _ in }, loadBlob: load)
    }

    private func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    }

    private func image(width: Int, height: Int) throws -> NSImage {
        let representation = try bitmap(width: width, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(representation)
        return image
    }

    @Test func byteBudgetEvictsTheLeastRecentlyUsedImageWithoutClearingHotImages() async throws {
        var loads: [String: Int] = [:]
        let context = context { id in
            loads[id, default: 0] += 1
            return try? image(width: 1024, height: 1024)
        }
        // Four RGBA images fill 16 MiB; touching a makes b the next eviction candidate.
        for id in ["a", "b", "c", "d", "a", "e", "a", "c", "d", "e"] {
            #expect(await context.image(id) != nil)
        }
        #expect(loads == ["a": 1, "b": 1, "c": 1, "d": 1, "e": 1])
        #expect(await context.image("b") != nil)
        #expect(loads["b"] == 2)
    }

    @Test func aSingleImageLargerThanTheBudgetIsDisplayedButNeverRetained() async throws {
        let oversized = try image(width: 2048, height: 2049)
        var loads = 0
        let context = context { _ in loads += 1; return oversized }
        #expect(await context.image("oversized") === oversized)
        #expect(await context.image("oversized") === oversized)
        #expect(loads == 2)
    }

    @Test func tinyImagesStillRespectTheMetadataEntryLimit() async throws {
        let tiny = try image(width: 1, height: 1)
        var loads: [String: Int] = [:]
        let context = context { id in loads[id, default: 0] += 1; return tiny }
        for id in 0...128 { #expect(await context.image(String(id)) === tiny) }
        #expect(await context.image("1") === tiny)
        #expect(loads["1"] == 1)
        #expect(await context.image("0") === tiny)
        #expect(loads["0"] == 2)
    }

    @Test func cancellingOneWaiterPreservesTheSharedLoadAndCachesItsResult() async throws {
        let gate = ImageLoadGate()
        let image = try image(width: 32, height: 32)
        let context = context { id in await gate.load(id) }
        let first = Task { await context.image("shared") }
        await gate.waitForLoad("shared")
        let entered = ImageLoadSignal()
        let second = Task {
            entered.signal()
            return await context.image("shared")
        }
        await entered.wait()
        first.cancel()
        #expect(gate.counts["shared"] == 1)
        gate.finish("shared", with: image)
        #expect(await first.value == nil)
        #expect(await second.value === image)
        #expect(!gate.loaderWasCancelled)
        #expect(await context.image("shared") === image)
        #expect(gate.counts["shared"] == 1)
    }

    @Test func differentBlobsCanLoadWhileAnotherBlobIsStillPending() async throws {
        let gate = ImageLoadGate()
        let image = try image(width: 32, height: 32)
        let context = context { id in await gate.load(id) }
        let first = Task { await context.image("a") }
        await gate.waitForLoad("a")
        let second = Task { await context.image("b") }
        await gate.waitForLoad("b")
        #expect(gate.counts == ["a": 1, "b": 1])
        gate.finish("b", with: image)
        #expect(await second.value === image)
        gate.finish("a", with: image)
        #expect(await first.value === image)
    }

    @Test func aFailedOrCancelledRequestCanBeRetried() async throws {
        let gate = ImageLoadGate()
        let image = try image(width: 32, height: 32)
        let context = context { id in await gate.load(id) }
        let first = Task { await context.image("retry") }
        await gate.waitForLoad("retry")
        first.cancel()
        gate.finish("retry", with: nil)
        #expect(await first.value == nil)
        let retry = Task { await context.image("retry") }
        await gate.waitForLoad("retry", count: 2)
        gate.finish("retry", with: image)
        #expect(await retry.value === image)
        #expect(await context.image("retry") === image)
        #expect(gate.counts["retry"] == 2)
    }

    @Test func costsUseActualBackingPixelsEvenWhenLogicalSizeIsOnePoint() throws {
        let bitmap = try bitmap(width: 64, height: 64)
        bitmap.size = NSSize(width: 1, height: 1)
        let bitmapImage = NSImage(size: NSSize(width: 1, height: 1))
        bitmapImage.addRepresentation(bitmap)
        let cgImage = try #require(bitmap.cgImage)
        let snapshot = NSImage(cgImage: cgImage, size: NSSize(width: 1, height: 1))
        #expect(ImageMemoryCache.cost(of: bitmapImage) == 64 * 64 * 4)
        #expect(ImageMemoryCache.cost(of: snapshot) == cgImage.bytesPerRow * cgImage.height)
    }

    @Test func costsIncludeEveryRepresentationAndAllPlanarStorage() throws {
        let image = try image(width: 32, height: 32)
        image.addRepresentation(try bitmap(width: 64, height: 64))
        #expect(image.representations.count == 2)
        #expect(ImageMemoryCache.cost(of: image) == (32 * 32 + 64 * 64) * 4)

        let planar = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                                  bitsPerSample: 16, samplesPerPixel: 4, hasAlpha: true, isPlanar: true,
                                                  colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 16))
        let planarImage = NSImage(size: NSSize(width: 16, height: 16))
        planarImage.addRepresentation(planar)
        #expect(ImageMemoryCache.cost(of: planarImage) == 32 * 16 * 4)
    }

    @Test func dimensionsThatOverflowCostAreNotCached() async {
        let invalid = NSImage(size: NSSize(width: CGFloat(Int.max), height: 2))
        #expect(ImageMemoryCache.cost(of: invalid) == nil)
        var loads = 0
        let context = context { _ in loads += 1; return invalid }
        #expect(await context.image("invalid") === invalid)
        #expect(await context.image("invalid") === invalid)
        #expect(loads == 2)
    }
}

@MainActor
private final class ImageLoadSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class ImageLoadGate {
    private(set) var counts: [String: Int] = [:]
    private(set) var loaderWasCancelled = false
    private var requests: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var starts: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]

    func load(_ id: String) async -> NSImage? {
        counts[id, default: 0] += 1
        let image: NSImage? = await withCheckedContinuation { continuation in
            requests[id, default: []].append(continuation)
            let ready = starts[id, default: []].filter { $0.0 <= counts[id, default: 0] }
            starts[id]?.removeAll { $0.0 <= counts[id, default: 0] }
            ready.forEach { $0.1.resume() }
        }
        loaderWasCancelled = loaderWasCancelled || Task.isCancelled
        return Task.isCancelled ? nil : image
    }

    func waitForLoad(_ id: String, count: Int = 1) async {
        if counts[id, default: 0] >= count { return }
        await withCheckedContinuation { starts[id, default: []].append((count, $0)) }
    }

    func finish(_ id: String, with image: NSImage?) {
        let pending = requests.removeValue(forKey: id) ?? []
        pending.forEach { $0.resume(returning: image) }
    }
}
