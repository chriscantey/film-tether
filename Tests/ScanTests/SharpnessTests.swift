import XCTest
@testable import Scan

/// The sharpness score the app uses to confirm an autofocus run. These check
/// the arithmetic. The noise floor on real frames is what makes a score mean
/// anything, and that is measured on the body, not here.
final class SharpnessTests: XCTestCase {

    private func noise(_ w: Int, _ h: Int, seed: UInt64 = 7) -> [UInt8] {
        var s = seed
        return (0..<(w * h)).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: s >> 56)
        }
    }

    private func boxBlur(_ g: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var out = g
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var sum = 0
                for dy in -1...1 { for dx in -1...1 { sum += Int(g[(y + dy) * w + x + dx]) } }
                out[y * w + x] = UInt8(sum / 9)
            }
        }
        return out
    }

    func testAFlatFrameScoresZero() {
        XCTAssertEqual(Sharpness.laplacianVariance(gray: [UInt8](repeating: 128, count: 64 * 48),
                                                   width: 64, height: 48), 0)
    }

    func testBlurredScoresBelowSharp() throws {
        let sharp = noise(80, 60)
        let s = try XCTUnwrap(Sharpness.laplacianVariance(gray: sharp, width: 80, height: 60))
        let b = try XCTUnwrap(Sharpness.laplacianVariance(gray: boxBlur(sharp, 80, 60), width: 80, height: 60))
        XCTAssertLessThan(b, s)
    }

    func testRoiScoresOnlyTheCenter() throws {
        // Detail in the border only: the centered half sees a flat field.
        var g = [UInt8](repeating: 100, count: 100 * 100)
        let n = noise(100, 100)
        for y in 0..<100 { for x in 0..<100 where x < 20 || x >= 80 || y < 20 || y >= 80 { g[y * 100 + x] = n[y * 100 + x] } }
        XCTAssertGreaterThan(try XCTUnwrap(Sharpness.laplacianVariance(gray: g, width: 100, height: 100)), 0)
        XCTAssertEqual(Sharpness.laplacianVariance(gray: g, width: 100, height: 100, roi: 0.5), 0)
    }

    func testTooSmallOrShortInputIsNil() {
        XCTAssertNil(Sharpness.laplacianVariance(gray: [1, 2, 3, 4], width: 2, height: 2))
        XCTAssertNil(Sharpness.laplacianVariance(gray: [1, 2, 3], width: 4, height: 4))
    }

}
