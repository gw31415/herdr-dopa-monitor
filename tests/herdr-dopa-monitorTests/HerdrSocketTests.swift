import XCTest
import Darwin
@testable import herdr_dopa_monitor

/// A one-shot Unix-socket server that speaks the herdr agent.list protocol:
/// reads one newline-terminated JSON request, answers with a canned response.
final class FakeHerdrServer {
    let path: String
    let response: String
    private var listenFD: Int32 = -1

    init(path: String, response: String) {
        self.path = path
        self.response = response.hasSuffix("\n") ? response : response + "\n"
    }

    func start() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        bytes.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: raw)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(listen(listenFD, 1), 0)
        DispatchQueue.global().async { [weak self] in
            self?.serveOnce()
        }
    }

    private func serveOnce() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var sawRequest = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !sawRequest {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { break }
            sawRequest = chunk[0..<n].contains(UInt8(ascii: "\n"))
        }
        if sawRequest {
            _ = response.withCString { pointer in
                send(client, pointer, strlen(pointer), 0)
            }
        }
        Thread.sleep(forTimeInterval: 0.05) // let the client read before EOF
        close(client)
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }
}

/// Unit tests for the herdr socket client: response parsing, error mapping,
/// and the HERDR_SOCKET_PATH-only read path.
final class HerdrSocketTests: XCTestCase {

    var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        // Keep socket paths short: sockaddr_un.sun_path is only 104 bytes,
        // and NSTemporaryDirectory() is long. /tmp on macOS is a symlink to
        // private/tmp but the length stays under the limit.
        tmpDir = "/tmp/hd-sock-" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        Env.set("HERDR_SOCKET_PATH", nil)
        super.tearDown()
    }

    func testWorkingAgentResponse() throws {
        let server = FakeHerdrServer(
            path: tmpDir + "/herdr.sock",
            response: #"{"id":"x","result":{"type":"agent_list","agents":[{"agent_status":"working"},{"agent_status":"idle"}]}}"#)
        try server.start()
        defer { server.stop() }
        let statuses = try HerdrSocket.agentStatusesFromSocket(server.path)
        XCTAssertEqual(statuses, ["working", "idle"])
        XCTAssertTrue(anyAgentWorking(statuses))
    }

    func testUnknownStatusDefaults() throws {
        let server = FakeHerdrServer(
            path: tmpDir + "/herdr.sock",
            response: #"{"result":{"agents":[{} ,{"agent_status":"done"}]}}"#)
        try server.start()
        defer { server.stop() }
        let statuses = try HerdrSocket.agentStatusesFromSocket(server.path)
        XCTAssertEqual(statuses, ["unknown", "done"])
    }

    func testErrorResponseThrows() throws {
        let server = FakeHerdrServer(
            path: tmpDir + "/herdr.sock",
            response: #"{"id":"x","error":{"code":1,"message":"nope"}}"#)
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try HerdrSocket.agentStatusesFromSocket(server.path)) { error in
            guard case HerdrError.socketError = error else {
                return XCTFail("expected socketError, got \(error)")
            }
        }
    }

    func testMissingSocketThrows() {
        XCTAssertThrowsError(try HerdrSocket.agentStatusesFromSocket(
            tmpDir + "/nope.sock")) { error in
            guard case HerdrError.socketUnavailable = error else {
                return XCTFail("expected socketUnavailable, got \(error)")
            }
        }
    }

    func testGarbageResponseThrows() throws {
        let server = FakeHerdrServer(path: tmpDir + "/herdr.sock", response: "not json at all")
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try HerdrSocket.agentStatusesFromSocket(server.path)) { error in
            guard case HerdrError.parseFailed = error else {
                return XCTFail("expected parseFailed, got \(error)")
            }
        }
    }

    func testGetAgentStatusesRequiresSocketEnv() {
        Env.set("HERDR_SOCKET_PATH", nil)
        XCTAssertThrowsError(try HerdrSocket.getAgentStatuses()) { error in
            guard case HerdrError.notInSession = error else {
                return XCTFail("expected notInSession, got \(error)")
            }
        }
    }

    func testGetAgentStatusesUsesEnvSocket() throws {
        let server = FakeHerdrServer(
            path: tmpDir + "/herdr.sock",
            response: #"{"result":{"agents":[{"agent_status":"working"}]}}"#)
        try server.start()
        defer { server.stop() }
        Env.set("HERDR_SOCKET_PATH", server.path)
        let statuses = try HerdrSocket.getAgentStatuses()
        XCTAssertEqual(statuses, ["working"])
    }

    func testAgentStatusesFromResponseEmpty() {
        XCTAssertEqual(HerdrSocket.agentStatusesFromResponse([:]), [])
        XCTAssertEqual(
            HerdrSocket.agentStatusesFromResponse(["result": [String: Any]()]), [])
    }
}

/// SHA-1 sanity for the session-slug fingerprint.
final class Sha1Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(SHA1.hex("abc"),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex("my session/01"),
                       "1ab3ddeeeadfb538ee6ed91a32b69a75c6b1ea88")
        XCTAssertEqual(SHA1.hex(""),
                       "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        // > 64-byte input exercises the multi-block path
        XCTAssertEqual(
            SHA1.hex(String(repeating: "a", count: 1000)),
            "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }
}
