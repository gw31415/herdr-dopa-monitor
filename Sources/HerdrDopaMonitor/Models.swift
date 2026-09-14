import Darwin
import Foundation

let pluginID = "herdr-dopa-monitor"
let pluginVersion = "0.2.0"
let dopaAPIVersion = 1
let minimumDopaVersion = SemanticVersion(0, 3, 3)

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(fields[0]),
              let minor = Int(fields[1]),
              let patch = Int(fields[2]) else { return nil }
        self.init(major, minor, patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct GuardConfig: Codable, Equatable {
    var keepDisplayOn = false
    var stopOnLidClose = false
    var dopaSocket = "/var/run/dopa/control.sock"

    enum CodingKeys: String, CodingKey {
        case keepDisplayOn = "keep_display_on"
        case stopOnLidClose = "stop_on_lid_close"
        case dopaSocket = "dopa_sock"
    }
}

enum MonitorState: String, Codable {
    case off
    case on
    case error
}

struct GuardState: Codable, Equatable {
    var monitorState: MonitorState = .off
    var sessionID: String?
    var holderPID: Int32?
    var holderToken: String?
    var holderRequestPath: String?
    var lastWorking = false
    var agentCount = -1
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case monitorState = "monitor_state"
        case sessionID = "session_id"
        case holderPID = "holder_pid"
        case holderToken = "holder_token"
        case holderRequestPath = "holder_request_path"
        case lastWorking = "last_working"
        case agentCount = "agent_count"
        case lastError = "last_error"
    }
}

struct HolderRequest: Codable, Equatable {
    let token: String
    let dopaSocket: String
    let keepDisplayOn: Bool
    let stopOnLidClose: Bool
    let pluginRegistry: String
    let readyPath: String
    let errorPath: String
    let endReasonPath: String
}

struct HolderReady: Codable, Equatable {
    let token: String
    let pid: Int32
    let sessionID: String
}

struct Paths {
    let configDirectory: String
    let stateDirectory: String
    let pluginRegistry: String

    var configFile: String { configDirectory + "/config.json" }
    var legacyConfigFile: String { configDirectory + "/config" }
    var stateFile: String { stateDirectory + "/state.json" }
    var legacyStateFile: String { stateDirectory + "/state" }
    var lockFile: String { stateDirectory + "/monitor.lock" }
    var holderDirectory: String { stateDirectory + "/holder" }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let xdgConfig = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        let xdgState = environment["XDG_STATE_HOME"] ?? home + "/.local/state"
        let config = nonEmpty(environment["HERDR_DOPA_CONFIG_DIR"])
            ?? nonEmpty(environment["HERDR_PLUGIN_CONFIG_DIR"])
            ?? xdgConfig + "/herdr/plugins/config/" + pluginID
        let state = nonEmpty(environment["HERDR_DOPA_STATE_DIR"])
            ?? nonEmpty(environment["HERDR_PLUGIN_STATE_DIR"])
            ?? xdgState + "/herdr/plugins/" + pluginID

        let registry: String
        if let override = nonEmpty(environment["HERDR_DOPA_PLUGIN_REGISTRY_FILE"]) {
            registry = override
        } else if let pluginConfig = nonEmpty(environment["HERDR_PLUGIN_CONFIG_DIR"]) {
            let configRoot = URL(fileURLWithPath: pluginConfig)
                .deletingLastPathComponent() // config
                .deletingLastPathComponent() // plugins
                .deletingLastPathComponent() // herdr
            registry = configRoot.appendingPathComponent("plugins.json").path
        } else if let configPath = nonEmpty(environment["HERDR_CONFIG_PATH"]) {
            registry = URL(fileURLWithPath: configPath)
                .deletingLastPathComponent().appendingPathComponent("plugins.json").path
        } else {
            registry = xdgConfig + "/herdr/plugins.json"
        }
        return Self(configDirectory: config, stateDirectory: state, pluginRegistry: registry)
    }
}

func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

enum Store {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func ensureDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func load<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try ensureDirectory(url.deletingLastPathComponent().path)
        let data = try encoder.encode(value)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try data.write(to: temporary, options: .completeFileProtectionUnlessOpen)
        if rename(temporary.path, path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func loadConfig(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) -> GuardConfig {
        var config = load(GuardConfig.self, from: paths.configFile)
            ?? loadLegacyConfig(from: paths.legacyConfigFile)
            ?? GuardConfig()
        if let socket = nonEmpty(environment["DOPA_SOCK"]) {
            config.dopaSocket = socket
        }
        if config.dopaSocket.isEmpty { config.dopaSocket = GuardConfig().dopaSocket }
        return config
    }

    static func loadState(paths: Paths) -> GuardState {
        load(GuardState.self, from: paths.stateFile)
            ?? loadLegacyState(from: paths.legacyStateFile)
            ?? GuardState()
    }

    private static func loadLegacyConfig(from path: String) -> GuardConfig? {
        guard let values = loadLegacyKeyValues(from: path) else { return nil }
        return GuardConfig(
            keepDisplayOn: values["KEEP_DISPLAY_ON"] == "true",
            stopOnLidClose: values["STOP_ON_LID_CLOSE"] == "true",
            dopaSocket: nonEmpty(values["DOPA_SOCK"]) ?? GuardConfig().dopaSocket
        )
    }

    private static func loadLegacyState(from path: String) -> GuardState? {
        guard let values = loadLegacyKeyValues(from: path) else { return nil }
        return GuardState(
            monitorState: MonitorState(rawValue: values["STATE"] ?? "") ?? .off,
            sessionID: nonEmpty(values["SESSION_ID"]),
            holderPID: values["HOLDER_PID"].flatMap(Int32.init),
            lastWorking: values["LAST_WORKING"] == "true",
            agentCount: values["AGENT_COUNT"].flatMap(Int.init) ?? -1,
            lastError: nonEmpty(values["LAST_ERROR"])
        )
    }

    private static func loadLegacyKeyValues(from path: String) -> [String: String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            var value = String(line[line.index(after: equals)...])
            if value.count >= 2, value.first == "'", value.last == "'" {
                value.removeFirst()
                value.removeLast()
                value = value.replacingOccurrences(of: "'\\''", with: "'")
            }
            result[key] = value
        }
        return result.isEmpty ? nil : result
    }
}

enum FileLock {
    static func withExclusiveLock<T>(at path: String, body: () throws -> T) rethrows -> T {
        try? Store.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX) != 0 { return try body() }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
