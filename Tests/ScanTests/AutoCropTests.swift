import XCTest
import CoreGraphics
@testable import Scan

/// The ladder's entry point, on the same synthetic film `PerforationFrameTests` uses.
///
/// `PerforationFrameTests` checks the rung finds a box. This checks the ladder hands that box
/// back, which is a separate claim: `AutoCrop.detect` resamples the picture, reads the
/// along-strip ratio out of the format's millimeters, applies its own guards on top of the
/// rung, and then runs the planner and frame-finder chain as a referee that may overrule it.
final class AutoCropTests: XCTestCase {

    private var perforationWasOn = true
    private var guardWasOn = true

    override func setUp() {
        super.setUp()
        perforationWasOn = AutoCrop.perforationEnabled
        guardWasOn = PerforationFrame.guardedBrightThreshold
        // Both are read from the environment once, so a run with FT_PERF=0 or FT_PERF_GUARD=0
        // set would otherwise test a different ladder than the one these assertions describe.
        AutoCrop.perforationEnabled = true
        PerforationFrame.guardedBrightThreshold = true
    }

    override func tearDown() {
        AutoCrop.perforationEnabled = perforationWasOn
        PerforationFrame.guardedBrightThreshold = guardWasOn
        super.tearDown()
    }

    // MARK: - Turning a grid back into a picture

    /// A `CGImage` carrying `grid` pixel for pixel.
    ///
    /// Written straight into the context's own buffer rather than filled rect by rect, which
    /// would be 175k drawing calls. Buffer row 0 is the top row of the image (the same
    /// convention `ColorGrid.sample` reads back out, and the one `PreviewRotationTests`
    /// documents), so no flip is needed here.
    ///
    /// The fixture is 512 wide, which is `FrameRegion.analysisWidth`, so `ColorGrid.sample`
    /// takes `min(512, 512)` and redraws it at its own size. That keeps the round trip a copy
    /// rather than a resample, and the only thing the grid loses on the way through is 8-bit
    /// quantization.
    private func image(from grid: ColorGrid) throws -> CGImage {
        let w = grid.width, h = grid.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let base = try XCTUnwrap(ctx.data)
        let px = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        for y in 0..<h {
            for x in 0..<w {
                let p = grid[x, y]
                let i = (y * w + x) * 4
                px[i] = byte(p.red)
                px[i + 1] = byte(p.green)
                px[i + 2] = byte(p.blue)
                // Opaque, so premultiplied and straight are the same bytes.
                px[i + 3] = 255
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func thirtyFiveMM() throws -> FilmSize {
        try XCTUnwrap(FilmSize.seedCatalog.first { $0.id == 4 })
    }

    // MARK: - The rung answers

    /// The same image on both arms, which is what the app does: this input is a negative, so
    /// its holes are brighter than its rebate and the bright pass is the one that fires.
    func testTheLadderTakesThePerforationRoute() throws {
        let cg = try image(from: PerfFixture.grid(PerfFixture.vision3))
        let size = try thirtyFiveMM()

        // The rung on its own first, so a failure says which half broke.
        let rung = try XCTUnwrap(AutoCrop.perforation(in: cg, expecting: size, negative: cg),
                                 "the perforation rung found nothing")
        XCTAssertEqual(rung.route, .perforationAnchored)

        let result = try XCTUnwrap(AutoCrop.detect(in: cg, expecting: size, negative: cg))
        // If this ever comes back as a chain route on a fixture the rung clearly measured,
        // the referee overruled, and the two boxes are worth printing before changing
        // anything.
        XCTAssertEqual(result.route, .perforationAnchored,
                       "the ladder did not keep the perforation box")
        XCTAssertTrue(result.route.isMeasured)
        XCTAssertTrue(result.isFullyBounded)
        XCTAssertEqual(result.rect, rung.rect)
    }

    // MARK: - Nothing to anchor on

    /// No perforations anywhere. The rung must decline, the ladder must fall through to the
    /// chain, and neither may crash on a picture that gives the sprocket search nothing.
    func testAFrameWithNoPerforationsFallsThroughToTheChain() throws {
        let cg = try image(from: PerfFixture.grid(PerfFixture.vision3, holes: false))
        let size = try thirtyFiveMM()

        XCTAssertNil(AutoCrop.perforation(in: cg, expecting: size, negative: cg),
                     "the rung claimed a box on a frame with no perforations")

        // The chain may or may not return a box here. It must not report the perforation route.
        if let result = AutoCrop.detect(in: cg, expecting: size, negative: cg) {
            XCTAssertNotEqual(result.route, .perforationAnchored,
                              "took the perforation route with no perforations in the picture")
        }
    }
}
