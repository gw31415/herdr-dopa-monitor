import Foundation

/// The `herdr-dopa` control surface: a single command with subcommands
/// (replaces the old Python guard.py). Works in any terminal, inside herdr
/// panes, over pipes, and from scripts.
enum GuardCLI {
    static let usage = """
        herdr-dopa — control the herdr dopa sleep guard

        USAGE:
          herdr-dopa status [--json] [--watch [SEC]]   show guard / agents / dopa state
          herdr-dopa on | off                          arm / disarm the guard
          herdr-dopa get [KEY]                         show config (all keys, or one)
          herdr-dopa set KEY VALUE                     change config (validated)
          herdr-dopa install                           install/refresh this session's LaunchAgent
          herdr-dopa sync                              match the LaunchAgent to the live agent count
          herdr-dopa uninstall [--cleanup]             remove the LaunchAgent (and optionally data)
          herdr-dopa once | daemon                     one monitor iteration / the daemon loop
          herdr-dopa event                             event hook: one immediate iteration
          herdr-dopa logs [-n LINES]                   tail the daemon log
          herdr-dopa report-metadata                   push guard state to the herdr pane UI
          herdr-dopa notify TITLE [--body TEXT]        show a herdr notification

        Config edits send SIGHUP to the running daemon best-effort (via
        launchctl kill); SIGHUP interrupts the daemon's sleep so the change
        applies immediately, and the daemon also re-reads config.json every
        poll, so a missed signal only delays the change by one cycle.
        """

    static let stateDot: [String: String] = [
        "on": "●",
        "off": "○",
        "error": "✖",
    ]

    static func stateColor(_ st: Style, _ state: String) -> String {
        let dot = stateDot[state] ?? "?"
        switch state {
        case "on": return st.green(dot)
        case "error": return st.red(dot)
        default: return st.dim(dot)
        }
    }

    /// Pin per-session config/state dirs; return launchagent paths.
    static func sessionEnv() throws -> LAPaths {
        let p = try LaunchAgent.paths()
        Env.setDefault("HERDR_DOPA_CONFIG_DIR", p.configDir)
        Env.setDefault("HERDR_DOPA_STATE_DIR", p.stateDir)
        return p
    }

    /// Run `body` with the session env pinned; report session errors once.
    static func withSessionEnv(_ body: (LAPaths) -> Int32) -> Int32 {
        do {
            let p = try sessionEnv()
            return body(p)
        } catch {
            errPrint(String(describing: error))
            return 2
        }
    }

    // MARK: - status

    struct AgentsInfo {
        var available: Bool
        var total: Int
        var working: Int
        var statuses: [String]
        var error: String?
    }

    struct StatusData {
        var armed: Bool
        var monitorState: String
        var dopaPid: Int32?
        var ownedSessionAlive: Bool
        var dopaFlags: [String]
        var dopaBin: String
        var dopaPresent: Bool
        var daemon: [String: Any]?
        var agents: AgentsInfo
        var configFile: String
        var stateFile: String
        var lastError: String?
    }

    /// Gather everything the dashboard needs. Read-only; never spawns dopa.
    static func collectStatus() -> StatusData {
        let cfg = loadMonitorConfig()
        let agents: AgentsInfo
        do {
            let statuses = try HerdrSocket.getAgentStatuses()
            agents = AgentsInfo(
                available: true,
                total: statuses.count,
                working: statuses.filter { $0 == "working" }.count,
                statuses: statuses,
                error: nil)
        } catch {
            agents = AgentsInfo(
                available: false, total: 0, working: 0, statuses: [],
                error: String(describing: error))
        }
        let persisted = loadStateDict(cfg.statePath)
        let dopaPid = (persisted["dopa_pid"] as? NSNumber).map { $0.int32Value }
        var flags: [String] = []
        if cfg.keepDisplayOn { flags.append("--keep-display-on") }
        if cfg.stopOnLidClose { flags.append("--stop-on-lid-close") }
        let lastError = (persisted["last_error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return StatusData(
            armed: cfg.armed,
            monitorState: (persisted["monitor_state"] as? String) ?? "off",
            dopaPid: dopaPid,
            ownedSessionAlive: DopaCtl.isPidAlive(dopaPid),
            dopaFlags: flags,
            dopaBin: cfg.dopaBin,
            dopaPresent: DopaCtl.isDopaAvailable(cfg.dopaBin),
            daemon: DopaCtl.daemonStatus(bin: cfg.dopaBin),
            agents: agents,
            configFile: Config.configPath(),
            stateFile: cfg.statePath,
            lastError: lastError)
    }

    static func statusJSONObject(_ data: StatusData, cfg: MonitorConfig) -> [String: Any] {
        [
            "armed": data.armed,
            "monitor_state": data.monitorState,
            "dopa_pid": data.dopaPid.map { NSNumber(value: $0) } ?? NSNull(),
            "owned_session_alive": data.ownedSessionAlive,
            "dopa_flags": data.dopaFlags,
            "dopa_bin": data.dopaBin,
            "dopa_present": data.dopaPresent,
            "daemon": data.daemon ?? NSNull(),
            "agents": [
                "available": data.agents.available,
                "total": data.agents.total,
                "working": data.agents.working,
                "statuses": data.agents.statuses,
                "error": data.agents.error ?? NSNull(),
            ] as [String: Any],
            "config": [
                "poll_seconds": cfg.pollSeconds,
                "keep_display_on": cfg.keepDisplayOn,
                "stop_on_lid_close": cfg.stopOnLidClose,
                "dopa_bin": cfg.dopaBin,
                "herdr_bin": cfg.herdrBin,
            ] as [String: Any],
            "config_file": data.configFile,
            "state_file": data.stateFile,
            "last_error": data.lastError ?? NSNull(),
        ]
    }

    static func printStatusText(_ data: StatusData, cfg: MonitorConfig) {
        let st = Style(on: Term.styled())
        let ms = data.monitorState
        var head = "\(stateColor(st, ms)) dopa guard — "
        if !data.armed {
            head += st.dim("paused (off)") + st.dim("  ·  `herdr-dopa on` to resume")
        } else if ms == "on" {
            head += st.bold(st.green("guarding")) + st.dim("  ·  \(data.agents.working) working")
        } else if ms == "error" {
            head += st.bold(st.red("error")) + st.dim("  ·  \(data.lastError ?? "see logs")")
        } else {
            head += st.dim("idle")
        }
        print(head)
        let ag = data.agents
        if ag.available {
            print("  agents        \(ag.total) observed · \(ag.working) working")
        } else {
            print("  agents        \(st.dim("unavailable")) (\(ag.error ?? "?"))")
        }
        if data.ownedSessionAlive {
            let flagStr = data.dopaFlags.isEmpty ? "" : " " + data.dopaFlags.joined(separator: " ")
            print("  dopa session  \(st.green("active")) · pid \(data.dopaPid.map(String.init) ?? "?")\(flagStr)")
        } else if data.dopaPid != nil, let pid = data.dopaPid {
            print("  dopa session  \(st.yellow("stale pid")) \(pid) (process gone)")
        } else {
            print("  dopa session  \(st.dim("none"))")
        }
        if !data.dopaPresent {
            print("  dopa binary   \(st.red("MISSING")): \(data.dopaBin)")
        }
        if let daemon = data.daemon {
            let sessions: String
            if let s = daemon["sessions"] as? String {
                sessions = s
            } else if let n = daemon["sessions"] as? NSNumber {
                sessions = n.stringValue
            } else if let list = daemon["sessions"] as? [Any] {
                sessions = String(list.count)
            } else {
                sessions = "?"
            }
            let phase = (daemon["phase"] as? String) ?? "?"
            print("  dopa daemon   phase=\(phase) · sessions=\(sessions)")
        } else {
            print("  dopa daemon   \(st.dim("unknown")) (dopa-daemon status unreachable)")
        }
        print("  config        \(st.cyan(data.configFile))")
        let entries: [(String, String)] = [
            ("poll_seconds", fmtSeconds(cfg.pollSeconds)),
            ("keep_display_on", cfg.keepDisplayOn ? "true" : "false"),
            ("stop_on_lid_close", cfg.stopOnLidClose ? "true" : "false"),
            ("dopa_bin", cfg.dopaBin),
            ("herdr_bin", cfg.herdrBin),
        ]
        for (key, value) in entries {
            let padding = String(repeating: " ", count: max(0, 20 - key.count))
            print("    \(key)\(padding) \(value)")
        }
    }

    static func printLogTail(_ p: LAPaths, lines: Int = 5) {
        let st = Style(on: Term.styled())
        let log = p.logDir + "/monitor.out.log"
        guard FsUtil.isFile(log),
              let text = FsUtil.readTextFile(log) else { return }
        let all = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        let tail = Array(all.suffix(lines))
        if tail.isEmpty { return }
        print(st.dim("  recent log:"))
        for line in tail {
            print(st.dim("    \(line)"))
        }
    }

    static func cmdStatus(json: Bool, watch: Double?) -> Int32 {
        withSessionEnv { p in
            func render() {
                let data = collectStatus()
                let cfg = loadMonitorConfig()
                if json {
                    if let object = try? JSONSerialization.data(
                        withJSONObject: statusJSONObject(data, cfg: cfg),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                       let text = String(data: object, encoding: .utf8) {
                        print(text)
                    }
                } else {
                    printStatusText(data, cfg: cfg)
                    printLogTail(p)
                }
            }
            if let watch {
                // Clear screen + redraw on an interval; Ctrl+C exits.
                let interval = max(0.5, watch)
                while true {
                    print("\u{1b}[H\u{1b}[2J\u{1b}[3J", terminator: "")
                    render()
                    fflush(stdout)
                    Thread.sleep(forTimeInterval: interval)
                }
            }
            render()
            return 0
        }
    }

    // MARK: - on / off

    static func nudgeDaemon(_ labelName: String) {
        _ = LaunchAgent.run(["launchctl", "kill", "HUP", serviceTargetSafe(labelName)])
    }

    private static func serviceTargetSafe(_ labelName: String) -> String {
        LaunchAgent.serviceTarget(labelName: labelName)
    }

    static func cmdOn() -> Int32 {
        withSessionEnv { p in
            var cfg = Config.loadConfigFile()
            cfg["armed"] = true
            try? Config.saveConfigFile(cfg)
            nudgeDaemon(p.label)
            let poll = Config.toDouble(Config.loadResolved()["poll_seconds"], 5.0)
            print("Guard armed. Takes effect within one poll (\(fmtSeconds(poll))s).")
            return 0
        }
    }

    static func cmdOff() -> Int32 {
        withSessionEnv { p in
            var cfg = Config.loadConfigFile()
            cfg["armed"] = false
            try? Config.saveConfigFile(cfg)
            nudgeDaemon(p.label)
            print("Guard paused. The owned dopa session (if any) ends within one poll; "
                + "nothing else is touched.")
            return 0
        }
    }

    // MARK: - get / set

    static func formatValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else {
            return "None"
        }
        if let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let d = value as? Double {
            return fmtSeconds(d)
        }
        if let i = value as? Int {
            return String(i)
        }
        if let s = value as? String {
            return s
        }
        return String(describing: value)
    }

    static func parseValue(key: String, raw: String) throws -> Any {
        if ["armed", "keep_display_on", "stop_on_lid_close"].contains(key) {
            let low = raw.lowercased()
            switch low {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                throw ValueError("\(key) wants true/false, got '\(raw)'")
            }
        }
        if key == "poll_seconds" {
            if let d = Double(raw) {
                return d
            }
            throw ValueError("\(key) wants a number of seconds, got '\(raw)'")
        }
        return raw // dopa_bin, herdr_bin_path: free-form paths
    }

    struct ValueError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func cmdGet(_ key: String?) -> Int32 {
        withSessionEnv { _ in
            let cfg = Config.loadResolved()
            if let key {
                guard Config.SET_KEYS.contains(key) else {
                    errPrint("Unknown key: \(key). Valid: \(Config.SET_KEYS.joined(separator: ", "))")
                    return 2
                }
                print(formatValue(cfg[key] ?? NSNull()))
                return 0
            }
            let st = Style(on: Term.styled())
            for key in Config.SET_KEYS {
                // Pad by the raw key length: ANSI codes must not count toward width.
                let padding = String(repeating: " ", count: max(0, 22 - key.count))
                print("\(st.cyan(key))\(padding)\(formatValue(cfg[key] ?? NSNull()))")
            }
            print(st.dim("# from \(Config.configPath())"))
            return 0
        }
    }

    static func cmdSet(_ key: String, _ rawValue: String) -> Int32 {
        withSessionEnv { p in
            guard Config.SET_KEYS.contains(key) else {
                errPrint("Unknown key: \(key). Valid: \(Config.SET_KEYS.joined(separator: ", "))")
                return 2
            }
            let value: Any
            do {
                value = try parseValue(key: key, raw: rawValue)
            } catch {
                errPrint("Invalid value: \(error)")
                return 2
            }
            var cfg = Config.loadConfigFile()
            cfg[key] = value
            do {
                try Config.saveConfigFile(cfg)
            } catch {
                errPrint("Could not save config: \(error)")
                return 1
            }
            let saved = Config.loadResolved()[key] ?? NSNull()
            nudgeDaemon(p.label)
            print("\(key) = \(formatValue(saved)) (takes effect within one poll)")
            if key == "dopa_bin", let path = saved as? String,
               !DopaCtl.isDopaAvailable(path) {
                errPrint("Warning: \(path) is not an executable file.")
            }
            return 0
        }
    }

    // MARK: - install / sync / uninstall

    static func cmdInstall() -> Int32 {
        withSessionEnv { _ in
            do {
                try doInstall()
                return 0
            } catch {
                errPrint(String(describing: error))
                return 2
            }
        }
    }

    static func cmdSync() -> Int32 {
        withSessionEnv { p in
            let count: Int
            do {
                count = try HerdrSocket.getAgentStatuses().count
            } catch {
                print("[sync] herdr unavailable; leaving LaunchAgent unchanged: \(error)")
                return 0
            }
            if count > 0 {
                print("[sync] \(count) agents; ensuring LaunchAgent is installed and started.")
                do {
                    try doInstall()
                } catch {
                    errPrint(String(describing: error))
                    return 2
                }
                // doInstall deliberately leaves the service stopped; re-enable
                // before bootstrap to recover from a persisted disabled override.
                _ = LaunchAgent.run(
                    ["launchctl", "enable", LaunchAgent.serviceTarget(labelName: p.label)])
                _ = LaunchAgent.run(
                    ["launchctl", "bootstrap", LaunchAgent.domain(), p.plist])
                LaunchAgent.start(p.label)
                return 0
            }
            print("[sync] no agents; stopping LaunchAgent but keeping it installed.")
            LaunchAgent.stop(p.label)
            return 0
        }
    }

    static func cmdUninstall(cleanup: Bool) -> Int32 {
        withSessionEnv { p in
            let plistDest = p.plist

            let (procCode, msg) = LaunchAgent.run(
                ["launchctl", "bootout", LaunchAgent.domain(), plistDest])
            if procCode == 0 {
                print("[uninstall] unloaded LaunchAgent: \(p.label)")
            } else if !msg.isEmpty {
                print("[uninstall] bootout (ignored if not loaded): \(msg)")
            }

            if FsUtil.isFile(plistDest) {
                try? FileManager.default.removeItem(atPath: plistDest)
                print("[uninstall] removed plist: \(plistDest)")
            } else {
                print("[uninstall] no plist at \(plistDest); nothing to remove.")
            }

            if cleanup {
                for dir in [p.logDir, p.stateDir] {
                    if FileManager.default.fileExists(atPath: dir) {
                        try? FileManager.default.removeItem(atPath: dir)
                        print("[uninstall] removed \(dir)")
                    }
                }
                let cfgFile = Config.configPath()
                if FsUtil.isFile(cfgFile) {
                    do {
                        try FileManager.default.removeItem(atPath: cfgFile)
                        print("[uninstall] removed \(cfgFile)")
                    } catch {
                        print("[uninstall] could not remove \(cfgFile): \(error)")
                    }
                }
                print("[uninstall] logs, state, and config removed.")
            } else {
                print("[uninstall] kept logs (\(p.logDir)), state (\(p.stateDir)), and config.")
                print("[uninstall] pass --cleanup to remove them.")
            }
            print("[uninstall] done. Your own dopa sessions were never touched.")
            return 0
        }
    }

    // MARK: - once / daemon / logs

    static func cmdOnce() -> Int32 {
        withSessionEnv { _ in
            runOnce(cfg: loadMonitorConfig())
            return 0
        }
    }

    static func cmdEvent() -> Int32 {
        withSessionEnv { _ in
            runEventHook(cfg: loadMonitorConfig())
            return 0
        }
    }

    static func cmdDaemon() -> Int32 {
        withSessionEnv { _ in
            let cfg = loadMonitorConfig()
            let statePath = cfg.statePath
            runDaemon(initialCfg: cfg) { event in
                let ctx = loadCtx(statePath)
                let armed = Config.toBool(Config.loadResolved()["armed"], true)
                HerdrCli.emitDaemonEvent(event, ctx: ctx, armed: armed)
            }
            return 0
        }
    }

    static func cmdLogs(_ lines: Int) -> Int32 {
        withSessionEnv { p in
            let log = p.logDir + "/monitor.out.log"
            guard FsUtil.isFile(log), let text = FsUtil.readTextFile(log) else {
                print("No log file yet: \(log)")
                return 0
            }
            let all = text.components(separatedBy: .newlines)
            for line in all.suffix(max(1, lines)) {
                print(line)
            }
            return 0
        }
    }

    // MARK: - herdr UI passthrough

    static func cmdReportMetadata() -> Int32 {
        withSessionEnv { _ in
            guard HerdrCli.uiBin() != nil else {
                errPrint("HERDR_BIN_PATH not set; not running from a herdr session.")
                return 1
            }
            guard let paneID = HerdrCli.resolvePaneID() else {
                errPrint("No herdr pane id (HERDR_PANE_ID / context); nothing to report.")
                return 1
            }
            let data = collectStatus()
            let ok = HerdrCli.reportMetadata(
                paneID: paneID,
                title: "dopa sleep guard",
                tokens: [
                    ("guard", data.armed ? "armed" : "paused"),
                    ("dopa", data.monitorState),
                    ("agents", data.agents.available ? String(data.agents.total) : "?"),
                ])
            if !ok {
                errPrint("herdr pane report-metadata failed.")
                return 1
            }
            print("reported pane metadata to \(paneID)")
            return 0
        }
    }

    static func cmdNotify(_ title: String, _ body: String?) -> Int32 {
        guard HerdrCli.uiBin() != nil else {
            errPrint("HERDR_BIN_PATH not set; not running from a herdr session.")
            return 1
        }
        guard HerdrCli.notify(title: title, body: body) else {
            errPrint("herdr notification show failed.")
            return 1
        }
        return 0
    }

    // MARK: - dispatch

    static func errPrint(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static func main(_ argv: [String]) -> Int32 {
        guard let cmd = argv.first, !cmd.isEmpty else {
            print(usage)
            return 2
        }
        let rest = Array(argv.dropFirst())
        switch cmd {
        case "status":
            return cmdStatus(argv: rest)
        case "on":
            return cmdOn()
        case "off", "stop":
            return cmdOff()
        case "get":
            return cmdGet(rest.first)
        case "set":
            guard rest.count == 2 else {
                errPrint("usage: herdr-dopa set KEY VALUE\nkeys: "
                    + Config.SET_KEYS.joined(separator: ", "))
                return 2
            }
            return cmdSet(rest[0], rest[1])
        case "install":
            return cmdInstall()
        case "sync":
            return cmdSync()
        case "uninstall":
            let cleanup = rest.contains("--cleanup")
            return cmdUninstall(cleanup: cleanup)
        case "once":
            return cmdOnce()
        case "event":
            return cmdEvent()
        case "daemon":
            return cmdDaemon()
        case "logs":
            var lines = 30
            var i = 0
            while i < rest.count {
                if rest[i] == "-n", i + 1 < rest.count, let n = Int(rest[i + 1]) {
                    lines = n
                    i += 1
                }
                i += 1
            }
            return cmdLogs(lines)
        case "report-metadata":
            return cmdReportMetadata()
        case "notify":
            var title: String?
            var body: String?
            var i = 0
            while i < rest.count {
                if rest[i] == "--body", i + 1 < rest.count {
                    body = rest[i + 1]
                    i += 1
                } else if title == nil {
                    title = rest[i]
                }
                i += 1
            }
            guard let title else {
                errPrint("usage: herdr-dopa notify TITLE [--body TEXT]")
                return 2
            }
            return cmdNotify(title, body)
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            errPrint("Unknown command: \(cmd)\n")
            print(usage)
            return 2
        }
    }

    private static func cmdStatus(argv: [String]) -> Int32 {
        var json = false
        var watch: Double? = nil
        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--json":
                json = true
            case "--watch":
                if i + 1 < argv.count, let v = Double(argv[i + 1]) {
                    watch = v
                    i += 1
                } else {
                    watch = loadMonitorConfig().pollSeconds
                }
            default:
                errPrint("Unknown option for status: \(argv[i])")
                return 2
            }
            i += 1
        }
        return cmdStatus(json: json, watch: watch)
    }
}
