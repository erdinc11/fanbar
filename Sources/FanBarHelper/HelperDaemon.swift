import Foundation
import Darwin
import FanBarSMC
import FanBarCore

/// Signal handler state. The C handler only sets an atomic flag and writes one
/// byte to a self-pipe — both async-signal-safe. The restore itself runs later
/// on the control thread, where taking NSLock and calling IOKit is safe.
private var shutdownFlag: sig_atomic_t = 0
private var shutdownPipeWrite: Int32 = -1

private func fanbarSignalHandler(_ signalNumber: Int32) {
    shutdownFlag = 1
    var byte: UInt8 = 1
    if shutdownPipeWrite >= 0 { _ = write(shutdownPipeWrite, &byte, 1) }
}

public final class HelperDaemon {
    private let backend: SMCBackend
    private let hardware: Hardware
    private let socketPath: String
    private let allowedUID: uid_t
    private let now: () -> Date
    private let sleepFn: (TimeInterval) -> Void
    private let log: (String) -> Void
    private let lock = NSLock()

    private var lastPing: Date?
    private var currentTarget: Float?
    private var monitorOnly = false

    public init(
        backend: SMCBackend,
        hardware: Hardware,
        socketPath: String = Constants.socketPath,
        allowedUID: uid_t,
        now: @escaping () -> Date = Date.init,
        sleep sleepFn: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        log: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.backend = backend
        self.hardware = hardware
        self.socketPath = socketPath
        self.allowedUID = allowedUID
        self.now = now
        self.sleepFn = sleepFn
        self.log = log

        // A manual fan left by another controller or a previous helper crash
        // has no owner: hand it back to macOS before serving anyone.
        if let fan = hardware.fans.first, Hardware.manualMode(backend, fan: fan) == true {
            restoreAuto()
        }
    }

    // MARK: - Command handling (testable without a socket)

    public func handle(request: FanRequest, peerUID: uid_t) -> FanResponse {
        lock.lock()
        defer { lock.unlock() }

        guard peerUID == 0 || peerUID == allowedUID else {
            return FanResponse(ok: false, error: "unauthorized")
        }

        switch request.cmd {
        case "ping":
            if currentTarget != nil { lastPing = now() }
            // Report whether control is actually held: after a helper restart
            // the fans can be back in Auto while the app still holds a choice.
            return FanResponse(ok: true, rpm: currentTarget, version: Constants.helperVersion)

        case "set":
            guard !monitorOnly, let fan = hardware.fans.first, let requested = request.rpm else {
                return FanResponse(ok: false, error: monitorOnly ? "monitor-only" : "bad request")
            }
            guard requested.isFinite else {
                return FanResponse(ok: false, error: "bad request")
            }
            let target = fan.clamp(requested)
            do {
                // On this M3 the SMC ignores F0Tg writes while mode is 0.
                // Engage manual first, then write the target immediately.
                try backend.writeUInt8(fan.modeKey, 1)
                try backend.writeFloat(fan.targetKey, target)
                var readBack = try backend.readFloat(fan.targetKey)
                for _ in 0..<5 where abs(readBack - target) > 5 {
                    Thread.sleep(forTimeInterval: 0.05)
                    readBack = try backend.readFloat(fan.targetKey)
                }
                guard abs(readBack - target) <= 5 else {
                    throw SMCError.callFailed(key: fan.targetKey, kern: 0, result: 0)
                }
                currentTarget = target
                lastPing = now()
                return statusLocked()
            } catch {
                log("set failed: \(error)")
                restoreAutoLocked()
                return FanResponse(ok: false, error: "smc write failed")
            }

        case "auto":
            if restoreAutoLocked() {
                return FanResponse(ok: true, version: Constants.helperVersion)
            }
            return FanResponse(ok: false, error: "Auto restore failed")

        case "status":
            // Only the owner of a manual selection may renew the lease; an
            // Auto-mode poller must not keep a stale manual target alive.
            if request.keepAlive == true, currentTarget != nil { lastPing = now() }
            return statusLocked()

        default:
            return FanResponse(ok: false, error: "unknown command")
        }
    }

    /// Control tick: re-assert the held target or release on lease expiry.
    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard let fan = hardware.fans.first, let target = currentTarget, let last = lastPing else { return }

        if Lease.isExpired(lastPing: last, now: now(), duration: Constants.leaseSeconds) {
            log("lease expired; restoring Auto")
            restoreAutoLocked()
            return
        }
        guard !monitorOnly else { return }
        do {
            try backend.writeUInt8(fan.modeKey, 1)
            try backend.writeFloat(fan.targetKey, target)
        } catch {
            log("re-assert failed: \(error)")
            restoreAutoLocked()
        }
    }

    func handleShutdownRequest() {
        restoreAuto()
    }

    public func restoreAuto() {
        lock.lock()
        defer { lock.unlock() }
        _ = restoreAutoLocked()
    }

    @discardableResult
    private func restoreAutoLocked() -> Bool {
        guard let fan = hardware.fans.first else { return false }
        let restored: Bool
        do {
            // OpenFan and fanctl release fans with mode=0 only. Never write a
            // target here: a stale target byte is ignored by the SMC in Auto.
            try backend.writeUInt8(fan.modeKey, 0)
            restored = true
        } catch {
            log("Auto restore failed: \(error)")
            monitorOnly = true
            restored = false
        }
        currentTarget = nil
        lastPing = nil
        return restored
    }

    private func statusLocked() -> FanResponse {
        guard let fan = hardware.fans.first else {
            return FanResponse(ok: false, error: "no fans")
        }
        let mode = try? backend.readUInt8(fan.modeKey)
        let actual = try? backend.readFloat(fan.actualKey)
        return FanResponse(
            ok: true,
            rpm: currentTarget,
            mode: mode,
            actual: actual,
            max: fan.maxRPM,
            min: fan.minRPM,
            error: monitorOnly ? "monitor-only" : nil,
            version: Constants.helperVersion
        )
    }

    // MARK: - Socket server

    /// The socket file needs the write bit for clients to connect at all.
    /// Authorization is enforced after connect with getpeereid(), so opening
    /// the file to all local users does not grant control of the fans.
    func makeListeningSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { throw SMCError.openFailed(errno) }
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SMCError.openFailed(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        let addrLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, addrLength)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SMCError.openFailed(code)
        }
        guard chmod(path, mode_t(0o666)) == 0 else {
            let code = errno
            close(fd)
            throw SMCError.openFailed(code)
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw SMCError.openFailed(code)
        }
        return fd
    }

    public func run() throws {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw SMCError.openFailed(errno) }
        shutdownPipeWrite = pipeFDs[1]
        installSignals()

        let fd = try makeListeningSocket(path: socketPath)
        log("listening on \(socketPath)")

        Thread.detachNewThread {
            self.acceptLoop(listenFD: fd)
        }
        while true {
            sleepFn(1)
            tick()
            if shutdownFlag != 0 {
                handleShutdownRequest()
                exit(0)
            }
        }
    }

    func acceptLoop(listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EBADF { return }
                continue
            }
            // One client must never block the control channel for everyone.
            Thread.detachNewThread { self.handleConnection(client) }
        }
    }

    private func handleConnection(_ client: Int32) {
        defer { close(client) }

        var idleTimeout = timeval(tv_sec: 10, tv_usec: 0)
        withUnsafePointer(to: &idleTimeout) { ptr in
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }

        var uid: uid_t = uid_t.max
        var gid: gid_t = gid_t.max
        if getpeereid(client, &uid, &gid) != 0 {
            send(FanResponse(ok: false, error: "unauthorized"), on: client)
            return
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        var used = 0
        while used < capacity {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(client, raw.baseAddress!.advanced(by: used), capacity - used)
            }
            if count <= 0 { break }
            used += count
            if buffer[..<used].contains(0x0A) { break }
        }
        guard used > 0 else { return }

        let response: FanResponse
        if let request = try? FanRequest.decode(Data(buffer[..<used])),
           let line = String(bytes: buffer[..<used], encoding: .utf8), line.contains("\n") {
            response = handle(request: request, peerUID: uid)
        } else {
            response = FanResponse(ok: false, error: "bad request")
        }
        send(response, on: client)
    }

    private func send(_ response: FanResponse, on client: Int32) {
        guard var data = try? FanResponse.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            _ = write(client, raw.baseAddress, raw.count)
        }
    }

    private func installSignals() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, fanbarSignalHandler)
        }
    }
}
