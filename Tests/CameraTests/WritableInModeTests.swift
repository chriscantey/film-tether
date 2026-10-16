import XCTest
@testable import Camera

final class WritableInModeTests: XCTestCase {

    func testManualModeAllWritable() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "M"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "shutterspeed", inMode: "M"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "aperture", inMode: "M"))
    }

    func testAvModeApertureWritableShutterReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "Av"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "aperture", inMode: "Av"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "shutterspeed", inMode: "Av"))
    }

    func testTvModeShutterWritableApertureReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "Tv"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "shutterspeed", inMode: "Tv"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "aperture", inMode: "Tv"))
    }

    func testPModeShutterAndApertureBothReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "P"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "shutterspeed", inMode: "P"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "aperture", inMode: "P"))
    }

    func testUnknownPropDefaultsToWritable() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "magicProperty", inMode: "Av"))
    }

    // MARK: - Which body events move a picker

    func testShutterEventMovesThePickerInTvAndM() {
        for mode in ["Tv", "TV", "M", "Manual"] {
            XCTAssertTrue(CameraProperties.pickerFollowsEvent(prop: "shutterspeed", mode: mode, value: "1/125"), mode)
        }
    }

    func testShutterEventLeavesThePickerInAvAndP() {
        for mode in ["Av", "AV", "P"] {
            XCTAssertFalse(CameraProperties.pickerFollowsEvent(prop: "shutterspeed", mode: mode, value: "1/125"), mode)
        }
    }

    func testAnAutoValueAlwaysMovesThePicker() {
        for mode in ["Av", "P", "Tv", "M"] {
            for value in ["auto", "Auto", ""] {
                XCTAssertTrue(CameraProperties.pickerFollowsEvent(prop: "shutterspeed", mode: mode, value: value),
                              "\(mode) \(value)")
            }
        }
    }
}
