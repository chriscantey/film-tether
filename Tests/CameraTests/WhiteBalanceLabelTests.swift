import XCTest
@testable import Camera

/// The one white-balance mode name we rewrite, and everything we must not.
///
/// "Color Temperature" is 136.6pt in the picker's monospaced face against
/// 88.4pt for the longest of the others, so it would force the box wide and
/// still truncate. It is shortened to "Temperature". Every other mode passes
/// through untouched, because they are already what a photographer calls them.
final class WhiteBalanceLabelTests: XCTestCase {
    func testColorTemperatureIsShortened() {
        XCTAssertEqual(PropertyLabels.whiteBalance("Color Temperature"), "Temperature")
    }

    func testSpellingDriftIsStillCaught() {
        for raw in ["color temperature", "Colour Temperature", "ColorTemperature",
                    "Color Temp", "colortemp", "  Color Temperature  "] {
            XCTAssertEqual(PropertyLabels.whiteBalance(raw), "Temperature",
                           "\(raw) should shorten")
        }
    }

    func testEveryOtherModeIsUntouched() {
        for raw in ["Auto", "Daylight", "Cloudy", "Shade", "Tungsten",
                    "Fluorescent", "Flash", "Custom", "Custom Whitebalance: PC-1"] {
            XCTAssertEqual(PropertyLabels.whiteBalance(raw), raw)
        }
    }

    func testEmptyAndPlaceholderSurvive() {
        XCTAssertEqual(PropertyLabels.whiteBalance(""), "")
        XCTAssertEqual(PropertyLabels.whiteBalance("\u{2014}"), "\u{2014}")
    }

    /// A mode that merely mentions color is not the color-temperature mode.
    func testNearMissesAreNotRewritten() {
        XCTAssertEqual(PropertyLabels.whiteBalance("Color"), "Color")
        XCTAssertEqual(PropertyLabels.whiteBalance("Temperature"), "Temperature")
        XCTAssertEqual(PropertyLabels.whiteBalance("Color Temperature Auto"),
                       "Color Temperature Auto")
    }
}
