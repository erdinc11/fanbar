import XCTest
import AppKit
import FanBarSMC
import FanBarCore
@testable import FanBarApp

private final class FakeSMC: SMCBackend {
    var floats: [String: Float] = [:]
    var uint8s: [String: UInt8] = [:]
    var keys: Set<String> = []
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
    func readUInt32(_ key: String) throws -> UInt32 { 0 }
    func writeFloat(_ key: String, _ value: Float) throws {}
    func writeUInt8(_ key: String, _ value: UInt8) throws {}
    func keyExists(_ key: String) -> Bool { keys.contains(key) }
}

private final class MockClient: HelperClientProtocol {
    let log: NSMutableArray
    var fail = false
    var responseOverride: ((FanRequest) -> FanResponse)?
    var lastRequest: FanRequest?

    init(log: NSMutableArray) { self.log = log }

    func send(_ request: FanRequest) throws -> FanResponse {
        lastRequest = request
        if let rpm = request.rpm {
            log.add("set:\(Int(rpm))")
        } else {
            log.add(request.cmd)
        }
        if let override = responseOverride { return override(request) }
        return fail
            ? FanResponse(ok: false, error: "mock failure")
            : FanResponse(ok: true, version: "1")
    }
}

private final class FakeLogin: LoginItemServicing {
    var enabled = false
    var isEnabled: Bool { enabled }
    func setEnabled(_ value: Bool) throws { enabled = value }
}

private final class FakeHelperManager: HelperManaging {
    var installed: Bool
    var installedCalled = false
    var uninstalledCalled = false
    var shouldFail = false

    init(installed: Bool) { self.installed = installed }
    var isInstalled: Bool { installed }
    var actionTitle: String { installed ? "Remove Helper…" : "Install Helper…" }
    func install() throws {
        if shouldFail { throw HelperManagerError.adminFailed }
        installed = true
        installedCalled = true
    }
    func uninstall() throws {
        if shouldFail { throw HelperManagerError.adminFailed }
        installed = false
        uninstalledCalled = true
    }
}

final class WakeRecoveryTests: XCTestCase {
    private func makeController(
        log: NSMutableArray,
        temps: [String: Float] = [:],
        helperInstalled: Bool = false,
        manualAnswer: String? = nil
    ) -> MenuBarController {
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 0
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        for (key, value) in temps {
            smc.keys.insert(key)
            smc.floats[key] = value
        }
        let hardware = try! Hardware.discover(smc)
        let client = MockClient(log: log)
        return MenuBarController(
            backend: smc,
            hardware: hardware,
            client: client,
            loginService: FakeLogin(),
            helperManager: FakeHelperManager(installed: helperInstalled),
            clientFactory: { MockClient(log: log) },
            alertPresenter: { _ in },
            manualPrompt: { _, _ in manualAnswer }
        )
    }

    func testWakeReappliesSelectedRPM() {
        let log = NSMutableArray()
        let controller = makeController(log: log)

        _ = controller.apply(option: .r5000)
        controller.handleWake()

        XCTAssertEqual(log as? [String], ["set:5000", "set:5000"])
    }

    func testWakeWithAutoOnlyChecksStatus() {
        let log = NSMutableArray()
        let controller = makeController(log: log)

        _ = controller.apply(option: .auto)
        controller.handleWake()

        XCTAssertEqual(log as? [String], ["auto", "status"])
    }

    func testTemperatureTitleUsesHottestCPUKey() {
        let controller = makeController(log: NSMutableArray(), temps: ["Tp09": 57, "Tp0T": 58.5])

        controller.refreshTemperature()

        XCTAssertEqual(controller.title, "59°")
    }

    func testHelperStatusTitle() {
        XCTAssertEqual(MenuBarController.statusTitle(FanResponse(ok: true, version: "1")), "Helper: ready")
        XCTAssertEqual(MenuBarController.statusTitle(FanResponse(ok: false, error: "monitor-only")), "Helper: limited")
        XCTAssertEqual(MenuBarController.statusTitle(nil), "Helper: not installed")
        XCTAssertEqual(MenuBarController.statusTitle(nil, installed: true), "Helper: not running")
    }

    func testManualRPMAppliesEnteredValue() {
        let log = NSMutableArray()
        let controller = makeController(log: log, manualAnswer: "4200")

        controller.requestManualRPM()

        XCTAssertEqual(log as? [String], ["set:4200"])
        XCTAssertEqual(controller.selectedOption, .manual)
        XCTAssertEqual(controller.manualRPM, 4200)
    }

    func testManualRPMRejectsOutOfRangeValue() {
        let log = NSMutableArray()
        let controller = makeController(log: log, manualAnswer: "9999")

        controller.requestManualRPM()

        XCTAssertEqual(log.count, 0)
        XCTAssertEqual(controller.selectedOption, .auto)
    }

    func testManualSelectionReappliesOnWake() {
        let log = NSMutableArray()
        let controller = makeController(log: log, manualAnswer: "4200")
        controller.requestManualRPM()
        log.removeAllObjects()

        controller.handleWake()

        XCTAssertEqual(log as? [String], ["set:4200"])
        XCTAssertEqual(controller.selectedOption, .manual)
    }

    func testInstallHelperAction() {
        let log = NSMutableArray()
        let controller = makeController(log: log)
        let manager = controller.helperManager as! FakeHelperManager

        controller.toggleHelperAction()

        XCTAssertTrue(manager.installedCalled)
        XCTAssertFalse(manager.uninstalledCalled)
    }

    func testRemoveHelperActionReleasesFanFirst() {
        let log = NSMutableArray()
        let controller = makeController(log: log, helperInstalled: true)
        let manager = controller.helperManager as! FakeHelperManager

        controller.toggleHelperAction()

        XCTAssertEqual(log as? [String], ["auto", "status"])
        XCTAssertTrue(manager.uninstalledCalled)
        XCTAssertFalse(manager.installed)
        XCTAssertEqual(controller.selectedOption, .auto)
    }

    func testRefreshStatusUpdatesRpmLabelEveryTick() {
        let log = NSMutableArray()
        let client = MockClient(log: log)
        var actual: Float = 1200
        client.responseOverride = { _ in FanResponse(ok: true, actual: actual, version: "1") }
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 0
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        let controller = MenuBarController(
            backend: smc,
            hardware: try! Hardware.discover(smc),
            client: client,
            loginService: FakeLogin(),
            helperManager: FakeHelperManager(installed: false),
            clientFactory: { MockClient(log: log) },
            alertPresenter: { _ in }
        )

        _ = controller.buildMenu()
        controller.refreshStatus()
        XCTAssertNil(client.lastRequest?.keepAlive, "Auto mode must not renew a manual lease")
        XCTAssertEqual(controller.rpmTextField?.frame.minX, 27, "RPM row must align with native menu item titles")
        XCTAssertEqual(controller.currentRPMLabel, "Fan: 1200 RPM")
        XCTAssertEqual(controller.rpmTextField?.stringValue, "Fan: 1200 RPM")
        actual = 4800
        controller.refreshStatus()
        XCTAssertEqual(controller.currentRPMLabel, "Fan: 4800 RPM")
        XCTAssertEqual(controller.rpmTextField?.stringValue, "Fan: 4800 RPM")
    }

    func testManualStatusSendsKeepAlive() {
        let log = NSMutableArray()
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 0
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        let client = MockClient(log: log)
        client.responseOverride = { _ in FanResponse(ok: true, rpm: 4000, version: "1") }
        let controller = MenuBarController(
            backend: smc,
            hardware: try! Hardware.discover(smc),
            client: client,
            loginService: FakeLogin(),
            helperManager: FakeHelperManager(installed: false),
            clientFactory: { MockClient(log: log) },
            alertPresenter: { _ in }
        )

        _ = controller.apply(option: .r4000)
        controller.refreshStatus()

        XCTAssertEqual(client.lastRequest?.keepAlive, true)
    }

    func testStartupClearsStaleManualControl() {
        let log = NSMutableArray()
        let controller = makeController(log: log)

        controller.clearStaleControlOnLaunch()

        XCTAssertEqual(log as? [String], ["auto"])
    }

    func testHelperLosingControlReappliesSelection() {
        let log = NSMutableArray()
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 0
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        let client = MockClient(log: log)
        let controller = MenuBarController(
            backend: smc,
            hardware: try! Hardware.discover(smc),
            client: client,
            loginService: FakeLogin(),
            helperManager: FakeHelperManager(installed: false),
            clientFactory: { MockClient(log: log) },
            alertPresenter: { _ in }
        )

        _ = controller.apply(option: .r4000)
        client.responseOverride = { request in
            request.cmd == "status"
                ? FanResponse(ok: true, rpm: nil, version: "1")
                : FanResponse(ok: true, rpm: 4000, version: "1")
        }
        controller.refreshStatus()

        XCTAssertEqual(log as? [String], ["set:4000", "status", "set:4000"])
    }

    func testRpmTitleShowsCurrentRPM() {
        XCTAssertEqual(MenuBarController.rpmTitle(FanResponse(ok: true, actual: 3448, version: "1")), "Fan: 3448 RPM")
        XCTAssertEqual(MenuBarController.rpmTitle(FanResponse(ok: true, actual: 0, version: "1")), "Fan: 0 RPM")
        XCTAssertEqual(MenuBarController.rpmTitle(nil), "Fan: —")
    }

    func testApplyFailureAlertsAndResetsSelection() {
        let log = NSMutableArray()
        let controller = makeController(log: log)
        // A fresh failing client supplied through the factory is used on wake;
        // for this test make the initial client fail via the shared log's owner.
        let smc = FakeSMC()
        smc.keys = ["FNum", "F0Mn", "F0Mx", "F0Md"]
        smc.uint8s["FNum"] = 1
        smc.uint8s["F0Md"] = 0
        smc.floats["F0Mn"] = 2317
        smc.floats["F0Mx"] = 6800
        let failing = MockClient(log: log)
        failing.fail = true
        let direct = MenuBarController(
            backend: smc,
            hardware: try! Hardware.discover(smc),
            client: failing,
            loginService: FakeLogin(),
            helperManager: FakeHelperManager(installed: false),
            clientFactory: { failing },
            alertPresenter: { _ in }
        )

        let response = direct.apply(option: .r5000)

        XCTAssertFalse(response?.ok ?? true)
        XCTAssertEqual(direct.selectedOption, .auto)
    }
}
