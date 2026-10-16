import Foundation
import CoreGraphics

/// Per-channel multipliers applied to the preview to neutralize a color cast.
///
/// For film scanning the cast being removed is usually the film base itself:
/// you click the unexposed leader and everything downstream is corrected
/// relative to it. Gains are the right representation (rather than a color
/// temperature) because a film base is off-neutral on *both* axes, and a
/// Kelvin-only control can slide along blue↔amber but cannot touch
/// green↔magenta at all. The app drives only the camera's white-balance mode
/// and Kelvin value, not its white-balance shift, so this correction lives on
/// the host.
public struct ChannelGains: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Gains are clamped to this range, so a near-black channel cannot divide
    /// out to an enormous multiplier.
    public static let minGain = 0.25
    public static let maxGain = 4.0

    /// A sample dimmer than this on every channel is treated as unusable.
    /// There isn't enough signal to say what its color is.
    public static let minUsableLevel = 0.02

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = ChannelGains(red: 1, green: 1, blue: 1)

    public var isIdentity: Bool { self == .identity }

    /// Gains that would render the sampled color neutral gray.
    ///
    /// The target is the sample's own mean level, so correcting preserves
    /// roughly the brightness you clicked on instead of darkening or blowing
    /// out the frame. Clicking a bright film base shouldn't also be an
    /// exposure change.
    ///
    /// Returns nil when the sample is too dark to carry reliable color, so the
    /// caller can tell the user to pick a brighter spot rather than silently
    /// applying a wild correction. Channels are expected in 0...1.
    public static func neutralizing(red r: Double, green g: Double, blue b: Double) -> ChannelGains? {
        guard r.isFinite, g.isFinite, b.isFinite else { return nil }
        guard max(r, max(g, b)) >= minUsableLevel else { return nil }
        let target = (r + g + b) / 3
        guard target > 0 else { return nil }
        return ChannelGains(
            red: clampGain(target / r),
            green: clampGain(target / g),
            blue: clampGain(target / b)
        )
    }

    /// Division by a zero or negative channel yields infinity or a nonsense
    /// sign. Both collapse to the ceiling, which is the most correction we're
    /// willing to apply in one click.
    private static func clampGain(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return maxGain }
        return min(max(v, minGain), maxGain)
    }
}

/// The eyedropper's raw film-base measurement (encoded sRGB, 0...1), kept
/// alongside the gains it produced. The gains alone can't reconstruct it,
/// because clamping is lossy, and a later tool that re-derives the correction
/// needs the measurement.
public struct BaseSample: Equatable, Codable, Sendable {
    /// Where on the frame the sample was taken: normalized [0,1]², y-down,
    /// in the same space as the crop (original orientation, after
    /// straightening). Film Positive re-measures the RAW at this point, so it
    /// is the one eyedropper value that crosses apps. The RGB below stays in
    /// Tether's own namespace.
    public struct Point: Equatable, Codable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public var red: Double
    public var green: Double
    public var blue: Double
    public var point: Point?

    public init(red: Double, green: Double, blue: Double, point: Point? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.point = point
    }
}

/// Host-side adjustments applied to the live preview before it's displayed.
///
/// These are *view* corrections: the camera is not reconfigured and captured
/// files are never re-encoded. With metadata writing on, they're recorded with
/// each capture so the same treatment can be replayed onto the RAW later (see
/// `MetadataWriter`).
public struct PreviewAdjustments: Equatable, Codable, Sendable {
    /// Render the preview as grayscale. Raw pixels off a black-and-white
    /// negative carry no meaningful color, so showing them in color is just
    /// noise to judge exposure and focus through.
    public var monochrome: Bool
    /// Invert tones, so a negative is previewed as the positive it will become.
    /// Judging framing, focus and exposure on the raw negative is guesswork.
    public var invert: Bool
    /// White-balance correction, or nil for as-shot.
    ///
    /// Applied *before* inversion, which is the order film scanning wants: the
    /// film base cast is a property of the negative, so it's neutralized on the
    /// negative and the result is then inverted.
    public var whiteBalance: ChannelGains?
    /// The raw measurement `whiteBalance` was derived from, or nil when the
    /// gains didn't come from the eyedropper. Not a display input. It is
    /// carried so the metadata writer can record it per capture.
    public var baseSample: BaseSample?

    public init(
        monochrome: Bool = false,
        invert: Bool = false,
        whiteBalance: ChannelGains? = nil,
        baseSample: BaseSample? = nil
    ) {
        self.monochrome = monochrome
        self.invert = invert
        self.whiteBalance = whiteBalance
        self.baseSample = baseSample
    }

    public static let none = PreviewAdjustments()

    /// True when nothing would change. The render path checks it, with peaking
    /// and straightening, to decide whether the frame needs any work. That
    /// matters at 30 fps: the common case is no adjustments at all.
    public var isIdentity: Bool {
        !monochrome && !invert && (whiteBalance == nil || whiteBalance == .identity)
    }
}
