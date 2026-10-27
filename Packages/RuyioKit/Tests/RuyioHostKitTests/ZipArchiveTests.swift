import Foundation
import Testing
@testable import RuyioHostKit

/// Builds archives with the system `ditto`/`zip` tools only as test fixtures; production code never shells out.
enum ZipFixture {
    static func run(_ tool: String, _ args: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ZipArchiveTests {
    @Test func extractsDittoBundleWithExecutableBitsAndInternalSymlink() throws {
        let work = ZipFixture.tempDir()
        let app = work.appendingPathComponent("Plugin.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("Plugin")
        try Data(repeating: 0x41, count: 300_000).write(to: exe)
        chmod(exe.path, 0o755)
        try "manifest".write(to: work.appendingPathComponent("Plugin.app/Contents/info.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("Plugin.app/Contents/Current").path, withDestinationPath: "MacOS")
        let zip = work.appendingPathComponent("p.zip")
        try ZipFixture.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Plugin.app", zip.path], cwd: work)

        let archive = try ZipArchive(url: zip)
        let out = ZipFixture.tempDir().appendingPathComponent("x")
        try archive.extract(to: out)
        let extracted = out.appendingPathComponent("Plugin.app/Contents/MacOS/Plugin")
        #expect(try Data(contentsOf: extracted).count == 300_000)
        #expect(FileManager.default.isExecutableFile(atPath: extracted.path))
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("Plugin.app/Contents/Current").path)
        #expect(link == "MacOS")
    }

    @Test func rejectsTraversalAbsoluteAndEscapingSymlinks() throws {
        #expect(throws: (any Error).self) { try ZipArchive.validate(path: "../evil") }
        #expect(throws: (any Error).self) { try ZipArchive.validate(path: "/etc/passwd") }
        #expect(throws: (any Error).self) { try ZipArchive.validate(path: "a/../../b") }
        #expect(throws: (any Error).self) { try ZipArchive.validate(path: "a\\b") }
        #expect(ZipArchive.symlinkStaysInside(entryPath: "A.app/Contents/Current", target: "MacOS", root: "/r"))
        #expect(ZipArchive.symlinkStaysInside(entryPath: "A.app/Contents/Frameworks/X.framework/X", target: "Versions/Current/X", root: "/r"))
        #expect(!ZipArchive.symlinkStaysInside(entryPath: "A.app/link", target: "../../etc", root: "/r"))
        #expect(!ZipArchive.symlinkStaysInside(entryPath: "link", target: "/etc/passwd", root: "/r"))
    }

    @Test func rejectsEscapingSymlinkInRealArchive() throws {
        let work = ZipFixture.tempDir()
        try FileManager.default.createDirectory(at: work.appendingPathComponent("P"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: work.appendingPathComponent("P/escape").path, withDestinationPath: "../../../../tmp")
        let zip = work.appendingPathComponent("s.zip")
        try ZipFixture.run("/usr/bin/zip", ["-q", "-y", "-r", zip.path, "P"], cwd: work)
        let archive = try ZipArchive(url: zip)
        #expect(throws: (any Error).self) { try archive.extract(to: ZipFixture.tempDir().appendingPathComponent("o")) }
    }

    @Test func rejectsZipBombRatioAndTotals() throws {
        let work = ZipFixture.tempDir()
        try Data(count: 50 << 20).write(to: work.appendingPathComponent("zeros.bin"))
        let zip = work.appendingPathComponent("bomb.zip")
        try ZipFixture.run("/usr/bin/zip", ["-q", "-9", zip.path, "zeros.bin"], cwd: work)
        #expect(throws: (any Error).self) { _ = try ZipArchive(url: zip) }
        var small = ZipArchive.Limits()
        small.maxRatio = 1_000_000
        small.maxTotalUncompressed = 1 << 20
        #expect(throws: (any Error).self) { _ = try ZipArchive(url: zip, limits: small) }
    }

    @Test func detectsCorruption() throws {
        let work = ZipFixture.tempDir()
        try String(repeating: "hello ruyio ", count: 1000).write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let zip = work.appendingPathComponent("c.zip")
        try ZipFixture.run("/usr/bin/zip", ["-q", zip.path, "a.txt"], cwd: work)
        var bytes = try Data(contentsOf: zip)
        let archive = try ZipArchive(data: bytes)
        let entry = try #require(archive.entry(named: "a.txt"))
        let header = entry.localHeaderOffset
        let dataStart = header + 30 + Int(bytes.readUInt16(header + 26)) + Int(bytes.readUInt16(header + 28))
        bytes[dataStart + entry.compressedSize / 2] ^= 0xFF
        let corrupted = try ZipArchive(data: bytes)
        #expect(throws: (any Error).self) { _ = try corrupted.contents(of: entry) }
    }

    @Test func crc32KnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
