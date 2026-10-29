import Foundation
import RuyioCore

/// A user-entered plugin or market source (PRD §7.6.1). Input is trimmed but never otherwise rewritten.
public enum SourceAddress: Sendable, Hashable {
    /// github.com/{owner}/{repo}[/tree/{ref-and-path}]
    case github(owner: String, repo: String, treeRest: [String])
    /// Any other https URL: a descriptor JSON or a .ruyioplugin(.zip) package.
    case https(URL)

    public static func parse(_ input: String) throws -> SourceAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048, let components = URLComponents(string: trimmed) else {
            throw RuyioError(.sourceInvalid, diagnostic: "not a URL")
        }
        guard components.scheme?.lowercased() == "https" else {
            throw RuyioError(.networkPolicy, diagnostic: "only https sources are allowed")
        }
        // Formal sources never embed credentials or tokens (PRD §7.6.4).
        guard components.user == nil, components.password == nil else {
            throw RuyioError(.networkPolicy, diagnostic: "credentials in URL are not allowed")
        }
        if let items = components.queryItems, items.contains(where: { ["token", "access_token", "auth", "key", "signature", "sig"].contains($0.name.lowercased()) }) {
            throw RuyioError(.networkPolicy, diagnostic: "access tokens in URL are not allowed")
        }
        guard let host = components.host?.lowercased(), !host.isEmpty, let url = components.url else {
            throw RuyioError(.sourceInvalid, diagnostic: "missing host")
        }
        if host == "github.com" || host == "www.github.com" {
            let parts = components.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { throw RuyioError(.sourceInvalid, diagnostic: "GitHub URL needs owner and repository") }
            let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            if parts.count == 2 { return .github(owner: parts[0], repo: repo, treeRest: []) }
            guard parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" else {
                throw RuyioError(.sourceInvalid, diagnostic: "unsupported GitHub URL form")
            }
            return .github(owner: parts[0], repo: repo, treeRest: Array(parts[3...]))
        }
        return .https(url)
    }

    public var isPackageURL: Bool {
        if case .https(let url) = self {
            let name = url.lastPathComponent.lowercased()
            return name.hasSuffix(".ruyioplugin.zip") || name.hasSuffix(".ruyioplugin")
        }
        return false
    }
}

/// Address policy applied to every connection target and redirect (PRD §7.6.4, plan §14.2).
public enum NetworkPolicy {
    public static func isPublic(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let (a, b) = (bytes[0], bytes[1])
        switch a {
        case 0, 10, 127: return false                       // unspecified, private, loopback
        case 100 where (64...127).contains(b): return false  // CGNAT
        case 169 where b == 254: return false                // link-local
        case 172 where (16...31).contains(b): return false   // private
        case 192 where b == 168: return false                // private
        case 192 where b == 0 && bytes[2] == 0: return false // IETF protocol assignments
        case 198 where b == 18 || b == 19: return false      // benchmarking (also common fake-ip range)
        case 224...255: return false                         // multicast, reserved, broadcast
        default: return true
        }
    }

    public static func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }                                  // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }       // ::1
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPublic(ipv4: Array(bytes[12..<16]))                                   // IPv4-mapped
        }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false }                // fe80::/10 link-local
        if (bytes[0] & 0xFE) == 0xFC { return false }                                      // fc00::/7 unique local
        if bytes[0] == 0xFF { return false }                                               // multicast
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return false } // documentation
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B {
            return isPublic(ipv4: Array(bytes[12..<16]))                                   // NAT64
        }
        return true
    }

    /// GitHub hosts Ruyio itself contacts for GitHub sources. A transparent proxy in fake-IP mode (Clash,
    /// Surge and the like, common where GitHub needs a proxy) answers them from 198.18.0.0/15 or a unique-local
    /// IPv6 range and connects to the real host, which never resolves to an intranet address; TLS still
    /// authenticates it. Only these names get that allowance; every other host stays public-only (A37).
    public static let fakeIPTolerantHosts: Set<String> = [
        "github.com", "api.github.com", "raw.githubusercontent.com", "codeload.github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// Whether a resolved address is acceptable for this host name.
    public static func accepts(_ bytes: [UInt8], for host: String) -> Bool {
        switch bytes.count {
        case 4:
            if isPublic(ipv4: bytes) { return true }
            return fakeIPTolerantHosts.contains(host.lowercased()) && bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
        case 16:
            if isPublic(ipv6: bytes) { return true }
            return fakeIPTolerantHosts.contains(host.lowercased()) && (bytes[0] & 0xFE) == 0xFC
        default:
            return false
        }
    }

    /// Resolves the host and requires every address to be public; IP literals are checked directly.
    public static func checkHost(_ host: String) throws {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower.hasSuffix(".local") || lower.hasSuffix(".internal") {
            throw RuyioError(.networkPolicy, objectID: host, diagnostic: "local host name")
        }
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &result)
        guard status == 0, let first = result else {
            throw RuyioError(.networkFailure, objectID: host, retryable: true, diagnostic: "DNS lookup failed (\(status))")
        }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var count = 0
        while let current = node {
            count += 1
            if let address = current.pointee.ai_addr {
                if current.pointee.ai_family == AF_INET {
                    let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    let bytes = withUnsafeBytes(of: ip) { Array($0) }
                    guard accepts(bytes, for: lower) else { throw RuyioError(.networkPolicy, objectID: host, diagnostic: "resolves to a non-public address") }
                } else if current.pointee.ai_family == AF_INET6 {
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    guard accepts(bytes, for: lower) else { throw RuyioError(.networkPolicy, objectID: host, diagnostic: "resolves to a non-public address") }
                }
            }
            node = current.pointee.ai_next
        }
        guard count > 0 else { throw RuyioError(.networkFailure, objectID: host, retryable: true) }
    }
}
