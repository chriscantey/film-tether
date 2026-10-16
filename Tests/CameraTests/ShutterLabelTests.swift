import XCTest
@testable import Camera

final class ShutterLabelTests: XCTestCase {
    /// The decimals the Canon driver lists between 1 s and 1/4 each get their
    /// own label as seconds.
    func testSubSecondDecimalsShowAsSeconds() {
        let expected = ["0.8": "0.8s", "0.7": "0.7s", "0.6": "0.6s",
                        "0.5": "0.5s", "0.4": "0.4s", "0.3": "0.3s"]
        for (raw, label) in expected {
            XCTAssertEqual(PropertyLabels.shutter(raw), label, raw)
        }
    }

    func testTwoDecimalPlacesAreKeptAndTrailingZerosDropped() {
        XCTAssertEqual(PropertyLabels.shutter("0.25"), "0.25s")
        XCTAssertEqual(PropertyLabels.shutter("0.50"), "0.5s")
    }

    /// The menu keeps every distinct speed from 1 s down to 1/8, in order.
    func testTheMenuKeepsEverySubSecondSpeed() {
        let choices = ["1", "0.8", "0.7", "0.6", "0.5", "0.4", "0.3", "1/4", "1/5", "1/6", "1/8"]
        let labels = PropertyLabels.transform(choices: choices, forProperty: "shutterspeed").map(\.label)
        XCTAssertEqual(labels, ["1s", "0.8s", "0.7s", "0.6s", "0.5s", "0.4s", "0.3s",
                                "1/4", "1/5", "1/6", "1/8"])
    }

    func testFractionsAndLongerSpeedsAreUnchanged() {
        XCTAssertEqual(PropertyLabels.shutter("1/200"), "1/200")
        XCTAssertEqual(PropertyLabels.shutter("1/4"), "1/4")
        XCTAssertEqual(PropertyLabels.shutter("1"), "1s")
        XCTAssertEqual(PropertyLabels.shutter("2.5"), "2.5s")
        XCTAssertEqual(PropertyLabels.shutter("30"), "30s")
        XCTAssertEqual(PropertyLabels.shutter("bulb"), "Bulb")
        XCTAssertEqual(PropertyLabels.shutter("auto"), "Auto")
    }
}
