import CryptoKit
import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// How much trust a package needs (PRD §13, plan §7.2).
public enum TrustMode: String, Sendable, Hashable {
    /// Shipped inside the verified host. Ad-hoc allowed only when no official Team ID is configured (dev builds).
    case bundledDefault
    /// Remote formal package: Developer ID, hardened runtime, sandbox, notarized.
    case remote
    /// Developer mode: relaxed signing, sandbox still required, never official IDs.
    case development
}

public struct VerificationCheck: Sendable, Hashable {
    public enum Outcome: String, Sendable { case passed, failed, notChecked }
    public var name: String
    public var outcome: Outcome
    public var detail: String?
}

/// Result of a read-only pre-install inspection (PRD §19.7: "verified" only after real checks).
public struct InstallPreview: Sendable {
    public var manifest: PluginManifest
    public var signing: SigningInfo
    public var checks: [VerificationCheck]
    public var sha256: String
    public var expectedSHA256: String?
    public var trust: TrustMode
    public var stagingBundle: URL
    public var stagingRoot: URL

    public var isInstallable: Bool { !checks.contains { $0.outcome == .failed } }
    public var failureSummary: String { checks.filter { $0.outcome == .failed }.map { "\($0.name): \($0.detail ?? "")" }.joined(separator: "; ") }
}

/// Stages, verifies and commits plugin packages. Shared by first-run defaults, offline restore,
/// remote installs and updates (plan §15.3: one Installer, no special business path).
public final class PluginInstaller: Sendable {
    private let paths: AppPaths
    private let officialTeamID: String

    public init(paths: AppPaths, officialTeamID: String = HostInfo.officialTeamID) {
        self.paths = paths
        self.officialTeamID = officialTeamID
    }

    /// Extracts a `.ruyioplugin.zip` (or copies an unpacked `.ruyioplugin` directory) to staging and verifies it.
    public func inspect(package: URL, trust: TrustMode, expectedSHA256: String? = nil, installedIDs: Set<PluginID> = []) throws -> InstallPreview {
        let stagingRoot = paths.downloads.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = stagingRoot.appendingPathComponent("package", isDirectory: true)
        let digest: String
        do {
            if package.hasDirectoryPath || (try? package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard trust != .remote else { throw RuyioError(.sourceInvalid, diagnostic: "remote packages must be archives") }
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: package, to: packageRoot)
                digest = ""
            } else {
                let data = try Data(contentsOf: package, options: .mappedIfSafe)
                guard data.count <= 200 << 20 else { throw RuyioError(.sourceInvalid, diagnostic: "package exceeds 200 MiB") }
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let expectedSHA256, expectedSHA256.lowercased() != digest {
                    throw RuyioError(.sourceInvalid, diagnostic: "SHA-256 mismatch")
                }
                try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try ZipArchive(data: data).extract(to: packageRoot)
            }
            return try verify(packageRoot: try Self.locatePackageRoot(packageRoot), stagingRoot: stagingRoot, trust: trust,
                              sha256: digest, expectedSHA256: expectedSHA256, installedIDs: installedIDs)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// Moves the verified bundle into Plugins/<identity>/<version>/ atomically and returns the record.
    public func commit(_ preview: InstallPreview, isDefault: Bool, updateChannel: UpdateChannel, source: String? = nil) throws -> InstalledPluginRecord {
        guard preview.isInstallable else { throw RuyioError(.sourceInvalid, diagnostic: preview.failureSummary) }
        let identity = AppPaths.identityDirectoryName(pluginID: preview.manifest.id, teamID: preview.signing.teamID)
        let versionDir = paths.pluginsRoot.appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent(preview.manifest.version.description, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: versionDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: versionDir.path) {
            // Reinstall of the same version replaces the files only after the new copy is in place.
            let old = versionDir.deletingLastPathComponent().appendingPathComponent(".old-\(UUID().uuidString)")
            try fm.moveItem(at: versionDir, to: old)
            do { try fm.moveItem(at: preview.stagingBundle.deletingLastPathComponent(), to: versionDir) }
            catch { try? fm.moveItem(at: old, to: versionDir); throw error }
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: preview.stagingBundle.deletingLastPathComponent(), to: versionDir)
        }
        try? fm.removeItem(at: preview.stagingRoot)
        let bundle = versionDir.appendingPathComponent(preview.manifest.bundlePath)
        let executable = versionDir.appendingPathComponent(preview.manifest.executable)
        return try InstalledPluginRecord(manifest: preview.manifest, installPath: bundle, executablePath: executable,
                                         teamID: preview.signing.teamID, signingIdentifier: preview.signing.identifier,
                                         isDevelopment: preview.trust == .development, isDefault: isDefault,
                                         updateChannel: updateChannel, source: source, artifactSHA256: preview.sha256.isEmpty ? nil : preview.sha256)
    }

    public func discard(_ preview: InstallPreview) {
        try? FileManager.default.removeItem(at: preview.stagingRoot)
    }

    /// Removes installed code for a plugin. Data is handled separately.
    public func removeCode(pluginID: PluginID, teamID: String?) throws {
        let dir = paths.pluginsRoot.appendingPathComponent(AppPaths.identityDirectoryName(pluginID: pluginID, teamID: teamID))
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: Verification

    func verify(packageRoot: URL, stagingRoot: URL, trust: TrustMode, sha256: String, expectedSHA256: String?, installedIDs: Set<PluginID>) throws -> InstallPreview {
        var checks: [VerificationCheck] = []
        func check(_ name: String, _ passed: Bool, _ detail: String? = nil) {
            checks.append(VerificationCheck(name: name, outcome: passed ? .passed : .failed, detail: passed ? nil : detail))
        }

        let outerURL = packageRoot.appendingPathComponent("manifest.json")
        let outerData = try Data(contentsOf: outerURL)
        let manifest = try ManifestValidator.decode(outerData)
        try ManifestValidator.validate(manifest)
        let bundle = packageRoot.appendingPathComponent(manifest.bundlePath)
        let innerData = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/manifest.json"))
        // The signed inner manifest is authoritative; the outer copy must match byte for byte (plan §7.1).
        check("manifest", innerData == outerData, "outer and signed manifest differ")

        let osOK = manifest.minimumMacOSVersion <= OSVersion.current
        let hostOK = manifest.minimumHostVersion.precedence(comparedTo: HostInfo.version) != .orderedDescending
            || (HostInfo.version.isPrerelease && manifest.minimumHostVersion.major <= HostInfo.version.major)
        let compatible = osOK && hostOK
        check("compatibility", compatible, "requires macOS \(manifest.minimumMacOSVersion) / host \(manifest.minimumHostVersion)")

        let executable = packageRoot.appendingPathComponent(manifest.executable)
        check("architecture", MachO.containsARM64(executable), "arm64 slice missing")

        let infoPlist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let plistProblems = Self.infoPlistViolations(infoPlist, manifest: manifest)
        check("bundle", plistProblems.isEmpty, plistProblems.joined(separator: ", "))
        let nestedProblems = Self.nestedCodeViolations(bundle: bundle, mainExecutable: executable)
        check("nestedCode", nestedProblems.isEmpty, nestedProblems.prefix(5).joined(separator: ", "))

        let signing = CodeSigning.inspect(bundle: bundle, checkRevocation: trust == .remote)
        check("signature", signing.isValid, signing.validationError ?? "invalid signature")
        if let identifier = signing.identifier, let bundleID = infoPlist["CFBundleIdentifier"] as? String {
            check("signingIdentity", identifier == bundleID, "signing identifier differs from CFBundleIdentifier")
        }
        let entitlementProblems = EntitlementPolicy.violations(signing, declaresNetwork: manifest.permissions.contains(.networkClient))
        check("entitlements", entitlementProblems.isEmpty, entitlementProblems.joined(separator: ", "))

        switch trust {
        case .remote:
            check("developerID", !signing.isAdHoc && signing.teamID?.isEmpty == false, "Developer ID signature required")
            check("hardenedRuntime", signing.hasHardenedRuntime, "Hardened Runtime required")
            let assessment = CodeSigning.assessExecution(bundle: bundle)
            check("notarization", assessment.passed, assessment.detail ?? "Gatekeeper assessment failed")
            if manifest.id.isOfficialNamespace {
                check("officialNamespace", !officialTeamID.isEmpty && signing.teamID == officialTeamID, "app.ruyio. IDs are reserved for the official team")
            }
        case .bundledDefault:
            if !officialTeamID.isEmpty {
                check("officialTeam", signing.teamID == officialTeamID, "default plugin not signed by the official team")
            }
        case .development:
            check("developmentID", !manifest.id.isOfficialNamespace, "development plugins may not use app.ruyio. IDs")
            check("developmentConflict", !installedIDs.contains(manifest.id), "ID already used by an installed plugin")
        }
        if let expectedSHA256 {
            check("sha256", expectedSHA256.lowercased() == sha256, "SHA-256 mismatch")
        }
        return InstallPreview(manifest: manifest, signing: signing, checks: checks, sha256: sha256, expectedSHA256: expectedSHA256,
                              trust: trust, stagingBundle: bundle, stagingRoot: stagingRoot)
    }

    /// Info.plist allowlist (plan §7.1): agent app, matching executable, no LaunchServices registrations.
    static func infoPlistViolations(_ plist: [String: Any], manifest: PluginManifest) -> [String] {
        var problems: [String] = []
        let agent = (plist["LSUIElement"] as? Bool) == true || (plist["LSUIElement"] as? String) == "1"
            || (plist["LSBackgroundOnly"] as? Bool) == true
        if !agent { problems.append("LSUIElement required") }
        // The launched file must be exactly the bundle's main executable, the one the signature checks cover.
        if let main = plist["CFBundleExecutable"] as? String, !main.contains("/") {
            if manifest.executable != manifest.bundlePath + "/Contents/MacOS/" + main { problems.append("executable is not the bundle's main executable") }
        } else {
            problems.append("CFBundleExecutable missing or invalid")
        }
        let forbidden = ["CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations",
                         "NSServices", "NSExtension", "LSEnvironment", "OSAScriptingDefinition", "SMPrivilegedExecutables"]
        for key in forbidden where plist[key] != nil { problems.append("forbidden key \(key)") }
        if let bundleID = plist["CFBundleIdentifier"] as? String, bundleID.hasPrefix("app.ruyio.mac") {
            problems.append("bundle identifier collides with the host")
        }
        return problems
    }

    /// No separately launchable code (plan §7.1): nested apps, XPC services, extensions, login items, launchd
    /// plists or extra executables would run under their own entitlements, outside the checks above.
    /// In-process libraries and frameworks are allowed; they are covered by the bundle signature.
    static func nestedCodeViolations(bundle: URL, mainExecutable: URL) -> [String] {
        let launchable: Set<String> = ["app", "xpc", "appex", "systemextension", "kext", "driverkit"]
        let forbiddenDirectories = ["Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Library/LaunchAgents",
                                    "Contents/Library/LaunchDaemons", "Contents/XPCServices", "Contents/PlugIns", "Contents/Library/SystemExtensions"]
        var problems: [String] = []
        let root = bundle.standardizedFileURL.path
        let main = mainExecutable.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) else {
            return ["unreadable bundle"]
        }
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if launchable.contains(url.pathExtension.lowercased()) || forbiddenDirectories.contains(relative) {
                    problems.append(relative)
                    walker.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, url.standardizedFileURL.resolvingSymlinksInPath().path != main else { continue }
            if MachO.isExecutableImage(url) { problems.append(relative) }
        }
        return problems
    }

    /// Accepts either a package root (manifest.json at top) or a single wrapping directory.
    static func locatePackageRoot(_ root: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { return root }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        if children.count == 1, FileManager.default.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) {
            return children[0]
        }
        throw RuyioError(.sourceInvalid, diagnostic: "package has no manifest.json")
    }
}
