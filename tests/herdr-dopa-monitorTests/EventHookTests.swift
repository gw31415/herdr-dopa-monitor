import XCTest
@testable import herdr_dopa_monitor

let DOPA_EVENT_STUB = """
#!/bin/sh
trap 'exit 0' TERM
while true; do sleep 0.2; done
"""

/// Tests for the event hook path (`herdr-dopa-monitor event`):
/// HERDR_PLUGIN_EVENT / HERDR_PLUGIN_EVENT_JSON parsing, degraded
/// (once-equivalent) behavior on unknown / missing / malformed event data,
/// the flock state lock, and double-run safety of the locked iteration when
/// two runners race.
final class EventHookTests: XCTestCase {

    var tmpDir: String = ""
    var stubPath: String = ""
    var savedEnv: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "herdr-dopa-event-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
        stubPath = tmpDir + "/dopa-stub"
        try? DOPA_EVENT_STUB.write(toFile: stubPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stubPath)
        for key in ["HERDR_PLUGIN_EVENT", "HERDR_PLUGIN_EVENT_JSON",
                    "HERDR_SOCKET_PATH"] {
            savedEnv[key] = Env.get(key)
        }
        Env.set("HERDR_PLUGIN_EVENT", nil)
        Env.set("HERDR_PLUGIN_EVENT_JSON", nil)
        Env.set("HERDR_SOCKET_PATH", nil)
    }

    override func tearDown() {
        for (key, value) in savedEnv {
            Env.set(key, value)
        }
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    func makeCfg() -> MonitorConfig {
        MonitorConfig(herdrBin: "herdr", pollSeconds: 5.0,
                      statePath: tmpDir + "/state.json",
                      dopaBin: stubPath, armed: true)
    }

    // MARK: - readPluginEvent

    func testEventInfoDefaultsWhenEnvMissing() {
        Env.set("HERDR_PLUGIN_EVENT", nil)
        Env.set("HERDR_PLUGIN_EVENT_JSON", nil)
        let info = readPluginEvent()
        XCTAssertEqual(info.name, "")
        XCTAssertTrue(info.payload.isEmpty)
    }

    func testEventInfoReadsNameAndPayload() {
        Env.set("HERDR_PLUGIN_EVENT", "pane.agent_status_changed")
        Env.set("HERDR_PLUGIN_EVENT_JSON",
                #"{"type":"pane.agent_status_changed","agent_status":"working"}"#)
        let info = readPluginEvent()
        XCTAssertEqual(info.name, "pane.agent_status_changed")
        XCTAssertEqual(info.payload["agent_status"] as? String, "working")
    }

    func testEventInfoInvalidJSONGivesEmptyPayload() {
        Env.set("HERDR_PLUGIN_EVENT", "pane.created")
        Env.set("HERDR_PLUGIN_EVENT_JSON", "{not json at all")
        let info = readPluginEvent()
        XCTAssertEqual(info.name, "pane.created")
        XCTAssertTrue(info.payload.isEmpty)
    }

    func testEventInfoNonDictJSONGivesEmptyPayload() {
        Env.set("HERDR_PLUGIN_EVENT", "pane.closed")
        Env.set("HERDR_PLUGIN_EVENT_JSON", #"[1,2,3]"#)
        let info = readPluginEvent()
        XCTAssertEqual(info.name, "pane.closed")
        XCTAssertTrue(info.payload.isEmpty)
    }

    // MARK: - runEventHook behaves like once (never fails on bad input)

    /// Without a herdr socket, observation degrades to idle: the hook writes
    /// an "off" state, spawns nothing, and still creates the lock file.
    private func assertHookRunsOneIteration(file: StaticString = #filePath,
                                            line: UInt = #line) {
        let cfg = makeCfg()
        runEventHook(cfg: cfg)
        XCTAssertTrue(FsUtil.isFile(cfg.statePath), "state file written",
                      file: file, line: line)
        XCTAssertTrue(FsUtil.isFile(tmpDir + "/monitor.lock"),
                      "state lock file created", file: file, line: line)
        let ctx = loadCtx(cfg.statePath)
        XCTAssertEqual(ctx.monitorState, "off", file: file, line: line)
        XCTAssertNil(ctx.dopaPid, file: file, line: line)
    }

    func testEventHookWithoutEnvRunsOnce() {
        assertHookRunsOneIteration()
    }

    func testEventHookWithUnknownEventRunsOnce() {
        Env.set("HERDR_PLUGIN_EVENT", "totally.unknown.event")
        assertHookRunsOneIteration()
    }

    func testEventHookWithEmptyEventRunsOnce() {
        Env.set("HERDR_PLUGIN_EVENT", "")
        assertHookRunsOneIteration()
    }

    func testEventHookWithMalformedJSONRunsOnce() {
        Env.set("HERDR_PLUGIN_EVENT", "pane.exited")
        Env.set("HERDR_PLUGIN_EVENT_JSON", "{{{ broken")
        assertHookRunsOneIteration()
    }

    // MARK: - StateLock

    func testLockPathLivesBesideStateFile() {
        XCTAssertEqual(StateLock.lockPath(forState: "/a/b/state.json"),
                       "/a/b/monitor.lock")
    }

    func testWithLockCreatesLockFileAndReturnsBody() {
        let statePath = tmpDir + "/state.json"
        let value = StateLock.withLock(statePath: statePath) { 41 + 1 }
        XCTAssertEqual(value, 42)
        XCTAssertTrue(FsUtil.isFile(tmpDir + "/monitor.lock"))
    }

    /// Body still runs (unlocked) when the lock file cannot be opened.
    func testWithLockUnopenablePathStillRunsBody() {
        let blocker = tmpDir + "/blocker"
        try? "file".write(toFile: blocker, atomically: true, encoding: .utf8)
        let statePath = blocker + "/state.json" // open() under a regular file
        let ran = StateLock.withLock(statePath: statePath) { true }
        XCTAssertTrue(ran)
    }

    /// flock is per open file description, so two concurrent acquisitions in
    /// one process must exclude each other: never two bodies at once.
    func testWithLockExcludesConcurrentHolders() {
        let statePath = tmpDir + "/state.json"
        let counter = ConcurrentCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "event-lock-tests", attributes: .concurrent)
        for _ in 0..<2 {
            group.enter()
            queue.async {
                StateLock.withLock(statePath: statePath) {
                    counter.enter()
                    Thread.sleep(forTimeInterval: 0.15)
                    counter.exit()
                }
                group.leave()
            }
        }
        let waited = group.wait(timeout: .now() + 10)
        XCTAssertEqual(waited, .success)
        XCTAssertEqual(counter.maxInside, 1, "two holders were inside at once")
    }

    // MARK: - double-run safety under the lock

    /// Two runners (daemon + event hook) race from empty state, both observe
    /// a working agent. The lock serializes load -> iterate -> save, and the
    /// second runner adopts the first's saved state, so the owned dopa child
    /// is spawned exactly once (never twice, never terminated).
    func testConcurrentLockedIterationsSpawnExactlyOnce() {
        var spawnCalls = 0
        let spawnLock = NSLock()
        let deps = IterateDeps(
            getAgentStatuses: { ["working"] },
            isDopaAvailable: { _ in true },
            isPidAlive: { $0 == 4242 },
            spawnSession: { _, _, _ in
                spawnLock.lock()
                spawnCalls += 1
                spawnLock.unlock()
                return 4242
            },
            terminateSession: { _ in true },
            log: { _ in })
        let cfg = makeCfg()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "event-race-tests", attributes: .concurrent)
        for _ in 0..<2 {
            group.enter()
            queue.async {
                _ = lockedIteration(cfg: cfg, deps: deps)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(spawnCalls, 1, "the owned child must spawn exactly once")
        let final = loadCtx(cfg.statePath)
        XCTAssertEqual(final.monitorState, "on")
        XCTAssertEqual(final.dopaPid, 4242)
    }

    // MARK: - state schema

    func testBackoffPersistedAcrossSaveLoad() {
        let path = tmpDir + "/state.json"
        saveCtx(path, MonitorCtx(monitorState: "error", backoff: 20.0))
        XCTAssertEqual(loadCtx(path).backoff, 20.0)
        // Junk falls back to the default, never below it.
        try? #"{"monitor_state":"error","backoff_seconds":0.2}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(loadCtx(path).backoff, DEFAULT_POLL_SECONDS)
    }
}

/// Tiny NSLock-guarded gauge for the concurrency tests above.
private final class ConcurrentCounter {
    private let lock = NSLock()
    private var inside = 0
    private(set) var maxInside = 0

    func enter() {
        lock.lock()
        inside += 1
        maxInside = max(maxInside, inside)
        lock.unlock()
    }

    func exit() {
        lock.lock()
        inside -= 1
        lock.unlock()
    }
}
