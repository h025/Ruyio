import Darwin
import Foundation
import RuyioCore
import RuyioProtocol

/// A spawned plugin executable with its anonymous pipes (plan §8.1).
///
/// No shell is involved, nothing user-controlled is interpolated into the path, the environment is
/// rebuilt from an allowlist, only fds 0/1/2 are inherited, and the child gets its own process group.
public final class PluginProcess: @unchecked Sendable {
    public let pid: pid_t
    public let readFD: Int32
    public let writeFD: Int32
    public let executable: URL
    private let exitSource: DispatchSourceProcess
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var exitHandlers: [@Sendable (Int32) -> Void] = []

    public struct Options: Sendable {
        public var workingDirectory: URL?
        public var locale: String
        public var captureStderr: Bool
        public init(workingDirectory: URL? = nil, locale: String = "en", captureStderr: Bool = false) {
            self.workingDirectory = workingDirectory
            self.locale = locale
            self.captureStderr = captureStderr
        }
    }

    public static func spawn(executable: URL, options: Options = Options()) throws -> PluginProcess {
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw RuyioError(.pluginLaunchFailed, diagnostic: "pipe errno=\(errno)") }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0]); close(toChild[1])
            throw RuyioError(.pluginLaunchFailed, diagnostic: "pipe errno=\(errno)")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        // Release builds discard stderr so an unread pipe can never block the plugin (plan §8.1).
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        if let directory = options.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only explicitly mapped fds survive; new process group for managed cleanup.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let environment = sanitizedEnvironment(locale: options.locale)
        var pid: pid_t = 0
        let path = executable.path
        let result: Int32 = withCStrings([path]) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            }
        }
        close(toChild[0])
        close(fromChild[1])
        guard result == 0 else {
            close(toChild[1])
            close(fromChild[0])
            throw RuyioError(.pluginLaunchFailed, objectID: executable.lastPathComponent, diagnostic: "posix_spawn \(result)")
        }
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        return PluginProcess(pid: pid, readFD: fromChild[0], writeFD: toChild[1], executable: executable)
    }

    private init(pid: pid_t, readFD: Int32, writeFD: Int32, executable: URL) {
        self.pid = pid
        self.readFD = readFD
        self.writeFD = writeFD
        self.executable = executable
        self.exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        exitSource.setEventHandler { [weak self] in self?.reap() }
        exitSource.resume()
        // The child may already have exited before the source was armed.
        DispatchQueue.global().async { [weak self] in self?.reapIfExited() }
    }

    deinit {
        exitSource.cancel()
        // Never leave a running or unreaped child behind when the owner goes away.
        if !hasExited {
            let pid = self.pid
            killpg(pid, SIGKILL)
            kill(pid, SIGKILL)
            DispatchQueue.global().async { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
        }
    }

    public var hasExited: Bool { lock.withLock { exitStatus != nil } }

    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        if let status = exitStatus {
            lock.unlock()
            handler(status)
            return
        }
        exitHandlers.append(handler)
        lock.unlock()
    }

    /// Sends a signal to the plugin's whole process group (managed descendants).
    public func signal(_ sig: Int32) {
        guard !hasExited else { return }
        killpg(pid, sig)
        kill(pid, sig)
    }

    /// Waits up to `timeout` for exit; escalates SIGTERM then SIGKILL.
    public func terminate(grace: Duration = .seconds(2)) async {
        if hasExited { return }
        signal(SIGTERM)
        let deadline = ContinuousClock.now + grace
        while !hasExited && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if !hasExited { signal(SIGKILL) }
        while !hasExited { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func reapIfExited() {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { finish(status) }
    }

    private func reap() {
        var status: Int32 = 0
        let result = waitpid(pid, &status, 0)
        if result == pid { finish(status) } else if result < 0 && errno == ECHILD { finish(-1) }
    }

    private func finish(_ status: Int32) {
        lock.lock()
        if exitStatus != nil { lock.unlock(); return }
        exitStatus = status
        let handlers = exitHandlers
        exitHandlers.removeAll()
        lock.unlock()
        exitSource.cancel()
        for handler in handlers { handler(status) }
    }

    static func sanitizedEnvironment(locale: String) -> [String] {
        // Drop DYLD_*, MallocStackLogging and anything else that affects loading or debugging.
        let language = locale.replacingOccurrences(of: "-", with: "_")
        return [
            "PATH=/usr/bin:/bin",
            "LANG=\(language).UTF-8",
            "RUYIO_PLUGIN=1",
        ]
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
