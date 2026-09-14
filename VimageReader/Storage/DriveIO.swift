import Foundation

enum DriveError: LocalizedError {
    case disconnected
    case notResponding

    var errorDescription: String? {
        switch self {
        case .disconnected: return "The drive is disconnected. Plug it back in, or choose it again."
        case .notResponding: return "The drive isn't responding. It may have been unplugged."
        }
    }
}

/// Every read and write on the external drive goes through here.
///
/// When a drive is unplugged, file calls on it don't fail quickly: they block, sometimes
/// for minutes. Run on Swift's small shared thread pool, a handful of those would stall
/// every task in the app. So drive work runs on its own queue, callers stop waiting after
/// a timeout, and while the drive is known to be gone new work fails immediately.
enum DriveIO {
    private static let queue = DispatchQueue(
        label: "plugroll.drive-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static let availability = LockedValue(true)
    private static let probeRunning = LockedValue(false)

    /// False while the drive is unplugged or not answering. Set by `AppState`'s monitor.
    static var isAvailable: Bool {
        get { availability.value }
        set { availability.value = newValue }
    }

    /// Blocking file work on the drive. `timeout` nil waits as long as it takes
    /// (for copies of big videos); otherwise throws `.notResponding` when it runs out.
    static func run<T>(timeout: TimeInterval? = nil, _ work: @escaping () throws -> T) async throws -> T {
        guard isAvailable else { throw DriveError.disconnected }
        return try await perform(timeout: timeout, work)
    }

    /// Async drive work (AVFoundation) with a timeout. A slot in a limiter held by a
    /// load that never returns would otherwise block every later thumbnail.
    static func withTimeout<T>(_ timeout: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        guard isAvailable else { throw DriveError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let task = Task {
                do {
                    once.resume(with: .success(try await operation()))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                task.cancel()
                once.resume(with: .failure(DriveError.notResponding))
            }
        }
    }

    /// Starts blocking work on the drive queue without waiting for it (e.g. a folder walk
    /// that reports results as it goes).
    static func start(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Whether the drive at `url` answers within a few seconds. Never piles up: if the last
    /// check is still stuck inside the file system, the drive counts as gone.
    static func probe(_ url: URL) async -> Bool {
        guard probeRunning.exchange(true) == false else { return false }
        do {
            return try await perform(timeout: 3) {
                defer { probeRunning.value = false }
                // Deliberately lenient: wrongly reporting "connected" only falls back to the
                // timeouts, but wrongly reporting "gone" would block a working drive.
                var fresh = url
                fresh.removeAllCachedResourceValues()
                return (try? fresh.checkResourceIsReachable()) == true
            }
        } catch {
            return false
        }
    }

    private static func perform<T>(timeout: TimeInterval?, _ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            queue.async {
                once.resume(with: Result { try work() })
            }
            if let timeout {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    once.resume(with: .failure(DriveError.notResponding))
                }
            }
        }
    }
}

/// Resumes a continuation at most once, whichever of the work or the timeout finishes first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Sets a new value and returns the old one, atomically.
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let old = stored
            stored = newValue
            return old
        }
    }
}
