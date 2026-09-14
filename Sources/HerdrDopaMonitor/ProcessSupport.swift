import Darwin
import Foundation

struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessSupport {
    static func capture(_ arguments: [String], timeout: TimeInterval = 8) -> ProcessResult? {
        guard let command = arguments.first else { return nil }
        let executable = command.hasPrefix("/") ? command : (which(command) ?? command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() } catch { return nil }

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 5)
            return nil
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(data: out, encoding: .utf8) ?? "",
            standardError: String(data: err, encoding: .utf8) ?? ""
        )
    }

    static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func commandLine(_ pid: Int32) -> String? {
        guard let result = capture(["/bin/ps", "-ww", "-p", String(pid), "-o", "command="], timeout: 2),
              result.status == 0 else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func spawnDetached(executable: String, arguments: [String], stdout: String, stderr: String) throws -> Int32 {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attributes) }

        let strings = ([executable] + arguments).map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var argv = strings.map(Optional.some) + [nil]
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return pid
    }
}
