import XCTest
@testable import FanBarSMC

final class SMCFormatTests: XCTestCase {
    func testFourCCBigEndian() {
        XCTAssertEqual(SMCFormat.fourCC("F0Md"), 0x46304D64)
        XCTAssertEqual(SMCFormat.fourCC("Tp09"), 0x54703039)
        XCTAssertEqual(SMCFormat.string(from: 0x46304D64), "F0Md")
    }

    func testDecodeFloatLittleEndian() {
        let value = SMCFormat.decodeFloat([0x00, 0x80, 0xD4, 0x45])
        XCTAssertEqual(value, 6800, accuracy: 0.01)
    }

    func testEncodeFloatLittleEndian() {
        XCTAssertEqual(SMCFormat.encodeFloat(6800), [0x00, 0x80, 0xD4, 0x45])
        let bytes = SMCFormat.encodeFloat(2317)
        XCTAssertEqual(SMCFormat.decodeFloat(bytes), 2317, accuracy: 0.01)
    }
}
