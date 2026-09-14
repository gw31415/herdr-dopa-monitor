import Darwin
import Foundation
import IOKit

enum LidState: String {
    case open
    case closed
}

enum Lid {
    static func state() -> LidState? {
        let matching = IOServiceNameMatching("IOPMrootDomain")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return state(service: service)
    }

    static func state(service: io_service_t) -> LidState? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean)) ? .closed : .open
    }
}

enum HolderError: Error, CustomStringConvertible {
    case invalidRequest
    case pluginInactive(PluginRegistryState)
    case lidUnavailable
    case lidClosed
    case didNotBecomeReady(String)

    var description: String {
        switch self {
        case .invalidRequest: return "invalid holder request"
        case let .pluginInactive(state): return "plugin is not enabled: \(state)"
        case .lidUnavailable: return "lid state unavailable; refusing to acquire"
        case .lidClosed: return "lid is already closed; refusing to acquire"
        case let .didNotBecomeReady(detail): return "holder did not become ready: \(detail)"
        }
    }
}

enum Holder {
    static func run(requestPath: String) -> Int32 {
        guard let request = Store.load(HolderRequest.self, from: requestPath) else {
            return 2
        }
        do {
            let monitor = try HolderEventMonitor(request: request)
            let connection = try DopaClient.connect(socketPath: request.dopaSocket)
            defer { connection.closeConnection() }
            let sessionID = try DopaClient.acquire(connection, keepDisplayOn: request.keepDisplayOn)
            try monitor.watchDopaConnection(connection)
            try Store.save(
                HolderReady(token: request.token, pid: getpid(), sessionID: sessionID),
                to: request.readyPath
            )
            writeReason(monitor.wait(), to: request.endReasonPath)
            return 0
        } catch {
            try? String(describing: error).write(
                toFile: request.errorPath, atomically: true, encoding: .utf8
            )
            return 1
        }
    }

    static func start(config: GuardConfig, paths: Paths) throws -> (HolderReady, HolderRequest) {
        stopLegacyHolder(paths: paths)
        stopOrphanedHolder(in: paths.holderDirectory)
        try cleanupDirectory(paths.holderDirectory)
        try Store.ensureDirectory(paths.holderDirectory)
        let token = UUID().uuidString
        let requestPath = paths.holderDirectory + "/request-\(token).json"
        let readyPath = paths.holderDirectory + "/ready-\(token).json"
        let errorPath = paths.holderDirectory + "/error-\(token).txt"
        let endReasonPath = paths.holderDirectory + "/end-reason-\(token).txt"
        let request = HolderRequest(
            token: token,
            dopaSocket: config.dopaSocket,
            keepDisplayOn: config.keepDisplayOn,
            stopOnLidClose: config.stopOnLidClose,
            pluginRegistry: paths.pluginRegistry,
            readyPath: readyPath,
            errorPath: errorPath,
            endReasonPath: endReasonPath
        )
        try Store.save(request, to: requestPath)

        let executable = try executablePath()
        let pid = try ProcessSupport.spawnDetached(
            executable: executable,
            arguments: ["hold", requestPath],
            stdout: paths.holderDirectory + "/stdout.log",
            stderr: paths.holderDirectory + "/stderr.log"
        )
        let waiter = try HolderReadyWaiter(
            directory: paths.holderDirectory,
            readyPath: readyPath,
            token: token,
            pid: pid
        )
        if let ready = waiter.wait(timeout: 7) {
            return (ready, request)
        }
        if isProcess(pid, requestPath: requestPath) { terminate(pid) }
        let detail = (try? String(contentsOfFile: errorPath, encoding: .utf8))
            ?? "process exited before handshake"
        throw HolderError.didNotBecomeReady(detail)
    }

    static func isAlive(state: GuardState) -> Bool {
        guard let pid = state.holderPID,
              let requestPath = state.holderRequestPath,
              let token = state.holderToken,
              requestPath.contains(token),
              ProcessSupport.isAlive(pid) else { return false }
        return isProcess(pid, requestPath: requestPath)
    }

    static func matches(config: GuardConfig, state: GuardState) -> Bool {
        guard isAlive(state: state),
              let requestPath = state.holderRequestPath,
              let request = Store.load(HolderRequest.self, from: requestPath) else { return false }
        return request.dopaSocket == config.dopaSocket
            && request.keepDisplayOn == config.keepDisplayOn
            && request.stopOnLidClose == config.stopOnLidClose
    }

    static func stop(state: GuardState, paths: Paths) {
        if let pid = state.holderPID,
           let requestPath = state.holderRequestPath,
           isProcess(pid, requestPath: requestPath) {
            terminate(pid)
        } else {
            stopLegacyHolder(paths: paths)
        }
        stopOrphanedHolder(in: paths.holderDirectory)
        try? cleanupDirectory(paths.holderDirectory)
    }

    static func stopLegacyHolder(paths: Paths) {
        let directory = paths.holderDirectory
        guard let pidText = try? String(contentsOfFile: directory + "/pid", encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let executable = try? String(contentsOfFile: directory + "/executable", encoding: .utf8),
              !executable.isEmpty,
              let command = ProcessSupport.commandLine(pid),
              command == executable || command.hasPrefix(executable + " ") else { return }
        terminate(pid)
    }

    private static func stopOrphanedHolder(in directory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return
        }
        for name in names where name.hasPrefix("ready-") && name.hasSuffix(".json") {
            let readyPath = directory + "/" + name
            guard let ready = Store.load(HolderReady.self, from: readyPath) else { continue }
            let requestPath = directory + "/request-\(ready.token).json"
            if isProcess(ready.pid, requestPath: requestPath) { terminate(ready.pid) }
        }
    }

    private static func isProcess(_ pid: Int32, requestPath: String) -> Bool {
        guard ProcessSupport.isAlive(pid),
              let command = ProcessSupport.commandLine(pid) else { return false }
        return command.contains(" hold ") && command.contains(requestPath)
    }

    private static func terminate(_ pid: Int32) {
        guard ProcessSupport.isAlive(pid) else { return }
        let waiter = ProcessExitWaiter(pid: pid)
        _ = kill(pid, SIGTERM)
        if !waiter.wait(timeout: 5), ProcessSupport.isAlive(pid) {
            _ = kill(pid, SIGKILL)
        }
    }

    private static func cleanupDirectory(_ path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func executablePath() throws -> String {
        let raw = CommandLine.arguments[0]
        let absolute = raw.hasPrefix("/")
            ? raw
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(raw).standardized.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(absolute, &buffer) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        return String(cString: buffer)
    }

    private static func writeReason(_ reason: String, to path: String) {
        try? reason.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
