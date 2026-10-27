import Foundation
import RuyioCore
import RuyioProtocol

/// `ruyio-plugin.json` (PRD §7.6.5). Identity and installable releases only; never executable code.
public struct PluginDescriptor: Codable, Sendable, Hashable {
    public struct Release: Codable, Sendable, Hashable {
        public var version: SemanticVersion
        public var minimumHostVersion: SemanticVersion
        public var minimumMacOSVersion: OSVersion
        public var architectures: [String]
        public var artifact: String
        public var sha256: String
        public var releaseNotes: String?
    }

    public var schemaVersion: Int
    public var kind: String
    public var id: PluginID
    public var name: String
    public var description: String?
    public var source: String?
    public var releases: [Release]

    public static let maxBytes = 1 << 20
    public static let maxReleases = 200

    public static func decode(_ data: Data) throws -> PluginDescriptor {
        guard data.count <= maxBytes else { throw RuyioError(.sourceInvalid, diagnostic: "descriptor exceeds 1 MiB") }
        let descriptor: PluginDescriptor
        do { descriptor = try JSONCoding.decoder().decode(PluginDescriptor.self, from: data) }
        catch { throw RuyioError(.sourceInvalid, diagnostic: "invalid ruyio-plugin.json: \(error)") }
        try descriptor.validate()
        return descriptor
    }

    public func validate() throws {
        guard schemaVersion == 1, kind == "plugin" else { throw RuyioError(.sourceInvalid, diagnostic: "unsupported descriptor") }
        guard releases.count <= Self.maxReleases else { throw RuyioError(.sourceInvalid, diagnostic: "too many releases") }
        var hashes: [String: String] = [:]
        for release in releases {
            let sha = release.sha256.lowercased()
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { throw RuyioError(.sourceInvalid, diagnostic: "release \(release.version) lacks SHA-256") }
            // A version number may never point to two different artifacts (PRD §7.6.5).
            if let existing = hashes[release.version.description], existing != sha {
                throw RuyioError(.sourceInvalid, diagnostic: "version \(release.version) has conflicting hashes")
            }
            hashes[release.version.description] = sha
        }
    }

    /// Highest compatible stable release; prereleases only when explicitly allowed (PRD §7.6.5).
    public func bestRelease(host: SemanticVersion = HostInfo.version, os: OSVersion = .current, includePrerelease: Bool = false) -> Release? {
        releases.filter { release in
            (includePrerelease || !release.version.isPrerelease)
                && release.architectures.contains("arm64")
                && release.minimumMacOSVersion <= os
                && (release.minimumHostVersion.precedence(comparedTo: host) != .orderedDescending
                    || (host.isPrerelease && release.minimumHostVersion.major <= host.major))
        }
        .max { $0.version < $1.version }
    }
}

/// `ruyio-market.json` (PRD §7.6.6). Lists descriptors; grants nothing.
public struct MarketDescriptor: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var id: PluginID
        public var manifest: String
        /// Display hints without verification value (plan §14.4).
        public var name: String?
        public var summary: String?
    }

    public var schemaVersion: Int
    public var kind: String
    public var id: String
    public var name: String
    public var description: String?
    public var plugins: [Entry]

    public static let maxBytes = 5 << 20
    public static let maxEntries = 5_000

    public static func decode(_ data: Data) throws -> MarketDescriptor {
        guard data.count <= maxBytes else { throw RuyioError(.sourceInvalid, diagnostic: "market index exceeds 5 MiB") }
        let market: MarketDescriptor
        do { market = try JSONCoding.decoder().decode(MarketDescriptor.self, from: data) }
        catch { throw RuyioError(.sourceInvalid, diagnostic: "invalid ruyio-market.json: \(error)") }
        guard market.schemaVersion == 1, market.kind == "market", !market.id.isEmpty, market.id.count <= 128 else {
            throw RuyioError(.sourceInvalid, diagnostic: "unsupported market descriptor")
        }
        guard market.plugins.count <= maxEntries else { throw RuyioError(.sourceInvalid, diagnostic: "market lists more than \(maxEntries) plugins") }
        guard Set(market.plugins.map(\.id)).count == market.plugins.count else { throw RuyioError(.sourceInvalid, diagnostic: "duplicate plugin entries") }
        return market
    }
}

/// Peeks at the root `kind` of a JSON descriptor.
public enum DescriptorKind: String, Sendable {
    case plugin, market

    public static func detect(_ data: Data) throws -> DescriptorKind {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String, let value = DescriptorKind(rawValue: kind) else {
            throw RuyioError(.sourceInvalid, diagnostic: "missing or unknown \"kind\"")
        }
        return value
    }
}
