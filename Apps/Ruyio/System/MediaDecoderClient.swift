import AppKit
import Foundation

@objc(RuyioMediaDecoding) protocol RuyioMediaDecoding {
    func decodeThumbnail(_ data: Data, maxPixel: Int, reply: @escaping (Data?, Int, Int) -> Void)
}

/// Host side of the sandboxed media decoder (R43). The host never runs ImageIO on untrusted bytes:
/// it only wraps a validated BGRA buffer. If the service is unavailable it fails closed (placeholder).
final class MediaDecoderClient: @unchecked Sendable {
    static let shared = MediaDecoderClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(_ onError: @escaping (Error) -> Void) -> RuyioMediaDecoding? {
        lock.withLock {
            if connection == nil {
                let c = NSXPCConnection(serviceName: "app.ruyio.mac.MediaDecoder")
                c.remoteObjectInterface = NSXPCInterface(with: RuyioMediaDecoding.self)
                c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
                c.resume()
                connection = c
            }
            return connection?.remoteObjectProxyWithErrorHandler(onError) as? RuyioMediaDecoding
        }
    }

    private func resetConnection() {
        let stale = lock.withLock { () -> NSXPCConnection? in
            defer { connection = nil }
            return connection
        }
        stale?.invalidate()
    }

    func image(from data: Data, maxPixel: Int = 1024) async -> NSImage? {
        let limit = max(16, min(maxPixel, 2048))
        let result: (Data?, Int, Int) = await withCheckedContinuation { continuation in
            let once = OnceBox()
            let finish: (Data?, Int, Int) -> Void = { pixels, w, h in
                if once.claim() { continuation.resume(returning: (pixels, w, h)) }
            }
            guard let decoder = proxy({ _ in finish(nil, 0, 0) }) else { finish(nil, 0, 0); return }
            decoder.decodeThumbnail(data, maxPixel: limit) { pixels, w, h in finish(pixels, w, h) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                // A stuck decode would hold up every later thumbnail on this connection: drop it so the
                // service restarts for the next request.
                if once.claim() {
                    continuation.resume(returning: (nil, 0, 0))
                    self?.resetConnection()
                }
            }
        }
        let (pixels, width, height) = result
        guard let pixels, width > 0, height > 0, width <= limit, height <= limit, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
