import XCTest
import CoreGraphics
@testable import Scan

/// A synthetic 35mm live-view frame, built as a `ColorGrid` because that is what
/// `PerforationFrame.detect` takes. Nothing in this file turns it into a `CGImage`, so a
/// failure here is a failure in the detector and not in a resampler.
///
/// **Where the geometry comes from.** Measured on real 1056x704 live-view frames of a
/// 35mm negative: holder mask at x < 28, x > 1040, y < 14, y > 702, sprocket
/// rows at y 14 to 50 and y 660 to 702, hole pitch roughly 95 to 120 px, picture roughly
/// x 70 to 988 and y 56 to 656. Those numbers are scaled here to the 512 px analysis width
/// the app samples at (`FrameRegion.analysisWidth`), a factor of 0.4848, which puts
/// the pitch at 55 px (113 px at the measured scale).
///
/// **Three deliberate departures from the literal scaled measurement**, each for its own
/// reason:
///
/// 1. Rounding. The bottom holder band is four rows (338 to 341) rather than the single row
///    that `y > 702` scales down to. A one-row band is a knife edge for the border-connected
///    outside mask and says nothing about the detector.
/// 2. The measurement itself. It has the top hole row abutting the mask (holes from y 14,
///    mask at y < 14). Here both hole rows (10 to 27 and 317 to 334) are inset from the
///    holder by three rows of rebate, and real film does carry rebate between its own edge
///    and the perforations. It matters here because `outsideMaskAny` seeds on both extremes,
///    so on the clipped Gold levels the holder (0.005) and the holes (1.000) are both in the
///    seed set. Touching, they flood into one region, the holes get masked out as "outside",
///    and the row is never found.
/// 3. The detector. The picture is rows 32 to 312, inside the scaled 27 to 318, so its top
///    and bottom edges sit clear of the two rows next to each hole row that `detect` skips.
///    Its columns, 42 to 463, also sit inside the scaled 34 to 479.
///
/// Only the picture gets texture. The rebate is left perfectly flat, which is both what
/// unexposed film looks like and what the gap-column test keys on.
enum PerfFixture {

    /// The three luminances that make a stock.
    struct Levels {
        let hole: Double
        let rebate: Double
        let picture: Double
    }

    /// Color negative, dense rebate, holes well clear of it. The easy case.
    static let vision3 = Levels(hole: 0.95, rebate: 0.61, picture: 0.50)

    /// Clipped at the top: the hole and the rebate are nearly the same value, and the band's
    /// own 95th percentile is pinned at 1.000. This is the stock the guard must not fire on,
    /// because a spread measured against a clipped p95 is not a spread.
    static let gold = Levels(hole: 1.00, rebate: 0.975, picture: 0.62)

    /// Black and white, developed thin. 0.65 is the band's p95, so the shipped fixed
    /// threshold lands above it and the mask comes out empty.
    static let aristaDark = Levels(hole: 0.65, rebate: 0.37, picture: 0.30)

    // MARK: - Geometry, in grid pixels

    static let width = 512
    static let height = 342

    /// The holder mask. Same value on every stock, because it is the holder and not the film.
    static let holderLevel = 0.005
    /// Columns 0 ..< holderLeft are mask.
    static let holderLeft = 14
    /// Columns holderRight ..< width are mask.
    static let holderRight = 505
    /// Rows 0 ..< holderTop are mask.
    static let holderTop = 7
    /// Rows holderBottom ..< height are mask.
    static let holderBottom = 338

    /// Inclusive row spans of the two perforation rows.
    static let topHoleRows = 10...27
    static let bottomHoleRows = 317...334

    static let holeCount = 9
    static let holePitch = 55
    static let holeFirstX = 20
    static let holeWidth = 32

    /// Inclusive picture bounds.
    static let pictureCols = 42...463
    static let pictureRows = 32...312

    /// Peak-to-peak texture on the picture. Large enough that the gradient bar and the
    /// polarity test have something real to measure, small enough that no picture pixel can
    /// reach any stock's rebate level.
    static let textureSpread = 0.08

    /// The inner edge of the top row.
    static var topRowInner: Double { Double(topHoleRows.upperBound + 1) }
    /// The inner edge of the bottom row.
    static var bottomRowInner: Double { Double(bottomHoleRows.lowerBound) }

    // MARK: - Building

    /// One fixture, parameterized by the three levels and by whether the perforations
    /// are there at all. Filled by writing into a flat array rather than through a per-pixel
    /// closure, so a release run of the whole file stays in the tens of milliseconds.
    static func grid(_ levels: Levels, holes: Bool = true, seed: UInt64 = 20_260_915) -> ColorGrid {
        var v = [Double](repeating: levels.rebate, count: width * height)

        for y in 0..<height {
            let row = y * width
            if y < holderTop || y >= holderBottom {
                for x in 0..<width { v[row + x] = holderLevel }
            } else {
                for x in 0..<holderLeft { v[row + x] = holderLevel }
                for x in holderRight..<width { v[row + x] = holderLevel }
            }
        }

        var rng = Rand(state: seed)
        for y in pictureRows {
            let row = y * width
            for x in pictureCols {
                v[row + x] = levels.picture + (rng.next() - 0.5) * textureSpread
            }
        }

        if holes {
            for band in [topHoleRows, bottomHoleRows] {
                for y in band {
                    let row = y * width
                    for i in 0..<holeCount {
                        let x0 = holeFirstX + i * holePitch
                        for x in x0..<(x0 + holeWidth) { v[row + x] = levels.hole }
                    }
                }
            }
        }

        var pixels: [ColorGrid.Pixel] = []
        pixels.reserveCapacity(v.count)
        for value in v {
            // Gray, so `Pixel.luminance` returns about the value back: the Rec. 709
            // coefficients sum to 1.
            let c = min(max(value, 0), 1)
            pixels.append(ColorGrid.Pixel(red: c, green: c, blue: c))
        }
        return ColorGrid(width: width, height: height, pixels: pixels)
    }
}

/// The perforation rung, on synthetic film.
///
/// Every test here passes the same grid on both arms, which is what `AutoCrop` does in the
/// field. `detect` consults the negative only for a row the dark pass failed to find, and
/// on this fixture the dark pass finds nothing (the only thing below its threshold is the
/// holder, and the holder is one component spanning the full width, which the blob filter
/// rejects).
final class PerforationFrameTests: XCTestCase {

    private var guardWasOn = true

    override func setUp() {
        super.setUp()
        guardWasOn = PerforationFrame.guardedBrightThreshold
    }

    override func tearDown() {
        // Restore unconditionally, so no test can decide another test's threshold.
        PerforationFrame.guardedBrightThreshold = guardWasOn
        super.tearDown()
    }

    private func detect(_ grid: ColorGrid) -> PerforationFrame.Result? {
        PerforationFrame.detect(in: grid, negative: grid, aspect: 1.5)
    }

    // MARK: - The ordinary case

    /// Vision3 levels. The box has to land between the two hole rows, be roughly 3:2, and be
    /// built on holes that were seen.
    func testFindsTheFrameOnAColorNegative() throws {
        let r = try XCTUnwrap(detect(PerfFixture.grid(PerfFixture.vision3)))

        let h = Double(PerfFixture.height)
        XCTAssertGreaterThan(Double(r.rect.minY), PerfFixture.topRowInner / h,
                             "frame top ran into the top sprocket row")
        XCTAssertLessThan(Double(r.rect.maxY), PerfFixture.bottomRowInner / h,
                          "frame bottom ran into the bottom sprocket row")

        let aspect = Double(r.rect.width) * Double(PerfFixture.width)
            / (Double(r.rect.height) * h)
        XCTAssertEqual(aspect, 1.5, accuracy: 0.15, "box is not the shape of a 35mm frame")
        // The shape the side edges wanted before the ratio was imposed. This is the number
        // that is evidence rather than assumption, so it is worth asserting separately.
        XCTAssertEqual(r.freeRatio, 1.5, accuracy: 0.15,
                       "unconstrained search did not want a 3:2 box")

        XCTAssertGreaterThanOrEqual(r.holesFound, 8, "too few perforations agreed on a row")
        XCTAssertFalse(r.touchesBorder)
    }

    // MARK: - The guard

    /// Without the guard, thin black and white is missed.
    ///
    /// On the Arista levels the top band reads med = 0.37 with p95 = 0.65, and 0.65 is the
    /// hole level itself. The shipped fixed threshold is med + 0.5 * (1 - med) = 0.685, which
    /// sits above the band's own p95, so the bright mask cannot admit a single pixel. Neither
    /// row is found, and with no rows there is no box.
    ///
    /// If this ever stops returning nil, check that 0.37 + 0.5 * 0.63 is still greater than
    /// the hole level before touching anything else.
    func testThinBlackAndWhiteIsMissedWithoutTheGuard() {
        PerforationFrame.guardedBrightThreshold = false
        XCTAssertNil(detect(PerfFixture.grid(PerfFixture.aristaDark)),
                     "the fixed bright threshold should have produced an empty mask")
    }

    /// The same frame, the same levels, the guard on. The threshold falls to the band's own
    /// spread, med + 0.35 * (p95 - med) = 0.468, and the holes at 0.65 clear it.
    func testTheGuardRecoversThinBlackAndWhite() throws {
        PerforationFrame.guardedBrightThreshold = true
        let r = try XCTUnwrap(detect(PerfFixture.grid(PerfFixture.aristaDark)),
                              "the guard did not recover the sprocket rows")
        XCTAssertGreaterThanOrEqual(r.holesFound, 8)
    }

    /// The stock the guard must leave alone.
    ///
    /// Gold's rebate reads 0.975 and its p95 is clipped at 1.000, so the fixed threshold
    /// (0.9875) is below the p95 and the guard's precondition never fires. With the
    /// precondition unmet, the guard on and off must give the same box. On this fixture any
    /// bright threshold between 0.975 and 1.000 makes the same mask, so equal boxes show the
    /// guard changed nothing visible here, not that the threshold is identical.
    func testTheGuardDoesNotTouchAClippedStock() throws {
        PerforationFrame.guardedBrightThreshold = true
        let on = try XCTUnwrap(detect(PerfFixture.grid(PerfFixture.gold)),
                               "no box on the clipped stock with the guard on")

        PerforationFrame.guardedBrightThreshold = false
        let off = try XCTUnwrap(detect(PerfFixture.grid(PerfFixture.gold)),
                                "no box on the clipped stock with the guard off")

        XCTAssertEqual(on.rect, off.rect, "the guard moved the threshold on a clipped stock")
        XCTAssertEqual(on.holesFound, off.holesFound)
    }

    // MARK: - Nothing to anchor on

    /// Same mask, same picture, no perforations anywhere. There is no periodic bright
    /// structure to cluster, so the rung has to decline rather than invent a row.
    ///
    /// The test runs with the guard on. With no holes the band's p95 equals its median, so
    /// the guarded threshold collapses onto the flat rebate level and the mask is empty. The
    /// unguarded threshold sits well above the rebate, so it would be empty too, but this
    /// test does not run that side.
    func testRefusesAFrameWithNoPerforations() {
        let flat = PerfFixture.grid(PerfFixture.vision3, holes: false)
        PerforationFrame.guardedBrightThreshold = true
        XCTAssertNil(detect(flat), "found a sprocket row in a field that has none")
    }
}
