import CryptoKit
import Darwin
import Foundation
import RuyioCore
import RuyioSourceTransport

/// Updates Ruyio itself from a Sparkle-format appcast without an Apple Developer ID (A41).
///
/// Sparkle cannot be embedded: under the hardened runtime that protects Ruyio's privacy grants, a process
/// without a Team ID may load no third-party framework, and turning library validation off would let a
/// replaced framework inherit those grants. So the app performs Sparkle's two checks itself: the archive's
/// EdDSA signature, and the new app's code signature must satisfy the running app's designated requirement
/// (same identifier, same certificate), which is also what keeps the grants across the update.
public actor AppUpdateService {
    public struct Configuration: Sendable {
        public var feedURL: URL
        /// Raw 32-byte Ed25519 public key (`SUPublicEDKey`).
        public var publicKey: Data
        public var currentVersion: SemanticVersion
        public var installedApp: URL
        /// Designated requirement of the running app; an update must satisfy it.
        public var designatedRequirement: String

        public init(feedURL: URL, publicKey: Data, currentVersion: SemanticVersion, installedApp: URL, designatedRequirement: String) {
            self.feedURL = feedURL
            self.publicKey = publicKey
            self.currentVersion = currentVersion
            self.installedApp = installedApp
            self.designatedRequirement = designatedRequirement
        }
    }

    /// Why the running copy cannot replace itself; the user installs the update by hand instead.
    public enum InstallProblem: String, Sendable {
        /// Opened straight from a download: macOS runs it from a read-only randomized path.
        case translocated
        /// The app or its folder is not writable by this user.
        case notWritable
    }

    public nonisolated let configuration: Configuration
    private let fetcher: any RemoteFetching
    private let staging: URL
    private var observer: (@Sendable (AppcastItem?) -> Void)?

    /// `staging` must be a folder the host cleans at startup (`AppPaths.downloads`).
    public init(configuration: Configuration, fetcher: any RemoteFetching = SourceFetcher(usesSystemProxy: true), staging: URL) {
        self.configuration = configuration
        self.fetcher = fetcher
        self.staging = staging
    }

    /// Called with the result of every successful check, background or manual.
    public func observe(_ handler: @escaping @Sendable (AppcastItem?) -> Void) { observer = handler }

    /// The newest compatible release above the running version, or nil when Ruyio is up to date.
    public func check() async throws -> AppcastItem? {
        let result = try await fetcher.fetch(configuration.feedURL, maxBytes: 1 << 20, accept: "application/rss+xml, application/xml, text/xml")
        guard result.statusCode == 200 else { throw RuyioError(.sourceInvalid, diagnostic: "appcast HTTP \(result.statusCode)") }
        let newest = Self.newest(try Appcast.parse(result.data), above: configuration.currentVersion, os: OSVersion.current)
        observer?(newest)
        return newest
    }

    static func newest(_ items: [AppcastItem], above current: SemanticVersion, os: OSVersion) -> AppcastItem? {
        items.filter { $0.version > current && !$0.version.isPrerelease && ($0.minimumSystemVersion ?? os) <= os }
            .max { $0.version < $1.version }
    }

    /// Downloads the archive, checks its EdDSA signature before unpacking anything, then verifies the app
    /// inside. Returns the staged app for `install(staged:)`.
    public func prepare(_ item: AppcastItem, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> URL {
        // The "staging-" prefix lets the next start remove whatever an interrupted update left behind.
        let work = staging.appendingPathComponent("staging-app-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let archive = work.appendingPathComponent("update.zip")
            try await fetcher.download(item.url, to: archive, maxBytes: 300 << 20, progress: progress)
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard item.length <= 0 || Int64(data.count) == item.length else {
                throw RuyioError(.sourceInvalid, diagnostic: "update size differs from the appcast")
            }
            guard let signature = Data(base64Encoded: item.edSignature),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: configuration.publicKey),
                  key.isValidSignature(signature, for: data) else {
                throw RuyioError(.sourceInvalid, diagnostic: "update EdDSA signature does not match")
            }
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try ZipArchive(data: data).extract(to: unpacked)
            try? FileManager.default.removeItem(at: archive)
            return try await verify(unpacked: unpacked, item: item)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private func verify(unpacked: URL, item: AppcastItem) async throws -> URL {
        let apps = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            .filter { $0.pathExtension == "app" }
        // A link would be copied as a link and leave the installed path pointing into the download folder.
        guard apps.count == 1, let app = apps.first,
              let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink == false, values.isDirectory == true else {
            throw RuyioError(.sourceInvalid, diagnostic: "update archive must hold one app folder")
        }
        try await verify(app: app, item: item)
        return app
    }

    /// The same publisher (designated requirement), a valid signature and the promised version.
    private func verify(app: URL, item: AppcastItem) async throws {
        let signing = await CodeSigning.inspect(bundle: app)
        guard signing.isValid else { throw RuyioError(.sourceInvalid, diagnostic: "update signature invalid: \(signing.validationError ?? "")") }
        let continuity = await CodeSigning.satisfies(bundle: app, requirement: configuration.designatedRequirement)
        guard continuity.passed else { throw RuyioError(.sourceInvalid, diagnostic: "update is not signed by the same publisher") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) == item.version else {
            throw RuyioError(.sourceInvalid, diagnostic: "update version differs from the appcast")
        }
    }

    /// The download folder `prepare` created for a staged app.
    public nonisolated static func workFolder(of staged: URL) -> URL {
        staged.deletingLastPathComponent().deletingLastPathComponent()
    }

    public nonisolated var installProblem: InstallProblem? { Self.installProblem(for: configuration.installedApp) }

    public nonisolated static func installProblem(for app: URL) -> InstallProblem? {
        if app.path.contains("/AppTranslocation/") { return .translocated }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else { return .notWritable }
        return nil
    }

    /// Puts the verified app in place of the running one with one atomic swap, so the app's path never
    /// goes missing. The copy waits in a temporary folder on the app's volume, outside the Applications
    /// folder, where LaunchServices could register it and its Finder extension; it is verified again
    /// there, since time passes between download and install. Returns that folder, which now holds the
    /// previous version, for the relauncher to remove once the new version is running.
    public func install(staged: URL, item: AppcastItem) async throws -> URL {
        if let problem = installProblem { throw RuyioError(.fileAccessDenied, diagnostic: "cannot replace the app: \(problem.rawValue)") }
        let installed = configuration.installedApp
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        let incoming = folder.appendingPathComponent(installed.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: staged, to: incoming)
            try await verify(app: incoming, item: item)
            guard renamex_np(installed.path, incoming.path, UInt32(RENAME_SWAP)) == 0 else {
                throw RuyioError(.fileWriteFailed, diagnostic: "swap failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Waits in a detached process for `pid` to exit, opens the updated app and then removes `leftovers`,
    /// which stay as a fallback when the app cannot be opened. Arguments travel as positional parameters,
    /// never inside the script text.
    public nonisolated func relaunch(after pid: pid_t, removing leftovers: [URL]) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        app=$2; shift 2
        # LaunchServices may list the old process for a moment after it exits; try again before giving up.
        /bin/sleep 0.5
        { /usr/bin/open "$app" || { /bin/sleep 2; /usr/bin/open "$app"; }; } && /bin/rm -rf "$@"
        """
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, no inherited descriptors besides the three below, default signal handling.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let arguments = ["/bin/sh", "-c", script, "ruyio-relaunch", String(pid), configuration.installedApp.path] + leftovers.map(\.path)
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, &argv, environ)
        guard status == 0 else { throw RuyioError(.internalError, diagnostic: "relauncher: \(String(cString: strerror(status)))") }
    }

    /// Removes swap leftovers beside the app that an interrupted update could not clean up (versions up to
    /// 0.0.1 swapped through a hidden sibling in the app's folder).
    public nonisolated static func removeLeftovers(beside app: URL) {
        let folder = app.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".ruyio-update-") && name.hasSuffix(".app") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
