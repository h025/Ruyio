import Foundation

/// Static facts about this host build used for compatibility decisions.
public enum HostInfo {
    public static let version = SemanticVersion(major: 1, minor: 0, patch: 0, prerelease: ["dev"])
    public static let supportedIPCVersions: [Int] = [1]
    public static let supportedUISchemaVersions: [Int] = [1]
    public static let minimumOS = OSVersion(major: 15)
    public static let architecture = "arm64"

    /// Official signing Team ID. Empty in development builds; `app.ruyio.` IDs then require developer mode.
    public static var officialTeamID: String {
        Bundle.main.object(forInfoDictionaryKey: "RuyioOfficialTeamID") as? String ?? ""
    }
}

/// Picks the highest version both sides support (plan §7.3). Nil means incompatible.
public func negotiateVersion(host: [Int], plugin: [Int]) -> Int? {
    Set(host).intersection(plugin).max()
}
