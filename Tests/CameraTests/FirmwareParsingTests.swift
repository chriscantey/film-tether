import XCTest
@testable import Camera

final class FirmwareParsingTests: XCTestCase {

    func testParsesStandardSummary() {
        let summary = """
        Manufacturer: Canon
        Model: EOS 7D
        Device Version: Canon EOS 7D
        Serial Number: 0000000000

        Firmware Version: 2.0.6
        """
        XCTAssertEqual(CameraSession.parseFirmware(from: summary), "2.0.6")
    }

    func testParsesAlternativeFormat() {
        let summary = "Firmware: 2.0.3"
        XCTAssertEqual(CameraSession.parseFirmware(from: summary), "2.0.3")
    }

    func testReturnsNilOnNoMatch() {
        let summary = "Model: EOS 7D\nFirmware: unknown"
        XCTAssertNil(CameraSession.parseFirmware(from: summary))
    }

    func test7DFirmware206IsAcceptable() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0.6"))
    }

    func testFirmware203IsRefused() {
        XCTAssertTrue(CameraSession.isFirmwareTooOld("2.0.3"))
    }

    func test70DTypicalFirmwareIsAcceptable() {
        // The 70D ships firmware in the 1.x range, which should not be blocked.
        XCTAssertFalse(CameraSession.isFirmwareTooOld("1.1.5"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld("1.0.4"))
    }

    func testOtherEOSVersionsArePermissive() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("3.0.0"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0.5"))
    }

    func testMalformedFirmwareIsAcceptedByDefault() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld(""))
    }
}
