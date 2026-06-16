import Foundation

/// Process-level mutex backed by a file in the App Group container.
///
/// Both binaries (the GUI app and the headless CLI) need to coordinate access to the
/// SwiftData container — Apple's docs are explicit that a single `ModelContainer` per
/// store URL is the supported usage pattern, and concurrent opens from two processes
/// can corrupt the underlying SQLite file.
///
/// `LockFile` uses `flock(2)` (BSD-style advisory lock) on a sentinel file at
/// `<group-container>/file13.lock`. Acquiring the lock is cheap (one open + one
/// flock); releasing happens automatically when the file descriptor is closed, so a
/// process crash never strands the lock.
public final class LockFile: @unchecked Sendable {
    /// Outcome of attempting to acquire the lock without blocking.
    public enum AcquireResult: Sendable {
        case acquired
        case heldByOther
        case error(String)
    }

    private let path: String
    private var fd: Int32 = -1

    public init(name: String = "file13.lock") {
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.appGroupId) {
            self.path = dir.appendingPathComponent(name).path
        } else {
            // Fallback: a path under temp. The lock still protects within a single user
            // session even if the App Group container isn't reachable.
            self.path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        }
    }

    /// Try to take the lock without blocking. Returns immediately.
    public func tryAcquire() -> AcquireResult {
        if fd >= 0 { return .acquired } // already held by this instance

        // Open with O_CREAT so the sentinel exists; permissions 0644.
        let openFD = open(path, O_RDWR | O_CREAT, 0o644)
        if openFD < 0 {
            return .error("couldn't open lock file at \(path) (errno \(errno))")
        }

        // LOCK_EX | LOCK_NB → fail with EWOULDBLOCK if another process holds it.
        let rc = flock(openFD, LOCK_EX | LOCK_NB)
        if rc == 0 {
            self.fd = openFD
            return .acquired
        }
        let err = errno
        close(openFD)
        if err == EWOULDBLOCK {
            return .heldByOther
        }
        return .error("flock failed (errno \(err))")
    }

    /// Wait up to `timeout` seconds for the lock, polling every 250ms.
    public func acquire(timeout: TimeInterval) -> AcquireResult {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let result = tryAcquire()
            switch result {
            case .acquired, .error:
                return result
            case .heldByOther:
                if Date() >= deadline { return .heldByOther }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// Release the lock and close the underlying file descriptor.
    public func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }

    /// Path the lock file lives at. Useful in error messages.
    public var sentinelPath: String { path }
}
