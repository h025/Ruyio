import Foundation
import RuyioCore

/// 4-byte big-endian length + UTF-8 JSON (plan §8.2).
public enum Framing {
    public static let maxFrameBytes = 1 << 20
    public static let maxJSONDepth = 32

    public static func encode(_ envelope: Envelope) throws -> Data {
        let body = try JSONCoding.encoder().encode(envelope)
        guard body.count <= maxFrameBytes else {
            throw RuyioError(.frameTooLarge, diagnostic: "\(body.count) bytes")
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }
}

/// Incremental decoder; feed arbitrary byte chunks, receive complete envelopes.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// Returns the next complete envelope, nil if more bytes are needed. Throws on protocol violations.
    public mutating func next() throws -> Envelope? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= Framing.maxFrameBytes else {
            throw RuyioError(.frameTooLarge, diagnostic: "declared \(length) bytes")
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer[(start + 4)..<(start + 4 + Int(length))]
        buffer.removeSubrange(start..<(start + 4 + Int(length)))
        let envelope: Envelope
        do {
            envelope = try JSONCoding.decoder().decode(Envelope.self, from: Data(body))
        } catch {
            throw RuyioError(.invalidRequest, diagnostic: "undecodable frame")
        }
        guard envelope.payload.depth <= Framing.maxJSONDepth else {
            throw RuyioError(.invalidRequest, diagnostic: "payload too deep")
        }
        return envelope
    }

    public var bufferedByteCount: Int { buffer.count }
}
