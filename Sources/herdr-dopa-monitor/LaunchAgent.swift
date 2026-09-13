import Foundation
import Darwin

/// Per-herdr-session LaunchAgent naming helpers for the dopa sleep guard.
/// Mirrors the original Python `launchagent.py`.

enum LaunchAgentError: Error, CustomStringConvertible {
    case ambiguousSession(names: [String])

    var description: String {
        switch self {
        case .ambiguousSession(let names):
            return "could not infer current herdr session; set HERDR_SESSION_NAME. "
                + "running sessions: \(names.joined(separator: ", "))"
        }
    }
}

struct LAPaths {
    let label: String
    let configDir: String
    let stateDir: String
    let logDir: String
    let plist: String
}

enum LaunchAgent {
    static let BASE_LABEL = "com.amas.herdr.dopa.monitor"
    /// Pre-rename label base. Kept only so install/uninstall can boot out
    /// and delete stale agents left by older installs of this plugin.
    static let LEGACY_BASE_LABEL = "com.herdr.dopa.monitor"
    static let PLUGIN_ID = "herdr-dopa-monitor"
    static let SESSION_ENV_KEYS = ["HERDR_SESSION_NAME", "HERDR_SESSION"]
    /// Standalone (non-herdr-injected) data dir name.
    static let APP_SUPPORT = "herdr-dopa-monitor"
    /// Pre-rename standalone data dir name. Kept only for the one-time
    /// data-dir migration (see `migrateLegacyDataDirs`).
    static let LEGACY_APP_SUPPORT = "herdr-dopa"

    static func sessionName() throws -> String {
        for key in SESSION_ENV_KEYS {
            if let val = Env.getNonEmpty(key) {
                return val
            }
        }
        if let result = ProcRunner.capture(
            ["herdr", "session", "list", "--json"], timeout: 5) {
            let sessions = jsonSessions(result)
            let running = sessions.filter { ($0["running"] as? Bool) == true }
            if running.count == 1 {
                let name = running[0]["name"] as? String
                return (name?.isEmpty == false) ? name! : "default"
            }
            if running.count > 1 {
                let names = running.map {
                    ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
                }
                throw LaunchAgentError.ambiguousSession(names: names)
            }
        }
        return "default"
    }

    /// Parse `herdr session list --json` output (accepts both the raw
    /// {"sessions": [...]} shape and an id/result envelope).
    static func jsonSessions(_ result: ProcResult) -> [[String: Any]] {
        guard result.exitCode == 0 else { return [] }
        guard let data = result.stdout.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var container = parsed
        if let inner = parsed["result"] as? [String: Any] {
            container = inner
        }
        return (container["sessions"] as? [[String: Any]]) ?? []
    }

    /// re.sub(r"[^A-Za-z0-9_.-]+", "-", name).strip("-") or "default",
    /// then a stable 8-hex-char SHA-1 suffix of the raw name.
    static func sessionSlug(_ name: String? = nil) throws -> String {
        let raw = try name ?? sessionName()
        let slug = slugify(raw)
        return "\(slug).\(String(SHA1.hex(raw).prefix(8)))"
    }

    static func slugify(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let v = scalar.value
            let good = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                || (v >= 0x30 && v <= 0x39)
                || scalar == "_" || scalar == "." || scalar == "-"
            if good {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        var trimmed = out
        while trimmed.hasPrefix("-") { trimmed.removeFirst() }
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed.isEmpty ? "default" : trimmed
    }

    static func label() throws -> String {
        "\(BASE_LABEL).\(try sessionSlug())"
    }

    static func domain() -> String {
        "gui/\(getuid())"
    }

    static func serviceTarget(labelName: String) -> String {
        "\(domain())/\(labelName)"
    }

    static func serviceTarget() throws -> String {
        try serviceTarget(labelName: label())
    }

    // MARK: - launchctl

    static func run(_ cmd: [String]) -> (Int32, String) {
        ProcRunner.runQuiet(cmd)
    }

    static func start(_ labelName: String? = nil) {
        let target = labelName.map { serviceTarget(labelName: $0) }
            ?? (try? serviceTarget())
        guard let target else { return }
        _ = run(["launchctl", "enable", target])
        _ = run(["launchctl", "kickstart", "-k", target])
    }

    static func stop(_ labelName: String? = nil) {
        let target = labelName.map { serviceTarget(labelName: $0) }
            ?? (try? serviceTarget())
        guard let target else { return }
        _ = run(["launchctl", "disable", target])
        _ = run(["launchctl", "kill", "TERM", target])
    }

    // MARK: - Paths

    /// A per-session data subdir under a plugin-scoped root.
    /// HERDR_PLUGIN_CONFIG_DIR / HERDR_PLUGIN_STATE_DIR (injected by herdr)
    /// are plugin-scoped roots, so the session slug is appended to keep
    /// concurrent sessions isolated. Otherwise the standalone
    /// ~/Library/Application Support root is used.
    private static func sessionSubdir(envVar: String, home: String, slug: String) -> String {
        if let root = Env.getNonEmpty(envVar) {
            return root + "/" + slug
        }
        return home + "/Library/Application Support/" + APP_SUPPORT + "/" + slug
    }

    static func paths(homeDir: String? = nil) throws -> LAPaths {
        let home = homeDir ?? NSHomeDirectory()
        let slug = try sessionSlug()
        let labelName = "\(BASE_LABEL).\(slug)"
        return LAPaths(
            label: labelName,
            configDir: sessionSubdir(envVar: "HERDR_PLUGIN_CONFIG_DIR", home: home, slug: slug),
            stateDir: sessionSubdir(envVar: "HERDR_PLUGIN_STATE_DIR", home: home, slug: slug),
            logDir: home + "/Library/Logs/" + APP_SUPPORT + "/" + slug,
            plist: home + "/Library/LaunchAgents/\(labelName).plist"
        )
    }

    // MARK: - Legacy label cleanup (com.herdr.* -> com.amas.*)

    /// Legacy label for the same session slug.
    static func legacyLabel(slug: String) -> String {
        "\(LEGACY_BASE_LABEL).\(slug)"
    }

    /// Map a current label to the legacy label of the same session slug.
    /// Nil when `label` is not one of ours (never guess on foreign labels).
    static func legacyLabel(forCurrentLabel label: String) -> String? {
        let prefix = BASE_LABEL + "."
        guard label.hasPrefix(prefix) else { return nil }
        return LEGACY_BASE_LABEL + "." + label.dropFirst(prefix.count)
    }

    static func legacyPlistPath(homeDir: String, slug: String) -> String {
        homeDir + "/Library/LaunchAgents/\(legacyLabel(slug: slug)).plist"
    }

    /// Boot out and delete a leftover pre-rename LaunchAgent for the same
    /// session slug as `currentLabel`. Only the exact legacy label for this
    /// slug is touched — no wildcard scans, so other sessions' agents and
    /// every other plist stay untouched. Returns true when legacy residue
    /// was found (and best-effort removed).
    @discardableResult
    static func cleanupLegacyAgent(
        currentLabel: String,
        homeDir: String,
        run: ([String]) -> (Int32, String) = LaunchAgent.run,
        log: (String) -> Void = { _ in }
    ) -> Bool {
        guard let legacy = legacyLabel(forCurrentLabel: currentLabel) else { return false }
        let plist = homeDir + "/Library/LaunchAgents/\(legacy).plist"
        guard FileManager.default.fileExists(atPath: plist) else { return false }
        log("booting out legacy LaunchAgent: \(legacy)")
        _ = run(["launchctl", "bootout", serviceTarget(labelName: legacy)])
        do {
            try FileManager.default.removeItem(atPath: plist)
            log("removed legacy plist: \(plist)")
        } catch {
            log("could not remove legacy plist \(plist): \(error)")
        }
        return true
    }

    // MARK: - Data dir migration (herdr-dopa -> herdr-dopa-monitor)

    /// Outcome of one legacy data-dir move.
    enum DataDirMigrationOutcome: Equatable {
        /// The legacy dir was moved to the current location.
        case moved
        /// Both dirs existed: the current one wins, the legacy dir is kept
        /// untouched (never merged, never deleted).
        case keptLegacy
        /// No legacy dir existed; nothing to do.
        case none
        /// The move failed; the legacy dir is intact and the caller should
        /// proceed with a freshly created current dir.
        case failed(String)
    }

    /// Pre-rename standalone Application Support slug dir.
    static func legacySupportDir(homeDir: String, slug: String) -> String {
        homeDir + "/Library/Application Support/" + LEGACY_APP_SUPPORT + "/" + slug
    }

    /// Pre-rename standalone Logs slug dir.
    static func legacyLogDir(homeDir: String, slug: String) -> String {
        homeDir + "/Library/Logs/" + LEGACY_APP_SUPPORT + "/" + slug
    }

    /// Move one legacy session data dir to its current location when only
    /// the legacy one exists. The current dir always wins: when both exist
    /// the legacy dir is preserved as-is for manual recovery. A failed move
    /// is logged and swallowed — the caller goes on to create/use the
    /// current dir fresh; the guard never falls back to reading the legacy
    /// layout. The legacy dir is never deleted by this code path.
    @discardableResult
    static func migrateSessionDataDir(
        legacy: String,
        current: String,
        log: (String) -> Void = { _ in }
    ) -> DataDirMigrationOutcome {
        let fm = FileManager.default
        var legacyIsDir = ObjCBool(false)
        guard fm.fileExists(atPath: legacy, isDirectory: &legacyIsDir),
              legacyIsDir.boolValue else {
            return .none
        }
        if fm.fileExists(atPath: current) {
            log("legacy data dir kept (current already exists): \(legacy)")
            return .keptLegacy
        }
        do {
            try fm.createDirectory(
                atPath: (current as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try fm.moveItem(atPath: legacy, toPath: current)
            log("migrated data dir: \(legacy) -> \(current)")
            return .moved
        } catch {
            log("could not migrate data dir \(legacy) -> \(current): \(error); "
                + "continuing with a fresh \(current)")
            return .failed(String(describing: error))
        }
    }

    /// Migrate this session's pre-rename standalone data dirs
    /// (`herdr-dopa/<slug>`) to the current layout
    /// (`herdr-dopa-monitor/<slug>`): the Application Support slug dir
    /// (config, state, and lock — they share the dir) and the Logs slug
    /// dir. Moves happen only when the current dir does not exist yet, so
    /// this is idempotent and safe to call at install time and once at
    /// daemon/once/event startup. Effective config/state targets honor the
    /// pinned `HERDR_DOPA_CONFIG_DIR` / `HERDR_DOPA_STATE_DIR` env (set by
    /// the plist or `withSessionEnv`) over the computed layout.
    ///
    /// Returns true when at least one dir was moved.
    @discardableResult
    static func migrateLegacyDataDirs(
        current: LAPaths,
        homeDir: String? = nil,
        log: (String) -> Void = { _ in }
    ) -> Bool {
        let home = homeDir ?? NSHomeDirectory()
        let prefix = BASE_LABEL + "."
        guard current.label.hasPrefix(prefix), current.label.count > prefix.count else {
            return false
        }
        let slug = String(current.label.dropFirst(prefix.count))
        let effectiveConfig = Env.getNonEmpty("HERDR_DOPA_CONFIG_DIR") ?? current.configDir
        let targets: [(legacy: String, current: String)] = [
            (legacySupportDir(homeDir: home, slug: slug), effectiveConfig),
            (legacyLogDir(homeDir: home, slug: slug), current.logDir),
        ]
        var movedAny = false
        for target in targets {
            if case .moved = migrateSessionDataDir(
                legacy: target.legacy, current: target.current, log: log) {
                movedAny = true
            }
        }
        return movedAny
    }
}
