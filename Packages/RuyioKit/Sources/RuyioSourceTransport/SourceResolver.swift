import Foundation
import RuyioCore
import RuyioProtocol

public struct GitHubLocation: Codable, Sendable, Hashable {
    public var owner: String
    public var repo: String
    /// Numeric repository ID; a change means the repository was recreated or the name taken over (R38).
    public var repoID: Int64
    public var ref: String
    public var path: String
    public var commitSHA: String
    public var isFixedRef: Bool
}

public struct ResolvedSource: Sendable {
    public enum Kind: Sendable {
        case plugin(PluginDescriptor, descriptorURL: URL)
        case market(MarketDescriptor, indexURL: URL)
        case package(URL)
    }

    public var kind: Kind
    public var inputURL: String
    public var canonicalURL: String
    public var github: GitHubLocation?
}

/// Turns an address into a single plugin, a market or a direct package, using only explicit
/// descriptor file names — never repository names or recursive scans (PRD §7.6.2).
public struct SourceResolver: Sendable {
    public static let pluginFile = "ruyio-plugin.json"
    public static let marketFile = "ruyio-market.json"

    let fetcher: any RemoteFetching

    public init(fetcher: any RemoteFetching) {
        self.fetcher = fetcher
    }

    public func resolve(_ input: String) async throws -> ResolvedSource {
        let address = try SourceAddress.parse(input)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch address {
        case .https(let url) where address.isPackageURL:
            // Direct packages install once and have no update source (PRD §7.6.1).
            return ResolvedSource(kind: .package(url), inputURL: trimmed, canonicalURL: url.absoluteString, github: nil)
        case .https(let url):
            let result = try await fetcher.fetch(url, maxBytes: MarketDescriptor.maxBytes, accept: "application/json")
            guard result.statusCode == 200 else { throw RuyioError(.sourceInvalid, objectID: url.host, diagnostic: "HTTP \(result.statusCode)") }
            return try classify(result.data, at: result.finalURL, input: trimmed, canonical: result.finalURL.absoluteString, github: nil)
        case .github(let owner, let repo, let treeRest):
            return try await resolveGitHub(owner: owner, repo: repo, treeRest: treeRest, input: trimmed)
        }
    }

    func classify(_ data: Data, at url: URL, input: String, canonical: String, github: GitHubLocation?) throws -> ResolvedSource {
        switch try DescriptorKind.detect(data) {
        case .plugin:
            return ResolvedSource(kind: .plugin(try PluginDescriptor.decode(data), descriptorURL: url), inputURL: input, canonicalURL: canonical, github: github)
        case .market:
            return ResolvedSource(kind: .market(try MarketDescriptor.decode(data), indexURL: url), inputURL: input, canonicalURL: canonical, github: github)
        }
    }

    // MARK: GitHub

    struct RepoInfo: Decodable {
        var id: Int64
        var default_branch: String
        var `private`: Bool?
    }

    func resolveGitHub(owner: String, repo: String, treeRest: [String], input: String) async throws -> ResolvedSource {
        guard Self.isSafeComponent(owner), Self.isSafeComponent(repo) else { throw RuyioError(.sourceInvalid, diagnostic: "invalid owner or repository") }
        let info = try await repoInfo(owner: owner, repo: repo)
        var ref = info.default_branch
        var path = ""
        var sha: String
        if treeRest.isEmpty {
            sha = try await commitSHA(owner: owner, repo: repo, ref: ref)
        } else {
            // `/tree/{ref}/{path}` is ambiguous when branch names contain "/": try prefixes and refuse to guess (plan §14.1).
            var matches: [(String, String, String)] = []
            for count in 1...min(treeRest.count, 4) {
                let candidate = treeRest[0..<count].joined(separator: "/")
                if let resolved = try? await commitSHA(owner: owner, repo: repo, ref: candidate) {
                    matches.append((candidate, treeRest[count...].joined(separator: "/"), resolved))
                }
            }
            guard !matches.isEmpty else { throw RuyioError(.sourceInvalid, diagnostic: "ref not found") }
            guard matches.count == 1 else { throw RuyioError(.sourceInvalid, diagnostic: "ambiguous ref; use a commit or an unambiguous branch") }
            (ref, path, sha) = matches[0]
        }
        guard path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }) else { throw RuyioError(.sourceInvalid) }
        let base = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(sha)/" + (path.isEmpty ? "" : path + "/")
        guard let pluginURL = URL(string: base + Self.pluginFile), let marketURL = URL(string: base + Self.marketFile) else { throw RuyioError(.sourceInvalid) }
        async let plugin = optionalFetch(pluginURL, maxBytes: PluginDescriptor.maxBytes)
        async let market = optionalFetch(marketURL, maxBytes: MarketDescriptor.maxBytes)
        let (pluginData, marketData) = try await (plugin, market)
        let location = GitHubLocation(owner: owner, repo: repo, repoID: info.id, ref: ref, path: path, commitSHA: sha,
                                      isFixedRef: ref.count == 40 && ref.allSatisfy(\.isHexDigit))
        let canonical = "https://github.com/\(owner)/\(repo)" + (treeRest.isEmpty ? "" : "/tree/\(ref)" + (path.isEmpty ? "" : "/\(path)"))
        switch (pluginData, marketData) {
        case (.some, .some):
            throw RuyioError(.sourceInvalid, diagnostic: "both ruyio-plugin.json and ruyio-market.json exist")
        case (.some(let data), nil):
            return try classify(data, at: pluginURL, input: input, canonical: canonical, github: location)
        case (nil, .some(let data)):
            return try classify(data, at: marketURL, input: input, canonical: canonical, github: location)
        case (nil, nil):
            throw RuyioError(.sourceInvalid, diagnostic: "no ruyio-plugin.json or ruyio-market.json at this location")
        }
    }

    func repoInfo(owner: String, repo: String) async throws -> RepoInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else { throw RuyioError(.sourceInvalid) }
        let result = try await fetcher.fetch(url, maxBytes: 1 << 20, accept: "application/vnd.github+json")
        if result.statusCode == 404 {
            // Private repositories are not supported in V1 (PRD §19.6): explain instead of retrying.
            throw RuyioError(.sourceInvalid, diagnostic: "repository not found or private")
        }
        guard result.statusCode == 200, let info = try? JSONDecoder().decode(RepoInfo.self, from: result.data) else {
            throw RuyioError(.networkFailure, retryable: true, diagnostic: "GitHub API HTTP \(result.statusCode)")
        }
        return info
    }

    func commitSHA(owner: String, repo: String, ref: String) async throws -> String {
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? ref
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(encoded)") else { throw RuyioError(.sourceInvalid) }
        let result = try await fetcher.fetch(url, maxBytes: 4096, accept: "application/vnd.github.sha")
        let sha = String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.statusCode == 200, sha.count == 40, sha.allSatisfy(\.isHexDigit) else {
            throw RuyioError(.sourceInvalid, diagnostic: "ref \(ref) not found")
        }
        return sha
    }

    func optionalFetch(_ url: URL, maxBytes: Int) async throws -> Data? {
        let result = try await fetcher.fetch(url, maxBytes: maxBytes)
        if result.statusCode == 404 { return nil }
        guard result.statusCode == 200 else { throw RuyioError(.networkFailure, retryable: true, diagnostic: "HTTP \(result.statusCode)") }
        return result.data
    }

    static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && value != "." && value != ".."
    }

    /// Resolves a release artifact relative to its descriptor; must stay https (PRD §7.6.4).
    public static func artifactURL(_ artifact: String, relativeTo descriptor: URL) throws -> URL {
        guard let url = URL(string: artifact, relativeTo: descriptor)?.absoluteURL, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil else {
            throw RuyioError(.networkPolicy, diagnostic: "artifact must be an https URL")
        }
        return url
    }
}
