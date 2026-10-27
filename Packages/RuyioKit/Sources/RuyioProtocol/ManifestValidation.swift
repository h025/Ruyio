import Foundation
import RuyioCore

/// Structural validation of a manifest before the host trusts any field (plan §7.1, §16 limits).
public enum ManifestValidator {
    public static let maxActions = 256
    public static let maxPresentationKinds = 4
    public static let maxManifestBytes = 1 << 20

    public struct Issue: Sendable, Hashable, CustomStringConvertible {
        public var field: String
        public var reason: String
        public var description: String { "\(field): \(reason)" }
    }

    public static func decode(_ data: Data) throws -> PluginManifest {
        guard data.count <= maxManifestBytes else {
            throw RuyioError(.manifestInvalid, diagnostic: "manifest exceeds \(maxManifestBytes) bytes")
        }
        do {
            return try JSONCoding.decoder().decode(PluginManifest.self, from: data)
        } catch {
            throw RuyioError(.manifestInvalid, diagnostic: String(describing: error))
        }
    }

    public static func issues(in manifest: PluginManifest) -> [Issue] {
        var issues: [Issue] = []
        if manifest.schemaVersion != 1 { issues.append(.init(field: "schemaVersion", reason: "unsupported \(manifest.schemaVersion)")) }
        if manifest.runtime != "native-isolated" { issues.append(.init(field: "runtime", reason: "unsupported runtime")) }
        if !manifest.architectures.contains("arm64") { issues.append(.init(field: "architectures", reason: "arm64 required")) }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(field: "name", reason: "empty")) }
        if !isSafeRelativePath(manifest.bundlePath) || !manifest.bundlePath.hasSuffix(".app") {
            issues.append(.init(field: "bundlePath", reason: "must be a relative .app path inside the package"))
        }
        let expectedPrefix = manifest.bundlePath + "/Contents/MacOS/"
        if !isSafeRelativePath(manifest.executable) || !manifest.executable.hasPrefix(expectedPrefix) {
            issues.append(.init(field: "executable", reason: "must be the main executable inside bundlePath"))
        }
        if negotiateVersion(host: HostInfo.supportedIPCVersions, plugin: manifest.supportedIPC) == nil {
            issues.append(.init(field: "supportedIPC", reason: "no common IPC version"))
        }
        if negotiateVersion(host: HostInfo.supportedUISchemaVersions, plugin: manifest.supportedUISchema) == nil {
            issues.append(.init(field: "supportedUISchema", reason: "no common UI schema version"))
        }
        if Set(manifest.permissions).count != manifest.permissions.count {
            issues.append(.init(field: "permissions", reason: "duplicate permission"))
        }
        if manifest.actions.count > maxActions { issues.append(.init(field: "actions", reason: "more than \(maxActions)")) }
        var seen = Set<ActionID>()
        let viewIDs = Set(manifest.views.map(\.id))
        for action in manifest.actions {
            if !seen.insert(action.id).inserted { issues.append(.init(field: "actions.\(action.id)", reason: "duplicate action id")) }
            let kinds = action.presentations.map(\.kind)
            if Set(kinds).count != kinds.count { issues.append(.init(field: "actions.\(action.id)", reason: "duplicate presentation kind")) }
            if kinds.count > maxPresentationKinds { issues.append(.init(field: "actions.\(action.id)", reason: "too many presentations")) }
            for presentation in action.presentations {
                if presentation.kind == .globalHotkey, let shortcut = presentation.defaultShortcut,
                   KeyShortcut(manifestString: shortcut) == nil {
                    issues.append(.init(field: "actions.\(action.id).defaultShortcut", reason: "unparseable shortcut"))
                }
                if presentation.kind == .finderContextMenu, presentation.contexts == nil {
                    issues.append(.init(field: "actions.\(action.id)", reason: "finder entry requires contexts"))
                }
            }
            if let view = action.opensView, !viewIDs.contains(view) {
                issues.append(.init(field: "actions.\(action.id).opensView", reason: "unknown view \(view)"))
            }
        }
        if !Set(Localization.hostLanguages + [manifest.defaultLocale]).contains(manifest.defaultLocale) {
            issues.append(.init(field: "defaultLocale", reason: "invalid"))
        }
        return issues
    }

    public static func validate(_ manifest: PluginManifest) throws {
        let found = issues(in: manifest)
        if !found.isEmpty {
            throw RuyioError(.manifestInvalid, objectID: manifest.id.rawValue, diagnostic: found.map(\.description).joined(separator: "; "))
        }
    }

    /// Relative path without traversal, absolute components or hidden tricks.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }
}
