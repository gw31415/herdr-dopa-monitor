import Darwin
import Foundation

enum UnixSocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case pathTooLong(String)
    case eof
    case responseTooLarge
    case invalidJSON(String)

    var description: String {
        switch self {
        case let .system(operation, code):
            return "\(operation): \(String(cString: strerror(code)))"
        case let .pathTooLong(path): return "Unix socket path is too long: \(path)"
        case .eof: return "socket closed before a response was received"
        case .responseTooLarge: return "socket response exceeded 1 MiB"
        case let .invalidJSON(text): return "invalid JSON response: \(text.prefix(300))"
        }
    }
}

final class UnixSocketConnection {
    private(set) var descriptor: Int32 = -1
    private var receiveBuffer = Data()

    init(path: String, timeout: TimeInterval = 5) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.system("socket", errno) }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw UnixSocketError.system("setsockopt SO_NOSIGPIPE", errno)
            }
            var timeoutValue = timeval(
                tv_sec: Int(timeout),
                tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
            )
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue,
                           socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue,
                           socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8CString)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= capacity else { throw UnixSocketError.pathTooLong(path) }
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                target.initializeMemory(as: UInt8.self, repeating: 0)
                target.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard status == 0 else { throw UnixSocketError.system("connect \(path)", errno) }
        } catch {
            close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { closeConnection() }

    func closeConnection() {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UnixSocketError.system("send", errno) }
                offset += count
            }
        }
    }

    func sendJSONObject(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        try send(data)
    }

    func readJSONObject() throws -> [String: Any] {
        let data = try readLine()
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw UnixSocketError.invalidJSON(String(data: data, encoding: .utf8) ?? "<non-UTF8>")
        }
        return dictionary
    }

    func readLine() throws -> Data {
        while true {
            if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let line = receiveBuffer[..<newline]
                receiveBuffer.removeSubrange(...newline)
                return Data(line)
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count == 0, !receiveBuffer.isEmpty {
                    defer { receiveBuffer.removeAll() }
                    return receiveBuffer
                }
                if count == 0 { throw UnixSocketError.eof }
                throw UnixSocketError.system("recv", errno)
            }
            receiveBuffer.append(contentsOf: bytes.prefix(count))
            guard receiveBuffer.count <= 1_048_576 else { throw UnixSocketError.responseTooLarge }
        }
    }

}
