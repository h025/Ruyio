import CryptoKit
import Foundation
import RuyioCore
import Security

/// Facts read from a bundle's code signature with Security.framework (plan §7.2).
public struct SigningInfo: Sendable, Hashable {
    public var identifier: String?
    public var teamID: String?
    /// SHA-256 of the leaf signing certificate, lowercase hex; nil for ad-hoc signatures.
    public var leafCertificateSHA256: String? = nil
    public var isAdHoc: Bool
    public var hasHardenedRuntime: Bool
    public var entitlements: [String: EntitlementValue]
    public var isValid: Bool
    public var validationError: String?

    public enum EntitlementValue: Sendable, Hashable {
        case bool(Bool)
        case string(String)
        case strings([String])
        case other
    }

    public func boolEntitlement(_ key: String) -> Bool {
        if case .bool(let value) = entitlements[key] { return value }
        return false
    }

    /// Who stands behind the code (A39): the Apple Team ID of an Apple-issued certificate, otherwise the
    /// signing certificate itself, which a free self-signed certificate provides. Only its private key can
    /// produce a valid signature with it. Nil for ad-hoc signatures, which anyone can make for any identifier.
    public var publisherID: String? {
        if let teamID, !teamID.isEmpty { return teamID }
        return leafCertificateSHA256.map { PublisherID.certificatePrefix + $0 }
    }
}

public enum CodeSigning {
    /// Security validates code by fanning work out to dispatch queues and waiting for it. Run on a Swift
    /// concurrency thread, that wait starved: with the few cooperative threads of a three-core machine all
    /// blocked, the fanned-out work never ran and validation hung. Validation therefore runs here, one at a
    /// time, at its own QoS, while callers suspend instead of blocking a cooperative thread.
    private static let worker = DispatchQueue(label: "ruyio.codesigning", qos: .userInitiated)

    private static func onWorker<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: body()) }
        }
    }

    /// Strict validation: nested code, all architectures, resources; revocation checks when online.
    public static func inspect(bundle: URL, checkRevocation: Bool = false) async -> SigningInfo {
        await onWorker { inspectNow(bundle: bundle, checkRevocation: checkRevocation) }
    }

    private static func inspectNow(bundle: URL, checkRevocation: Bool) -> SigningInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return SigningInfo(identifier: nil, teamID: nil, isAdHoc: false, hasHardenedRuntime: false, entitlements: [:],
                               isValid: false, validationError: "no code object")
        }
        var flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        if checkRevocation { flags.insert(SecCSFlags(rawValue: 1 << 30)) } // kSecCSEnforceRevocationChecks
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &cfError)
        let validationError = status == errSecSuccess ? nil : (cfError?.takeRetainedValue().localizedDescription ?? "status \(status)")

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            .map { SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined() }
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        var entitlements: [String: SigningInfo.EntitlementValue] = [:]
        if let dict = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            for (key, value) in dict {
                switch value {
                case let b as Bool: entitlements[key] = .bool(b)
                case let s as String: entitlements[key] = .string(s)
                case let a as [String]: entitlements[key] = .strings(a)
                default: entitlements[key] = .other
                }
            }
        }
        return SigningInfo(
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
            leafCertificateSHA256: leaf,
            isAdHoc: codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            hasHardenedRuntime: codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            entitlements: entitlements, isValid: status == errSecSuccess, validationError: validationError)
    }

    /// Developer ID + notarization check through the public requirement language (plan §7.2). Since A39 it
    /// only labels a package as notarized; it is not required. `notarized` accepts a stapled ticket offline
    /// or an online lookup.
    public static let developerIDNotarizedRequirement =
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and notarized"

    public static func satisfies(bundle: URL, requirement text: String) async -> (passed: Bool, detail: String?) {
        await onWorker { satisfiesNow(bundle: bundle, requirement: text) }
    }

    private static func satisfiesNow(bundle: URL, requirement text: String) -> (passed: Bool, detail: String?) {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let req = requirement else {
            return (false, "cannot evaluate requirement")
        }
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), req, &cfError)
        if status == errSecSuccess { return (true, nil) }
        return (false, cfError?.takeRetainedValue().localizedDescription ?? "status \(status)")
    }

    public static func assessExecution(bundle: URL) async -> (passed: Bool, detail: String?) {
        await satisfies(bundle: bundle, requirement: developerIDNotarizedRequirement)
    }
}

/// Entitlement allowlist for plugin bundles (plan §7.2): everything not listed is refused.
public enum EntitlementPolicy {
    public static let identityKeys: Set<String> = [
        "com.apple.application-identifier", "com.apple.developer.team-identifier",
    ]

    public static func violations(_ signing: SigningInfo, declaresNetwork: Bool) -> [String] {
        var problems: [String] = []
        if !signing.boolEntitlement("com.apple.security.app-sandbox") { problems.append("App Sandbox not enabled") }
        for key in signing.entitlements.keys.sorted() {
            switch key {
            case "com.apple.security.app-sandbox": continue
            case "com.apple.security.network.client":
                if !declaresNetwork && signing.boolEntitlement(key) { problems.append("network.client not declared in manifest") }
            case _ where identityKeys.contains(key): continue
            default: problems.append("entitlement not allowed: \(key)")
            }
        }
        if declaresNetwork && !signing.boolEntitlement("com.apple.security.network.client") {
            problems.append("manifest declares network.client but signature lacks it")
        }
        return problems
    }
}

/// Mach-O architecture check without executing anything (plan §7.2: arm64 required).
public enum MachO {
    public static func containsARM64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 4096) else { return false }
        defer { try? handle.close() }
        guard header.count >= 8 else { return false }
        let magic = header.readUInt32(0)
        let cpuTypeARM64: UInt32 = 0x0100_000C
        switch magic {
        case 0xFEED_FACF: // MH_MAGIC_64 little-endian
            return header.readUInt32(4) == cpuTypeARM64
        case 0xBEBA_FECA, 0xBFBA_FECA: // FAT_MAGIC / FAT_MAGIC_64 stored big-endian
            let count = Int(header.readUInt32BE(4))
            let stride = magic == 0xBEBA_FECA ? 20 : 32
            for i in 0..<min(count, 16) {
                let offset = 8 + i * stride
                guard offset + 4 <= header.count else { break }
                if header.readUInt32BE(offset) == cpuTypeARM64 { return true }
            }
            return false
        default:
            return false
        }
    }

    /// True for a main-program image (MH_EXECUTE), thin or universal; libraries and bundles are not.
    public static func isExecutableImage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 4 else { return false }
        let magic = header.readUInt32(0)
        let MH_EXECUTE: UInt32 = 2
        switch magic {
        case 0xFEED_FACF, 0xFEED_FACE:
            // A truncated recognized image is rejected as potentially launchable, never treated as a resource.
            guard header.count >= 16 else { return true }
            return header.readUInt32(12) == MH_EXECUTE
        case 0xBEBA_FECA, 0xBFBA_FECA:
            guard header.count >= 8, let fileSize = try? handle.seekToEnd() else { return true }
            let count = Int(header.readUInt32BE(4))
            let stride = magic == 0xBEBA_FECA ? 20 : 32
            guard count > 0, count <= 64, count <= (header.count - 8) / stride else { return true }
            for index in 0..<count {
                let base = 8 + index * stride
                let offset = magic == 0xBEBA_FECA ? UInt64(header.readUInt32BE(base + 8))
                    : (UInt64(header.readUInt32BE(base + 8)) << 32) | UInt64(header.readUInt32BE(base + 12))
                let size = magic == 0xBEBA_FECA ? UInt64(header.readUInt32BE(base + 12))
                    : (UInt64(header.readUInt32BE(base + 16)) << 32) | UInt64(header.readUInt32BE(base + 20))
                guard offset >= UInt64(8 + count * stride), offset <= fileSize,
                      size >= 16, size <= fileSize - offset,
                      (try? handle.seek(toOffset: offset)) != nil,
                      let slice = try? handle.read(upToCount: 16), slice.count == 16 else { return true }
                guard [UInt32(0xFEED_FACF), 0xFEED_FACE].contains(slice.readUInt32(0)) else { return true }
                if slice.readUInt32(12) == MH_EXECUTE { return true }
            }
            return false
        default:
            return false
        }
    }
}

extension Data {
    func readUInt32BE(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
}
