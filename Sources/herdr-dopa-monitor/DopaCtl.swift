import Foundation
import Darwin

enum DopaError: Error, CustomStringConvertible {
    case spawnFailed(String)
    case signalRefused(pid: Int32, reason: String)

    var description: String {
        switch self {
        case .spawnFailed(let message):
            return message
        case .signalRefused(let pid, let reason):
            return "cannot signal dopa session (pid \(pid)): \(reason)"
        }
    }
}

/// Thin, auditable wrappers around the dopa CLI. A dopa session is bound to
/// the lifetime of its `dopa` process; the monitor owns exactly one child and
/// never touches sessions created by the user, Dopa.app, or other tools.
/// Mirrors the original Python `dopa_ctl.py`.
enum DopaCtl {
    static let DEFAULT_DOPA_BIN = "/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa"
    static let TERMINATE_TIMEOUT_SECONDS: TimeInterval = 10.0

    /// Resolve the dopa binary: DOPA_BIN env > configured value > default.
    static func binPath(configured: String? = nil) -> String {
        if let env = Env.getNonEmpty("DOPA_BIN")?.trimmingCharacters(in: .whitespaces),
           !env.isEmpty {
            return env
        }
        if let configured = configured?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            return configured
        }
        return DEFAULT_DOPA_BIN
    }

    /// Cheap, side-effect-free existence check for the dopa binary.
    static func isDopaAvailable(_ bin: String? = nil) -> Bool {
        let candidate = binPath(configured: bin)
        return FsUtil.isFile(candidate) && FsUtil.isExecutableFile(candidate)
    }

    /// Build the argv for one owned dopa session.
    static func buildArgv(bin: String? = nil,
                          keepDisplayOn: Bool = false,
                          stopOnLidClose: Bool = false) -> [String] {
        var argv = [binPath(configured: bin)]
        if keepDisplayOn { argv.append("--keep-display-on") }
        if stopOnLidClose { argv.append("--stop-on-lid-close") }
        return argv
    }

    // MARK: - spawn (detached via posix_spawn POSIX_SPAWN_SETSID)

    /// Start one owned dopa session and return the child PID.
    ///
    /// The child is detached (own session via POSIX_SPAWN_SETSID, like Python's
    /// start_new_session=True) so terminal signals aimed at the monitor do not
    /// leak into it; the monitor ends it explicitly with terminateSession.
    /// Its stdio is /dev/null — the monitor logs to its own stdout, which the
    /// LaunchAgent captures.
    @discardableResult
    static func spawnSession(bin: String? = nil,
                             keepDisplayOn: Bool = false,
                             stopOnLidClose: Bool = false) throws -> Int32 {
        let argv = buildArgv(bin: bin, keepDisplayOn: keepDisplayOn,
                             stopOnLidClose: stopOnLidClose)
        if !isDopaAvailable(argv[0]) {
            throw DopaError.spawnFailed("dopa binary not found or not executable: \(argv[0])")
        }
        return try spawnDetached(argv: argv)
    }

    static func spawnDetached(argv: [String]) throws -> Int32 {
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let holders = argv.map { strdup($0)! }
        defer { holders.forEach { free($0) } }

        var pid: pid_t = 0
        let rv = holders.withUnsafeBufferPointer { buffer -> Int32 in
            var cargv = Array(buffer) + [nil]
            return cargv.withUnsafeMutableBufferPointer { raw in
                posix_spawn(&pid, raw.baseAddress![0]!, &fileActions, &attr,
                            raw.baseAddress!, environ)
            }
        }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)
        if rv != 0 {
            throw DopaError.spawnFailed(
                "could not start dopa (\(argv.joined(separator: " "))): "
                + String(cString: strerror(rv)))
        }
        return pid
    }

    // MARK: - liveness / termination

    /// True if `pid` names a live process (ours or anyone's). A zombie child
    /// of this process is reaped and reported as dead: without this, a dopa
    /// child we just terminated would still answer `kill 0` until reaped.
    static func isPidAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        var status: Int32 = 0
        let done = waitpid(pid, &status, WNOHANG)
        if done == pid {
            return false // zombie child, just reaped
        }
        if done == -1 {
            if errno == ECHILD {
                // not our child (or already reaped); fall through to kill check
            } else {
                return false
            }
        }
        if kill(pid, 0) == 0 {
            return true
        }
        if errno == EPERM {
            return true // exists, but not ours to signal
        }
        return false
    }

    /// End the owned dopa session `pid`; true when it is gone. Already-dead
    /// PIDs count as success. SIGTERM first (dopa shuts its session down
    /// gracefully), SIGKILL fallback after `timeout`. Never fails for a
    /// missing process; throws DopaError only when signalling is refused.
    @discardableResult
    static func terminateSession(_ pid: Int32?,
                                 timeout: TimeInterval = TERMINATE_TIMEOUT_SECONDS) throws -> Bool {
        guard let pid, pid > 0 else { return true }
        do {
            try signalChild(pid, SIGTERM)
        } catch {
            throw error
        }
        let deadline = Date().addingTimeInterval(max(0.5, timeout))
        while Date() < deadline {
            if !isPidAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? signalChild(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        return !isPidAlive(pid)
    }

    private static func signalChild(_ pid: Int32, _ sig: Int32) throws {
        if kill(pid, sig) == 0 { return }
        switch errno {
        case ESRCH:
            return // already gone: success
        case EPERM:
            throw DopaError.signalRefused(pid: pid, reason: "operation not permitted")
        default:
            throw DopaError.signalRefused(
                pid: pid, reason: String(cString: strerror(errno)))
        }
    }

    // MARK: - daemon status

    /// Best-effort `dopa-daemon status --json`; nil when unavailable. Never
    /// creates a session, never escalates: the daemon answers on its public
    /// socket without sudo. Any failure (not installed, not running,
    /// unparseable output) returns nil so callers can show "unknown".
    static func daemonStatus(bin: String? = nil) -> [String: Any]? {
        let resolved = binPath(configured: bin)
        let daemon = (resolved as NSString).deletingLastPathComponent + "/dopa-daemon"
        guard FsUtil.isFile(daemon) && FsUtil.isExecutableFile(daemon) else {
            return nil
        }
        guard let result = ProcRunner.capture([daemon, "status", "--json"], timeout: 10),
              result.exitCode == 0 else {
            return nil
        }
        guard let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            return nil
        }
        return dict
    }
}
