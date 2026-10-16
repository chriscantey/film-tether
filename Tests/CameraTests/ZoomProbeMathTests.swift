import XCTest
import CoreGraphics
import ImageIO
@testable import Camera

final class ZoomProbeMathTests: XCTestCase {

    /// Synthesize a solid-gray JPEG of `value` luminance, 200x200.
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


    func testJPEGCropDownsizesCenter() {
        let g = gray(128)
        guard let cropped = JPEGCrop.cropAt(g, divisor: 5, center: CGPoint(x: 0.5, y: 0.5)) else {
            XCTFail("crop returned nil")
            return
        }
        // Byte count is no proxy for dimensions on tiny synthetic JPEGs (encoder
        // overhead dominates and a recompressed crop can be bigger than the
        // source). The 200x200 source cropped by 5 is 40x40, so the decoded
        // crop must come back strictly smaller than the source.
        XCTAssertGreaterThan(cropped.count, 0)
        let (w, h) = LiveView.parseJPEGDimensions(cropped)
        let (sw, sh) = LiveView.parseJPEGDimensions(g)
        XCTAssertTrue((w ?? 0) > 0 && (w ?? 0) < (sw ?? 0), "cropped width \(w ?? 0) vs source \(sw ?? 0)")
        XCTAssertTrue((h ?? 0) > 0 && (h ?? 0) < (sh ?? 0), "cropped height \(h ?? 0) vs source \(sh ?? 0)")
    }

    func testJPEGCropDivisor1ReturnsOriginal() {
        let g = gray(128)
        let unchanged = JPEGCrop.cropAt(g, divisor: 1, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(unchanged, g)
    }
}
