import Foundation
import Darwin

/// Cross-process mutual exclusion for monitor state updates.
///
/// Three kinds of runners mutate `<state_dir>/state.json`: the poll daemon,
/// `herdr-dopa-monitor once`, and `herdr-dopa-monitor event` (invoked by
/// herdr plugin event hooks, potentially at the same moment the daemon is
/// iterating). Each holds an advisory POSIX `flock` on
/// `<state_dir>/monitor.lock` across its whole load -> iterate -> save
/// critical section, so two runners can never double-spawn or
/// double-terminate the owned dopa child. Foundation/Darwin only; no
/// external dependencies.
///
/// `flock` locks are per open file description, so this works both between
/// processes and between two opens inside one process. The flip side: the
/// lock is NOT reentrant — a nested `withLock` on the same path from the same
/// thread would deadlock against itself. Keep every critical section flat;
/// never call `withLock` from inside a `withLock` body.
enum StateLock {

    /// `<state_dir>/monitor.lock` for a given state.json path.
    static func lockPath(forState statePath: String) -> String {
        let dir = (statePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "monitor.lock" : dir + "/monitor.lock"
    }

    /// Run `body` while holding an exclusive, blocking flock on the lock
    /// file, then return its result. The wait is bounded in practice: a
    /// holder keeps the lock for at most one monitor iteration.
    ///
    /// If the lock file cannot be opened (for example an unwritable state
    /// dir), `body` still runs without the lock — monitoring availability
    /// beats strictness, and the atomic (rename-based) state write already
    /// makes torn files impossible either way.
    static func withLock<T>(statePath: String, _ body: () -> T) -> T {
        let path = lockPath(forState: statePath)
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { FsUtil.mkdirp(dir) }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}
