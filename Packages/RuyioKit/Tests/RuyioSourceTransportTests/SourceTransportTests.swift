import Foundation
import Testing
@testable import RuyioSourceTransport
import RuyioCore

struct SourceAddressTests {
    @Test func parsesGitHubForms() throws {
        #expect(try SourceAddress.parse("  https://github.com/ruyio/plugins  ") == .github(owner: "ruyio", repo: "plugins", treeRest: []))
        #expect(try SourceAddress.parse("https://github.com/ruyio/plugins.git") == .github(owner: "ruyio", repo: "plugins", treeRest: []))
        #expect(try SourceAddress.parse("https://github.com/ruyio/plugins/tree/feature/x/market") == .github(owner: "ruyio", repo: "plugins", treeRest: ["feature", "x", "market"]))
    }

    @Test func rejectsInsecureAndCredentialedSources() {
        #expect(throws: RuyioError.self) { try SourceAddress.parse("http://example.com/ruyio-market.json") }
        #expect(throws: RuyioError.self) { try SourceAddress.parse("file:///etc/passwd") }
        #expect(throws: RuyioError.self) { try SourceAddress.parse("https://user:pw@example.com/x.json") }
        #expect(throws: RuyioError.self) { try SourceAddress.parse("https://example.com/x.json?token=abc") }
        #expect(throws: RuyioError.self) { try SourceAddress.parse("https://github.com/onlyowner") }
    }

    @Test func detectsPackages() throws {
        #expect(try SourceAddress.parse("https://example.com/Foo.ruyioplugin.zip").isPackageURL)
        #expect(!(try SourceAddress.parse("https://example.com/ruyio-plugin.json").isPackageURL))
    }
}

struct NetworkPolicyTests {
    @Test(arguments: [[10, 0, 0, 1], [127, 0, 0, 1], [169, 254, 1, 1], [172, 16, 0, 1], [192, 168, 1, 1], [0, 0, 0, 0],
                      [100, 64, 0, 1], [198, 18, 0, 1], [224, 0, 0, 1], [255, 255, 255, 255]] as [[UInt8]])
    func blocksPrivateIPv4(_ bytes: [UInt8]) { #expect(!NetworkPolicy.isPublic(ipv4: bytes)) }

    @Test func allowsPublicIPv4() {
        #expect(NetworkPolicy.isPublic(ipv4: [1, 1, 1, 1]))
        #expect(NetworkPolicy.isPublic(ipv4: [140, 82, 112, 3]))
    }

    @Test func ipv6Rules() {
        var loopback = [UInt8](repeating: 0, count: 16); loopback[15] = 1
        #expect(!NetworkPolicy.isPublic(ipv6: loopback))
        var mapped = [UInt8](repeating: 0, count: 16); mapped[10] = 0xFF; mapped[11] = 0xFF; mapped[12] = 192; mapped[13] = 168; mapped[14] = 0; mapped[15] = 1
        #expect(!NetworkPolicy.isPublic(ipv6: mapped))
        var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xFE; linkLocal[1] = 0x80
        #expect(!NetworkPolicy.isPublic(ipv6: linkLocal))
        var ula = [UInt8](repeating: 0, count: 16); ula[0] = 0xFD
        #expect(!NetworkPolicy.isPublic(ipv6: ula))
        var global = [UInt8](repeating: 0, count: 16); global[0] = 0x26; global[1] = 0x06; global[15] = 1
        #expect(NetworkPolicy.isPublic(ipv6: global))
    }

    @Test func refusesLocalNamesAndLoopbackLiterals() {
        #expect(throws: RuyioError.self) { try NetworkPolicy.checkHost("localhost") }
        #expect(throws: RuyioError.self) { try NetworkPolicy.checkHost("printer.local") }
        #expect(throws: RuyioError.self) { try NetworkPolicy.checkHost("127.0.0.1") }
        #expect(throws: RuyioError.self) { try NetworkPolicy.checkHost("10.1.2.3") }
        #expect(throws: RuyioError.self) { try NetworkPolicy.checkHost("::1") }
    }
}

struct DescriptorTests {
    static let sha = String(repeating: "a", count: 64)
    static let shaB = String(repeating: "b", count: 64)

    func release(_ version: String, host: String = "1.0.0", os: String = "15.0", arch: [String] = ["arm64"], sha: String = DescriptorTests.sha) -> String {
        "{\"version\":\"\(version)\",\"minimumHostVersion\":\"\(host)\",\"minimumMacOSVersion\":\"\(os)\",\"architectures\":\(arch.description),\"artifact\":\"releases/\(version)/P.ruyioplugin.zip\",\"sha256\":\"\(sha)\"}"
    }

    func descriptor(_ releases: [String]) -> Data {
        Data("{\"schemaVersion\":1,\"kind\":\"plugin\",\"id\":\"org.example.image-converter\",\"name\":\"Image Converter\",\"releases\":[\(releases.joined(separator: ","))]}".utf8)
    }

    @Test func picksHighestCompatibleStableRelease() throws {
        let d = try PluginDescriptor.decode(descriptor([release("1.0.0"), release("1.2.0"), release("2.0.0-beta.1"), release("1.3.0", os: "99.0"), release("1.4.0", arch: ["x86_64"])]))
        #expect(d.bestRelease(host: SemanticVersion("1.0.0")!)?.version == SemanticVersion("1.2.0"))
        #expect(d.bestRelease(host: SemanticVersion("1.0.0")!, includePrerelease: true)?.version == SemanticVersion("2.0.0-beta.1"))
    }

    @Test func rejectsConflictingHashesAndMissingHashes() {
        #expect(throws: RuyioError.self) { try PluginDescriptor.decode(descriptor([release("1.0.0"), release("1.0.0", sha: DescriptorTests.shaB)])) }
        #expect(throws: RuyioError.self) { try PluginDescriptor.decode(descriptor([release("1.0.0", sha: "nothex")])) }
    }

    @Test func detectsKindAndMarketLimits() throws {
        #expect(try DescriptorKind.detect(Data("{\"schemaVersion\":1,\"kind\":\"market\"}".utf8)) == .market)
        #expect(throws: RuyioError.self) { try DescriptorKind.detect(Data("{\"schemaVersion\":1}".utf8)) }
        let dup = Data("{\"schemaVersion\":1,\"kind\":\"market\",\"id\":\"m\",\"name\":\"M\",\"plugins\":[{\"id\":\"a.b\",\"manifest\":\"x\"},{\"id\":\"a.b\",\"manifest\":\"y\"}]}".utf8)
        #expect(throws: RuyioError.self) { try MarketDescriptor.decode(dup) }
    }

    @Test func artifactURLsResolveRelativeAndStayHTTPS() throws {
        let base = URL(string: "https://raw.githubusercontent.com/o/r/abc/plugins/x/ruyio-plugin.json")!
        #expect(try SourceResolver.artifactURL("releases/1.0/P.zip", relativeTo: base).absoluteString == "https://raw.githubusercontent.com/o/r/abc/plugins/x/releases/1.0/P.zip")
        #expect(throws: RuyioError.self) { try SourceResolver.artifactURL("http://evil.example/P.zip", relativeTo: base) }
        #expect(throws: RuyioError.self) { try SourceResolver.artifactURL("file:///tmp/P.zip", relativeTo: base) }
    }
}
