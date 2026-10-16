import XCTest
import CoreGraphics
@testable import Scan

/// The status line after Auto-Crop says what happened in plain words. The route case
/// names are internal and never reach the status line.
final class AutoCropNoticeTests: XCTestCase {

    private let all: [AutoCrop.Route] = [
        .plannerDetected, .frameFinderBounded, .perforationAnchored,
        .plannerAnchored, .frameFinderPartial, .coarse,
    ]

    /// House style for the status line: not the route's own case name, no em-dash, no semicolon.
    func testTheStatusLineCarriesNeitherItsRouteNameNorAnEmDashOrSemicolon() {
        for route in all {
            let line = AutoCrop.notice(for: route, pixelSize: CGSize(width: 5184, height: 3456))
            XCTAssertFalse(line.contains(route.rawValue), line)
            XCTAssertFalse(line.contains("\u{2014}"), line)
            XCTAssertFalse(line.contains(";"), line)
        }
    }

    func testMeasuredRungsSayWhatTheyFound() {
        XCTAssertEqual(AutoCrop.Route.plannerDetected.plainWords, "Found the frame edges")
        XCTAssertEqual(AutoCrop.Route.frameFinderBounded.plainWords, "Found the frame edges")
        XCTAssertEqual(AutoCrop.Route.perforationAnchored.plainWords, "Found the sprocket holes")
    }

    /// A rung that assumed or guessed tells the operator what to check. A measured one does not.
    func testOnlyTheUnmeasuredRungsAskForACheck() {
        for route in all {
            let asks = route.plainWords.contains("Check") || route.plainWords.contains("Adjust")
            XCTAssertEqual(asks, !route.isMeasured, "\(route.rawValue): \(route.plainWords)")
        }
    }

    func testTheSizeFollowsTheWordsInWholePixels() {
        XCTAssertEqual(AutoCrop.notice(for: .perforationAnchored,
                                       pixelSize: CGSize(width: 4210.4, height: 2807.6)),
                       "Found the sprocket holes. Crop 4210 × 2808")
    }

    /// No box size yet means no size at all, never "0 × 0".
    func testNoSizeMeansNoZeroByZero() {
        XCTAssertEqual(AutoCrop.notice(for: .plannerDetected, pixelSize: nil),
                       "Found the frame edges.")
        XCTAssertEqual(AutoCrop.notice(for: .coarse, pixelSize: .zero),
                       "No frame edges found, so this is a rough box. Adjust it by hand.")
    }
}
