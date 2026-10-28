/// Serializes multi-request document mutations across suspension points. Actor isolation alone
/// would allow another mutation to interleave while a storage RPC is awaiting its reply.
actor ClipboardMutationQueue {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
}
