import Foundation

/// Subprocess helpers. `capture` runs a command with piped stdout/stderr and
/// optional timeout; readers drain the pipes on background queues so a large
/// output can never deadlock the wait, and a timeout SIGKILLs the child.
struct ProcResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

enum ProcRunner {
    /// Run `argv`, capture stdout/stderr. Returns nil when the process could
    /// not be spawned or timed out.
    static func capture(_ argv: [String], timeout: TimeInterval? = nil) -> ProcResult? {
        precondition(!argv.isEmpty, "ProcRunner.capture requires argv")
        // Foundation's Process does not do a PATH lookup for relative
        // executable paths (unlike Python's subprocess), so resolve here.
        let executable: String
        if argv[0].hasPrefix("/") {
            executable = argv[0]
        } else if let found = which(argv[0]) {
            executable = found
        } else {
            executable = "/usr/bin/" + argv[0]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        if argv.count > 1 { proc.arguments = Array(argv[1...]) }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        let outBuf = Locked(Data())
        let errBuf = Locked(Data())
        let terminated = DispatchSemaphore(value: 0)
        let outEOF = DispatchSemaphore(value: 0)
        let errEOF = DispatchSemaphore(value: 0)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                outEOF.signal()
            } else {
                outBuf.with { $0.append(chunk) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errEOF.signal()
            } else {
                errBuf.with { $0.append(chunk) }
            }
        }
        proc.terminationHandler = { _ in terminated.signal() }

        do {
            try proc.run()
        } catch {
            return nil
        }

        let wait: DispatchTimeoutResult
        if let timeout {
            wait = terminated.wait(timeout: .now() + timeout)
        } else {
            wait = terminated.wait(timeout: .distantFuture)
        }
        if wait == .timedOut {
            kill(proc.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 5)
            _ = outEOF.wait(timeout: .now() + 5)
            _ = errEOF.wait(timeout: .now() + 5)
            return nil
        }
        _ = outEOF.wait(timeout: .now() + 10)
        _ = errEOF.wait(timeout: .now() + 10)
        let out = String(data: outBuf.with { $0 }, encoding: .utf8) ?? ""
        let err = String(data: errBuf.with { $0 }, encoding: .utf8) ?? ""
        return ProcResult(exitCode: proc.terminationStatus, stdout: out, stderr: err)
    }

    /// launchctl-style quiet run: (exit code, trimmed stderr).
    static func runQuiet(_ argv: [String]) -> (Int32, String) {
        guard let result = capture(argv) else {
            return (127, "could not spawn \(argv.first ?? "?")")
        }
        return (result.exitCode, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
