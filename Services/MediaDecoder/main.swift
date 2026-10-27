import CoreGraphics
import Foundation
import ImageIO

/// Sandboxed XPC service that decodes untrusted images for the host (plan §9, R43). It has no network
/// or file entitlements; it receives bytes and returns a fixed-format BGRA pixel buffer only.
@objc(RuyioMediaDecoding) protocol RuyioMediaDecoding {
    func decodeThumbnail(_ data: Data, maxPixel: Int, reply: @escaping (Data?, Int, Int) -> Void)
}

final class MediaDecoder: NSObject, RuyioMediaDecoding {
    static let maxInputBytes = 16 << 20
    static let maxSourcePixels = 40_000_000

    func decodeThumbnail(_ data: Data, maxPixel: Int, reply: @escaping (Data?, Int, Int) -> Void) {
        let limit = max(16, min(maxPixel, 2048))
        guard data.count <= Self.maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "public.tiff", "public.heic"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h <= Self.maxSourcePixels else { reply(nil, 0, 0); return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: limit,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { reply(nil, 0, 0); return }
        let width = image.width, height = image.height
        var pixels = Data(count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        reply(drawn ? pixels : nil, drawn ? width : 0, drawn ? height : 0)
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: RuyioMediaDecoding.self)
        connection.exportedObject = MediaDecoder()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
