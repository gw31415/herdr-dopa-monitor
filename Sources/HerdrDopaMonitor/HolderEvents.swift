import Darwin
import Dispatch
import Foundation
import IOKit

private func holderLidInterestCallback(
    _ reference: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let reference else { return }
    Unmanaged<HolderEventMonitor>.fromOpaque(reference)
        .takeUnretainedValue()
        .lidStateDidChange(service: service)
}

/// Event sources that keep a holder alive without timers or periodic reads.
///
/// - The parent directory of plugins.json is watched because Herdr replaces
///   the registry atomically.
/// - The dopa socket is watched for readable/EOF events and drained only when
///   the kernel reports activity.
/// - IOPMrootDomain general-interest notifications trigger a fresh read of
///   AppleClamshellState only when IOKit reports a power-state change.
final class HolderEventMonitor {
    private let request: HolderRequest
    private let queue = DispatchQueue(label: "dev.amas.herdr-dopa-monitor.holder-events")
    private let completion = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var result: String?

    private var registryDescriptor: Int32 = -1
    private var registrySource: DispatchSourceFileSystemObject?
    private var registryFileSource: DispatchSourceFileSystemObject?
    private var dopaSource: DispatchSourceRead?
    private var notificationPort: IONotificationPortRef?
    private var lidService: io_service_t = IO_OBJECT_NULL
    private var lidNotification: io_object_t = IO_OBJECT_NULL

    init(request: HolderRequest) throws {
        self.request = request
        try watchPluginRegistry()
        if request.stopOnLidClose {
            try watchLid()
        }
        let state = PluginRegistry.state(at: request.pluginRegistry)
        guard state == .enabled else { throw HolderError.pluginInactive(state) }
    }

    deinit {
        registrySource?.cancel()
        registryFileSource?.cancel()
        dopaSource?.cancel()
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if lidNotification != IO_OBJECT_NULL { IOObjectRelease(lidNotification) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        // Stop all producers before draining callbacks that retain only an
        // unowned IOKit refCon pointer to this object.
        queue.sync {}
        if lidService != IO_OBJECT_NULL { IOObjectRelease(lidService) }
        if registryDescriptor >= 0 { close(registryDescriptor) }
    }

    func watchDopaConnection(_ connection: UnixSocketConnection) throws {
        let descriptor = connection.descriptor
        guard descriptor >= 0 else { throw UnixSocketError.eof }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainDopaEvent(descriptor: descriptor)
        }
        dopaSource = source
        source.resume()
    }

    func wait() -> String {
        completion.wait()
        return resultLock.withLock { result ?? "unknown_event" }
    }

    fileprivate func lidStateDidChange(service: io_service_t) {
        switch Lid.state(service: service) {
        case .open: return
        case .closed: finish("lid_closed")
        case nil: finish("lid_error")
        }
    }

    private func watchPluginRegistry() throws {
        let directory = URL(fileURLWithPath: request.pluginRegistry)
            .deletingLastPathComponent().path
        registryDescriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        guard registryDescriptor >= 0 else {
            throw UnixSocketError.system("open plugin registry directory", errno)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: registryDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.verifyPluginRegistry() }
        registrySource = source
        source.resume()
        armRegistryFileSource()
    }

    private func verifyPluginRegistry() {
        let state = PluginRegistry.state(at: request.pluginRegistry)
        if state != .enabled {
            finish("plugin_\(state)")
            return
        }

        // A parent-directory event means plugins.json may have been replaced
        // atomically. Re-open the path so the file source follows its new inode.
        armRegistryFileSource()
    }

    private func armRegistryFileSource() {
        let descriptor = open(request.pluginRegistry, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            registryFileSource?.cancel()
            registryFileSource = nil
            return
        }

        let previous = registryFileSource
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke, .attrib, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.verifyPluginRegistry() }
        source.setCancelHandler { close(descriptor) }
        registryFileSource = source
        source.resume()
        previous?.cancel()
    }

    private func watchLid() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw HolderError.lidUnavailable
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        lidService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain")
        )
        guard lidService != IO_OBJECT_NULL else { throw HolderError.lidUnavailable }
        let status = IOServiceAddInterestNotification(
            port,
            lidService,
            kIOGeneralInterest,
            holderLidInterestCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &lidNotification
        )
        guard status == KERN_SUCCESS else { throw HolderError.lidUnavailable }

        // Register first, then read. A change racing this read will either be
        // reflected here or delivered by the already-armed notification.
        guard let state = Lid.state(service: lidService) else {
            throw HolderError.lidUnavailable
        }
        guard state == .open else { throw HolderError.lidClosed }
    }

    private func drainDopaEvent(descriptor: Int32) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 { continue }
            if count == 0 {
                finish("dopa_disconnected")
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            finish("dopa_error")
            return
        }
    }

    private func finish(_ reason: String) {
        let shouldSignal = resultLock.withLock { () -> Bool in
            guard result == nil else { return false }
            result = reason
            return true
        }
        if shouldSignal { completion.signal() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Waits for a holder's ready file or process exit using kqueue-backed
/// dispatch sources. The timeout is a single deadline, not an interval timer.
final class HolderReadyWaiter {
    private let readyPath: String
    private let token: String
    private let pid: Int32
    private let queue = DispatchQueue(label: "dev.amas.herdr-dopa-monitor.holder-start")
    private let completion = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var result: HolderReady?
    private var completed = false
    private var directoryDescriptor: Int32 = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?

    init(directory: String, readyPath: String, token: String, pid: Int32) throws {
        self.readyPath = readyPath
        self.token = token
        self.pid = pid
        directoryDescriptor = open(directory, O_EVTONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw UnixSocketError.system("open holder directory", errno)
        }

        let directorySource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        directorySource.setEventHandler { [weak self] in self?.checkReady() }
        self.directorySource = directorySource

        let processSource = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: queue
        )
        processSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkReady()
            self.finish(nil)
        }
        self.processSource = processSource

        directorySource.resume()
        processSource.resume()
        checkReady()
        if !ProcessSupport.isAlive(pid) { finish(nil) }
    }

    deinit {
        directorySource?.cancel()
        processSource?.cancel()
        queue.sync {}
        if directoryDescriptor >= 0 { close(directoryDescriptor) }
    }

    func wait(timeout: TimeInterval) -> HolderReady? {
        _ = completion.wait(timeout: .now() + timeout)
        return resultLock.withLock { result }
    }

    private func checkReady() {
        guard let ready = Store.load(HolderReady.self, from: readyPath),
              ready.token == token,
              ready.pid == pid else { return }
        finish(ready)
    }

    private func finish(_ ready: HolderReady?) {
        let shouldSignal = resultLock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            result = ready
            return true
        }
        if shouldSignal { completion.signal() }
    }
}

/// One-shot process exit wait. This replaces repeated kill(0)/sleep probes.
final class ProcessExitWaiter {
    private let completion = DispatchSemaphore(value: 0)
    private let source: DispatchSourceProcess?

    init(pid: Int32) {
        guard ProcessSupport.isAlive(pid) else {
            source = nil
            completion.signal()
            return
        }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [completion] in completion.signal() }
        self.source = source
        source.resume()
        if !ProcessSupport.isAlive(pid) { completion.signal() }
    }

    deinit { source?.cancel() }

    func wait(timeout: TimeInterval) -> Bool {
        completion.wait(timeout: .now() + timeout) == .success
    }
}
