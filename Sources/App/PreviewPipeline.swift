import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Scan

/// The host-side Core Image pass over each live-view frame: white balance,
/// invert, monochrome, focus peaking, and straightening.
///
/// Separate JPEG-to-JPEG steps would each decode and re-encode the frame, a
/// decode per stage at 30 fps plus JPEG round-trips that also throw away
/// quality. Here the frame is decoded once, all requested stages run as one
/// Core Image graph, and one bitmap comes out.
enum PreviewPipeline {

    /// Focus-peaking settings, bundled so `render` takes one optional rather
    /// than three correlated parameters plus an enabled flag.
    struct Peaking {
        var mode: FocusPeaking.Mode
        var intensity: Float
        var color: FocusPeaking.PeakColor
    }

    /// Color management is disabled (`workingColorSpace` of null), so filters
    /// operate directly on the frame's encoded values.
    ///
    /// This is what makes click-to-set white balance land neutral in one click.
    /// `PixelSampler` reads gamma-encoded sRGB bytes to compute the gains. If
    /// Core Image then applied those gains in linear space, a gain of k would
    /// act like k^(1/2.2), roughly half the correction asked for, leaving a
    /// visible residual cast that no amount of re-clicking would converge away.
    /// Sampling and applying have to agree on the space, and encoded is the one
    /// we can read cheaply.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull(),
    ])

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// Render a frame with the requested adjustments.
    ///
    /// `straightenDegrees` turns the picture clockwise about its own center,
    /// the crop box's rotate band driving it. It is a stage of this graph
    /// rather than a pass after it: see the note on the stage itself, and on
    /// `FineRotation`.
    ///
    /// Returns nil when there is nothing to do (no adjustments, no peaking, no
    /// straightening), so the caller can hand the untouched JPEG straight to
    /// `NSImage` and skip Core Image entirely. That's the common case and it
    /// should cost nothing. Also returns nil if decoding or rendering fails,
    /// which the caller treats the same way: show the unmodified frame rather
    /// than a black pane.
    static func render(
        jpeg: Data,
        adjustments: PreviewAdjustments,
        peaking: Peaking?,
        straightenDegrees: Double = 0
    ) -> NSImage? {
        guard hasWork(adjustments, peaking, straightenDegrees) else { return nil }
        guard let decoded = CIImage(data: jpeg) else { return nil }
        return renderStages(from: decoded, adjustments: adjustments,
                            peaking: peaking, straightenDegrees: straightenDegrees)
    }

    /// Whether the graph has anything to do. `render` and `renderTapped` both
    /// check it, and when it is false they return nil and the caller shows
    /// the raw JPEG.
    static func hasWork(
        _ adjustments: PreviewAdjustments,
        _ peaking: Peaking?,
        _ straightenDegrees: Double
    ) -> Bool {
        !adjustments.isIdentity || peaking != nil
            || !FineRotation.isNegligible(straightenDegrees)
    }

    /// Straighten a decoded frame and hand back a bitmap, for the crop
    /// detector.
    ///
    /// Detection runs on the frame the camera sent, with every display
    /// correction skipped: inversion, monochrome and white-balance gains are
    /// the operator's view of the film, not the film. Straightening is the one
    /// exception, because the crop it is about to produce is an axis-aligned
    /// rectangle in the straightened frame. Detecting in the unstraightened
    /// one would hand back the bounding box of a tilted negative, which is
    /// larger than the negative and full of rebate.
    static func straightenedBitmap(jpeg: Data, straightenDegrees: Double) -> CGImage? {
        guard let decoded = CIImage(data: jpeg) else { return nil }
        let extent = decoded.extent
        guard !FineRotation.isNegligible(straightenDegrees) else {
            return context.createCGImage(decoded, from: extent,
                                         format: .RGBA8, colorSpace: outputColorSpace)
        }
        let turned = straighten(decoded, byDegrees: straightenDegrees, within: extent)
        return context.createCGImage(turned, from: extent,
                                     format: .RGBA8, colorSpace: outputColorSpace)
    }

    /// `render` plus an optional histogram tap, sharing one decode and one
    /// CIContext for both outputs.
    ///
    /// The histogram is computed from the unadjusted decoded frame, before
    /// white balance, inversion, or monochrome, because it's an exposure aid
    /// for the capture: it must report what the sensor is being asked to
    /// record, not what the corrected preview looks like. The
    /// eyedropper samples the same way. It also bins the frame's encoded
    /// gamma values, this context's working space, which is the same convention
    /// as the camera's own histogram.
    static func renderTapped(
        jpeg: Data,
        adjustments: PreviewAdjustments,
        peaking: Peaking?,
        computeHistogram: Bool,
        straightenDegrees: Double = 0
    ) -> (image: NSImage?, histogram: HistogramData?) {
        guard computeHistogram else {
            return (render(jpeg: jpeg, adjustments: adjustments, peaking: peaking,
                           straightenDegrees: straightenDegrees), nil)
        }
        guard let decoded = CIImage(data: jpeg) else { return (nil, nil) }
        let hist = HistogramCompute.compute(image: decoded, context: context)
        // The display render still short-circuits to nil when there's nothing
        // to apply, and the caller hands the raw JPEG straight to NSImage,
        // which is cheaper than a passthrough CI render.
        let image = hasWork(adjustments, peaking, straightenDegrees)
            ? renderStages(from: decoded, adjustments: adjustments,
                           peaking: peaking, straightenDegrees: straightenDegrees)
            : nil
        return (image, hist)
    }

    private static func renderStages(
        from decoded: CIImage,
        adjustments: PreviewAdjustments,
        peaking: Peaking?,
        straightenDegrees: Double
    ) -> NSImage? {
        var image = decoded
        let extent = image.extent

        // 1. White balance. Correct the illuminant before anything else looks
        //    at color, so peaking and monochrome both see corrected pixels.
        if let gains = adjustments.whiteBalance, !gains.isIdentity {
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            m.rVector = CIVector(x: CGFloat(gains.red), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(gains.green), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains.blue), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            guard let out = m.outputImage else { return nil }
            image = out
        }

        // 2. Invert, turning a negative into the positive it will become.
        //    After white balance on purpose: the film base cast belongs to the
        //    negative, so it's neutralized there and the result is inverted.
        //    This runs in the same unmanaged space as everything else, so
        //    it's a plain 1−c on encoded values, matching what you'd get from
        //    an invert in any image editor.
        if adjustments.invert {
            let f = CIFilter.colorInvert()
            f.inputImage = image
            guard let out = f.outputImage else { return nil }
            image = out
        }

        // 3. Monochrome, after white balance. Order against invert doesn't
        //    matter: desaturation is linear, so luma(1−c) == 1−luma(c).
        if adjustments.monochrome {
            let c = CIFilter.colorControls()
            c.inputImage = image
            c.saturation = 0
            guard let out = c.outputImage else { return nil }
            image = out
        }

        // 4. Peaking, after the color stages, so its highlights sit on top and
        //    keep their color even when the frame has been desaturated or
        //    inverted.
        if let peaking {
            if let out = FocusPeaking.overlay(
                on: image,
                mode: peaking.mode,
                intensity: peaking.intensity,
                color: peaking.color
            ) {
                image = out
            }
        }

        // 5. Straightening, last, because it is the only stage that moves a
        //    pixel somewhere else. Every stage above reads the pixel under a
        //    coordinate (peaking's gradient most of all), and running them on
        //    a resampled frame would have them analyzing interpolation.
        //
        //    Rotation composes with the quarter turn applied downstream in
        //    AppModel, so the order of those two doesn't matter. The crop box
        //    can therefore be edited on screen and stored in sensor space.
        if !FineRotation.isNegligible(straightenDegrees) {
            image = straighten(image, byDegrees: straightenDegrees, within: extent)
        }

        guard let cg = context.createCGImage(
            image, from: extent, format: .RGBA8, colorSpace: outputColorSpace
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Turn `image` about the center of `extent`, keeping `extent`'s dimensions.
    ///
    /// The frame does not grow to hold the rotated corners. They go out of
    /// view instead, and black comes in behind them. The crop sits well inside
    /// the negative, and a canvas that grew with the angle would slide the
    /// picture under a crop box that is trying to stay still.
    ///
    /// The turned frame is composited over black because rendering at `.RGBA8`
    /// leaves the swept corners transparent, and how a transparent preview
    /// pixel looks would then be up to the image view.
    ///
    /// Sign: Core Image's space is y-up, where a positive angle turns
    /// counter-clockwise, while `FineRotation`'s convention is clockwise on
    /// screen. Hence the negation. A wrong sign here tilts the picture the
    /// wrong way at the same rate, which a still preview does not show.
    private static func straighten(
        _ image: CIImage, byDegrees degrees: Double, within extent: CGRect
    ) -> CIImage {
        let radians = -CGFloat(degrees) * .pi / 180
        let c = CGPoint(x: extent.midX, y: extent.midY)
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: radians)
            .translatedBy(x: -c.x, y: -c.y)
        let turned = image.transformed(by: t)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        return turned.composited(over: black)
    }

    /// Average color under the eyedropper, for click-to-set white balance.
    ///
    /// Samples the unadjusted frame on purpose: sampling the corrected
    /// preview would compound corrections, so a second click on the same spot
    /// would drift instead of being a no-op.
    ///
    /// This stays right when invert is on: an armed pick shows the negative
    /// (`WhiteBalancePick.displayed`), so the user clicks the film base where
    /// it appears bright, and this reads that same original pixel, which is
    /// the value the gains must be derived from.
    ///
    /// `point` is normalized and y-down in the frame's own (unrotated) space.
    static func sampleColor(
        jpeg: Data,
        atNormalized point: CGPoint
    ) -> (red: Double, green: Double, blue: Double)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return PixelSampler.averageColor(in: cg, atNormalized: point)
    }
}
