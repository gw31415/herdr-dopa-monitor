import Darwin
import Foundation

struct AgentObservation: Equatable {
    let total: Int
    let working: Int
}

enum HerdrObserver {
    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let fileManager = FileManager.default
        let home = environment["HOME"] ?? NSHomeDirectory()
        let environmentSocket = nonEmpty(environment["HERDR_SOCKET_PATH"])
        let root: String
        if let socket = environmentSocket {
            let parent = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let grandparent = parent.deletingLastPathComponent()
            root = grandparent.lastPathComponent == "sessions"
                ? grandparent.deletingLastPathComponent().path
                : parent.path
        } else {
            root = home + "/.config/herdr"
        }

        var candidates = [root + "/herdr.sock"]
        let sessions = root + "/sessions"
        if let names = try? fileManager.contentsOfDirectory(atPath: sessions) {
            candidates += names.sorted().map { sessions + "/\($0)/herdr.sock" }
        }
        if let environmentSocket { candidates.append(environmentSocket) }

        var seen = Set<String>()
        return candidates.filter { path in
            guard seen.insert(path).inserted else { return false }
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
    }

    static func observe(environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentObservation? {
        var total = 0
        var working = 0
        var answered = false
        for socket in socketPaths(environment: environment) {
            guard let statuses = try? statuses(socketPath: socket) else { continue }
            answered = true
            total += statuses.count
            working += statuses.filter { $0 == "working" }.count
        }
        return answered ? AgentObservation(total: total, working: working) : nil
    }

    static func statuses(socketPath: String) throws -> [String] {
        let connection = try UnixSocketConnection(path: socketPath)
        defer { connection.closeConnection() }
        try connection.sendJSONObject([
            "id": "hd-observe-\(UUID().uuidString)",
            "method": "agent.list",
            "params": [:],
        ])
        let response = try connection.readJSONObject()
        guard response["error"] == nil else {
            throw DopaError.protocolError("agent.list failed: \(DopaClient.summary(response))")
        }
        var statuses: [String] = []
        collectAgentStatuses(response, into: &statuses)
        return statuses
    }

    private static func collectAgentStatuses(_ value: Any, into output: inout [String]) {
        if let dictionary = value as? [String: Any] {
            if let status = dictionary["agent_status"] as? String { output.append(status) }
            for child in dictionary.values { collectAgentStatuses(child, into: &output) }
        } else if let array = value as? [Any] {
            for child in array { collectAgentStatuses(child, into: &output) }
        }
    }
}

enum PluginRegistryState: Equatable {
    case enabled
    case disabled
    case missing
    case unavailable
}

enum PluginRegistry {
    static func state(at path: String) -> PluginRegistryState {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let plugins = object as? [[String: Any]] else { return .unavailable }
        guard let plugin = plugins.first(where: { $0["plugin_id"] as? String == pluginID }) else {
            return .missing
        }
        guard let enabled = plugin["enabled"] as? Bool else { return .unavailable }
        return enabled ? .enabled : .disabled
    }
}
