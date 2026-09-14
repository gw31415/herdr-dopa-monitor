import Darwin
import Foundation

struct IterationResult {
    let previousState: MonitorState
    let state: GuardState
    let observation: AgentObservation
}

enum GuardEngine {
    static func iterate(paths: Paths = .resolve()) throws -> IterationResult {
        try FileLock.withExclusiveLock(at: paths.lockFile) {
            let config = Store.loadConfig(paths: paths)
            var state = Store.loadState(paths: paths)
            let previous = state.monitorState

            // A 0.1.x shell holder has no Swift token. End only the verified
            // symlinked nc process before adopting the new state format.
            if state.holderToken == nil,
               state.holderPID != nil || state.sessionID != nil {
                Holder.stopLegacyHolder(paths: paths)
                state.sessionID = nil
                state.holderPID = nil
                state.monitorState = .off
            }

            let observed = HerdrObserver.observe()
            let observation: AgentObservation
            if let observed {
                observation = observed
            } else {
                log("herdr unreachable; treating as no working agents")
                observation = AgentObservation(total: max(0, state.agentCount), working: 0)
            }

            if observation.working > 0 {
                if state.monitorState == .error {
                    state = clearedRuntime(state, monitorState: .off)
                }
                if state.monitorState == .off {
                    do {
                        state = try acquire(config: config, paths: paths, state: state)
                        log("Transition: off -> on (working=\(observation.working))")
                    } catch {
                        Holder.stop(state: state, paths: paths)
                        state = clearedRuntime(state, monitorState: .error)
                        state.lastError = "dopa acquire failure: \(error)"
                        log(state.lastError!)
                    }
                } else if state.monitorState == .on {
                    let alive = state.sessionID.map {
                        DopaClient.sessionIsAlive(socketPath: config.dopaSocket, sessionID: $0)
                    } ?? false
                    if !alive || !Holder.matches(config: config, state: state) {
                        log("Owned dopa session is gone or its options changed; restarting it")
                        Holder.stop(state: state, paths: paths)
                        state = clearedRuntime(state, monitorState: .off)
                        do {
                            state = try acquire(config: config, paths: paths, state: state)
                            log("Restarted owned dopa session")
                        } catch {
                            state = clearedRuntime(state, monitorState: .error)
                            state.lastError = "dopa restart failure: \(error)"
                            log(state.lastError!)
                        }
                    }
                }
            } else {
                if state.sessionID != nil || state.holderPID != nil || Holder.isAlive(state: state) {
                    Holder.stop(state: state, paths: paths)
                    log("Agents idle; ended owned dopa session")
                } else {
                    Holder.stopLegacyHolder(paths: paths)
                    log("Agents idle; nothing to stop")
                }
                state = clearedRuntime(state, monitorState: .off)
                state.lastError = nil
            }

            state.lastWorking = observation.working > 0
            state.agentCount = observation.total
            try Store.save(state, to: paths.stateFile)
            return IterationResult(previousState: previous, state: state, observation: observation)
        }
    }

    static func reconcileDisabled(paths: Paths = .resolve()) throws -> Bool {
        try FileLock.withExclusiveLock(at: paths.lockFile) {
            var state = Store.loadState(paths: paths)
            let held = state.sessionID != nil || state.holderPID != nil || Holder.isAlive(state: state)
            Holder.stop(state: state, paths: paths)
            state = clearedRuntime(state, monitorState: .off)
            state.lastError = nil
            try Store.save(state, to: paths.stateFile)
            return held
        }
    }

    static func stop(paths: Paths = .resolve()) throws -> Bool {
        try reconcileDisabled(paths: paths)
    }

    private static func acquire(
        config: GuardConfig,
        paths: Paths,
        state: GuardState
    ) throws -> GuardState {
        let (ready, request) = try Holder.start(config: config, paths: paths)
        var updated = state
        updated.monitorState = .on
        updated.sessionID = ready.sessionID
        updated.holderPID = ready.pid
        updated.holderToken = ready.token
        updated.holderRequestPath = paths.holderDirectory + "/request-\(request.token).json"
        updated.lastError = nil
        return updated
    }

    private static func clearedRuntime(_ state: GuardState, monitorState: MonitorState) -> GuardState {
        var result = state
        result.monitorState = monitorState
        result.sessionID = nil
        result.holderPID = nil
        result.holderToken = nil
        result.holderRequestPath = nil
        return result
    }
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}

enum HookContext {
    static func isHook(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ["HERDR_PLUGIN_EVENT", "HERDR_PLUGIN_ACTION_ID", "HERDR_PLUGIN_ENTRYPOINT_ID"]
            .contains { nonEmpty(environment[$0]) != nil }
    }

    static func manualCommandIsBlocked(paths: Paths = .resolve()) -> Bool {
        !isHook() && PluginRegistry.state(at: paths.pluginRegistry) == .disabled
    }
}
