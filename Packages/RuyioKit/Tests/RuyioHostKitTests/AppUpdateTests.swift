import CryptoKit
import Foundation
import Security
import Testing
@testable import RuyioHostKit
import RuyioCore

@Suite(.serialized)
struct AppUpdateTests {
    let feed = URL(string: "https://example.com/appcast.xml")!
    let archiveURL = "https://example.com/Ruyio-1.2.0.zip"

    func appcast(version: String = "1.2.0", url: String? = nil, signature: String = "c2ln", length: Int = 0, minimumOS: String = "15.0") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Ruyio</title>
            <item>
              <title>Ruyio \(version)</title>
              <sparkle:version>\(version)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <sparkle:minimumSystemVersion>\(minimumOS)</sparkle:minimumSystemVersion>
              <sparkle:releaseNotesLink>https://github.com/h025/Ruyio/releases/tag/v\(version)</sparkle:releaseNotesLink>
              <enclosure url="\(url ?? archiveURL)" length="\(length)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
            </item>
          </channel>
        </rss>
        """.utf8)
    }

    /// A signed stand-in for Ruyio.app, zipped the way Scripts/release.sh does.
    static func makeApp(version: String, signer: SigningFixture.Identity, marker: String = "new") throws -> (zip: Data, app: URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("appupd-\(UUID().uuidString)")
        let contents = work.appendingPathComponent("Ruyio.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixture.testPluginExecutable, to: contents.appendingPathComponent("MacOS/Ruyio"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker"))
        let info: [String: Any] = ["CFBundleExecutable": "Ruyio", "CFBundleIdentifier": "app.ruyio.update-test", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try ZipFixture.run("/usr/bin/codesign", ["--force", "--sign", signer.hash, "--keychain", signer.keychain.path, "Ruyio.app"], cwd: work)
        try ZipFixture.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Ruyio.app", "Ruyio.zip"], cwd: work)
        return (try Data(contentsOf: work.appendingPathComponent("Ruyio.zip")), work.appendingPathComponent("Ruyio.app"))
    }

    static func designatedRequirement(of app: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { throw CocoaError(.fileReadUnknown) }
        return text as String
    }

    func service(_ fetcher: FakeFetcher, key: Curve25519.Signing.PrivateKey, requirement: String, installed: URL? = nil) -> AppUpdateService {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("appupd-staging-\(UUID().uuidString)")
        let configuration = AppUpdateService.Configuration(
            feedURL: feed, publicKey: key.publicKey.rawRepresentation, currentVersion: SemanticVersion("1.1.0")!,
            installedApp: installed ?? URL(fileURLWithPath: "/Applications/Ruyio.app"), designatedRequirement: requirement)
        return AppUpdateService(configuration: configuration, fetcher: fetcher, staging: staging)
    }

    @Test func appcastParsingKeepsCompleteHTTPSItemsOnly() throws {
        let items = try Appcast.parse(appcast(length: 42))
        #expect(items.count == 1)
        #expect(items[0].version == SemanticVersion("1.2.0"))
        #expect(items[0].length == 42)
        #expect(items[0].minimumSystemVersion == OSVersion("15.0"))
        #expect(items[0].releaseNotesURL?.absoluteString == "https://github.com/h025/Ruyio/releases/tag/v1.2.0")
        #expect(try Appcast.parse(appcast(url: "http://example.com/Ruyio.zip")).isEmpty)
        #expect(try Appcast.parse(appcast(signature: "")).isEmpty)
        #expect(throws: RuyioError.self) { try Appcast.parse(Data("not xml <".utf8)) }
    }

    @Test func onlyNewerCompatibleReleasesAreOffered() throws {
        let item = { (version: String, os: String) in
            try #require(try Appcast.parse(self.appcast(version: version, minimumOS: os)).first)
        }
        let current = SemanticVersion("1.1.0")!
        let os = OSVersion(major: 15, minor: 4)
        #expect(AppUpdateService.newest([try item("1.0.9", "15.0"), try item("1.1.0", "15.0")], above: current, os: os) == nil)
        #expect(AppUpdateService.newest([try item("1.2.0", "26.0")], above: current, os: os) == nil)
        #expect(AppUpdateService.newest([try item("1.3.0-beta.1", "15.0")], above: current, os: os) == nil)
        #expect(AppUpdateService.newest([try item("1.2.0", "15.0"), try item("1.3.0", "15.4")], above: current, os: os)?.version == SemanticVersion("1.3.0"))
    }

    @Test func checkReportsTheUpdateToObservers() async throws {
        let fetcher = FakeFetcher()
        fetcher.files[feed.absoluteString] = appcast()
        let updates = service(fetcher, key: Curve25519.Signing.PrivateKey(), requirement: "identifier \"x\"")
        let seen = Locked<[SemanticVersion?]>([])
        await updates.observe { item in seen.withLock { $0.append(item?.version) } }
        #expect(try await updates.check()?.version == SemanticVersion("1.2.0"))
        #expect(seen.withLock { $0 } == [SemanticVersion("1.2.0")])
    }

    @Test func prepareVerifiesSignatureAndPublisherBeforeHandingOutTheApp() async throws {
        let publisher = try SigningFixture.first.get()
        let key = Curve25519.Signing.PrivateKey()
        let current = try Self.makeApp(version: "1.1.0", signer: publisher)
        let requirement = try Self.designatedRequirement(of: current.app)
        #expect(requirement.contains("certificate leaf"))

        let genuine = try Self.makeApp(version: "1.2.0", signer: publisher)
        let fetcher = FakeFetcher()
        fetcher.files[archiveURL] = genuine.zip
        let goodItem = try #require(try Appcast.parse(appcast(signature: try key.signature(for: genuine.zip).base64EncodedString(), length: genuine.zip.count)).first)
        let updates = service(fetcher, key: key, requirement: requirement)
        let staged = try await updates.prepare(goodItem)
        #expect(try String(contentsOf: staged.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8) == "new")

        // Signed with another key, or a length that does not match: rejected before unpacking.
        let forged = try #require(try Appcast.parse(appcast(signature: try Curve25519.Signing.PrivateKey().signature(for: genuine.zip).base64EncodedString())).first)
        await #expect(throws: RuyioError.self) { _ = try await updates.prepare(forged) }
        var truncated = goodItem
        truncated.length = Int64(genuine.zip.count - 1)
        await #expect(throws: RuyioError.self) { _ = try await updates.prepare(truncated) }

        // Correct EdDSA signature, but the app comes from another certificate: someone else's build.
        let impostor = try Self.makeApp(version: "1.2.0", signer: try SigningFixture.second.get())
        fetcher.files[archiveURL] = impostor.zip
        let impostorItem = try #require(try Appcast.parse(appcast(signature: try key.signature(for: impostor.zip).base64EncodedString())).first)
        do {
            _ = try await updates.prepare(impostorItem)
            Issue.record("impostor accepted")
        } catch let error as RuyioError {
            #expect(error.diagnostic?.contains("same publisher") == true)
        }

        // The app inside must be the version the appcast promised.
        let mislabeled = try Self.makeApp(version: "1.1.5", signer: publisher)
        fetcher.files[archiveURL] = mislabeled.zip
        let mislabeledItem = try #require(try Appcast.parse(appcast(signature: try key.signature(for: mislabeled.zip).base64EncodedString())).first)
        await #expect(throws: RuyioError.self) { _ = try await updates.prepare(mislabeledItem) }
    }

    @Test func installSwapsAtomicallyAndKeepsThePreviousVersionAside() async throws {
        let publisher = try SigningFixture.first.get()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("appupd-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installed = folder.appendingPathComponent("Ruyio.app")
        try FileManager.default.copyItem(at: try Self.makeApp(version: "1.1.0", signer: publisher, marker: "old").app, to: installed)
        let staged = try Self.makeApp(version: "1.2.0", signer: publisher, marker: "new").app
        let updates = service(FakeFetcher(), key: Curve25519.Signing.PrivateKey(), requirement: "", installed: installed)
        #expect(updates.installProblem == nil)

        let previous = try await updates.install(staged: staged)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: previous.appendingPathComponent("Contents/Resources/marker"), encoding: .utf8) == "old")
        #expect(previous.deletingLastPathComponent() == installed.deletingLastPathComponent())

        AppUpdateService.removeLeftovers(beside: installed)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(AppUpdateService.installProblem(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Ruyio.app")) == .translocated)
    }

    @Test func relauncherWaitsForTheOldProcessThenRemovesLeftovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("appupd-relaunch-\(UUID().uuidString)")
        let leftover = folder.appendingPathComponent("previous.app")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        // A missing app: `open` only fails, so the test never launches anything.
        let updates = service(FakeFetcher(), key: Curve25519.Signing.PrivateKey(), requirement: "",
                              installed: folder.appendingPathComponent("Missing.app"))
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["1"]
        try old.run()
        try updates.relaunch(after: old.processIdentifier, removing: [leftover])
        #expect(FileManager.default.fileExists(atPath: leftover.path), "must wait for the old process")
        old.waitUntilExit()
        for _ in 0..<50 where FileManager.default.fileExists(atPath: leftover.path) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }
}

/// Minimal lock box for observer callbacks in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
