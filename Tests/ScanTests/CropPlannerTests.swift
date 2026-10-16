import XCTest
import CoreGraphics
@testable import Scan

final class CropPlannerTests: XCTestCase {

    private let width = 240
    private let height = 156

    /// A strip of film running left to right: black holder above and below, a
    /// bright rebate between frames, and textured picture inside each frame.
    ///
    /// `frames` are along-strip spans in grid columns.
    private func makeStrip(
        frames: [Range<Int>],
        holderRows: Int = 18,
        /// Rows of rebate between the frame and the film's own edge. Without it
        /// the picture abuts the holder and a region grown from the center
        /// floods straight into it, which is a real geometry, but not the one
        /// these tests are about.
        frameInset: Int = 6,
        rebate: Double = 0.85,
        picture: Double = 0.35,
        holder: Double = 0.02,
        seed: UInt64 = 5
    ) -> ColorGrid {
        var rng = Rand(state: seed)
        // Smooth, photograph-like tone rather than blocks. Blocky texture makes
        // every block boundary a hard edge, and they line up into long straight
        // verticals running the frame's whole height, something no photograph
        // produces, and convincing enough to outvote the film's own edges. A sum
        // of a few waves has plenty of contrast and no straight edges at all.
        let phase = (0..<4).map { _ in rng.next() * 6.283 }
        func tone(_ x: Int, _ y: Int) -> Double {
            let fx = Double(x), fy = Double(y)
            return 0.5
                + 0.22 * sin(fx / 23 + phase[0]) * cos(fy / 31 + phase[1])
                + 0.16 * sin(fx / 11 + fy / 17 + phase[2])
                + 0.08 * cos(fx / 7 - fy / 9 + phase[3])
        }

        var pixels: [ColorGrid.Pixel] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v: Double
                if y < holderRows || y >= height - holderRows {
                    v = holder
                } else if frames.contains(where: { $0.contains(x) }),
                          y >= holderRows + frameInset,
                          y < height - holderRows - frameInset {
                    v = picture + (tone(x, y) - 0.5) * 0.60
                } else {
                    v = rebate
                }
                v = min(max(v, 0), 1)
                pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
            }
        }
        return ColorGrid(width: width, height: height, pixels: pixels)
    }

    private let square = FilmSize(id: 2, name: "120mm Rollei", widthMM: 56, heightMM: 56)
    private let threeByTwo = FilmSize(id: 8, name: "6x9", widthMM: 56, heightMM: 84)

    private func plan(_ grid: ColorGrid, _ expect: FilmSize?) -> CropPlanner.Plan? {
        CropPlanner.plan(in: grid, expecting: expect, around: CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - The holder

    func testCrossBoundsGiveTheAxisAndThePicturesExtent() throws {
        let grid = makeStrip(frames: [60..<180])
        let h = try XCTUnwrap(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(h.axis, .horizontal, "film runs along the unbounded axis")
        XCTAssertEqual(h.near, 24, accuracy: 3)
        XCTAssertEqual(h.far, height - 25, accuracy: 3)
    }

    /// The strip's direction must come from the holder, not from the frame's
    /// shape. A 6x6 frame is square, so its shape says nothing about the axis.
    func testASquareFrameStillResolvesTheAxis() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let h = try XCTUnwrap(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(h.axis, .horizontal)
    }

    func testNoCrossBoundsWhenNothingMasksTheFilm() {
        // Uniform texture everywhere: nothing that looks like a mask.
        var rng = Rand(state: 9)
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            let v = 0.4 + (rng.next() - 0.5) * 0.2
            pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        XCTAssertNil(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
    }

    // MARK: - Believing the detection

    /// A clean frame of the expected shape should come back from the detector
    /// itself, not from the fallback.
    func testACleanFrameOfTheExpectedShapeIsDetected() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertEqual(p.route, .detected)
        XCTAssertEqual(p.rect.width * Double(width) / (p.rect.height * Double(height)),
                       1.0, accuracy: 0.10)
    }

    /// A detection whose shape no expected frame could have must not be used.
    /// Measured on a real capture, the region detector returned a 1.60 aspect
    /// for a 120 negative.
    func testADetectionOfTheWrongShapeIsRejected() throws {
        // A frame far wider than tall, while a square one is expected.
        let grid = makeStrip(frames: [12..<228])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertNotEqual(p.route, .detected,
                          "a 2:1 detection was accepted for a square format")
    }

    /// When the planner takes a detection of a different format than the
    /// expected one, the box keeps the detected shape. The shape check runs
    /// only on the `.detected` route, so the test passes without it when the
    /// planner takes another route.
    func testABelievedDetectionOfADifferentFormatKeepsItsOwnShape() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        // Square frame in view, but 6x9 is expected. When the detection wins,
        // its box stays square rather than being forced into a 3:2 box.
        let p = try XCTUnwrap(plan(grid, threeByTwo))
        if p.route == .detected {
            let a = (p.rect.width * Double(width)) / (p.rect.height * Double(height))
            XCTAssertEqual(a, 1.0, accuracy: 0.15)
        }
    }

    func testWithNoExpectationTheDetectionIsUsed() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let p = try XCTUnwrap(plan(grid, nil))
        XCTAssertEqual(p.route, .detected)
        XCTAssertNil(p.size)
    }

    /// A region running off the picture is a lower bound on the frame. With no
    /// format to build from, it comes back as a rough box, not a detection.
    func testWithNoExpectationARegionRunningOffThePictureIsRough() throws {
        // One frame filling the whole strip, so the region touches both ends.
        let grid = makeStrip(frames: [0..<240])
        let p = try XCTUnwrap(plan(grid, nil))
        XCTAssertEqual(p.route, .rough)
        XCTAssertNil(p.size)
        XCTAssertGreaterThan(p.rect.width, 0)
        XCTAssertGreaterThan(p.rect.height, 0)
    }

    /// The same strip with a format set goes to the fallback, which is built
    /// from that format, never to the rough route.
    func testWithAFormatARegionRunningOffThePictureIsBuilt() throws {
        let grid = makeStrip(frames: [0..<240])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertTrue(p.route == .anchored || p.route == .centered, p.route.rawValue)
    }

    /// The ladder reports the rough box as unmeasured, so the app says the box
    /// is approximate and `FrameScale` learns nothing from it. A region inside
    /// the picture, with no format, is still a measurement.
    func testTheLadderDoesNotCountARegionRunningOffThePictureAsMeasured() throws {
        let rough = try XCTUnwrap(AutoCrop.chain(in: image(makeStrip(frames: [0..<240])), expecting: nil))
        XCTAssertFalse(rough.route.isMeasured, rough.route.rawValue)
        XCTAssertGreaterThan(rough.rect.width * rough.rect.height, 0)
        var scale = FrameScale()
        scale.learn(from: rough)
        XCTAssertEqual(scale.sampleCount, 0)

        let inside = try XCTUnwrap(AutoCrop.chain(
            in: image(makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])), expecting: nil))
        XCTAssertEqual(inside.route, .plannerDetected)
    }

    /// `grid` as an opaque sRGB picture, pixel for pixel. The grid is narrower
    /// than `FrameRegion.analysisWidth`, so `ColorGrid.sample` reads it back at
    /// its own size.
    private func image(_ grid: ColorGrid) throws -> CGImage {
        let w = grid.width, h = grid.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let px = try XCTUnwrap(ctx.data).bindMemory(to: UInt8.self, capacity: w * h * 4)
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        for y in 0..<h {
            for x in 0..<w {
                let p = grid[x, y]
                let i = (y * w + x) * 4
                px[i] = byte(p.red)
                px[i + 1] = byte(p.green)
                px[i + 2] = byte(p.blue)
                px[i + 3] = 255
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    // MARK: - The fallback

    /// When the detection is rejected, the crop is *built*: the expected format
    /// sets the shape, the holder sets the size.
    func testTheFallbackHasTheExpectedShape() throws {
        let grid = makeStrip(frames: [12..<228])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertNotEqual(p.route, .detected)
        let a = (p.rect.width * Double(width)) / (p.rect.height * Double(height))
        XCTAssertEqual(a, 1.0, accuracy: 0.05, "fallback is not the expected shape")
    }

    func testTheFallbackIsSizedToTheHolder() throws {
        let grid = makeStrip(frames: [12..<228], holderRows: 24)
        let p = try XCTUnwrap(plan(grid, square))
        // holderRows 24 either side, plus 6 rows of rebate: the picture spans
        // what's left.
        let pictureRows = Double(height - 2 * (24 + 6))
        XCTAssertEqual(p.rect.height * Double(height), pictureRows, accuracy: 6,
                       "height should be the picture's extent across the strip")
    }

    /// One side is pinned to a real edge, and the other follows from the format.
    func testTheFallbackAnchorsToANearbyEdge() throws {
        // A frame too wide to be believed as square, so the fallback runs, with
        // its right edge close enough for the built box to reach.
        let grid = makeStrip(frames: [24..<200])
        let p = try XCTUnwrap(plan(grid, square))
        guard p.route == .anchored else {
            return XCTFail("expected to anchor, got \(p.route.rawValue)")
        }
        let anchored = p.anchoredEdge
        XCTAssertTrue(anchored == .left || anchored == .right)
        let edgePx = anchored == .right ? p.rect.maxX * Double(width)
                                        : p.rect.minX * Double(width)
        XCTAssertEqual(edgePx, 200, accuracy: 12, "did not land on the frame's edge")
    }

    /// With no edge within reach, the fallback is centered rather than
    /// anchored.
    func testWithNoEdgeInReachTheFallbackIsCentered() throws {
        // One frame filling the whole strip: no inter-frame edge anywhere, so
        // there is nothing within reach to anchor to.
        let grid = makeStrip(frames: [0..<240])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertEqual(p.route, .centered)
        XCTAssertNil(p.anchoredEdge)
        XCTAssertEqual(p.rect.midX, 0.5, accuracy: 0.02)
    }

    /// With no format to build from and no detection, there's nothing to
    /// return.
    func testNoExpectationAndNoDetectionYieldsNothing() {
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            pixels.append(ColorGrid.Pixel(red: 0.5, green: 0.5, blue: 0.5))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        XCTAssertNil(plan(grid, nil))
    }

    /// The fallback needs the holder. Without it there's no size to build from.
    func testNoCrossBoundsMeansNoFallback() {
        var rng = Rand(state: 3)
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            let v = 0.4 + (rng.next() - 0.5) * 0.5
            pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        // Whatever comes back must not be a fallback built on nothing.
        if let p = plan(grid, square) {
            XCTAssertEqual(p.route, .detected)
        }
    }

    // MARK: - Which edge runs along the strip

    /// The fallback's size along and across the strip in grid pixels, on a strip
    /// whose single frame runs off both ends, so the detection touches the border
    /// and is always rejected. `sideways` turns the strip to run top to bottom.
    private func fallbackBox(_ size: FilmSize, sideways: Bool) throws
        -> (along: Double, across: Double, crossExtent: Double) {
        var grid = makeStrip(frames: [0..<width])
        if sideways { grid = AutoCrop.transposed(grid) }
        let center = CGPoint(x: 0.5, y: 0.5)
        let bounds = try XCTUnwrap(CropPlanner.crossBounds(in: grid, around: center))
        XCTAssertEqual(bounds.axis, sideways ? .vertical : .horizontal)
        let p = try XCTUnwrap(CropPlanner.plan(in: grid, expecting: size, around: center))
        XCTAssertNotEqual(p.route, .detected, "\(size.name): the detection was not rejected")
        let w = p.rect.width * Double(grid.width)
        let h = p.rect.height * Double(grid.height)
        return (along: sideways ? h : w, across: sideways ? w : h,
                crossExtent: Double(bounds.far - bounds.near + 1))
    }

    private func row(_ id: Int) throws -> FilmSize { try XCTUnwrap(FilmSize.resolve(id: id)) }

    /// The half frame and 6x4.5 run their long edge across the strip, so the
    /// built box is shorter along the strip than across it.
    func testTheFallbackBuildsHalfFrameAnd6x45ShortEdgeAlong() throws {
        for sideways in [false, true] {
            for (id, ratio) in [(12, 0.75), (13, 41.5 / 56)] {
                let size = try row(id)
                let box = try fallbackBox(size, sideways: sideways)
                XCTAssertEqual(box.across, box.crossExtent, accuracy: 1e-9, size.name)
                XCTAssertEqual(box.along, box.crossExtent * ratio, accuracy: 1e-9,
                               "\(size.name), sideways \(sideways)")
                XCTAssertLessThan(box.along, box.across, size.name)
            }
        }
    }

    /// Formats that run their long edge along the strip, and sheet film, are
    /// built at across times long over short.
    func testTheFallbackBuildsLongEdgeAlongFormatsLongOverShort() throws {
        // 35mm, 6x7, 6x9, 4x5 sheet.
        for sideways in [false, true] {
            for id in [4, 14, 8, 3] {
                let size = try row(id)
                let aspect = try XCTUnwrap(size.aspectRatio)
                let box = try fallbackBox(size, sideways: sideways)
                XCTAssertEqual(box.across, box.crossExtent, accuracy: 1e-9, size.name)
                XCTAssertEqual(box.along, box.crossExtent * aspect, accuracy: 1e-9,
                               "\(size.name), sideways \(sideways)")
            }
        }
    }

    // MARK: - The plan stays in the picture

    func testThePlanIsAlwaysInsideThePicture() throws {
        for frames in [[12..<228], [0..<120], [180..<240]] {
            let grid = makeStrip(frames: frames)
            let p = try XCTUnwrap(plan(grid, square))
            XCTAssertGreaterThanOrEqual(p.rect.minX, 0)
            XCTAssertGreaterThanOrEqual(p.rect.minY, 0)
            XCTAssertLessThanOrEqual(p.rect.maxX, 1.0001)
            XCTAssertLessThanOrEqual(p.rect.maxY, 1.0001)
        }
    }
}

