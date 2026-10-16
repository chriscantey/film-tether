import Foundation
import CoreGraphics

/// Geometry of the preview pane: where the picture sits inside the view it is
/// drawn in.
///
/// The crop box's rotate handles live in a band *outside* the box, so a crop
/// taken right up to the edge of the negative puts that band in the letterbox.
/// The overlay therefore covers the whole pane (an overlay clipped to the
/// picture never receives the pointer out there, and those handles would not
/// exist) and has to work out for itself where the picture is.
///
/// `fittedRect` was contributed by Alex Teslik.
public enum PreviewViewport {

    /// Where a frame of `aspect` (width ÷ height) sits inside a pane,
    /// letterboxed and centered.
    ///
    /// A degenerate aspect or an unlaid-out pane falls back to the whole pane,
    /// which keeps the caller's arithmetic finite.
    public static func fittedRect(aspect: CGFloat, in pane: CGSize) -> CGRect {
        guard aspect > 0, pane.width > 0, pane.height > 0 else {
            return CGRect(origin: .zero, size: pane)
        }
        if pane.width / pane.height > aspect {
            let w = pane.height * aspect
            return CGRect(x: (pane.width - w) / 2, y: 0, width: w, height: pane.height)
        }
        let h = pane.width / aspect
        return CGRect(x: 0, y: (pane.height - h) / 2, width: pane.width, height: h)
    }
}
