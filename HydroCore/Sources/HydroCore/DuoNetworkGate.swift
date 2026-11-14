import Foundation

/// A local consent stop, independent of the server's availability and of an identity wipe.
/// Unreadable consent pauses work; a known refusal cannot be lifted by a later successful read.
public final class DuoNetworkGate: @unchecked Sendable {
    public enum State: Sendable { case open, unavailable, refused }
    private let lock = NSLock()
    private var heldState: State = .unavailable
    private var generation = 0
    private var nextID = 0
    private var running: [Int: @Sendable () -> Void] = [:]

    public init() {}
    public var state: State { lock.withLock { heldState } }
    public var revision: Int { lock.withLock { generation } }

    @discardableResult
    public func transition(to proposed: State) -> Bool {
        let change: (Bool, [@Sendable () -> Void]) = lock.withLock {
            let next = heldState == .refused ? State.refused : proposed
            guard heldState != next else { return (false, []) }
            heldState = next
            generation += 1
            let cancel = Array(running.values)
            running.removeAll()
            return (true, cancel)
        }
        change.1.forEach { $0() }
        return change.0
    }

    /// Register before work starts, invalidate late answers, and cancel outstanding ordinary
    /// work when consent changes. Deletion is the sole exception and never enters the registry.
    public func run<T: Sendable>(deletion: Bool = false, preservingDispatchedAnswer: Bool = false,
                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if deletion { return try await operation() }
        let started: (Int, Task<T, Error>) = try lock.withLock {
            guard heldState == .open else { throw CancellationError() }
            nextID += 1
            let id = nextID
            let revision = generation
            let task = Task {
                try self.validate(revision)
                let result = try await operation()
                if !preservingDispatchedAnswer { try self.validate(revision) }
                return result
            }
            // A dispatched rotation's answer contains the only new credential. Losing it would
            // prevent the remaining permitted DELETE. It may finish, but cannot start if blocked.
            if !preservingDispatchedAnswer { running[id] = { task.cancel() } }
            return (id, task)
        }
        defer { _ = lock.withLock { running.removeValue(forKey: started.0) } }
        return try await withTaskCancellationHandler {
            try await started.1.value
        } onCancel: {
            started.1.cancel()
        }
    }

    private func validate(_ revision: Int) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard heldState == .open, generation == revision else { throw CancellationError() }
        }
    }
}
