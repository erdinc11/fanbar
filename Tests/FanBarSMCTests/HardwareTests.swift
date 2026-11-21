import XCTest
@testable import FanBarSMC

private final class FakeSMC: SMCBackend {
    var floats: [String: Float] = [:]
    var uint8s: [String: UInt8] = [:]
    var uint32s: [String: UInt32] = [:]
    var keys: Set<String> = []
    var writes: [(String, Float)] = []
    var uint8Writes: [(String, UInt8)] = []

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        guard keys.contains(key) else { throw SMCError.keyNotFound(key) }
        return SMCKeyInfo(dataSize: 4, dataType: SMCFormat.fourCC("flt "), attributes: 0x80)
    }
    func readFloat(_ key: String) throws -> Float {
        guard keys.contains(key), let value = floats[key] else { throw SMCError.keyNotFound(key) }
        return value
    }
    func readUInt8(_ key: String) throws -> UInt8 {
        guard keys.contains(key), let value = uint8s[key] else { throw SMCError.keyNotFound(key) }
        return value
    }
    func readUInt32(_ key: String) throws -> UInt32 {
        guard keys.contains(key), let value = uint32s[key] else { throw SMCError.keyNotFound(key) }
        return value
    }
    func writeFloat(_ key: String, _ value: Float) throws { writes.append((key, value)) }
    func writeUInt8(_ key: String, _ value: UInt8) throws { uint8Writes.append((key, value)) }
    func keyExists(_ key: String) -> Bool { keys.contains(key) }
}

final class HardwareTests: XCTestCase {
    func testDiscoverFindsUppercaseModeKey() throws {
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 3
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800

        let hardware = try Hardware.discover(smc)
        XCTAssertEqual(hardware.fans.count, 1)
        XCTAssertEqual(hardware.fans[0].modeKey, "F0Md")
        XCTAssertEqual(hardware.fans[0].minRPM, 2317)
        XCTAssertEqual(hardware.fans[0].maxRPM, 6800)
    }

    func testDiscoverSkipsFanWithUnreadableLimits() throws {
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.floats["F0Mn"] = 0
        smc.floats["F0Mx"] = 6800

        let hardware = try Hardware.discover(smc)
        XCTAssertTrue(hardware.fans.isEmpty)
    }

    func testClamp() {
        let fan = FanHardware(index: 0, minRPM: 2317, maxRPM: 6800, modeKey: "F0Md")
        XCTAssertEqual(fan.clamp(1000), 2317)
        XCTAssertEqual(fan.clamp(6800), 6800)
        XCTAssertEqual(fan.clamp(5000), 5000)
    }

    func testCpuTemperatureIsHottestValidKey() throws {
        let smc = FakeSMC()
        smc.keys = ["FNum", "Tp09", "Tp0T", "Tp01", "Tp05"]
        smc.uint8s["FNum"] = 0
        smc.floats["Tp09"] = 57
        smc.floats["Tp0T"] = 58.5
        smc.floats["Tp01"] = 0
        smc.floats["Tp05"] = 200
        let hardware = try Hardware.discover(smc)

        XCTAssertEqual(hardware.cpuTemperature(smc), 58.5)
    }

    func testManualModeOnlyOne() throws {
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 1
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        let fan = try Hardware.discover(smc).fans[0]

        XCTAssertTrue(try XCTUnwrap(Hardware.manualMode(smc, fan: fan)))
        smc.uint8s["F0Md"] = 3
        XCTAssertFalse(try XCTUnwrap(Hardware.manualMode(smc, fan: fan)))
    }
}
