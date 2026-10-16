import Foundation
import CoreGraphics

/// Straightening: a rotation of up to `limitDegrees` either way, applied on
/// top of the exact quarter turn.
///
/// Kept apart from `PreviewRotation` because the two are different
/// operations. A quarter turn moves pixels to new positions and loses nothing.
/// Any other angle has to resample, and every frame it's applied to is slightly
/// softer for it. Separating them means a preview that hasn't been straightened
/// never pays that cost.
///
/// This type carries no pixels. The rotation itself is an affine transform
/// inside `PreviewPipeline`'s Core Image graph, where it costs one more step on
/// a graph that is already running. What lives here is the arithmetic: the
/// threshold below which straightening is a no-op, and the point mapping that
/// overlays such as the metering box and the eyedropper use to keep pointing at
/// the same film after the picture has been turned.
///
/// Sign convention, used everywhere: positive degrees turn the picture
/// clockwise on screen.
public enum FineRotation {

    /// Angles smaller than this are treated as none. Guards the common case,
    /// an unstraightened preview, from paying for a resample that would change
    /// nothing.
    public static let negligibleDegrees = 0.01

    /// Largest straightening the crop box will apply. Beyond this the operator
    /// wants the quarter-turn button, not the rotate band.
    public static let limitDegrees = 45.0

    public static func isNegligible(_ degrees: Double) -> Bool {
        abs(degrees) < negligibleDegrees
    }

    public static func clamped(_ degrees: Double) -> Double {
        min(max(degrees, -limitDegrees), limitDegrees)
    }

    /// Where a normalized point of the un-straightened frame ends up once the
    /// frame has been straightened by `degrees`.
    ///
    /// `aspect` is the frame's width ÷ height. It matters because normalized
    /// coordinates stretch x on a frame wider than it is tall: rotating in that
    /// space without undoing the stretch is a shear, not a rotation, and every
    /// overlay positioned through it would drift off the film in a way that
    /// changes with the window's shape.
    public static func straightened(
        _ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat
    ) -> CGPoint {
        rotate(p, byDegrees: degrees, aspect: aspect)
    }

    /// Inverse of `straightened`: takes a point on the straightened picture
    /// back to the pixel of the frame the camera sent.
    ///
    /// This is the one the eyedropper and the metering box need. Both are
    /// defined against the raw frame (the eyedropper samples it, and the
    /// metering box names a sensor region the body will punch into), while the
    /// operator is clicking on a picture that has been turned under them.
    public static func unstraightened(
        _ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat
    ) -> CGPoint {
        rotate(p, byDegrees: -degrees, aspect: aspect)
    }

    /// Rotate about the frame's center, clockwise for a positive angle.
    ///
    /// The coordinate space is y-down, so the ordinary rotation matrix
    /// already turns clockwise on screen and no sign flip is needed here. The
    /// flip that does exist lives in `PreviewPipeline`, whose Core Image space
    /// is y-up.
    private static func rotate(
        _ p: CGPoint, byDegrees degrees: Double, aspect: CGFloat
    ) -> CGPoint {
        guard !isNegligible(degrees) else { return p }
        let a = max(aspect, 0.0001)
        let t = CGFloat(degrees) * .pi / 180
        let c = cos(t), s = sin(t)
        // Into a space where one unit means the same distance on both axes,
        // rotate, and back out again.
        let x = (p.x - 0.5) * a
        let y = p.y - 0.5
        return CGPoint(x: (x * c - y * s) / a + 0.5,
                       y: (x * s + y * c) + 0.5)
    }
}
