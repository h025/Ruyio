import Foundation

/// Semantic Versioning 2.0.0. Invalid strings never take part in update comparison (PRD §7.6.5).
public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]
    public var build: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = [], build: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public init?(_ string: String) {
        var core = Substring(string)
        var build: [String] = []
        var prerelease: [String] = []
        if let plus = core.firstIndex(of: "+") {
            let tail = core[core.index(after: plus)...]
            build = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !build.isEmpty, build.allSatisfy({ !$0.isEmpty && Self.isIdentifier($0) }) else { return nil }
            core = core[..<plus]
        }
        if let dash = core.firstIndex(of: "-") {
            let tail = core[core.index(after: dash)...]
            prerelease = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !prerelease.isEmpty, prerelease.allSatisfy({ !$0.isEmpty && Self.isIdentifier($0) }) else { return nil }
            for part in prerelease where part.allSatisfy(\.isNumber) && part.count > 1 && part.first == "0" { return nil }
            core = core[..<dash]
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(number.count > 1 && number.first == "0"),
                  let value = Int(number) else { return nil }
            parsed.append(value)
        }
        self.init(major: parsed[0], minor: parsed[1], patch: parsed[2], prerelease: prerelease, build: build)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = SemanticVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid semantic version: \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { text += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { text += "+" + build.joined(separator: ".") }
        return text
    }

    /// Precedence ignores build metadata (SemVer §11). Equality for `Hashable` keeps it.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.precedence(comparedTo: rhs) == .orderedAscending
    }

    public func precedence(comparedTo other: SemanticVersion) -> ComparisonResult {
        for (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)] where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
        switch (prerelease.isEmpty, other.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (a, b) in zip(prerelease, other.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y ? .orderedAscending : .orderedDescending
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            case (nil, nil): return a < b ? .orderedAscending : .orderedDescending
            }
        }
        if prerelease.count == other.prerelease.count { return .orderedSame }
        return prerelease.count < other.prerelease.count ? .orderedAscending : .orderedDescending
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "-" }
    }
}

/// macOS major.minor version used for compatibility filtering.
public struct OSVersion: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        self.init(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = OSVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid OS version: \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static var current: OSVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
    }

    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
