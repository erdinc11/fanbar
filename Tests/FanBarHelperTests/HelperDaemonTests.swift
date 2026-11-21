import XCTest
import FanBarSMC
import FanBarCore
@testable import FanBarHelper

private enum Write: Equatable {
    case float(String, Float)
    case uint8(String, UInt8)
}

private final class FakeSMC: SMCBackend {
    var floats: [String: Float] = [:]
    var uint8s: [String: UInt8] = [:]
    var keys: Set<String> = []
    var writes: [Write] = []
    var failingWriteKeys: Set<String> = []

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        guard keys.contains(key) else { throw SMCError.keyNotFound(key) }
        return SMCKeyInfo(dataSize: 4, dataType: SMCFormat.fourCC("flt "), attributes: 0xC0)
    }
    func readFloat(_ key: String) throws -> Float {
        guard keys.contains(key), let value = floats[key] else { throw SMCError.keyNotFound(key) }
        return value
    }
    func readUInt8(_ key: String) throws -> UInt8 {
        guard keys.contains(key), let value = uint8s[key] else { throw SMCError.keyNotFound(key) }
        return value
    }
    func readUInt32(_ key: String) throws -> UInt32 { 1 }
    func writeFloat(_ key: String, _ value: Float) throws {
        writes.append(.float(key, value))
        floats[key] = value
    }
    func writeUInt8(_ key: String, _ value: UInt8) throws {
        if failingWriteKeys.contains(key) { throw SMCError.keyNotFound(key) }
        writes.append(.uint8(key, value))
        uint8s[key] = value
    }
    func keyExists(_ key: String) -> Bool { keys.contains(key) }
}

private func makeFake(mode: UInt8 = 0) -> (FakeSMC, Hardware) {
    let smc = FakeSMC()
    smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md", "F0Tg", "F0Ac"]
    smc.uint8s["FNum"] = 1
    smc.uint8s["F0Md"] = mode
    smc.floats["F0Mn"] = 2317
    smc.floats["F0Mx"] = 6800
    smc.floats["F0Tg"] = 0
    smc.floats["F0Ac"] = 0
    return (smc, try! Hardware.discover(smc))
}

final class HelperDaemonTests: XCTestCase {
    func testSetWritesModeBeforeTargetAndClamps() throws {
        let (smc, hardware) = makeFake()
        var clock = Date(timeIntervalSince1970: 1000)
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501, now: { clock })

        let response = daemon.handle(request: FanRequest(cmd: "set", rpm: 1000), peerUID: 501)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(smc.writes, [.uint8("F0Md", 1), .float("F0Tg", 2317)])
    }

    func testAutoWritesOnlyModeZero() throws {
        let (smc, hardware) = makeFake()
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 5000), peerUID: 501)
        smc.writes.removeAll()

        let response = daemon.handle(request: FanRequest(cmd: "auto"), peerUID: 501)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(smc.writes, [.uint8("F0Md", 0)])
    }

    func testLeaseExpiryRestoresAuto() throws {
        let (smc, hardware) = makeFake()
        var clock = Date(timeIntervalSince1970: 1000)
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501, now: { clock })
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 5000), peerUID: 501)
        smc.writes.removeAll()

        clock = clock.addingTimeInterval(13)
        daemon.tick()

        XCTAssertEqual(smc.writes, [.uint8("F0Md", 0)])
        XCTAssertEqual(daemon.handle(request: FanRequest(cmd: "status"), peerUID: 501).rpm, nil)
    }

    func testStartupCleansStaleManualMode() throws {
        let (smc, hardware) = makeFake(mode: 1)

        _ = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)

        XCTAssertEqual(smc.writes, [.uint8("F0Md", 0)])
        XCTAssertEqual(smc.uint8s["F0Md"], 0)
    }

    func testListeningSocketAllowsClientConnect() throws {
        let path = "/tmp/fanbar-socket-test-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let (_, hardware) = makeFake()
        let daemon = HelperDaemon(backend: FakeSMC(), hardware: hardware, allowedUID: 501)

        let fd = try daemon.makeListeningSocket(path: path)
        defer { close(fd) }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & mode_t(0o777), mode_t(0o666))
        let client = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in connect(client, sa, length) }
        }
        XCTAssertEqual(result, 0)
    }

    func testStatusRefreshesLease() throws {
        let (smc, hardware) = makeFake()
        var clock = Date(timeIntervalSince1970: 1000)
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501, now: { clock })
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 4000), peerUID: 501)
        smc.writes.removeAll()

        clock = clock.addingTimeInterval(11)
        _ = daemon.handle(request: FanRequest(cmd: "status", keepAlive: true), peerUID: 501)
        clock = clock.addingTimeInterval(2)
        daemon.tick()

        XCTAssertFalse(smc.writes.contains(.uint8("F0Md", 0)), "owner status polling must keep the 12s lease alive")
    }

    func testPlainStatusDoesNotRefreshLease() throws {
        let (smc, hardware) = makeFake()
        var clock = Date(timeIntervalSince1970: 1000)
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501, now: { clock })
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 4000), peerUID: 501)
        smc.writes.removeAll()

        clock = clock.addingTimeInterval(11)
        _ = daemon.handle(request: FanRequest(cmd: "status"), peerUID: 501)
        clock = clock.addingTimeInterval(2)
        daemon.tick()

        XCTAssertTrue(smc.writes.contains(.uint8("F0Md", 0)), "a non-owner status poll must not extend the lease")
    }

    func testPingReportsCurrentTarget() throws {
        let (smc, hardware) = makeFake()
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)

        XCTAssertNil(daemon.handle(request: FanRequest(cmd: "ping"), peerUID: 501).rpm)
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 4000), peerUID: 501)
        XCTAssertEqual(daemon.handle(request: FanRequest(cmd: "ping"), peerUID: 501).rpm, 4000)
        _ = daemon.handle(request: FanRequest(cmd: "auto"), peerUID: 501)
        XCTAssertNil(daemon.handle(request: FanRequest(cmd: "ping"), peerUID: 501).rpm)
    }

    func testAutoReportsFailureWhenRestoreWriteFails() throws {
        let (smc, hardware) = makeFake(mode: 0)
        smc.failingWriteKeys = ["F0Md"]
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)

        let response = daemon.handle(request: FanRequest(cmd: "auto"), peerUID: 501)

        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    func testShutdownRequestRestoresAuto() throws {
        let (smc, hardware) = makeFake()
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)
        _ = daemon.handle(request: FanRequest(cmd: "set", rpm: 5000), peerUID: 501)
        smc.writes.removeAll()

        daemon.handleShutdownRequest()

        XCTAssertEqual(smc.writes, [.uint8("F0Md", 0)])
        XCTAssertNil(daemon.handle(request: FanRequest(cmd: "status"), peerUID: 501).rpm)
    }

    func testStalledClientDoesNotBlockOtherClients() throws {
        let path = "/tmp/fanbar-stall-\(UUID().uuidString).sock"
        defer { unlink(path) }
        let (_, hardware) = makeFake()
        let daemon = HelperDaemon(backend: FakeSMC(), hardware: hardware, allowedUID: 501)
        let fd = try daemon.makeListeningSocket(path: path)
        defer { close(fd) }
        Thread.detachNewThread { daemon.acceptLoop(listenFD: fd) }

        func openClient() -> Int32 {
            let client = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
            }
            let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1)
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in connect(client, sa, length) }
            }
            XCTAssertEqual(result, 0)
            return client
        }

        let stalled = openClient()   // connects but never sends a newline
        defer { close(stalled) }
        let responsive = openClient()
        defer { close(responsive) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(responsive, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        let request = try FanRequest.encode(FanRequest(cmd: "status")) + [0x0A]
        _ = request.withUnsafeBytes { write(responsive, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(responsive, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let response = try FanResponse.decode(Data(buffer[..<count]))
        XCTAssertTrue(response.ok)
    }

    func testUnauthorizedUIDRejected() throws {
        let (smc, hardware) = makeFake()
        let daemon = HelperDaemon(backend: smc, hardware: hardware, allowedUID: 501)

        let response = daemon.handle(request: FanRequest(cmd: "set", rpm: 5000), peerUID: 502)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "unauthorized")
        XCTAssertTrue(smc.writes.isEmpty)
    }
}
