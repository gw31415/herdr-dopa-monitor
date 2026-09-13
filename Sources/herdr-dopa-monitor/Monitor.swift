import Foundation
import Darwin

/// herdr dopa sleep-guard monitor: observes herdr agent status over the
/// session socket and holds one owned `dopa` child process while at least one
/// agent is `working`. Transitions are immediate: working starts dopa right
/// away, all-idle stops it right away. The owned session is exactly the child
/// process: ending it ends only our session. Ported from `monitor.py`.
///
/// Hybrid timing: herdr plugin event hooks (`herdr-dopa-monitor event`)
/// trigger one locked iteration the moment pane/agent state changes, while
/// the poll daemon (default 5s) remains as the safety net for missed events
/// and reconnects. All state writers serialize through `StateLock`.

// Valid monitor states.
let MONITOR_STATES = ["off", "on", "error"]

// Built-in defaults; runtime values come from config.json.
let DEFAULT_POLL_SECONDS: Double = 5.0

// MARK: - Pure helpers (no I/O) - the unit-tested core of the state machine.

/// True if any status is exactly "working".
func anyAgentWorking(_ agentStatuses: [String]) -> Bool {
    agentStatuses.contains { $0 == "working" }
}

/// Next monitor state given the latest observation. Transitions are
/// immediate — no grace periods:
///
///     off --working-->      on
///     on  --not working-->  off
///
/// `error` is reconciled by the daemon (child liveness) before normal flow
/// resumes; this mapping keeps the function total for any state.
func nextMonitorState(currentState: String, observedWorking: Bool) -> String {
    observedWorking ? "on" : "off"
}

/// Perform dopa side effects for a state transition. Returns (dopaPid, ok);
/// ok is false when dopa could not be started or stopped — the caller should
/// then enter the error state. Entering "on" ensures the owned child is
/// running (adopt a live PID, otherwise spawn); entering "off" terminates the
/// owned child if it is still alive. Only the PID recorded in our own state
/// file is ever signalled.
func handleTransition(new: String,
                      dopaPid: Int32?,
                      spawnFn: () throws -> Int32,
                      terminateFn: (Int32?) throws -> Bool,
                      isAliveFn: (Int32?) -> Bool,
                      logFn: (String) -> Void) -> (pid: Int32?, ok: Bool) {
    if new == "on" {
        if let pid = dopaPid, isAliveFn(pid) {
            logFn("Adopted live dopa session (pid \(pid)).")
            return (pid, true)
        }
        if let pid = dopaPid {
            logFn("Stale dopa pid \(pid) is gone; starting a fresh session.")
        }
        do {
            let pid = try spawnFn()
            logFn("Started owned dopa session (pid \(pid)).")
            return (pid, true)
        } catch {
            logFn("dopa start failed: \(error)")
            return (nil, false)
        }
    }

    if new == "off" {
        if let pid = dopaPid, isAliveFn(pid) {
            let gone: Bool
            do {
                gone = try terminateFn(pid)
            } catch {
                logFn("dopa stop failed (pid \(pid)): \(error)")
                return (pid, false)
            }
            if gone {
                logFn("Agents idle; ended owned dopa session (pid \(pid)).")
            } else {
                logFn("dopa session (pid \(pid)) did not exit; will retry.")
                return (pid, false)
            }
        } else {
            logFn("Agents idle; nothing to stop.")
        }
        return (nil, true)
    }

    return (dopaPid, true)
}

// MARK: - State persistence

struct MonitorCtx {
    var monitorState: String = "off"
    var dopaPid: Int32? = nil
    var lastTransition: Double = 0.0
    var lastAgentWorking: Bool = false
    var agentCount: Int = -1
    var lastError: String? = nil
    var backoff: Double = DEFAULT_POLL_SECONDS
}

func defaultStateDict() -> [String: Any] {
    [
        "monitor_state": "off",
        "dopa_pid": NSNull(),
        "last_agent_working": false,
        "agent_count": -1,
        "last_transition_unix": 0.0,
        "last_error": NSNull(),
        "backoff_seconds": DEFAULT_POLL_SECONDS,
    ]
}

/// Load monitor state, returning defaults if missing or corrupt.
func loadStateDict(_ path: String) -> [String: Any] {
    var state = defaultStateDict()
    guard FsUtil.isFile(path),
          let data = FileManager.default.contents(atPath: path),
          let parsed = try? JSONSerialization.jsonObject(with: data),
          let dict = parsed as? [String: Any] else {
        return state
    }
    for key in state.keys where dict[key] != nil {
        state[key] = dict[key]!
    }
    return state
}

/// Atomically write monitor state (write temp file then rename).
func saveStateDict(_ path: String, _ state: [String: Any]) {
    try? FsUtil.atomicWriteJSON(path: path, object: state)
}

func loadCtx(_ path: String) -> MonitorCtx {
    let s = loadStateDict(path)
    let lastT = Config.toDouble(s["last_transition_unix"], 0)
    let agentCountInt: Int
    if let n = s["agent_count"] as? Int {
        agentCountInt = n
    } else if let n = s["agent_count"] as? NSNumber {
        agentCountInt = n.intValue
    } else if let str = s["agent_count"] as? String, let n = Int(str) {
        agentCountInt = n
    } else {
        agentCountInt = -1
    }
    let dopaPid: Int32?
    if let n = s["dopa_pid"] as? NSNumber, !(s["dopa_pid"] is NSNull) {
        dopaPid = Int32(exactly: n.intValue) ?? n.int32Value
    } else if let str = s["dopa_pid"] as? String, let n = Int32(str) {
        dopaPid = n
    } else {
        dopaPid = nil
    }
    let lastError: String?
    if let e = s["last_error"] as? String, !e.isEmpty {
        lastError = e
    } else {
        lastError = nil
    }
    return MonitorCtx(
        monitorState: (s["monitor_state"] as? String) ?? "off",
        dopaPid: dopaPid,
        lastTransition: lastT,
        lastAgentWorking: Config.toBool(s["last_agent_working"], false),
        agentCount: agentCountInt,
        lastError: lastError,
        backoff: max(DEFAULT_POLL_SECONDS, Config.toDouble(s["backoff_seconds"], DEFAULT_POLL_SECONDS))
    )
}

func saveCtx(_ path: String, _ ctx: MonitorCtx) {
    saveStateDict(path, [
        "monitor_state": ctx.monitorState,
        "dopa_pid": ctx.dopaPid.map { NSNumber(value: $0) } ?? NSNull(),
        "last_agent_working": ctx.lastAgentWorking,
        "agent_count": ctx.agentCount,
        "last_transition_unix": ctx.lastTransition,
        "last_error": ctx.lastError ?? NSNull(),
        "backoff_seconds": ctx.backoff,
    ])
}

// MARK: - Config (built from config.json + env overrides)

struct MonitorConfig {
    var herdrBin: String
    var pollSeconds: Double
    var statePath: String
    var dopaBin: String = DopaCtl.DEFAULT_DOPA_BIN
    var keepDisplayOn: Bool = false
    var stopOnLidClose: Bool = false
    var armed: Bool = true
}

/// The runtime state file: <state_dir>/state.json.
func resolveStatePath() -> String {
    Config.stateDir() + "/state.json"
}

/// Build the runtime MonitorConfig from config.json (file -> env -> validate).
func loadMonitorConfig() -> MonitorConfig {
    let raw = Config.loadResolved()
    let herdrBin = Config.herdrBinPath(raw) ?? which("herdr") ?? "herdr"
    return MonitorConfig(
        herdrBin: herdrBin,
        pollSeconds: raw["poll_seconds"] as? Double ?? 5.0,
        statePath: resolveStatePath(),
        dopaBin: raw["dopa_bin"] as? String ?? DopaCtl.DEFAULT_DOPA_BIN,
        keepDisplayOn: Config.toBool(raw["keep_display_on"], false),
        stopOnLidClose: Config.toBool(raw["stop_on_lid_close"], false),
        armed: Config.toBool(raw["armed"], true)
    )
}

// MARK: - Logging (stdout -> LaunchAgent log file)

func monitorLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let stamp = formatter.string(from: Date())
    print("\(stamp) \(message)")
    fflush(stdout)
}

// MARK: - Iteration (pure with respect to injected time and I/O)

/// Injectable process/observation seams so `iterate` stays unit-testable
/// without real dopa or herdr.
struct IterateDeps {
    var getAgentStatuses: () throws -> [String] = HerdrSocket.getAgentStatuses
    var isDopaAvailable: (String) -> Bool = DopaCtl.isDopaAvailable
    var isPidAlive: (Int32?) -> Bool = DopaCtl.isPidAlive
    var spawnSession: (String, Bool, Bool) throws -> Int32 = DopaCtl.spawnSession
    var terminateSession: (Int32?) throws -> Bool = { pid in
        try DopaCtl.terminateSession(pid)
    }
    var log: (String) -> Void = monitorLog
}

/// Run one monitor iteration and return the updated context. `now` is
/// injected so this is unit-testable; the daemon passes Date().timeIntervalSince1970.
func iterate(cfg: MonitorConfig, ctx: MonitorCtx, now: Double,
             deps: IterateDeps = IterateDeps()) -> MonitorCtx {
    var state = ctx.monitorState
    var pid = ctx.dopaPid
    var lastT = ctx.lastTransition != 0 ? ctx.lastTransition : now
    var backoff = cfg.pollSeconds
    var lastError: String? = nil

    func spawn() throws -> Int32 {
        try deps.spawnSession(cfg.dopaBin, cfg.keepDisplayOn, cfg.stopOnLidClose)
    }

    // Master switch: when disarmed, hold no dopa process.
    if !cfg.armed {
        if let pid, deps.isPidAlive(pid) {
            do {
                if try deps.terminateSession(pid) {
                    deps.log("Disarmed; ended owned dopa session (pid \(pid)).")
                }
            } catch {
                deps.log("Disarmed; could not end dopa session (pid \(pid)): \(error)")
            }
        }
        return MonitorCtx(
            monitorState: "off",
            dopaPid: nil,
            lastTransition: now,
            lastAgentWorking: ctx.lastAgentWorking,
            agentCount: ctx.agentCount,
            lastError: nil,
            backoff: cfg.pollSeconds
        )
    }

    if !deps.isDopaAvailable(cfg.dopaBin) {
        lastError = "dopa binary not found at \(cfg.dopaBin)"
        deps.log(lastError! + "; waiting.")
        return MonitorCtx(
            monitorState: "error",
            dopaPid: pid,
            lastTransition: lastT,
            lastAgentWorking: ctx.lastAgentWorking,
            agentCount: ctx.agentCount,
            lastError: lastError,
            backoff: min(60.0, ctx.backoff * 2)
        )
    }

    // Recover from error: drop a stale PID, then resume normal flow.
    if state == "error" {
        if let existing = pid, !deps.isPidAlive(existing) {
            deps.log("Owned dopa session (pid \(existing)) is gone; cleared.")
            pid = nil
        }
        state = pid != nil ? "on" : "off"
        lastT = now
        backoff = cfg.pollSeconds
        deps.log("Recovered from error; resuming in state '\(state)'.")
    }

    // Observe herdr. herdr being down is NOT an error state - treat as idle.
    var statuses: [String] = []
    var agentCount = ctx.agentCount
    do {
        statuses = try deps.getAgentStatuses()
        agentCount = statuses.count
    } catch {
        deps.log("herdr unavailable (\(error)); treating as no working agents.")
    }
    let working = anyAgentWorking(statuses)

    let newState = nextMonitorState(currentState: state, observedWorking: working)

    if newState != state {
        let result = handleTransition(
            new: newState, dopaPid: pid,
            spawnFn: spawn,
            terminateFn: { try deps.terminateSession($0) },
            isAliveFn: deps.isPidAlive,
            logFn: deps.log)
        pid = result.pid
        if result.ok {
            deps.log("Transition: \(state) -> \(newState) (working=\(working)).")
            state = newState
            lastT = now
        } else {
            deps.log("Transition \(state) -> \(newState) failed; entering error state.")
            state = "error"
            lastT = now
            lastError = "dopa control failure"
        }
    } else if state == "on" {
        // Reconcile the on-state with reality: our child may have exited on
        // its own (e.g. --stop-on-lid-close ended it when the lid closed).
        if pid == nil || !deps.isPidAlive(pid) {
            deps.log("Owned dopa session is gone while agents work; restarting it.")
            do {
                pid = try spawn()
                deps.log("Restarted owned dopa session (pid \(pid ?? -1)).")
                lastT = now
            } catch {
                deps.log("Restart failed: \(error); entering error state.")
                state = "error"
                lastT = now
                lastError = "dopa restart failure"
                pid = nil
            }
        }
    }

    return MonitorCtx(
        monitorState: state,
        dopaPid: pid,
        lastTransition: lastT,
        lastAgentWorking: working,
        agentCount: agentCount,
        lastError: lastError,
        backoff: backoff
    )
}

// MARK: - Signal handling for the daemon loop

private var gDaemonStopRequested: Int32 = 0
private var gDaemonReloadRequested: Int32 = 0

private func installDaemonSignalHandlers() {
    signal(SIGTERM) { _ in gDaemonStopRequested = 1 }
    signal(SIGINT) { _ in gDaemonStopRequested = 1 }
    signal(SIGHUP) { _ in gDaemonReloadRequested = 1 }
}

/// Sleep up to `seconds`, returning early when stop was requested or when
/// SIGHUP asked for an immediate wakeup: the daemon loop then reloads config
/// and runs the next iteration right away instead of finishing the sleep.
private func waitInterruptible(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if gDaemonStopRequested == 1 { return }
        if gDaemonReloadRequested == 1 { return }
        Thread.sleep(forTimeInterval: min(0.1, deadline.timeIntervalSinceNow))
    }
}

/// Stop only this session's LaunchAgent when no agents remain.
private func autoStopIfEmpty(_ ctx: MonitorCtx) -> Bool {
    let autoUnload = Env.get("HERDR_DOPA_AUTO_UNLOAD") == "1"
    guard autoUnload, ctx.agentCount == 0 else { return false }
    guard let labelName = Env.getNonEmpty("HERDR_DOPA_LABEL") else { return false }
    monitorLog("No agents remain; stopping this session LaunchAgent.")
    LaunchAgent.stop(labelName)
    return true
}

// MARK: - Modes

/// Events surfaced by the daemon loop so the CLI can push herdr UI
/// (notification + pane report-metadata) at the transitions that matter.
enum MonitorUiEvent {
    case started
    case guardStarted(pid: Int32?)
    case guardEnded
    case errored(String?)
    case stopped
}

// MARK: - Locked iteration core

/// One full monitor iteration under the state lock: load -> iterate -> save.
///
/// Every writer path — `once`, `event`, the daemon loop, and daemon shutdown —
/// funnels its state mutation through this critical section, so concurrent
/// runners serialize instead of double-spawning or double-terminating the
/// owned dopa child. State is re-loaded inside the lock on every call, which
/// also means the daemon adopts whatever an event hook last wrote instead of
/// clobbering it with a stale in-memory copy.
///
/// Returns the state observed before the iteration and the resulting context.
func lockedIteration(cfg: MonitorConfig, now: Double = Date().timeIntervalSince1970,
                     deps: IterateDeps = IterateDeps()) -> (previousState: String, ctx: MonitorCtx) {
    StateLock.withLock(statePath: cfg.statePath) {
        var ctx = loadCtx(cfg.statePath)
        let previousState = ctx.monitorState
        ctx = iterate(cfg: cfg, ctx: ctx, now: now, deps: deps)
        saveCtx(cfg.statePath, ctx)
        return (previousState, ctx)
    }
}

/// Print the short JSON summary shared by `once` and `event`.
private func printMonitorSummary(_ ctx: MonitorCtx) {
    let summary: [String: Any] = [
        "monitor_state": ctx.monitorState,
        "dopa_pid": ctx.dopaPid.map { NSNumber(value: $0) } ?? NSNull(),
        "last_agent_working": ctx.lastAgentWorking,
        "last_error": ctx.lastError ?? NSNull(),
    ]
    if let data = try? JSONSerialization.data(
        withJSONObject: summary,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

// MARK: - Event hooks (herdr plugin integration)

/// What herdr told us when it invoked `herdr-dopa-monitor event`. Both
/// fields are best-effort: any missing or malformed piece degrades to "run
/// one iteration now" rather than failing the hook.
struct PluginEventInfo {
    /// HERDR_PLUGIN_EVENT value ("startup", an event name, or empty).
    var name: String
    /// Parsed HERDR_PLUGIN_EVENT_JSON object, or an empty dict.
    var payload: [String: Any]
}

/// Read HERDR_PLUGIN_EVENT / HERDR_PLUGIN_EVENT_JSON from the environment.
/// herdr injects these when running manifest `[[events]]` and `[[startup]]`
/// hooks; anything else (manual runs, unknown names, invalid JSON) yields an
/// inert info — the hook still behaves like `once`.
func readPluginEvent() -> PluginEventInfo {
    let name = Env.get("HERDR_PLUGIN_EVENT") ?? ""
    var payload: [String: Any] = [:]
    if let raw = Env.get("HERDR_PLUGIN_EVENT_JSON"),
       let data = raw.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data),
       let dict = parsed as? [String: Any] {
        payload = dict
    }
    return PluginEventInfo(name: name, payload: payload)
}

/// Run a single iteration and exit. Does not end the session on exit.
func runOnce(cfg: MonitorConfig) {
    let (_, ctx) = lockedIteration(cfg: cfg)
    printMonitorSummary(ctx)
}

/// Event-hook entrypoint (`herdr-dopa-monitor event`). herdr invokes this
/// from the manifest's `[[events]]` / `[[startup]]` hooks with
/// HERDR_PLUGIN_EVENT (and HERDR_PLUGIN_EVENT_JSON) in the environment; it
/// runs exactly one locked iteration so pane/agent changes reach the guard
/// immediately instead of waiting for the next poll. Unknown, missing, or
/// malformed event data is not an error — the hook then simply behaves
/// like `once`.
func runEventHook(cfg: MonitorConfig) {
    let info = readPluginEvent()
    let name = info.name.isEmpty ? "unnamed" : info.name
    let detail = (info.payload["agent_status"] as? String)
        .map { " (agent_status=\($0))" } ?? ""
    monitorLog("Event hook '\(name)' received\(detail); running one immediate iteration.")
    runOnce(cfg: cfg)
}

/// Run the monitor loop until SIGTERM/SIGINT. Reloads config.json every cycle
/// and on SIGHUP (which also interrupts the current sleep for an immediate
/// iteration). Each cycle re-loads state inside the state lock, so writes
/// from concurrent `event`/`once` runs are adopted, never clobbered. The
/// session LaunchAgent is stopped when no agents remain. On shutdown the
/// owned dopa child is terminated under the same lock: it is our session,
/// and leaving it behind would hold the Mac awake with no owner.
func runDaemon(initialCfg: MonitorConfig,
               onEvent: (MonitorUiEvent) -> Void = { _ in }) {
    var cfg = initialCfg

    // Startup safety (under the state lock): adopt the recorded PID only if
    // it is actually alive; otherwise drop it so the next `on` cycle spawns
    // fresh.
    StateLock.withLock(statePath: cfg.statePath) {
        var ctx = loadCtx(cfg.statePath)
        if let pid = ctx.dopaPid, !DopaCtl.isPidAlive(pid) {
            monitorLog("Recorded dopa pid \(pid) is not alive; cleared.")
            ctx.dopaPid = nil
        }
        saveCtx(cfg.statePath, ctx)
    }

    installDaemonSignalHandlers()

    monitorLog("Monitor started (poll=\(fmtSeconds(cfg.pollSeconds))s "
        + "armed=\(cfg.armed) state=\(cfg.statePath)).")
    onEvent(.started)
    defer {
        // Terminate the owned child and reflect "off" in state. Under the
        // lock, and against freshly loaded state: an event hook may have
        // written a newer PID since our last iteration.
        StateLock.withLock(statePath: cfg.statePath) {
            var ctx = loadCtx(cfg.statePath)
            if let pid = ctx.dopaPid {
                do {
                    if try DopaCtl.terminateSession(pid) {
                        monitorLog("Ended owned dopa session (pid \(pid)) on shutdown.")
                    } else {
                        monitorLog("Owned dopa session (pid \(pid)) would not exit.")
                    }
                } catch {
                    monitorLog("Could not end owned dopa session on shutdown: \(error)")
                }
                ctx.dopaPid = nil
            }
            // We are stopping, so we are no longer guarding: reflect that in
            // state so the CLI / status do not show a stale "on".
            ctx.monitorState = "off"
            ctx.lastError = nil
            saveCtx(cfg.statePath, ctx)
        }
        monitorLog("Monitor stopped.")
        onEvent(.stopped)
    }

    while gDaemonStopRequested == 0 {
        if gDaemonReloadRequested == 1 {
            gDaemonReloadRequested = 0
            cfg = loadMonitorConfig() // never let a reload kill the daemon
            monitorLog("Config reloaded.")
        }
        let (previousState, ctx) = lockedIteration(cfg: cfg)
        if ctx.monitorState != previousState {
            switch ctx.monitorState {
            case "on":
                onEvent(.guardStarted(pid: ctx.dopaPid))
            case "off":
                onEvent(.guardEnded)
            case "error":
                onEvent(.errored(ctx.lastError))
            default:
                break
            }
        }
        if autoStopIfEmpty(ctx) {
            return
        }
        let delay = ctx.monitorState == "error" ? ctx.backoff : cfg.pollSeconds
        waitInterruptible(max(1.0, delay))
    }
    monitorLog("Received stop signal; stopping after current iteration.")
}

/// `%g`-style seconds formatting ("5" not "5.0", "7.5" as-is).
func fmtSeconds(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(Int64(value))
    }
    return String(format: "%g", value)
}
