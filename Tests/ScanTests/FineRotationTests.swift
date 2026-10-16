import XCTest
import CoreGraphics
@testable import Scan

/// Straightening's point mapping. This is what keeps the eyedropper and the
/// metering box pointing at the same film after the picture has been turned
/// under them, so a sign error here is a click that samples the wrong pixel
/// silently, by an amount too small to look like a bug.
final class FineRotationTests: XCTestCase {

    private func assertPoint(
        _ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y", file: file, line: line)
    }

    func testNegligibleAnglesAreLeftAlone() {
        XCTAssertTrue(FineRotation.isNegligible(0))
        XCTAssertTrue(FineRotation.isNegligible(0.009))
        XCTAssertFalse(FineRotation.isNegligible(0.02))
        let p = CGPoint(x: 0.2, y: 0.7)
        assertPoint(FineRotation.straightened(p, byDegrees: 0.001, aspect: 1.5), p)
    }

    func testTheCenterNeverMoves() {
        let c = CGPoint(x: 0.5, y: 0.5)
        assertPoint(FineRotation.straightened(c, byDegrees: 12, aspect: 1.5), c)
        assertPoint(FineRotation.unstraightened(c, byDegrees: 12, aspect: 1.5), c)
    }

    /// Positive degrees turn the picture clockwise on screen. In a y-down space
    /// that sends a point on the right-hand edge downward, not upward. This
    /// assertion pins the sign convention.
    func testAPositiveAngleTurnsThePictureClockwise() {
        let right = CGPoint(x: 1.0, y: 0.5)
        let turned = FineRotation.straightened(right, byDegrees: 90, aspect: 1)
        assertPoint(turned, CGPoint(x: 0.5, y: 1.0), accuracy: 1e-9)
    }

    /// The round trip is what the eyedropper relies on, and it must be exact.
    func testTheRoundTripLandsWhereItStarted() {
        for aspect in [1.0, 1.5, 2.0 / 3.0] as [CGFloat] {
            for degrees in [-45.0, -3.7, 0.5, 12.0, 45.0] {
                for p in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.8),
                          CGPoint(x: 0.5, y: 0.0), CGPoint(x: 0.0, y: 0.5)] {
                    let there = FineRotation.straightened(p, byDegrees: degrees, aspect: aspect)
                    let back = FineRotation.unstraightened(there, byDegrees: degrees, aspect: aspect)
                    assertPoint(back, p, accuracy: 1e-9)
                }
            }
        }
    }

    /// Normalized coordinates stretch x on a wide frame. Rotating without
    /// undoing that stretch is a shear, and a rotation by θ
    /// followed by one by −θ would still land back home while an intermediate
    /// point sat in the wrong place. So check a real distance instead: a point
    /// on the frame's center line, turned a quarter turn, must end up as far
    /// from the center as it started.
    func testAspectIsUndoneRatherThanSheared() {
        let aspect: CGFloat = 3.0 / 2.0
        let p = CGPoint(x: 0.9, y: 0.5)                       // 0.4 * 1.5 = 0.6 across
        let turned = FineRotation.straightened(p, byDegrees: 90, aspect: aspect)
        // A quarter turn puts it below the center, 0.6 away in the same
        // isotropic units, and y is not stretched, so that is 0.6 outright.
        assertPoint(turned, CGPoint(x: 0.5, y: 1.1), accuracy: 1e-9)
    }

    func testStraighteningIsClampedToTheBandsLimit() {
        XCTAssertEqual(FineRotation.clamped(400), FineRotation.limitDegrees)
        XCTAssertEqual(FineRotation.clamped(-400), -FineRotation.limitDegrees)
        XCTAssertEqual(FineRotation.clamped(-2.5), -2.5)
    }
}
