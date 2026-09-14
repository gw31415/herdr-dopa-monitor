import Foundation

enum DopaError: Error, CustomStringConvertible {
    case protocolError(String)

    var description: String {
        switch self {
        case let .protocolError(message): return message
        }
    }
}

enum DopaClient {
    static func connect(socketPath: String) throws -> UnixSocketConnection {
        let connection = try UnixSocketConnection(path: socketPath)
        do {
            let response = try request(
                connection,
                id: "hd-hello-\(UUID().uuidString)",
                method: "hello",
                params: [
                    "apiVersion": dopaAPIVersion,
                    "client": ["name": pluginID, "version": pluginVersion],
                ]
            )
            guard let result = response["result"] as? [String: Any],
                  numberIsOne(result["apiVersion"]),
                  let rawVersion = result["daemonVersion"] as? String,
                  let daemonVersion = SemanticVersion(rawVersion),
                  daemonVersion >= minimumDopaVersion else {
                throw DopaError.protocolError(
                    "dopa API handshake failed (requires Dopa >=0.3.3, API v1): \(summary(response))"
                )
            }
            return connection
        } catch {
            connection.closeConnection()
            throw error
        }
    }

    static func acquire(_ connection: UnixSocketConnection, keepDisplayOn: Bool) throws -> String {
        let response = try request(
            connection,
            id: "hd-acquire-\(UUID().uuidString)",
            method: "session.acquire",
            params: ["options": ["keepDisplayOn": keepDisplayOn]]
        )
        guard let result = response["result"] as? [String: Any],
              let sessionID = result["sessionId"] as? String,
              !sessionID.isEmpty else {
            throw DopaError.protocolError("dopa acquire failed: \(summary(response))")
        }
        return sessionID
    }

    static func release(_ connection: UnixSocketConnection, sessionID: String) {
        _ = try? request(
            connection,
            id: "hd-release-\(UUID().uuidString)",
            method: "session.release",
            params: ["sessionId": sessionID]
        )
    }

    static func sessionIsAlive(socketPath: String, sessionID: String) -> Bool {
        guard !sessionID.isEmpty,
              let connection = try? connect(socketPath: socketPath) else { return false }
        defer { connection.closeConnection() }
        guard let response = try? request(
            connection,
            id: "hd-status-\(UUID().uuidString)",
            method: "status.get",
            params: [:]
        ), response["result"] != nil else { return false }
        return containsString(sessionID, in: response["result"] as Any)
    }

    static func request(
        _ connection: UnixSocketConnection,
        id: String,
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        try connection.sendJSONObject(["id": id, "method": method, "params": params])
        let response = try connection.readJSONObject()
        if let error = response["error"] {
            throw DopaError.protocolError("\(method) returned an error: \(summary(error))")
        }
        return response
    }

    static func numberIsOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }

    static func containsString(_ needle: String, in value: Any) -> Bool {
        if let string = value as? String { return string == needle }
        if let array = value as? [Any] { return array.contains { containsString(needle, in: $0) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsString(needle, in: $0) }
        }
        return false
    }

    static func summary(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value).prefix(300).description
        }
        return text.prefix(300).description
    }
}
