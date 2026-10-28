import Darwin
import Foundation
import RuyioCore
import RuyioPersistence
import RuyioProtocol

/// What the user chose in the host's conflict sheet (PRD §19.19).
public struct ConflictResolution: Sendable, Hashable {
    public enum Choice: String, Sendable { case keepBoth, replace, skip, cancel }
    public var choice: Choice
    public var applyToAll: Bool
    public init(_ choice: Choice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct ConflictInfo: Sendable, Hashable {
    public var fileName: String
    public var directory: String
    public var existingSize: Int64?
    public var existingModified: Date?
    public var newSize: Int64?
    public var remainingCount: Int
}

public protocol FileBrokerDelegate: AnyObject, Sendable {
    func resolveConflict(_ info: ConflictInfo) async -> ConflictResolution
}

/// Host-mediated file creation (plan §13.3). Writes a same-volume temporary file, then commits with a
/// non-overwriting rename (or an atomic replace when the user chose "Replace"). Every side effect has a
/// persistent intent and receipt so a lost reply never causes a second write.
public final class FileBroker: Sendable {
    private let database: HostDatabase
    private let contexts: InvocationContexts
    private let blobReader: @Sendable (PluginID, String) throws -> Data
    public weak var delegate: FileBrokerDelegate? {
        get { delegateBox.value }
        set { delegateBox.value = newValue }
    }
    private let delegateBox = WeakBox<FileBrokerDelegate>()
    private let revealable = RevealablePaths()

    /// Files this plugin created through the broker; the only paths it may ask the host to reveal.
    public func revealablePaths(for pluginID: PluginID) -> Set<String> { revealable.paths(for: pluginID) }

    public static let receiptRetention: TimeInterval = 7 * 24 * 3600

    public init(database: HostDatabase, contexts: InvocationContexts, blobReader: @escaping @Sendable (PluginID, String) throws -> Data) {
        self.database = database
        self.contexts = contexts
        self.blobReader = blobReader
    }

    public func write(_ request: FileWriteRequest, pluginID: PluginID, operationID: OperationID?, executionID: ExecutionID?,
                      actionID: ActionID? = nil) async throws -> FileWriteReply {
        let operationID = operationID ?? OperationID()
        // Idempotency: a retried request with the same operation ID returns the stored receipt.
        if let existing = try database.operation(operationID) {
            guard existing.pluginID == pluginID.rawValue else { throw RuyioError(.invalidRequest, diagnostic: "operation owned by another plugin") }
            switch existing.phase {
            case .completed, .failed:
                if let receipt = existing.receipt { return try JSONCoding.decoder().decode(FileWriteReply.self, from: Data(receipt.utf8)) }
            case .intent, .staged, .committed, .unknown:
                throw RuyioError(.outcomeUnknown, objectID: operationID.rawValue, dataEffect: .unknown, recovery: .revealInFinder)
            case .resolved:
                throw RuyioError(.invalidRequest, diagnostic: "operation already resolved")
            }
        }

        let directory = try contexts.resolve(request.directory, for: pluginID)
        guard request.items.count <= 1_000 else { throw RuyioError(.invalidRequest, diagnostic: "too many items") }
        for item in request.items { try Self.validateFileName(item.fileName) }

        let intent = String(decoding: try JSONCoding.encoder().encode(request), as: UTF8.self)
        var record = OperationRecord(operationID: operationID.rawValue, pluginID: pluginID.rawValue, actionID: actionID?.rawValue,
                                     executionID: executionID?.rawValue, phase: .intent, intent: intent)
        try database.saveOperation(record)

        var outcomes: [FileWriteOutcome] = []
        var stickyResolution: ConflictResolution?
        var cancelled = false
        for (index, item) in request.items.enumerated() {
            // Once the execution has ended (timeout, cancel, disable) its grants are revoked: stop here,
            // and report what was already committed (plan §13.3).
            if !cancelled, !contexts.isStillValid(request.directory, for: pluginID) { cancelled = true }
            if cancelled {
                outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil, status: .cancelled))
                continue
            }
            do {
                let data = try payload(for: item.source, pluginID: pluginID)
                let destination = directory.appendingPathComponent(item.fileName)
                // Replacing an existing file is the user's call, made in the host conflict dialog (PRD §19.19);
                // a plugin asking for .replace gets that dialog, never a silent overwrite.
                var policy = request.conflictPolicy == .replace ? .ask : request.conflictPolicy
                if FileManager.default.fileExists(atPath: destination.path) {
                    if policy == .ask {
                        let resolution: ConflictResolution
                        if let sticky = stickyResolution {
                            resolution = sticky
                        } else if let delegate {
                            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
                            resolution = await delegate.resolveConflict(ConflictInfo(
                                fileName: item.fileName, directory: directory.path,
                                existingSize: (attrs?[.size] as? NSNumber)?.int64Value,
                                existingModified: attrs?[.modificationDate] as? Date,
                                newSize: data.map { Int64($0.count) }, remainingCount: request.items.count - index - 1))
                            if resolution.applyToAll { stickyResolution = resolution }
                            // The dialog may outlive the action (timeout, cancel): never write after that.
                            if !contexts.isStillValid(request.directory, for: pluginID) {
                                cancelled = true
                                outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil, status: .cancelled))
                                continue
                            }
                        } else {
                            resolution = ConflictResolution(.skip)
                        }
                        switch resolution.choice {
                        case .keepBoth: policy = .keepBoth
                        case .replace: policy = .replace
                        case .skip: policy = .skip
                        case .cancel:
                            cancelled = true
                            outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil, status: .cancelled))
                            continue
                        }
                    }
                }
                record.phase = .staged
                try database.saveOperation(record)
                let finalURL = try commit(item: item, data: data, in: directory, policy: policy, pluginID: pluginID)
                if let finalURL {
                    outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: finalURL.path, status: .written))
                } else {
                    outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil,
                                                     status: policy == .skip ? .skipped : .conflict, errorCode: policy == .fail ? ErrorCode.fileConflict.rawValue : nil))
                }
            } catch let error as RuyioError {
                outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil, status: .failed, errorCode: error.code.rawValue))
            } catch {
                outcomes.append(FileWriteOutcome(requestedName: item.fileName, finalPath: nil, status: .failed, errorCode: ErrorCode.fileWriteFailed.rawValue))
            }
        }

        let written = outcomes.filter { $0.status == .written }.count
        // "partial" tells the caller some files exist even though the whole request did not complete.
        let effect: DataEffect = (written > 0 && written < outcomes.count) ? .partial : .unmodified
        let reply = FileWriteReply(outcomes: outcomes, dataEffect: effect)
        revealable.add(outcomes.compactMap(\.finalPath), for: pluginID)
        // If the router already reported "outcome unknown", keep that state for the user and attach the receipt.
        let latest = (try? database.operation(operationID)) ?? nil
        record.phase = latest?.phase == .unknown ? .unknown : .completed
        record.receipt = String(decoding: try JSONCoding.encoder().encode(reply), as: UTF8.self)
        try database.saveOperation(record)
        return reply
    }

    /// Crash recovery: operations left before completion become "outcome unknown" (never replayed).
    public func recoverInterruptedOperations() throws -> [OperationRecord] {
        var unresolved: [OperationRecord] = []
        for var record in try database.unresolvedOperations() where record.phase != .unknown {
            record.phase = .unknown
            try database.saveOperation(record)
            unresolved.append(record)
        }
        try database.pruneOperations(olderThan: Date().addingTimeInterval(-Self.receiptRetention))
        return unresolved
    }

    // MARK: Validation

    /// Rejects empty names, separators, traversal, NUL, over-long names (plan §13.3) and hidden names:
    /// dot files such as `.zshenv` are invisible in Finder and some are executed by other programs.
    public static func validateFileName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw RuyioError(.fileNameInvalid, objectID: name, recovery: .rename)
        }
    }

    /// Removes characters that cannot appear in a file name and trims to a sane length.
    public static func sanitizeFileName(_ raw: String, fallback: String = "Untitled") -> String {
        var cleaned = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = fallback }
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        return cleaned
    }

    // MARK: Writing

    private func payload(for source: FileWriteItem.Source, pluginID: PluginID) throws -> Data? {
        switch source {
        case .text(let text): return Data(text.utf8)
        case .blob(let id): return try blobReader(pluginID, id)
        case .empty: return Data()
        case .copyOf: return nil
        }
    }

    private func commit(item: FileWriteItem, data: Data?, in directory: URL, policy: ConflictPolicy, pluginID: PluginID) throws -> URL? {
        let temp = directory.appendingPathComponent(".ruyio-\(UUID().uuidString.prefix(8)).tmp")
        do {
            if case .copyOf(let ref) = item.source {
                let source = try contexts.resolve(ref, for: pluginID)
                // Clone when possible; never moves or deletes the source (PRD §19.19).
                let result = copyfile(source.path, temp.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE))
                guard result == 0 else { throw Self.posixError(errno, name: item.fileName) }
            } else {
                let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard fd >= 0 else { throw Self.posixError(errno, name: item.fileName) }
                defer { close(fd) }
                let bytes = data ?? Data()
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n < 0 { if errno == EINTR { continue }; throw Self.posixError(errno, name: item.fileName) }
                        offset += n
                    }
                }
                guard fsync(fd) == 0 else { throw Self.posixError(errno, name: item.fileName) }
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        var destination = directory.appendingPathComponent(item.fileName)
        switch policy {
        case .replace:
            // Atomic replace: the old file stays intact until the rename succeeds.
            guard rename(temp.path, destination.path) == 0 else {
                let error = Self.posixError(errno, name: item.fileName)
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            return destination
        case .keepBoth, .ask, .fail, .skip:
            var attempt = 1
            while true {
                if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
                let code = errno
                if code != EEXIST {
                    try? FileManager.default.removeItem(at: temp)
                    throw Self.posixError(code, name: item.fileName)
                }
                guard policy == .keepBoth else {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
                attempt += 1
                destination = directory.appendingPathComponent(Self.numberedName(item.fileName, attempt))
                if attempt > 9_999 {
                    try? FileManager.default.removeItem(at: temp)
                    throw RuyioError(.fileConflict, objectID: item.fileName)
                }
            }
        }
    }

    /// "Report.md" → "Report 2.md", matching Finder's convention.
    public static func numberedName(_ name: String, _ number: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
    }

    static func posixError(_ code: Int32, name: String) -> RuyioError {
        switch code {
        case EACCES, EPERM: return RuyioError(.fileAccessDenied, objectID: name, recovery: .openSystemSettings, diagnostic: "errno \(code)")
        case EEXIST: return RuyioError(.fileConflict, objectID: name)
        case ENOSPC, EDQUOT: return RuyioError(.fileWriteFailed, objectID: name, diagnostic: "disk full")
        default: return RuyioError(.fileWriteFailed, objectID: name, retryable: true, diagnostic: "errno \(code)")
        }
    }
}

final class RevealablePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var byPlugin: [PluginID: [String]] = [:]

    func add(_ paths: [String], for pluginID: PluginID) {
        guard !paths.isEmpty else { return }
        lock.withLock { byPlugin[pluginID] = Array((byPlugin[pluginID] ?? []) + paths).suffix(500) }
    }

    func paths(for pluginID: PluginID) -> Set<String> { lock.withLock { Set(byPlugin[pluginID] ?? []) } }
}

final class WeakBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: AnyObject?
    var value: T? {
        get { lock.withLock { _value as? T } }
        set { lock.withLock { _value = newValue as AnyObject? } }
    }
}
