import XCTest
import CoreGraphics
@testable import Scan

/// Where the picture sits inside the pane. Small surface, but every crop-box
/// coordinate is derived from it, so a wrong letterbox is a crop that lands on
/// the wrong film.
final class PreviewViewportTests: XCTestCase {

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    /// A pane wider than the picture letterboxes left and right, and the
    /// picture is centered in what's left.
    func testAWidePaneLetterboxesSideways() {
        let r = PreviewViewport.fittedRect(aspect: 1.5, in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.height, 500, accuracy: 1e-6)
        XCTAssertEqual(r.width, 750, accuracy: 1e-6)
        XCTAssertEqual(r.minX, 125, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 0, accuracy: 1e-6)
    }

    func testATallPaneLetterboxesAboveAndBelow() {
        let r = PreviewViewport.fittedRect(aspect: 1.5, in: CGSize(width: 600, height: 800))
        XCTAssertEqual(r.width, 600, accuracy: 1e-6)
        XCTAssertEqual(r.height, 400, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 200, accuracy: 1e-6)
    }

    /// The letterbox is the room the crop box's rotate handles reach into, so a
    /// pane that exactly matches the picture leaves none. That is worth pinning,
    /// since it's the case where those handles are hardest to reach.
    func testAMatchingPaneLeavesNoLetterbox() {
        let r = PreviewViewport.fittedRect(aspect: 2, in: CGSize(width: 800, height: 400))
        assertRect(r, CGRect(x: 0, y: 0, width: 800, height: 400))
    }

    /// A quarter-turned preview is 2:3, and in a wide pane it letterboxes at
    /// the sides.
    func testAQuarterTurnedFrameLetterboxesSideways() {
        let r = PreviewViewport.fittedRect(aspect: 2.0 / 3.0, in: CGSize(width: 1200, height: 600))
        XCTAssertEqual(r.height, 600, accuracy: 1e-6)
        XCTAssertEqual(r.width, 400, accuracy: 1e-6)
        XCTAssertEqual(r.midX, 600, accuracy: 1e-6)
    }

    func testDegenerateFitFallsBackToTheWholePane() {
        let pane = CGSize(width: 300, height: 200)
        assertRect(PreviewViewport.fittedRect(aspect: 0, in: pane),
                   CGRect(origin: .zero, size: pane))
        assertRect(PreviewViewport.fittedRect(aspect: 1.5, in: .zero),
                   CGRect(origin: .zero, size: .zero))
    }
}
