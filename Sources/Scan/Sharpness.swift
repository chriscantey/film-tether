import Foundation
import CoreGraphics
import ImageIO

/// Focus sharpness: the variance of the 4-neighbor Laplacian over an 8-bit
/// gray frame. The app compares a before and after score to confirm an
/// autofocus run (`AppAutofocus.verdict`). The camera does the focusing and
/// the score never steers the lens. It only decides whether a run counts as
/// confirmed.
///
/// A score only means something against its noise floor: the same frame at a
/// fixed focus scores differently from one live-view JPEG to the next, and a
/// change smaller than that spread is not a focus change.
public enum Sharpness {
    /// - Parameters:
    ///   - gray: row-major 8-bit luminance, `width * height` bytes.
    ///   - roi: fraction of each dimension kept, centered (1 = whole frame).
    ///     The punch-in frame is already the region that matters, so the
    ///     default is 1.
    /// - Returns: nil when the region is too small to have an interior.
    public static func laplacianVariance(gray: [UInt8], width: Int, height: Int,
                                         roi: Double = 1) -> Double? {
        guard width > 0, height > 0, gray.count >= width * height else { return nil }
        let f = min(max(roi, 0), 1)
        let rw = Int((Double(width) * f).rounded()), rh = Int((Double(height) * f).rounded())
        let x0 = (width - rw) / 2, y0 = (height - rh) / 2
        guard rw >= 3, rh >= 3 else { return nil }
        var sum = 0.0, sumSq = 0.0
        var n = 0
        gray.withUnsafeBufferPointer { p in
            for y in (y0 + 1)..<(y0 + rh - 1) {
                let row = y * width
                for x in (x0 + 1)..<(x0 + rw - 1) {
                    let c = Int(p[row + x])
                    let l = 4 * c - Int(p[row + x - 1]) - Int(p[row + x + 1])
                        - Int(p[row - width + x]) - Int(p[row + width + x])
                    let d = Double(l)
                    sum += d
                    sumSq += d * d
                    n += 1
                }
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / Double(n)
        return max(0, sumSq / Double(n) - mean * mean)
    }

    /// Decode a live-view JPEG to 8-bit gray, row-major, one byte per pixel.
    public static func grayPixels(jpeg: Data) -> (bytes: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ok = bytes.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    /// The score of one live-view JPEG, the number the app's AF check compares
    /// before and after a run.
    public static func score(jpeg: Data, roi: Double = 1) -> Double? {
        guard let g = grayPixels(jpeg: jpeg) else { return nil }
        return laplacianVariance(gray: g.bytes, width: g.w, height: g.h, roi: roi)
    }
}

