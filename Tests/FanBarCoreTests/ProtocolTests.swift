import XCTest
@testable import FanBarCore

final class ProtocolTests: XCTestCase {
    func testRequestJSONRoundTrip() throws {
        let request = FanRequest(cmd: "set", rpm: 5000)
        let data = try FanRequest.encode(request)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("\n"))
        XCTAssertEqual(try FanRequest.decode(data), request)
    }

    func testResponseJSONRoundTrip() throws {
        let response = FanResponse(ok: false, rpm: nil, mode: nil, actual: nil, max: 6800, min: 2317, error: "unauthorized", version: "1")
        XCTAssertEqual(try FanResponse.decode(try FanResponse.encode(response)), response)
    }
}
