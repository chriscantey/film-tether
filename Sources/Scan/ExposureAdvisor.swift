import Foundation
import CoreGraphics
import ImageIO

/// The per-frame exposure advisor. In manual with live view running, about
/// once a second, the app measures how much of the frame's center clips, and
/// when more than 1% does it shows one small glyph beside the shutter
/// control: "Highlights clip at 1/10, try 1/13", with the next faster shutter
/// taken from the camera's own choices. It never changes the setting on its
/// own: a double-click on the glyph applies the suggestion.
///
/// The clip rule: a pixel of the live-view JPEG counts as clipped when any channel is
/// at 254 or above, measured over the central 60% of the frame (20% margins),
/// so the rebate, the sprocket holes and the light box around the film do not
/// count. Hysteresis keeps the glyph from flickering on a frame that sits near
/// the line: it appears above 1% and goes only below 0.5%.
public enum ExposureAdvisor {
    public static let clipLevel: UInt8 = 254
    /// The share of each dimension measured, centered.
    public static let centralFraction = 0.6
    /// The glyph appears when more than this share of the center clips.
    public static let showAbove = 0.01
    /// Once shown, it goes only when the share falls below this.
    public static let hideBelow = 0.005

    /// Decode a live-view JPEG to 8-bit RGBA, row-major, four bytes a pixel.
    public static func rgbaPixels(jpeg: Data) -> (bytes: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { p -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h) : nil
    }

    /// The share of the central region's pixels with any of R, G, B at or
    /// above `clipLevel`. `rgba` is four bytes a pixel, alpha ignored.
    public static func clippedShare(rgba: [UInt8], width: Int, height: Int) -> Double {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return 0 }
        let mx = Int((Double(width) * (1 - centralFraction) / 2).rounded())
        let my = Int((Double(height) * (1 - centralFraction) / 2).rounded())
        let x0 = mx, x1 = max(mx + 1, width - mx), y0 = my, y1 = max(my + 1, height - my)
        var clipped = 0, total = 0
        for y in y0..<y1 {
            var i = (y * width + x0) * 4
            for _ in x0..<x1 {
                if rgba[i] >= clipLevel || rgba[i + 1] >= clipLevel || rgba[i + 2] >= clipLevel { clipped += 1 }
                total += 1
                i += 4
            }
        }
        return total > 0 ? Double(clipped) / Double(total) : 0
    }

    public static func clippedShare(jpeg: Data) -> Double? {
        guard let p = rgbaPixels(jpeg: jpeg) else { return nil }
        return clippedShare(rgba: p.bytes, width: p.w, height: p.h)
    }

    /// A shutter value as libgphoto2 names it, in seconds: "1/13", "0.3",
    /// "30". nil for "bulb", "auto" and anything else that is not a time.
    public static func seconds(_ shutter: String) -> Double? {
        let s = shutter.trimmingCharacters(in: .whitespaces)
        if let slash = s.firstIndex(of: "/") {
            guard let n = Double(s[..<slash]), let d = Double(s[s.index(after: slash)...]), n > 0, d > 0 else { return nil }
            return n / d
        }
        guard let v = Double(s), v > 0 else { return nil }
        return v
    }

    /// The camera's next faster shutter after `current`, from its own list,
    /// whatever order the list is in. nil at the fastest, or when `current`
    /// is not a time.
    public static func nextFaster(than current: String, choices: [String]) -> String? {
        guard let now = seconds(current) else { return nil }
        var best: (String, Double)?
        for c in choices {
            guard let t = seconds(c), t < now * 0.999 else { continue }
            if best == nil || t > best!.1 { best = (c, t) }
        }
        return best?.0
    }

    /// What the glyph says.
    public struct Advice: Equatable, Sendable {
        public let clippedShare: Double
        public let current: String
        public let suggestion: String?

        public var tooltip: String {
            if let suggestion { return "Highlights clip at \(current), try \(suggestion)" }
            return "Highlights clip at \(current)"
        }

        public var popover: String {
            let pct = String(format: "%.1f", clippedShare * 100)
            if let suggestion {
                return "\(pct)% of the center of the frame clips at \(current). The next faster shutter the camera offers is \(suggestion). Double-click the sun to set it."
            }
            return "\(pct)% of the center of the frame clips at \(current), and there is no faster shutter to suggest. Stop the lens down or dim the light."
        }

        /// What a double-click on the glyph sets. nil (a no-op) when
        /// there is nothing faster, or when the mode dial owns the shutter.
        public func shutterToApply(writable: Bool) -> String? {
            writable ? suggestion : nil
        }
    }

    public static func advice(clippedShare: Double, current: String, choices: [String]) -> Advice {
        Advice(clippedShare: clippedShare, current: current, suggestion: nextFaster(than: current, choices: choices))
    }

    /// Show above 1%, hide below 0.5%: one reading near the line cannot make
    /// the glyph blink.
    public struct Gate: Equatable, Sendable {
        public private(set) var showing = false
        public init() {}
        public mutating func update(share: Double) -> Bool {
            if showing { if share < ExposureAdvisor.hideBelow { showing = false } }
            else if share > ExposureAdvisor.showAbove { showing = true }
            return showing
        }
        public mutating func reset() { showing = false }
    }
}
