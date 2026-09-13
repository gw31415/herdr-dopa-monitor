import Foundation

/// Persistent, CLI-editable configuration for the dopa sleep guard.
///
/// Settings live in `config.json` under the config directory; runtime state
/// lives in `state.json` under the state directory. Both resolve to
/// per-session subdirectories so concurrent herdr sessions stay isolated.
/// The daemon re-reads `config.json` every poll cycle, so `herdr-dopa set`
/// takes effect within one cycle without reinstalling the LaunchAgent.
///
/// Load precedence: environment (when set and non-empty) > config.json >
/// built-in default. Mirrors the original Python `config.py`.
enum Config {
    // Provisional dopa location (user-specified). Point it at a stable PATH
    // copy once dopa is installed elsewhere; the daemon never rewrites it.
    static let DEFAULT_DOPA_BIN = "/Users/ama/dopa/.build/Dopa.app/Contents/Helpers/dopa"

    /// Display/save order (matches the original DEFAULT_CONFIG insertion order).
    static let SET_KEYS: [String] = [
        "armed",
        "poll_seconds",
        "dopa_bin",
        "keep_display_on",
        "stop_on_lid_close",
        "herdr_bin_path",
    ]

    private static let envFloat: [(key: String, env: String)] = [
        ("poll_seconds", "HERDR_DOPA_POLL_SECONDS"),
    ]

    /// Standalone fallback root (also where pre-herdr runs keep working).
    private static func legacyDir() -> String {
        NSHomeDirectory() + "/Library/Application Support/herdr-dopa"
    }

    static func configDir() -> String {
        if let override = Env.getNonEmpty("HERDR_DOPA_CONFIG_DIR") {
            return override
        }
        return legacyDir()
    }

    static func stateDir() -> String {
        if let override = Env.getNonEmpty("HERDR_DOPA_STATE_DIR") {
            return override
        }
        return legacyDir()
    }

    static func configPath() -> String {
        configDir() + "/config.json"
    }

    /// Fresh, independent copy of the defaults (JSON-safe values only).
    static func defaultConfig() -> [String: Any] {
        [
            "armed": true,
            "poll_seconds": 5.0,
            "dopa_bin": DEFAULT_DOPA_BIN,
            "keep_display_on": false,
            "stop_on_lid_close": false,
            "herdr_bin_path": NSNull(),
        ]
    }

    // MARK: - JSON value coercion

    /// True only for JSON true/false (not for generic NSNumber, whose Bool
    /// bridge would turn any non-zero number into true).
    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func asDouble(_ value: Any?) -> Double? {
        if isJSONBoolean(value ?? NSNull()) { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func toDouble(_ value: Any?, _ fallback: Double) -> Double {
        asDouble(value) ?? fallback
    }

    static func toBool(_ value: Any?, _ fallback: Bool) -> Bool {
        guard let value else { return fallback }
        if isJSONBoolean(value) {
            return (value as! NSNumber).boolValue
        }
        if value is NSNull { return fallback }
        let s = stringified(value).lowercased()
        switch s {
        case "1", "true", "yes", "y", "on", "armed":
            return true
        case "0", "false", "no", "n", "off", "disarmed":
            return false
        default:
            return fallback
        }
    }

    private static func stringified(_ value: Any) -> String {
        if let s = value as? String { return s }
        if isJSONBoolean(value) { return (value as! NSNumber).boolValue ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value)
    }

    // MARK: - File I/O

    /// Load config.json merged over defaults. Never throws. Missing file,
    /// corrupt/unreadable file, or non-dict JSON all give defaults. Unknown
    /// keys are dropped so the schema stays forward-compatible.
    static func loadConfigFile() -> [String: Any] {
        var cfg = defaultConfig()
        let path = configPath()
        guard FsUtil.isFile(path),
              let data = FileManager.default.contents(atPath: path),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            return cfg
        }
        for key in SET_KEYS where dict[key] != nil {
            cfg[key] = dict[key]!
        }
        return cfg
    }

    /// Atomically write config.json (only known keys, validated first). Safe
    /// to call with a partial dict; missing keys fall back to defaults.
    static func saveConfigFile(_ cfg: [String: Any]) throws {
        var merged = defaultConfig()
        for key in SET_KEYS {
            merged[key] = cfg[key] ?? merged[key]!
        }
        let normalized = validate(merged)
        try FsUtil.atomicWriteJSON(path: configPath(), object: normalized)
    }

    // MARK: - Validate / env

    /// Coerce and clamp values into a sane config. Returns a new dict.
    /// Numerics are clamped non-negative (poll >= 1s); booleans accept bool or
    /// common true/false strings; paths may be empty (then default/nil).
    static func validate(_ cfg: [String: Any]?) -> [String: Any] {
        var out = defaultConfig()
        if let cfg {
            for key in SET_KEYS where cfg[key] != nil {
                out[key] = cfg[key]!
            }
        }
        out["armed"] = toBool(out["armed"], true)
        out["keep_display_on"] = toBool(out["keep_display_on"], false)
        out["stop_on_lid_close"] = toBool(out["stop_on_lid_close"], false)
        out["poll_seconds"] = max(1.0, toDouble(out["poll_seconds"], 5.0))
        // herdr_bin_path: nil/empty -> nil (JSON null)
        if let val = out["herdr_bin_path"] {
            if val is NSNull {
                out["herdr_bin_path"] = NSNull()
            } else {
                let s = stringified(val).trimmingCharacters(in: .whitespaces)
                out["herdr_bin_path"] = s.isEmpty ? NSNull() : s
            }
        } else {
            out["herdr_bin_path"] = NSNull()
        }
        // dopa_bin: empty/nil -> built-in default
        let dopaRaw = out["dopa_bin"].map(stringified) ?? ""
        let dopa = dopaRaw.trimmingCharacters(in: .whitespaces)
        out["dopa_bin"] = dopa.isEmpty ? DEFAULT_DOPA_BIN : dopa
        return out
    }

    /// Apply HERDR_DOPA_* / HERDR_BIN_PATH / DOPA_BIN env overrides. Env is
    /// applied only when set and non-empty.
    static func applyEnvOverrides(_ cfg: [String: Any]) -> [String: Any] {
        var out = cfg
        for (key, env) in envFloat {
            if let raw = Env.getNonEmpty(env) {
                // Parse failure keeps the existing value (validated later).
                if let parsed = asDouble(raw) {
                    out[key] = parsed
                }
            }
        }
        if let herdr = Env.getNonEmpty("HERDR_BIN_PATH") {
            out["herdr_bin_path"] = herdr
        }
        if let dopa = Env.getNonEmpty("DOPA_BIN") {
            out["dopa_bin"] = dopa
        }
        return out
    }

    /// Convenience: file -> env overrides -> validate. The canonical read path.
    static func loadResolved() -> [String: Any] {
        validate(applyEnvOverrides(loadConfigFile()))
    }

    /// herdr_bin_path as String? (JSON null / missing -> nil).
    static func herdrBinPath(_ cfg: [String: Any]) -> String? {
        guard let val = cfg["herdr_bin_path"], !(val is NSNull) else { return nil }
        let s = val as? String
        return (s?.isEmpty == false) ? s : nil
    }
}
