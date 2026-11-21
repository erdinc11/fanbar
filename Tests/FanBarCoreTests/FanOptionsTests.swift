import XCTest
@testable import FanBarCore

final class FanOptionsTests: XCTestCase {
    func testOptionLabelsAndRPMs() {
        XCTAssertEqual(FanOption.allCases.map(\.label), [
            "Auto", "2.5k", "3k", "4k", "5k", "6.8k (Full)", "Manual RPM…",
        ])
        XCTAssertEqual(FanOption.r2500.rpm(min: 2317, max: 6800), 2500)
        XCTAssertEqual(FanOption.r3000.rpm(min: 2317, max: 6800), 3000)
        XCTAssertEqual(FanOption.r4000.rpm(min: 2317, max: 6800), 4000)
        XCTAssertEqual(FanOption.r5000.rpm(min: 2317, max: 6800), 5000)
        XCTAssertEqual(FanOption.full.rpm(min: 2317, max: 6800), 6800)
        XCTAssertEqual(FanOption.full.rpm(min: 2317, max: 9000), 9000)
    }

    func testAutoAndManualHaveNoPresetRPM() {
        XCTAssertNil(FanOption.auto.rpm(min: 2317, max: 6800))
        XCTAssertNil(FanOption.manual.rpm(min: 2317, max: 6800))
    }

    func testManualRPMValidation() {
        XCTAssertEqual(ManualRPM.parse("4000", min: 2317, max: 6800), 4000)
        XCTAssertEqual(ManualRPM.parse("  3500 ", min: 2317, max: 6800), 3500)
        XCTAssertEqual(ManualRPM.parse("4,2k", min: 2317, max: 6800), 4200)
        XCTAssertNil(ManualRPM.parse("", min: 2317, max: 6800))
        XCTAssertNil(ManualRPM.parse("fast", min: 2317, max: 6800))
        XCTAssertNil(ManualRPM.parse("1000", min: 2317, max: 6800))
        XCTAssertNil(ManualRPM.parse("7000", min: 2317, max: 6800))
    }

    func testLeaseExpiry() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(Lease.isExpired(lastPing: now.addingTimeInterval(-11), now: now, duration: 12))
        XCTAssertTrue(Lease.isExpired(lastPing: now.addingTimeInterval(-13), now: now, duration: 12))
        XCTAssertTrue(Lease.isExpired(lastPing: now.addingTimeInterval(-12), now: now, duration: 12))
    }
}
