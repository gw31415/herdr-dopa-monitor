import XCTest
@testable import herdr_dopa

/// Unit tests for the pure monitor logic: state machine, transition side
/// effects (owned dopa child), one-iteration flows with injected fakes, and
/// state file I/O. No real dopa or herdr calls.
final class StateMachineTests: XCTestCase {

    // MARK: - anyAgentWorking

    func testAnyAgentWorkingEmpty() {
        XCTAssertFalse(anyAgentWorking([]))
    }

    func testAnyAgentWorkingNoWorking() {
        XCTAssertFalse(anyAgentWorking(["idle", "done", "blocked", "unknown"]))
    }

    func testAnyAgentWorkingPresent() {
        XCTAssertTrue(anyAgentWorking(["idle", "working"]))
    }

    func testAnyAgentWorkingCaseSensitive() {
        XCTAssertFalse(anyAgentWorking(["Working"]))
    }

    // MARK: - nextMonitorState (immediate transitions)

    func testOffIdleStays() {
        XCTAssertEqual(nextMonitorState(currentState: "off", observedWorking: false), "off")
    }

    func testOffWorkingStartsImmediately() {
        XCTAssertEqual(nextMonitorState(currentState: "off", observedWorking: true), "on")
    }

    func testOnWorkingHolds() {
        XCTAssertEqual(nextMonitorState(currentState: "on", observedWorking: true), "on")
    }

    func testOnIdleStopsImmediately() {
        XCTAssertEqual(nextMonitorState(currentState: "on", observedWorking: false), "off")
    }

    func testErrorFallbackWorking() {
        XCTAssertEqual(nextMonitorState(currentState: "error", observedWorking: true), "on")
    }

    func testErrorFallbackIdle() {
        XCTAssertEqual(nextMonitorState(currentState: "error", observedWorking: false), "off")
    }

    func testUnknownStateFallsOff() {
        XCTAssertEqual(nextMonitorState(currentState: "bogus", observedWorking: false), "off")
    }

    // MARK: - handleTransition

    struct FakeDopa {
        var alivePids: Set<Int32>
        var spawnPid: Int32 = 4242
        var spawnError: Error? = nil
        var terminateOK = true
        var spawnCalls = 0
        var terminateCalls: [Int32?] = []
        var logs: [String] = []
    }

    func makeFns(_ fake: FakeDopa) -> IterateDeps {
        var mutable = fake
        return IterateDeps(
            getAgentStatuses: { [] },
            isDopaAvailable: { _ in true },
            isPidAlive: { pid in fake.alivePids.contains(pid ?? -1) },
            spawnSession: { _, _, _ in
                mutable.spawnCalls += 1
                if let error = fake.spawnError { throw error }
                return fake.spawnPid
            },
            terminateSession: { pid in
                mutable.terminateCalls.append(pid)
                return fake.terminateOK
            },
            log: { mutable.logs.append($0) }
        )
    }

    func testEnterOnSpawns() {
        let deps = makeFns(FakeDopa(alivePids: []))
        let result = handleTransition(new: "on", dopaPid: nil,
                                      spawnFn: { try deps.spawnSession("", false, false) },
                                      terminateFn: { pid in try deps.terminateSession(pid) },
                                      isAliveFn: deps.isPidAlive,
                                      logFn: deps.log)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.pid, 4242)
    }

    func testEnterOnAdoptsLivePid() {
        let deps = makeFns(FakeDopa(alivePids: [111]))
        // A spawn would throw here, proving it is never called.
        let result = handleTransition(new: "on", dopaPid: 111,
                                      spawnFn: { throw NSError(domain: "boom", code: 1) },
                                      terminateFn: { _ in true },
                                      isAliveFn: deps.isPidAlive,
                                      logFn: { _ in })
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.pid, 111)
    }

    func testEnterOnSpawnFailureIsError() {
        let result = handleTransition(new: "on", dopaPid: nil,
                                      spawnFn: { throw DopaError.spawnFailed("nope") },
                                      terminateFn: { _ in true },
                                      isAliveFn: { _ in false },
                                      logFn: { _ in })
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.pid)
    }

    func testEnterOnRespawnsStalePid() {
        let deps = makeFns(FakeDopa(alivePids: []))
        let result = handleTransition(new: "on", dopaPid: 999,
                                      spawnFn: { try deps.spawnSession("", false, false) },
                                      terminateFn: { _ in true },
                                      isAliveFn: deps.isPidAlive,
                                      logFn: { _ in })
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.pid, 4242)
    }

    func testEnterOffTerminatesChild() {
        let deps = makeFns(FakeDopa(alivePids: [111]))
        let result = handleTransition(new: "off", dopaPid: 111,
                                      spawnFn: { 1 },
                                      terminateFn: { pid in try deps.terminateSession(pid) },
                                      isAliveFn: deps.isPidAlive,
                                      logFn: { _ in })
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.pid)
    }

    func testEnterOffWithoutChild() {
        let result = handleTransition(new: "off", dopaPid: nil,
                                      spawnFn: { 1 },
                                      terminateFn: { _ in true },
                                      isAliveFn: { _ in false },
                                      logFn: { _ in })
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.pid)
    }

    func testEnterOffChildAlreadyGone() {
        let result = handleTransition(new: "off", dopaPid: 111,
                                      spawnFn: { 1 },
                                      terminateFn: { _ in true },
                                      isAliveFn: { _ in false },
                                      logFn: { _ in })
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.pid)
    }

    // MARK: - iterate

    var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "herdr-dopa-tests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    func makeCfg(armed: Bool = true) -> MonitorConfig {
        MonitorConfig(herdrBin: "herdr", pollSeconds: 5.0,
                      statePath: tmpDir + "/state.json",
                      dopaBin: "/tmp/dopa", armed: armed)
    }

    func runIterate(ctx: MonitorCtx, statuses: [String]?, now: Double = 1000.0,
                    alivePids: Set<Int32> = [], armed: Bool = true,
                    dopaAvailable: Bool = true) -> MonitorCtx {
        let cfg = makeCfg(armed: armed)
        var spawnCalls = 0
        var terminateCalls: [Int32?] = []
        let deps = IterateDeps(
            getAgentStatuses: {
                guard let statuses else { throw HerdrError.notInSession }
                return statuses
            },
            isDopaAvailable: { _ in dopaAvailable },
            isPidAlive: { pid in alivePids.contains(pid ?? -1) },
            spawnSession: { _, _, _ in
                spawnCalls += 1
                return 4242
            },
            terminateSession: { pid in
                terminateCalls.append(pid)
                return true
            },
            log: { _ in })
        let out = iterate(cfg: cfg, ctx: ctx, now: now, deps: deps)
        _lastSpawnCalls = spawnCalls
        _lastTerminateCalls = terminateCalls
        return out
    }

    private var _lastSpawnCalls = 0
    private var _lastTerminateCalls: [Int32?] = []

    var lastSpawnCalls: Int { _lastSpawnCalls }
    var lastTerminateCalls: [Int32?] { _lastTerminateCalls }

    func testIdleStaysOff() {
        let out = runIterate(ctx: MonitorCtx(), statuses: ["idle"])
        XCTAssertEqual(out.monitorState, "off")
        XCTAssertNil(out.dopaPid)
    }

    func testWorkingStartsImmediately() {
        let out = runIterate(ctx: MonitorCtx(), statuses: ["working"])
        XCTAssertEqual(out.monitorState, "on")
        XCTAssertEqual(out.dopaPid, 4242)
        XCTAssertEqual(lastSpawnCalls, 1)
    }

    func testOnToOffTerminates() {
        let ctx = MonitorCtx(monitorState: "on", dopaPid: 111)
        let out = runIterate(ctx: ctx, statuses: ["idle"], alivePids: [111])
        XCTAssertEqual(out.monitorState, "off")
        XCTAssertNil(out.dopaPid)
        XCTAssertEqual(lastTerminateCalls, [111])
    }

    func testDisarmedKillsChild() {
        let ctx = MonitorCtx(monitorState: "on", dopaPid: 111)
        let out = runIterate(ctx: ctx, statuses: ["working"], alivePids: [111], armed: false)
        XCTAssertEqual(out.monitorState, "off")
        XCTAssertNil(out.dopaPid)
        XCTAssertEqual(lastTerminateCalls, [111])
    }

    func testMissingDopaIsError() {
        let out = runIterate(ctx: MonitorCtx(), statuses: nil, dopaAvailable: false)
        XCTAssertEqual(out.monitorState, "error")
        XCTAssertNotNil(out.lastError)
    }

    func testErrorRecoversByChildLiveness() {
        // Live child -> resume as on and keep the session.
        let live = MonitorCtx(monitorState: "error", dopaPid: 111)
        let outLive = runIterate(ctx: live, statuses: ["working"], alivePids: [111])
        XCTAssertEqual(outLive.monitorState, "on")
        XCTAssertEqual(outLive.dopaPid, 111)
        XCTAssertEqual(lastSpawnCalls, 0)
        // Dead child -> resume as off, then working observation starts fresh.
        let dead = MonitorCtx(monitorState: "error", dopaPid: 999)
        let outDead = runIterate(ctx: dead, statuses: ["working"])
        XCTAssertEqual(outDead.monitorState, "on")
        XCTAssertEqual(outDead.dopaPid, 4242)
        XCTAssertEqual(lastSpawnCalls, 1)
    }

    func testOnReconcilesDeadChild() {
        let ctx = MonitorCtx(monitorState: "on", dopaPid: 111)
        let out = runIterate(ctx: ctx, statuses: ["working"])
        XCTAssertEqual(out.monitorState, "on")
        XCTAssertEqual(out.dopaPid, 4242)
    }

    func testHerdrDownTreatedAsIdle() {
        let ctx = MonitorCtx(monitorState: "on", dopaPid: 111)
        let out = runIterate(ctx: ctx, statuses: nil, alivePids: [111])
        // working unknown -> treated idle -> immediate off, child ended
        XCTAssertEqual(out.monitorState, "off")
        XCTAssertNil(out.dopaPid)
        XCTAssertEqual(lastTerminateCalls, [111])
    }

    // MARK: - state file

    func testStateRoundtrip() {
        let path = tmpDir + "/state.json"
        var ctx = MonitorCtx(monitorState: "on", dopaPid: 4242,
                             lastTransition: 123.0, lastAgentWorking: true, agentCount: 2)
        ctx.lastError = nil
        saveCtx(path, ctx)
        let back = loadCtx(path)
        XCTAssertEqual(back.monitorState, "on")
        XCTAssertEqual(back.dopaPid, 4242)
        XCTAssertEqual(back.agentCount, 2)
        XCTAssertEqual(back.lastTransition, 123.0)
        XCTAssertTrue(back.lastAgentWorking)
    }

    func testCorruptStateGivesDefaults() {
        let path = tmpDir + "/state.json"
        try? "{not json".write(toFile: path, atomically: true, encoding: .utf8)
        let ctx = loadCtx(path)
        XCTAssertEqual(ctx.monitorState, "off")
        XCTAssertNil(ctx.dopaPid)
    }
}
