import XCTest
import CoreGraphics
@testable import Scan

final class PreviewMirrorTests: XCTestCase {

    // MARK: - Point mapping

    func testUnmirrorIsIdentityWhenOff() {
        let p = CGPoint(x: 0.3, y: 0.8)
        XCTAssertEqual(PreviewMirror.unmirror(p, mirrored: false), p)
        let d = CGVector(dx: 0.1, dy: -0.2)
        XCTAssertEqual(PreviewMirror.unmirror(d, mirrored: false).dx, d.dx)
        XCTAssertEqual(PreviewMirror.unmirror(d, mirrored: false).dy, d.dy)
    }

    func testUnmirrorReflectsXOnly() {
        let p = PreviewMirror.unmirror(CGPoint(x: 0.3, y: 0.8), mirrored: true)
        XCTAssertEqual(p.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.8, accuracy: 1e-9)
    }

    func testUnmirrorIsItsOwnInverse() {
        let p = CGPoint(x: 0.25, y: 0.6)
        let twice = PreviewMirror.unmirror(PreviewMirror.unmirror(p, mirrored: true), mirrored: true)
        XCTAssertEqual(twice.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(twice.y, p.y, accuracy: 1e-9)
    }

    func testDeltaNegatesXKeepsY() {
        let d = PreviewMirror.unmirror(CGVector(dx: 0.1, dy: -0.2), mirrored: true)
        XCTAssertEqual(d.dx, -0.1, accuracy: 1e-9)
        XCTAssertEqual(d.dy, -0.2, accuracy: 1e-9)
    }

    /// A display point run through unmirror and the inverse rotation, then
    /// mapped forward again, lands where it started at every rotation.
    func testDisplayRoundTripAtEveryRotationWithMirrorOn() {
        let display = CGPoint(x: 0.2, y: 0.7)
        for r in PreviewRotation.allCases {
            let sensor = r.sensorPoint(fromDisplay: PreviewMirror.unmirror(display, mirrored: true))
            let back = PreviewMirror.unmirror(r.displayPoint(fromSensor: sensor), mirrored: true)
            XCTAssertEqual(back.x, display.x, accuracy: 1e-9, "rotation \(r)")
            XCTAssertEqual(back.y, display.y, accuracy: 1e-9, "rotation \(r)")
        }
    }

    func testMirrorRectReflectsAndRoundTrips() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let m = PreviewMirror.mirrorRect(r, mirrored: true)
        XCTAssertEqual(m.minX, 0.6, accuracy: 1e-9)   // 1 − (0.1 + 0.3)
        XCTAssertEqual(m.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(m.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(m.height, 0.4, accuracy: 1e-9)
        let back = PreviewMirror.mirrorRect(m, mirrored: true)
        XCTAssertEqual(back.minX, r.minX, accuracy: 1e-9)
        XCTAssertEqual(PreviewMirror.mirrorRect(r, mirrored: false), r)
    }

    // MARK: - Pixel placement

    /// 2x1 image, left pixel red, right pixel blue → flipped puts blue left.
    func testFlipMovesLeftPixelRight() throws {
        let ctx = CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let src = ctx.makeImage()!

        let flipped = try XCTUnwrap(PreviewMirror.flip(src))
        XCTAssertEqual(flipped.width, 2)
        XCTAssertEqual(flipped.height, 1)

        let out = CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        out.draw(flipped, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let bytes = out.data!.assumingMemoryBound(to: UInt8.self)
        // byteOrder32Little + noneSkipFirst → memory order B,G,R,X per pixel.
        XCTAssertGreaterThan(bytes[0], 200, "left pixel should now be blue")
        XCTAssertLessThan(bytes[2], 50, "left pixel red channel should be empty")
        XCTAssertGreaterThan(bytes[6], 200, "right pixel should now be red")
        XCTAssertLessThan(bytes[4], 50, "right pixel blue channel should be empty")
    }

    /// Mirror + 180° rotation is the vertical flip: the display point that was
    /// at the top ends up at the bottom, x unchanged. This is why no separate
    /// vertical-flip control exists.
    func testMirrorPlus180IsVerticalFlip() {
        // Forward transform of a sensor point: rotate 180, then mirror.
        let sensor = CGPoint(x: 0.2, y: 0.1)
        let display = PreviewMirror.unmirror(
            PreviewRotation.cw180.displayPoint(fromSensor: sensor), mirrored: true)
        XCTAssertEqual(display.x, sensor.x, accuracy: 1e-9)
        XCTAssertEqual(display.y, 1 - sensor.y, accuracy: 1e-9)
    }
}
