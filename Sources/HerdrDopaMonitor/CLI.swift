import Darwin
import Foundation

enum CLI {
    static let usage = """
    Usage:
      herdr-dopa-monitor event
      herdr-dopa-monitor once
      herdr-dopa-monitor status [--json]
      herdr-dopa-monitor set <keep_display_on|stop_on_lid_close|dopa_sock> <VALUE>
      herdr-dopa-monitor stop
    """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "event": return event()
        case "once": return once()
        case "status": return status(rest)
        case "set": return set(rest)
        case "stop": return stop()
        case "hold":
            guard rest.count == 1 else { return 2 }
            return Holder.run(requestPath: rest[0])
        case "--version", "version":
            print(pluginVersion)
            return 0
        case "--help", "-h", "help":
            print(usage)
            return 0
        default:
            fputs("Unknown command: \(command)\n\(usage)\n", stderr)
            return 2
        }
    }

    private static func event() -> Int32 {
        let name = ProcessInfo.processInfo.environment["HERDR_PLUGIN_EVENT"] ?? "unnamed"
        log("Event hook '\(name)' received; running one immediate iteration")
        return once()
    }

    private static func once() -> Int32 {
        let paths = Paths.resolve()
        if HookContext.manualCommandIsBlocked(paths: paths) {
            do {
                let stopped = try GuardEngine.reconcileDisabled(paths: paths)
                print(stopped ? "Plugin disabled; ended owned dopa session." : "Plugin disabled; nothing held.")
                return 0
            } catch {
                fputs("Failed to reconcile disabled plugin: \(error)\n", stderr)
                return 1
            }
        }
        return runIteration(alwaysSuccess: true)
    }

    private static func runIteration(alwaysSuccess: Bool) -> Int32 {
        do {
            let result = try GuardEngine.iterate()
            notifyTransition(result)
            return 0
        } catch {
            log("guard iteration failed: \(error)")
            return alwaysSuccess ? 0 : 1
        }
    }

    private static func stop() -> Int32 {
        do {
            let stopped = try GuardEngine.stop()
            print(stopped ? "Stopped: ended owned dopa session." : "Stopped: no owned dopa session.")
            print("Done.")
            return 0
        } catch {
            fputs("Stop failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func set(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 else {
            fputs("usage: set KEY VALUE\nkeys: keep_display_on, stop_on_lid_close, dopa_sock\n", stderr)
            return 2
        }
        let paths = Paths.resolve()
        var config = Store.loadConfig(paths: paths, environment: [:])
        let key = arguments[0]
        let raw = arguments[1]
        switch key {
        case "keep_display_on", "stop_on_lid_close":
            guard let value = parseBoolean(raw) else {
                fputs("Invalid value: \(key) wants true/false, got '\(raw)'\n", stderr)
                return 2
            }
            if key == "keep_display_on" { config.keepDisplayOn = value }
            else { config.stopOnLidClose = value }
        case "dopa_sock":
            guard !raw.isEmpty else {
                fputs("Invalid value: dopa_sock wants a socket path\n", stderr)
                return 2
            }
            config.dopaSocket = raw
        default:
            fputs("Unknown key: \(key). Valid: keep_display_on, stop_on_lid_close, dopa_sock\n", stderr)
            return 2
        }
        do {
            try Store.save(config, to: paths.configFile)
        } catch {
            fputs("Could not save config: \(error)\n", stderr)
            return 1
        }
        print("\(key) = \(raw) (applied)")
        if HookContext.manualCommandIsBlocked(paths: paths) {
            print("Plugin disabled; change saved, applies on next enable.")
            return 0
        }
        return runIteration(alwaysSuccess: true)
    }

    private static func status(_ arguments: [String]) -> Int32 {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json": json = true
            default:
                fputs("Unknown option for status: \(argument)\n", stderr)
                return 2
            }
        }

        renderStatus(json: json)
        return 0
    }

    private static func renderStatus(json: Bool) {
        let paths = Paths.resolve()
        let config = Store.loadConfig(paths: paths)
        let state = Store.loadState(paths: paths)
        let observation = HerdrObserver.observe()
        let holderAlive = Holder.isAlive(state: state)
        let sessionAlive = holderAlive && state.sessionID.map {
            DopaClient.sessionIsAlive(socketPath: config.dopaSocket, sessionID: $0)
        } ?? false
        let registry = PluginRegistry.state(at: paths.pluginRegistry)
        let socketPresent = isSocket(config.dopaSocket)

        if json {
            let pluginEnabled: Any
            switch registry {
            case .enabled: pluginEnabled = true
            case .disabled: pluginEnabled = false
            case .missing, .unavailable: pluginEnabled = NSNull()
            }
            let agentError: Any
            if observation == nil { agentError = "herdr unreachable" }
            else { agentError = NSNull() }
            var object: [String: Any] = [
                "monitor_state": state.monitorState.rawValue,
                "session_id": state.sessionID ?? NSNull(),
                "owned_session_alive": sessionAlive,
                "dopa_sock": config.dopaSocket,
                "dopa_present": socketPresent,
                "plugin_enabled": pluginEnabled,
                "agents": [
                    "available": observation != nil,
                    "total": observation?.total ?? 0,
                    "working": observation?.working ?? 0,
                    "error": agentError,
                ],
                "config": [
                    "keep_display_on": config.keepDisplayOn,
                    "stop_on_lid_close": config.stopOnLidClose,
                    "dopa_sock": config.dopaSocket,
                ],
                "config_file": paths.configFile,
                "state_file": paths.stateFile,
                "last_error": state.lastError ?? NSNull(),
            ]
            if !JSONSerialization.isValidJSONObject(object) { object = ["error": "status serialization failed"] }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            return
        }

        if registry == .disabled {
            print("○ dopa guard — disabled")
        } else if state.monitorState == .on {
            print("● dopa guard — guarding  ·  \(observation?.working ?? 0) working")
        } else if state.monitorState == .error {
            print("✖ dopa guard — error  ·  \(state.lastError ?? "run once/event to retry")")
        } else {
            print("○ dopa guard — idle")
        }
        if let observation {
            print("  agents        \(observation.total) observed · \(observation.working) working")
        } else {
            print("  agents        unavailable (herdr unreachable)")
        }
        if sessionAlive {
            var flags: [String] = []
            if config.keepDisplayOn { flags.append("--keep-display-on") }
            if config.stopOnLidClose { flags.append("--stop-on-lid-close") }
            print("  dopa session  active\(flags.isEmpty ? "" : " · " + flags.joined(separator: " "))")
        } else if let sessionID = state.sessionID {
            print("  dopa session  stale session \(sessionID) (gone)")
        } else {
            print("  dopa session  none")
        }
        if !socketPresent { print("  dopa socket   MISSING: \(config.dopaSocket)") }
        print("  config        \(paths.configFile)")
        print("    keep_display_on    \(config.keepDisplayOn)")
        print("    stop_on_lid_close  \(config.stopOnLidClose)")
        print("    dopa_sock          \(config.dopaSocket)")
    }

    private static func parseBoolean(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return nil
        }
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func notifyTransition(_ result: IterationResult) {
        guard result.previousState != result.state.monitorState,
              let herdr = nonEmpty(ProcessInfo.processInfo.environment["HERDR_BIN_PATH"])
                ?? ProcessSupport.which("herdr") else { return }
        let title: String
        let body: String
        switch result.state.monitorState {
        case .on:
            title = "dopa guard: keeping Mac awake"
            body = "Agents working; owned dopa session started."
        case .off:
            title = "dopa guard: idle"
            body = "Agents idle; owned dopa session ended."
        case .error:
            title = "dopa guard: error"
            body = result.state.lastError ?? "see status"
        }
        _ = ProcessSupport.capture([herdr, "notification", "show", title, "--body", body], timeout: 3)
        reportMetadata(
            herdr: herdr,
            state: result.state.monitorState,
            working: result.observation.working
        )
    }

    private static func reportMetadata(herdr: String, state: MonitorState, working: Int) {
        let environment = ProcessInfo.processInfo.environment
        var paneID = nonEmpty(environment["HERDR_PANE_ID"])
        if paneID == nil,
           let context = environment["HERDR_PLUGIN_CONTEXT_JSON"]?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: context) {
            paneID = findPaneID(in: object)
        }
        guard let paneID else { return }
        let token: String
        switch state {
        case .on: token = "guarding"
        case .off: token = "idle"
        case .error: token = "error"
        }
        _ = ProcessSupport.capture([
            herdr, "pane", "report-metadata", paneID,
            "--source", pluginID,
            "--title", "dopa sleep guard",
            "--token", "dopa=\(token)",
            "--token", "agents=\(working)",
            "--ttl-ms", "600000",
        ], timeout: 3)
    }

    private static func findPaneID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let paneID = dictionary["pane_id"] as? String { return paneID }
            for child in dictionary.values {
                if let paneID = findPaneID(in: child) { return paneID }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let paneID = findPaneID(in: child) { return paneID }
            }
        }
        return nil
    }
}
