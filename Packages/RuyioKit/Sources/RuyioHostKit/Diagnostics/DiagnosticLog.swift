import Foundation
import RuyioCore

/// Minimal local diagnostics (PRD §21). Records versions, lifecycle and result codes only — never
/// clipboard text, file contents, action inputs, paths or full URLs. Rolls at 20 MiB / 7 days (plan §16).
public final class DiagnosticLog: @unchecked Sendable {
    public static let maxBytes: Int64 = 20 << 20
    public static let maxAge: TimeInterval = 7 * 86_400

    public enum Event: String, Sendable {
        case hostStarted, pluginInstalled, pluginEnabled, pluginDisabled, pluginUninstalled, pluginCrashed
        case actionCompleted, updateCompleted, updateRolledBack, marketRefreshed, finderRequest, permissionChanged
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "ruyio.diagnostics")

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// `fields` must contain identifiers and codes only; values are truncated and newlines removed.
    public func record(_ event: Event, _ fields: [String: String] = [:]) {
        let line: [String: String] = fields.mapValues { String($0.prefix(200)).replacingOccurrences(of: "\n", with: " ") }
            .merging(["event": event.rawValue, "time": ISO8601DateFormatter().string(from: Date())]) { $1 }
        queue.async { [directory] in
            guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            let file = directory.appendingPathComponent("ruyio-\(Self.day()).log")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
            self.prune()
        }
    }

    /// URL with query, fragment and credentials removed; only scheme, host and path remain (PRD §21).
    public static func sanitized(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "-" }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "-"
    }

    public func clear() {
        queue.sync {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
            let old = (values?.contentModificationDate ?? Date()).timeIntervalSinceNow < -Self.maxAge
            if old || total > Self.maxBytes { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func day() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
