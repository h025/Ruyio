import Testing
@testable import RuyioCore

struct IdentifierTests {
    @Test(arguments: ["app.ruyio.clipboard-history", "org.example.image-converter", "a.b"])
    func validPluginIDs(_ raw: String) { #expect(PluginID(rawValue: raw) != nil) }

    @Test(arguments: ["", "noDots", "Upper.Case", "a..b", "-a.b", "a.b-", "a.b/c", "a b.c", "中文.id"])
    func invalidPluginIDs(_ raw: String) { #expect(PluginID(rawValue: raw) == nil) }

    @Test func officialNamespace() {
        #expect(PluginID("app.ruyio.clipboard-history").isOfficialNamespace)
        #expect(!PluginID("org.example.x").isOfficialNamespace)
    }
}

struct SemanticVersionTests {
    @Test func parsesAndOrders() throws {
        let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.2.0", "2.0.0"]
        let versions = try order.map { try #require(SemanticVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
    }

    @Test(arguments: ["1.0", "01.0.0", "1.0.0-", "1.0.0-01", "v1.0.0", "1.0.0+", "1.x.0"])
    func rejectsInvalid(_ raw: String) { #expect(SemanticVersion(raw) == nil) }

    @Test func buildMetadataIgnoredForPrecedence() throws {
        let a = try #require(SemanticVersion("1.0.0+1"))
        let b = try #require(SemanticVersion("1.0.0+2"))
        #expect(!(a < b) && !(b < a))
        #expect(a.description == "1.0.0+1")
    }
}

struct PluginStatusTests {
    @Test func dimensionsStayIndependent() {
        let status = PluginStatus(installation: .installed, activation: .enabled, update: .available, source: .orphaned, updateChannel: .market)
        #expect(status.badges == [.updateAvailable, .sourceRemoved])
        #expect(status.primaryBadge == .updateAvailable)
        #expect(!status.needsAttention)
        #expect(status.listGroup == .enabled)
    }

    @Test func badgePriority() {
        let status = PluginStatus(activation: .runtimeFailed, update: .available, source: .conflicted, updateChannel: .market)
        #expect(status.primaryBadge == .runtimeFailed)
        #expect(status.needsAttention)
    }

    @Test func disabledWithErrorNeedsAttention() {
        let status = PluginStatus(activation: .disabled, updateChannel: .market, lastErrorCode: "plugin.handshakeFailed")
        #expect(status.needsAttention)
        #expect(status.listGroup == .disabled)
    }

    @Test func restorableDefault() {
        let status = PluginStatus(installation: .notInstalled, activation: .disabled, updateChannel: .bundledWithHost, isRestorableDefault: true)
        #expect(status.listGroup == .restorableDefault)
    }
}

struct ExecutionStateTests {
    @Test func allowedTransitions() {
        #expect(ExecutionState.requested.canTransition(to: .validating))
        #expect(ExecutionState.validating.canTransition(to: .awaitingInput))
        #expect(ExecutionState.running.canTransition(to: .outcomeUnknown))
        #expect(!ExecutionState.succeeded.canTransition(to: .running))
        #expect(!ExecutionState.requested.canTransition(to: .running))
    }
}

struct KeyShortcutTests {
    @Test func parsesManifestStrings() throws {
        let shortcut = try #require(KeyShortcut(manifestString: "command+shift+v"))
        #expect(shortcut.displayString == "⇧⌘V")
        #expect(shortcut.manifestString == "shift+command+v")
        #expect(KeyShortcut(manifestString: "hyper+v") == nil)
    }

    @Test func rejectsSystemAndInputSourceShortcuts() throws {
        let inputSource = try #require(KeyShortcut(manifestString: "control+option+space"))
        #expect(inputSource.rejection() == .systemReserved)
        let optionOnly = try #require(KeyShortcut(manifestString: "option+k"))
        #expect(optionOnly.rejection(on: OSVersion(major: 15, minor: 1)) == .optionOnlyOnEarlySequoia)
        #expect(optionOnly.rejection(on: OSVersion(major: 15, minor: 2)) == nil)
        #expect(KeyShortcut(manifestString: "shift+a")?.rejection() == .noModifier)
    }

    @Test func versionNegotiation() {
        #expect(negotiateVersion(host: [1, 2], plugin: [2, 3]) == 2)
        #expect(negotiateVersion(host: [1], plugin: [2]) == nil)
    }
}
