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
    static let BASE_LABEL = "com.herdr.dopa.monitor"
    static let PLUGIN_ID = "dopa-macos"
    static let SESSION_ENV_KEYS = ["HERDR_SESSION_NAME", "HERDR_SESSION"]
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
        return home + "/Library/Application Support/" + LEGACY_APP_SUPPORT + "/" + slug
    }

    static func paths(homeDir: String? = nil) throws -> LAPaths {
        let home = homeDir ?? NSHomeDirectory()
        let slug = try sessionSlug()
        let labelName = "\(BASE_LABEL).\(slug)"
        return LAPaths(
            label: labelName,
            configDir: sessionSubdir(envVar: "HERDR_PLUGIN_CONFIG_DIR", home: home, slug: slug),
            stateDir: sessionSubdir(envVar: "HERDR_PLUGIN_STATE_DIR", home: home, slug: slug),
            logDir: home + "/Library/Logs/" + LEGACY_APP_SUPPORT + "/" + slug,
            plist: home + "/Library/LaunchAgents/\(labelName).plist"
        )
    }
}
