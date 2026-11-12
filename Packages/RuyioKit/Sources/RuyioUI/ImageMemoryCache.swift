import AppKit

/// Bounds the images retained by a view context; visible views own their images separately.
@MainActor
struct ImageMemoryCache {
    static let defaultByteLimit = 16 << 20
    static let defaultEntryLimit = 128

    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private let byteLimit: Int
    private let entryLimit: Int
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    private var totalCost = 0

    init(byteLimit: Int = Self.defaultByteLimit, entryLimit: Int = Self.defaultEntryLimit) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    mutating func image(for key: String) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.image
    }

    mutating func insert(_ image: NSImage, for key: String) {
        remove(key)
        guard entryLimit > 0, let cost = Self.cost(of: image), cost > 0, cost <= byteLimit else { return }
        // Subtraction keeps the comparison safe even for an uncacheably large image.
        while totalCost > byteLimit - cost || entries.count >= entryLimit {
            guard let oldest = recency.first else { return }
            remove(oldest)
        }
        entries[key] = Entry(image: image, cost: cost)
        recency.append(key)
        totalCost += cost
    }

    private mutating func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) { totalCost -= entry.cost }
        recency.removeAll { $0 == key }
    }

    /// Count decoded pixels, including every retained representation and planar/float storage.
    /// Unknown dimensions or overflowing costs are returned as uncacheable, never as zero bytes.
    static func cost(of image: NSImage) -> Int? {
        guard !image.representations.isEmpty else { return fallbackCost(size: image.size) }
        var total = 0
        for representation in image.representations {
            let cost: Int?
            if let bitmap = representation as? NSBitmapImageRep {
                guard let storage = product(bitmap.bytesPerRow, bitmap.pixelsHigh, bitmap.numberOfPlanes),
                      let rgba = product(bitmap.pixelsWide, bitmap.pixelsHigh, 4) else { return nil }
                cost = max(storage, rgba)
            } else {
                // CGImage-backed NSImage reps report scaled logical dimensions on macOS, even
                // when their backing pixels are much larger. Inspect that backing per rep.
                guard representation.pixelsWide > 0, representation.pixelsHigh > 0,
                      !(representation is NSCustomImageRep), !(representation is NSPDFImageRep),
                      representation.size.width.isFinite, representation.size.height.isFinite,
                      representation.size.width > 0, representation.size.height > 0 else { return nil }
                let singleRepresentation = NSImage(size: representation.size)
                singleRepresentation.addRepresentation(representation)
                guard let cgImage = singleRepresentation.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let storage = product(cgImage.bytesPerRow, cgImage.height),
                      let rgba = product(cgImage.width, cgImage.height, 4) else { return nil }
                cost = max(storage, rgba)
            }
            guard let cost, total <= Int.max - cost else { return nil }
            total += cost
        }
        return total
    }

    private static func fallbackCost(size: NSSize) -> Int? {
        // A vector or not-yet-rasterized image may acquire a Retina representation when displayed.
        let width = ceil(size.width * 2)
        let height = ceil(size.height * 2)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width < Double(Int.max), height < Double(Int.max) else { return nil }
        return product(Int(width), Int(height), 4)
    }

    private static func product(_ factors: Int...) -> Int? {
        var result = 1
        for factor in factors {
            guard factor > 0 else { return nil }
            let multiplied = result.multipliedReportingOverflow(by: factor)
            guard !multiplied.overflow else { return nil }
            result = multiplied.partialValue
        }
        return result
    }
}
