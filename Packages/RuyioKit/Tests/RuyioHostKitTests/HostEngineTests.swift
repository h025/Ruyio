import Foundation
import Testing
@testable import RuyioHostKit
import RuyioPersistence
import RuyioProtocol
import RuyioCore

/// Builds a real, ad-hoc signed, sandboxed plugin package around the test executable.
enum PackageFixture {
    static let actions = ["echo", "slow", "crash", "block-main", "storage", "undeclared-capability", "sandbox-probe", "read-path", "network-probe", "storage-read", "version"]

    static func manifest(version: String = "1.0.0", permissions: [Permission] = [.clipboardWrite], schema: Int = 1) -> PluginManifest {
        var manifest = PluginManifest(
            id: PluginID("org.ruyio.test-plugin"), name: "Test Plugin", version: SemanticVersion(version)!,
            bundlePath: "Test.app", executable: "Test.app/Contents/MacOS/RuyioTestPlugin",
            permissions: permissions,
            actions: actions.map { ActionDeclaration(id: ActionID($0), title: $0, presentations: [Presentation(type: .commandPalette, title: $0)]) })
        manifest.storageSchemaVersion = schema
        return manifest
    }

    static func build(sandbox: Bool = true, extraEntitlements: [String: Any] = [:], infoOverrides: [String: Any] = [:],
                      version: String = "1.0.0", failMigration: Bool = false, failHealth: Bool = false, schema: Int = 1) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString)")
        let root = work.appendingPathComponent("Test.ruyioplugin")
        let contents = root.appendingPathComponent("Test.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixture.testPluginExecutable, to: contents.appendingPathComponent("MacOS/RuyioTestPlugin"))
        var info: [String: Any] = [
            "CFBundleExecutable": "RuyioTestPlugin", "CFBundleIdentifier": "org.ruyio.plugin.test",
            "CFBundlePackageType": "APPL", "CFBundleName": "Test", "LSUIElement": true,
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
        ]
        info.merge(infoOverrides) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let manifestData = try JSONCoding.encoder().encode(manifest(version: version, schema: schema))
        if failMigration { try Data().write(to: contents.appendingPathComponent("Resources/fail-migration")) }
        if failHealth { try Data().write(to: contents.appendingPathComponent("Resources/fail-health")) }
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))
        try manifestData.write(to: contents.appendingPathComponent("Resources/manifest.json"))
        var entitlements: [String: Any] = sandbox ? ["com.apple.security.app-sandbox": true] : [:]
        entitlements.merge(extraEntitlements) { $1 }
        let entURL = work.appendingPathComponent("ent.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entURL)
        try ZipFixture.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entURL.path, root.appendingPathComponent("Test.app").path], cwd: work)
        let zip = work.appendingPathComponent("Test.ruyioplugin.zip")
        try ZipFixture.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Test.ruyioplugin", zip.path], cwd: work)
        return zip
    }
}

final class TestBridge: SystemBridge, @unchecked Sendable {
    var pasteboard: [[String: Data]] = []
    func writePasteboard(_ items: [[String: Data]], originToken: String) async throws -> Int { pasteboard = items; return 1 }
    func openWebLink(_ url: URL) async throws {}
    func openTerminal(at directories: [URL]) async throws {}
    func open(_ targets: [URL], withApplicationBundleID bundleID: String) async throws {}
    func reveal(_ urls: [URL]) async {}
    func confirmBatch(title: String, count: Int) async -> Bool { true }
    func chooseApplication(role: String) async -> String? { nil }
    func toggleFinderHiddenFiles() async throws -> Bool { false }
    var capture: Result<CapturedScreen, RuyioError> = .failure(RuyioError(.cancelled))
    var pins: [(data: Data, scale: Double, pluginID: PluginID)] = []
    func captureScreen() async throws -> CapturedScreen { try capture.get() }
    func pinImage(_ data: Data, scale: Double, pluginID: PluginID) async throws { pins.append((data, scale, pluginID)) }
    var placements: [(urls: [URL], location: CGPoint)] = []
    func place(_ urls: [URL], at location: CGPoint) async { placements.append((urls, location)) }
}

@Suite(.serialized)
struct HostEngineTests {
    func makeEngine() throws -> (HostEngine, AppPaths) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        let paths = AppPaths(applicationSupport: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try paths.ensureDirectories()
        let engine = try HostEngine(paths: paths, locale: "zh-Hans")
        engine.setBridge(TestBridge())
        return (engine, paths)
    }

    let id = PluginID("org.ruyio.test-plugin")
    func ref(_ action: String) -> ActionRef { ActionRef(pluginID: id, actionID: ActionID(action)) }

    @Test func firstRunInstallsEnablesAndRunsSandboxedPlugin() async throws {
        let zip = try PackageFixture.build()
        let (engine, _) = try makeEngine()
        try await engine.start(bundledPackages: [zip])
        let status = try #require(await engine.registry.status(id))
        #expect(status.activation == .enabled)
        #expect(status.updateChannel == .bundledWithHost)

        let echo = await engine.invoke(InvocationRequest(ref: ref("echo"), entry: .commandPalette, parameters: ["text": "你好"]))
        #expect(echo.state == .succeeded)
        #expect(echo.output == .notice("echo:你好:zh-Hans"))

        // P0-02 evidence (same machine, ad-hoc signer): the child really runs in its own sandbox.
        let probe = await engine.invoke(InvocationRequest(ref: ref("sandbox-probe"), entry: .commandPalette))
        guard case .notice(let text) = probe.output else { Issue.record("no probe output"); return }
        print("P0-02 sandbox-probe:", text)
        #expect(text.contains("/Library/Containers/org.ruyio.plugin.test/Data"), "\(text)")

        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let read = await engine.invoke(InvocationRequest(ref: ref("read-path"), entry: .commandPalette, parameters: ["path": .string(secret.path)]))
        #expect(read.output == .notice("denied"))

        let network = await engine.invoke(InvocationRequest(ref: ref("network-probe"), entry: .commandPalette))
        guard case .notice(let net) = network.output else { Issue.record("no network output"); return }
        print("P0-02 network-probe:", net, "| read-path:", read.output)
        #expect(net.hasPrefix("blocked"), "\(net)")

        let storage = await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        #expect(storage.output == .notice("中文内容"))
        await engine.shutdown()
    }

    @Test func disableRemovesEntriesAndBlocksInvocation() async throws {
        let zip = try PackageFixture.build()
        let (engine, _) = try makeEngine()
        try await engine.start(bundledPackages: [zip])
        #expect(await engine.registry.snapshot().entries.commands.contains { $0.ref.pluginID == id })
        await engine.disable(id)
        let snapshot = await engine.registry.snapshot()
        #expect(!snapshot.entries.commands.contains { $0.ref.pluginID == id })
        #expect(await engine.supervisor.isRunning(id) == false)
        let report = await engine.invoke(InvocationRequest(ref: ref("echo"), entry: .commandPalette))
        #expect(report.state == .failed)
        #expect(report.error?.code == .pluginNotInvocable)
        #expect(await engine.enable(id) == nil)
        #expect(await engine.invoke(InvocationRequest(ref: ref("echo"), entry: .commandPalette)).state == .succeeded)
        await engine.shutdown()
    }

    @Test func uninstallDefaultThenOfflineRestoreKeepsData() async throws {
        let zip = try PackageFixture.build()
        let (engine, paths) = try makeEngine()
        try await engine.start(bundledPackages: [zip])
        _ = await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        try await engine.uninstall(id, deleteData: false)
        var snapshot = await engine.registry.snapshot()
        #expect(snapshot.plugins.isEmpty)
        #expect(snapshot.restorableDefaults.map(\.id) == [id])

        // Restarting the host must not silently reinstall an uninstalled default.
        let engine2 = try HostEngine(paths: paths, locale: "en")
        engine2.setBridge(TestBridge())
        try await engine2.start(bundledPackages: [zip])
        snapshot = await engine2.registry.snapshot()
        #expect(snapshot.plugins.isEmpty)

        try await engine2.restoreDefault(id)
        #expect(await engine2.registry.status(id)?.activation == .enabled)
        let storage = await engine2.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette))
        #expect(storage.output == .notice("中文内容"))
        await engine2.shutdown()
    }

    @Test func devBuildReplacesRebuiltDefaultWithSameVersionAndKeepsDataAndPreference() async throws {
        let zip = try PackageFixture.build()
        let (engine, paths) = try makeEngine()
        try await engine.start(bundledPackages: [zip])
        #expect(await engine.invoke(InvocationRequest(ref: ref("storage"), entry: .commandPalette)).output == .notice("中文内容"))
        await engine.disable(id)
        let firstDigest = await engine.registry.record(id)?.artifactSHA256
        await engine.shutdown()

        // Same version, different build (e.g. a plugin code change during development).
        let rebuilt = try PackageFixture.build(infoOverrides: ["CFBundleVersion": "2"])
        let engine2 = try HostEngine(paths: paths, locale: "en")
        engine2.setBridge(TestBridge())
        try await engine2.start(bundledPackages: [rebuilt])
        let record = try #require(await engine2.registry.record(id))
        #expect(record.artifactSHA256 == HostEngine.sha256(of: rebuilt))
        #expect(record.artifactSHA256 != firstDigest)
        #expect(await engine2.registry.status(id)?.activation == .disabled)
        #expect(await engine2.enable(id) == nil)
        #expect(await engine2.invoke(InvocationRequest(ref: ref("storage-read"), entry: .commandPalette)).output == .notice("中文内容"))

        // An unchanged package is left alone.
        await engine2.shutdown()
        let engine3 = try HostEngine(paths: paths, locale: "en")
        engine3.setBridge(TestBridge())
        try await engine3.start(bundledPackages: [rebuilt])
        #expect(await engine3.registry.record(id)?.installedAt == record.installedAt)
        await engine3.shutdown()
    }

    @Test func installerRejectsUnsandboxedAndForbiddenPlist() throws {
        let (engine, _) = try makeEngine()
        let unsandboxed = try PackageFixture.build(sandbox: false)
        let preview = try engine.installer.inspect(package: unsandboxed, trust: .bundledDefault)
        #expect(!preview.isInstallable)
        #expect(preview.checks.contains { $0.name == "entitlements" && $0.outcome == .failed })

        let withScheme = try PackageFixture.build(infoOverrides: ["CFBundleURLTypes": [["CFBundleURLSchemes": ["ruyio"]]]])
        let preview2 = try engine.installer.inspect(package: withScheme, trust: .bundledDefault)
        #expect(preview2.checks.contains { $0.name == "bundle" && $0.outcome == .failed })

        let withJIT = try PackageFixture.build(extraEntitlements: ["com.apple.security.cs.allow-jit": true])
        let preview3 = try engine.installer.inspect(package: withJIT, trust: .bundledDefault)
        #expect(!preview3.isInstallable)
    }

    @Test func remoteTrustRequiresDeveloperIDAndNotarization() throws {
        let (engine, _) = try makeEngine()
        let zip = try PackageFixture.build()
        let preview = try engine.installer.inspect(package: zip, trust: .remote)
        #expect(!preview.isInstallable)
        #expect(preview.checks.contains { $0.name == "developerID" && $0.outcome == .failed })
        #expect(preview.checks.contains { $0.name == "notarization" && $0.outcome == .failed })
        engine.installer.discard(preview)
    }

    @Test func crashOfOnDemandPluginKeepsHostWorking() async throws {
        let zip = try PackageFixture.build()
        let (engine, _) = try makeEngine()
        try await engine.start(bundledPackages: [zip])
        let crash = await engine.invoke(InvocationRequest(ref: ref("crash"), entry: .commandPalette))
        #expect(crash.state == .failed)
        // The next invocation starts a fresh process; no crash loop, no host impact.
        let echo = await engine.invoke(InvocationRequest(ref: ref("echo"), entry: .commandPalette, parameters: ["text": "again"]))
        #expect(echo.state == .succeeded)
        await engine.shutdown()
    }
}
