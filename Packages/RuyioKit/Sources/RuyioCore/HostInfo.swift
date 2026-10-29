import Foundation

/// Static facts about this host build used for compatibility decisions.
public enum HostInfo {
    public static let version = SemanticVersion(major: 0, minor: 0, patch: 3)
    public static let supportedIPCVersions: [Int] = [1]
    public static let supportedUISchemaVersions: [Int] = [1]
    public static let minimumOS = OSVersion(major: 14)
    public static let architecture = "arm64"

    /// Publisher ID (see `PublisherID`) of official builds, set by `Scripts/release.sh`. Empty in development
    /// builds; `app.ruyio.` IDs then require developer mode.
    public static var officialPublisherID: String {
        Bundle.main.object(forInfoDictionaryKey: "RuyioOfficialPublisher") as? String ?? ""
    }
}

/// A plugin publisher's identity (A39): an Apple Team ID, or `cert:` followed by the SHA-256 of a
/// self-signed signing certificate. Ruyio does not require Apple's paid Developer Program.
public enum PublisherID {
    public static let certificatePrefix = "cert:"

    /// The certificate fingerprint of a `cert:` publisher, nil for a Team ID or no publisher.
    public static func certificateSHA256(_ publisherID: String?) -> String? {
        guard let publisherID, publisherID.hasPrefix(certificatePrefix) else { return nil }
        return String(publisherID.dropFirst(certificatePrefix.count))
    }
}

/// Picks the highest version both sides support (plan §7.3). Nil means incompatible.
public func negotiateVersion(host: [Int], plugin: [Int]) -> Int? {
    Set(host).intersection(plugin).max()
}
