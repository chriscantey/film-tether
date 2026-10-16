import Foundation
import AppKit

/// Horizontal mirror applied to the live-view preview, on top of
/// `PreviewRotation`.
///
/// Like rotation, this is a *display* transform only: nothing is written to
/// the camera and captured files are never re-encoded. The use case is film on
/// the copy stand emulsion-side-up: the preview reads mirrored (text
/// backwards), and flipping it here beats flipping the film and re-focusing.
///
/// Order of transforms, fixed by convention: rotate first, then mirror, both
/// in display space. The user-visible meaning of the toggle is "flip what I
/// am currently looking at left-to-right", regardless of rotation. A vertical
/// flip needs no separate control: mirror plus 180° rotation is the vertical
/// flip, so the existing rotate buttons complete the set (the four rotations
/// times mirror on/off reach all eight orientations of a frame).
///
/// Same structural rule as `PreviewRotation`: everything upstream of the final
/// blit stays in unrotated, unmirrored sensor space, which keeps the zoom
/// calibration valid with the mirror on.
public enum PreviewMirror {

    // MARK: - Point mapping (display space, y-down normalized [0,1]²)

    /// Undo the mirror on a click in the displayed frame, yielding the point
    /// in the rotated-but-unmirrored display space that `PreviewRotation`'s
    /// inverse mapping expects. A horizontal mirror is its own inverse.
    public static func unmirror(_ p: CGPoint, mirrored: Bool) -> CGPoint {
        mirrored ? CGPoint(x: 1 - p.x, y: p.y) : p
    }

    /// Undo the mirror on a *direction* the user expressed on screen (arrow
    /// keys): the linear part of `unmirror`, translation dropped.
    public static func unmirror(_ d: CGVector, mirrored: Bool) -> CGVector {
        mirrored ? CGVector(dx: -d.dx, dy: d.dy) : d
    }

    /// Mirror an axis-aligned rectangle in display space. Its own inverse,
    /// like the point mapping: x' = 1 − (x + w).
    public static func mirrorRect(_ r: CGRect, mirrored: Bool) -> CGRect {
        mirrored ? CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height) : r
    }

    // MARK: - Image flip

    /// Flip a composed (already-rotated) preview frame for display. Returns
    /// the input untouched when `mirrored` is false (the common case) and on
    /// any decode failure, so a bad frame degrades to an unmirrored preview
    /// rather than a black pane. Mirrors `PreviewRotation.rotate`'s shape.
    public static func apply(_ image: NSImage, mirrored: Bool) -> NSImage {
        guard mirrored else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        guard let flipped = flip(cg) else { return image }
        return NSImage(cgImage: flipped, size: NSSize(width: flipped.width, height: flipped.height))
    }

    /// Bitmap flip. Kept separate from the `NSImage` wrapper so tests can
    /// assert pixel placement directly, same split as `PreviewRotation`.
    /// Color space forced to device RGB for the same reason documented there,
    /// and safe for the same reason: these pixels are only displayed.
    public static func flip(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
