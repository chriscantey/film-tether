import XCTest
import CoreGraphics
import ImageIO
@testable import Camera

final class ZoomProbeMathTests: XCTestCase {

    /// Synthesize a solid-gray JPEG of `value` luminance, 200×200.
    private func gray(_ value: UInt8) -> Data {
        let size = 200
        let cs = CGColorSpaceCreateDeviceGray()
        var bytes = [UInt8](repeating: value, count: size * size)
        guard let ctx = CGContext(
            data: &bytes,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let img = ctx.makeImage() else {
            return Data()
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            return Data()
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testIdenticalFramesProduceZeroDiff() {
        let g = gray(128)
        let diff = LiveZoom.meanCenterPixelDifference(baseline: g, zoomed: g)
        // JPEG quantization can introduce tiny residuals even on identical frames; still < 1.
        XCTAssertLessThan(diff, 1.0)
    }

    func testDifferentFramesProduceLargeDiff() {
        let dark = gray(20)
        let bright = gray(220)
        let diff = LiveZoom.meanCenterPixelDifference(baseline: dark, zoomed: bright)
        // |220 - 20| = 200 in the limit; JPEG compression knocks it down but >> 8.
        XCTAssertGreaterThan(diff, 50.0)
    }

    func testJPEGCropDownsizesCenter() {
        let g = gray(128)
        guard let cropped = JPEGCrop.centerCrop(g, divisor: 5) else {
            XCTFail("crop returned nil")
            return
        }
        // Byte count is no proxy for dimensions on tiny synthetic JPEGs (encoder
        // overhead dominates and a recompressed crop can be BIGGER than the
        // source). Assert the decoded pixel dimensions instead: 128 / 5 ≈ 25.
        XCTAssertGreaterThan(cropped.count, 0)
        // (centerCrop clamps to a ~40px floor, so assert "strictly smaller
        // than the source frame," not an exact 128/5.)
        let (w, h) = LiveView.parseJPEGDimensions(cropped)
        let (sw, sh) = LiveView.parseJPEGDimensions(g)
        XCTAssertTrue((w ?? 0) > 0 && (w ?? 0) < (sw ?? 0), "cropped width \(w ?? 0) vs source \(sw ?? 0)")
        XCTAssertTrue((h ?? 0) > 0 && (h ?? 0) < (sh ?? 0), "cropped height \(h ?? 0) vs source \(sh ?? 0)")
    }

    func testJPEGCropDivisor1ReturnsOriginal() {
        let g = gray(128)
        let unchanged = JPEGCrop.centerCrop(g, divisor: 1)
        XCTAssertEqual(unchanged, g)
    }
}
