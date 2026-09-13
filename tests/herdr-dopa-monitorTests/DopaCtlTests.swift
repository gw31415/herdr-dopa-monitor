import XCTest
@testable import herdr_dopa

let DOPA_STUB = """
#!/bin/sh
# Behaves like `dopa` for lifecycle tests: runs until SIGTERM, then exits 0.
trap 'exit 0' TERM
while true; do sleep 0.2; done
"""

/// Unit tests for dopa_ctl: argv building, PID liveness, and real spawn /
/// terminate cycles against a stub executable (no real dopa needed).
final class DopaCtlTests: XCTestCase {

    var tmpDir: String = ""
    var stubPath: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "herdr-dopa-dopa-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
        stubPath = tmpDir + "/dopa-stub"
        try? DOPA_STUB.write(toFile: stubPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stubPath)
        Env.set("DOPA_BIN", nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        Env.set("DOPA_BIN", nil)
        super.tearDown()
    }

    // MARK: - bin path

    func testBinPathDefault() {
        Env.set("DOPA_BIN", nil)
        XCTAssertEqual(DopaCtl.binPath(), DopaCtl.DEFAULT_DOPA_BIN)
    }

    func testBinPathConfigured() {
        Env.set("DOPA_BIN", nil)
        XCTAssertEqual(DopaCtl.binPath(configured: "/tmp/x/dopa"), "/tmp/x/dopa")
    }

    func testBinPathEnvWins() {
        Env.set("DOPA_BIN", "/tmp/env/dopa")
        XCTAssertEqual(DopaCtl.binPath(configured: "/tmp/x/dopa"), "/tmp/env/dopa")
    }

    // MARK: - argv

    func testArgvBare() {
        XCTAssertEqual(DopaCtl.buildArgv(bin: "/tmp/dopa"), ["/tmp/dopa"])
    }

    func testArgvDisplayFlag() {
        XCTAssertEqual(DopaCtl.buildArgv(bin: "/tmp/dopa", keepDisplayOn: true),
                       ["/tmp/dopa", "--keep-display-on"])
    }

    func testArgvLidFlag() {
        XCTAssertEqual(DopaCtl.buildArgv(bin: "/tmp/dopa", stopOnLidClose: true),
                       ["/tmp/dopa", "--stop-on-lid-close"])
    }

    func testArgvBothFlags() {
        XCTAssertEqual(DopaCtl.buildArgv(bin: "/tmp/dopa", keepDisplayOn: true,
                                         stopOnLidClose: true),
                       ["/tmp/dopa", "--keep-display-on", "--stop-on-lid-close"])
    }

    // MARK: - pid liveness

    func testSelfAlive() {
        XCTAssertTrue(DopaCtl.isPidAlive(getpid()))
    }

    func testNoneDead() {
        XCTAssertFalse(DopaCtl.isPidAlive(nil))
    }

    func testBogusDead() {
        XCTAssertFalse(DopaCtl.isPidAlive(999_999_999))
    }

    func testNegativeDead() {
        XCTAssertFalse(DopaCtl.isPidAlive(-3))
    }

    // MARK: - spawn / terminate (real child processes)

    func testSpawnAndTerminate() throws {
        let pid = try DopaCtl.spawnSession(bin: stubPath)
        XCTAssertTrue(DopaCtl.isPidAlive(pid))
        XCTAssertTrue(try DopaCtl.terminateSession(pid))
        XCTAssertFalse(DopaCtl.isPidAlive(pid))
    }

    func testSpawnDetachedIsOwnSession() throws {
        // POSIX_SPAWN_SETSID: the child must not share our process group.
        let pid = try DopaCtl.spawnSession(bin: stubPath)
        defer { _ = try? DopaCtl.terminateSession(pid) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        XCTAssertEqual(rc, size)
        XCTAssertEqual(info.pbi_pgid, UInt32(pid), "child should lead its own session")
    }

    func testTerminateMissingPidIsSuccess() {
        XCTAssertTrue((try? DopaCtl.terminateSession(999_999_999)) == true)
        XCTAssertTrue((try? DopaCtl.terminateSession(nil)) == true)
    }

    func testSpawnMissingBinaryThrows() {
        XCTAssertThrowsError(try DopaCtl.spawnSession(bin: "/nonexistent/dopa-binary-xyz")) {
            error in
            guard case DopaError.spawnFailed = error else {
                return XCTFail("expected spawnFailed, got \(error)")
            }
        }
    }

    func testIsAvailable() {
        XCTAssertTrue(DopaCtl.isDopaAvailable(stubPath))
        XCTAssertFalse(DopaCtl.isDopaAvailable("/nonexistent/dopa-binary-xyz"))
    }

    // MARK: - daemon status

    func testDaemonStatusUnavailableReturnsNone() {
        XCTAssertNil(DopaCtl.daemonStatus(bin: "/nonexistent/dopa-binary-xyz"))
    }
}
