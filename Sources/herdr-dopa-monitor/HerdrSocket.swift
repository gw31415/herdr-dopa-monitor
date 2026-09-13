import Foundation
import Darwin

enum HerdrError: Error, CustomStringConvertible {
    case socketUnavailable(path: String, reason: String)
    case parseFailed(String)
    case socketError(String)
    case notInSession

    var description: String {
        switch self {
        case .socketUnavailable(let path, let reason):
            return "herdr socket unavailable at '\(path)': \(reason)"
        case .parseFailed(let reason):
            return "could not parse herdr socket response as JSON: \(reason)"
        case .socketError(let message):
            return "herdr socket error: \(message)"
        case .notInSession:
            return "HERDR_SOCKET_PATH is not set; not running from a herdr session"
        }
    }
}

/// herdr observation over the session's Unix socket. The LaunchAgent (and any
/// herdr pane) pins HERDR_SOCKET_PATH; if that env is absent this process is
/// outside a herdr session and must not probe user-facing CLI paths that may
/// trigger terminal notifications. Mirrors the Python `monitor.py` socket code.
enum HerdrSocket {
    static func agentStatusesFromResponse(_ data: [String: Any]) -> [String] {
        let result = (data["result"] as? [String: Any]) ?? [:]
        let agents = (result["agents"] as? [[String: Any]]) ?? []
        return agents.map { ($0["agent_status"] as? String) ?? "unknown" }
    }

    /// Read herdr agent statuses: send one {"id","method":"agent.list"} JSON
    /// line, read the first newline-terminated response, extract
    /// result.agents[].agent_status. Throws HerdrError on any failure.
    static func agentStatusesFromSocket(_ socketPath: String) throws -> [String] {
        let request: [String: Any] = [
            "id": "herdr-dopa-monitor:agent:list",
            "method": "agent.list",
            "params": [String: Any](),
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        var payload = requestData
        payload.append(UInt8(ascii: "\n"))

        let response = try roundTrip(socketPath: socketPath, payload: payload)

        guard let text = String(data: response, encoding: .utf8) else {
            throw HerdrError.parseFailed("response is not valid UTF-8")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw HerdrError.parseFailed(trimmed.isEmpty ? "<empty>" : trimmed)
        }
        if let error = dict["error"] {
            if let errDict = error as? [String: Any] {
                let message = (errDict["message"] as? String) ?? String(describing: errDict)
                throw HerdrError.socketError(message)
            }
            if let message = error as? String {
                throw HerdrError.socketError(message)
            }
            throw HerdrError.socketError(String(describing: error))
        }
        return agentStatusesFromResponse(dict)
    }

    /// Connect, send, and read one newline-terminated response (or EOF).
    private static func roundTrip(socketPath: String, payload: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrError.socketUnavailable(
                path: socketPath, reason: "socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HerdrError.socketUnavailable(path: socketPath, reason: "path too long")
        }
        pathBytes.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: raw)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw HerdrError.socketUnavailable(
                path: socketPath, reason: String(cString: strerror(errno)))
        }

        try sendAll(fd: fd, payload: payload)

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !buffer.isEmpty { break } // partial data at timeout: use it
                    throw HerdrError.socketUnavailable(path: socketPath, reason: "timed out")
                }
                throw HerdrError.socketUnavailable(
                    path: socketPath, reason: String(cString: strerror(errno)))
            }
            if n == 0 { break } // EOF
            let piece = chunk[0..<n]
            buffer.append(contentsOf: piece)
            if piece.contains(UInt8(ascii: "\n")) { break }
        }
        return buffer
    }

    private static func sendAll(fd: Int32, payload: Data) throws {
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, raw.baseAddress!.advanced(by: offset),
                                raw.count - offset, 0)
                if sent <= 0 {
                    throw HerdrError.socketUnavailable(
                        path: "", reason: String(cString: strerror(errno)))
                }
                offset += sent
            }
        }
    }

    /// The runtime read path: HERDR_SOCKET_PATH only.
    static func getAgentStatuses() throws -> [String] {
        guard let socketPath = Env.getNonEmpty("HERDR_SOCKET_PATH") else {
            throw HerdrError.notInSession
        }
        return try agentStatusesFromSocket(socketPath)
    }
}
