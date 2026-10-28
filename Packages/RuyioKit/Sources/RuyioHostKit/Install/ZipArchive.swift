import Compression
import Darwin
import Foundation
import RuyioCore

/// Minimal, defensive ZIP reader for plugin packages (PRD §19.10 step 3, plan §15.1).
///
/// Supports stored and deflated entries. Rejects encryption, ZIP64, absolute paths, `..` traversal,
/// backslashes, duplicate names (case-insensitive, matching APFS defaults), special files, symlinks
/// escaping the archive root, oversize totals, excessive expansion ratios and CRC mismatches.
/// No external tool or script is executed.
public struct ZipArchive: Sendable {
    public struct Limits: Sendable {
        public var maxEntries = 10_000
        public var maxTotalUncompressed: Int64 = 500 << 20
        public var maxEntryUncompressed: Int64 = 256 << 20
        public var maxRatio: Double = 200
        public init() {}
    }

    public struct Entry: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case file(mode: UInt16), directory, symlink }
        public var path: String
        public var kind: Kind
        public var method: UInt16
        public var crc32: UInt32
        public var compressedSize: Int
        public var uncompressedSize: Int
        public var localHeaderOffset: Int
    }

    public let entries: [Entry]
    private let data: Data
    private let limits: Limits

    public init(url: URL, limits: Limits = Limits()) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
    }

    public init(data: Data, limits: Limits = Limits()) throws {
        self.data = data
        self.limits = limits
        entries = try Self.readCentralDirectory(data, limits: limits)
    }

    /// Extracts into `destination` (created fresh). Symlinks are created last so no file is ever
    /// written through a link that the archive itself planted.
    public func extract(to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw Self.error("destination exists") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = destination.standardizedFileURL.path
        var symlinks: [(Entry, String)] = []
        for entry in entries {
            let target = destination.appendingPathComponent(entry.path)
            switch entry.kind {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            case .file(let mode):
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                let bytes = try contents(of: entry)
                let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode & 0o755 | 0o600))
                guard fd >= 0 else { throw Self.error("cannot create \(entry.path) errno=\(errno)") }
                defer { close(fd) }
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n < 0 { if errno == EINTR { continue }; throw Self.error("write failed \(entry.path)") }
                        offset += n
                    }
                }
            case .symlink:
                let linkTarget = String(decoding: try contents(of: entry), as: UTF8.self)
                symlinks.append((entry, linkTarget))
            }
        }
        let linkPaths = Set(symlinks.map(\.0.path))
        for (entry, linkTarget) in symlinks {
            let location = destination.appendingPathComponent(entry.path)
            // The literal check below assumes every component is a real directory. A link placed under (or
            // resolving through) another link breaks that assumption, e.g. `l1 -> .` plus `l1/l1/x -> ../../..`.
            guard !Self.passesThroughLink(entryPath: entry.path, target: linkTarget, links: linkPaths),
                  Self.symlinkStaysInside(entryPath: entry.path, target: linkTarget, root: root) else {
                throw Self.error("symlink escapes archive: \(entry.path)")
            }
            try fm.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard symlink(linkTarget, location.path) == 0 else { throw Self.error("symlink failed \(entry.path)") }
        }
    }

    public func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.readUInt32(header) == 0x04034b50 else { throw Self.error("bad local header") }
        let nameLength = Int(data.readUInt16(header + 26))
        let extraLength = Int(data.readUInt16(header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw Self.error("truncated entry") }
        let compressed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0: output = compressed
        case 8: output = try Self.inflate(compressed, expected: entry.uncompressedSize)
        default: throw Self.error("unsupported compression \(entry.method)")
        }
        guard output.count == entry.uncompressedSize else { throw Self.error("size mismatch \(entry.path)") }
        guard CRC32.checksum(output) == entry.crc32 else { throw Self.error("crc mismatch \(entry.path)") }
        return output
    }

    public func entry(named path: String) -> Entry? { entries.first { $0.path == path } }

    // MARK: Parsing

    static func readCentralDirectory(_ data: Data, limits: Limits) throws -> [Entry] {
        guard data.count >= 22 else { throw error("not a zip") }
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        var index = data.count - 22
        while index >= searchStart {
            if data.readUInt32(index) == 0x06054b50 { eocd = index; break }
            index -= 1
        }
        guard let end = eocd else { throw error("missing end of central directory") }
        let total = Int(data.readUInt16(end + 10))
        let size = Int(data.readUInt32(end + 12))
        let offset = Int(data.readUInt32(end + 16))
        guard total != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw error("ZIP64 not supported") }
        guard total <= limits.maxEntries else { throw error("too many entries (\(total))") }
        guard offset + size <= end else { throw error("bad central directory") }

        var entries: [Entry] = []
        var seen = Set<String>()
        var totalSize: Int64 = 0
        var cursor = offset
        for _ in 0..<total {
            guard cursor + 46 <= data.count, data.readUInt32(cursor) == 0x02014b50 else { throw error("bad central header") }
            let madeBy = data.readUInt16(cursor + 4)
            let flags = data.readUInt16(cursor + 8)
            let method = data.readUInt16(cursor + 10)
            let crc = data.readUInt32(cursor + 16)
            let compressed = Int(data.readUInt32(cursor + 20))
            let uncompressed = Int(data.readUInt32(cursor + 24))
            let nameLength = Int(data.readUInt16(cursor + 28))
            let extraLength = Int(data.readUInt16(cursor + 30))
            let commentLength = Int(data.readUInt16(cursor + 32))
            let external = data.readUInt32(cursor + 38)
            let localOffset = Int(data.readUInt32(cursor + 42))
            guard cursor + 46 + nameLength <= data.count else { throw error("truncated name") }
            let nameData = data.subdata(in: (data.startIndex + cursor + 46)..<(data.startIndex + cursor + 46 + nameLength))
            cursor += 46 + nameLength + extraLength + commentLength

            guard flags & 0x1 == 0 else { throw error("encrypted entries are not allowed") }
            guard let rawName = String(data: nameData, encoding: .utf8) else { throw error("non-UTF-8 entry name") }
            // AppleDouble entries carry extended attributes, not bundle content; extracting them would add
            // unsealed files and break the code signature. Quarantine is applied by the host instead.
            let lastComponent = rawName.split(separator: "/").last.map(String.init) ?? rawName
            if rawName.hasPrefix("__MACOSX/") || lastComponent.hasPrefix("._") || lastComponent == ".DS_Store" { continue }

            let unixMode = UInt16(truncatingIfNeeded: external >> 16)
            let fileType = unixMode & 0o170000
            let isDirectory = rawName.hasSuffix("/") || (madeBy >> 8 == 3 && fileType == 0o040000)
            let name = isDirectory && rawName.hasSuffix("/") ? String(rawName.dropLast()) : rawName
            try validate(path: name)
            guard seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw error("duplicate entry \(name)") }

            let kind: Entry.Kind
            if isDirectory { kind = .directory }
            else if madeBy >> 8 == 3 && fileType == 0o120000 { kind = .symlink }
            else if madeBy >> 8 != 3 || fileType == 0o100000 || fileType == 0 { kind = .file(mode: unixMode & 0o777 == 0 ? 0o644 : unixMode & 0o777) }
            else { throw error("special file \(name)") }

            if case .file = kind {
                guard Int64(uncompressed) <= limits.maxEntryUncompressed else { throw error("entry too large \(name)") }
                if uncompressed > 1 << 20, compressed > 0, Double(uncompressed) / Double(compressed) > limits.maxRatio {
                    throw error("expansion ratio too high \(name)")
                }
                totalSize += Int64(uncompressed)
                guard totalSize <= limits.maxTotalUncompressed else { throw error("archive expands beyond limit") }
            }
            entries.append(Entry(path: name, kind: kind, method: method, crc32: crc, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
        }
        return entries
    }

    static func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), path.utf8.count <= 1024 else {
            throw error("unsafe path \(path)")
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != ".", component != ".." else { throw error("unsafe path \(path)") }
        }
    }

    static func passesThroughLink(entryPath: String, target: String, links: Set<String>) -> Bool {
        var components = entryPath.split(separator: "/").dropLast().map(String.init)
        var prefix: [String] = []
        for component in components {
            prefix.append(component)
            if links.contains(prefix.joined(separator: "/")) { return true }
        }
        for part in target.split(separator: "/").dropLast() where part != "." {
            if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(part))
            if links.contains(components.joined(separator: "/")) { return true }
        }
        return false
    }

    static func symlinkStaysInside(entryPath: String, target: String, root: String) -> Bool {
        guard !target.hasPrefix("/"), !target.isEmpty, !target.contains("\0") else { return false }
        var components = entryPath.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { return false }
                components.removeLast()
            } else {
                components.append(String(part))
            }
        }
        return true
    }

    static func inflate(_ input: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (inp: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw error("inflate failed") }
        return output
    }

    static func error(_ message: String) -> RuyioError {
        RuyioError(.sourceInvalid, diagnostic: "zip: \(message)")
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func readUInt16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func readUInt32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}
