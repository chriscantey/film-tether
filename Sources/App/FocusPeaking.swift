import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Host-side focus peaking for the live-view stream.
///
/// Two modes are exposed:
///   • `.edges`, classic Sobel-style edge detection (CIEdges). Catches strong
///     boundaries (faces, building lines, leaves). Cheap and forgiving but
///     under-emphasizes film grain when scanning negatives.
///   • `.grain`, high-pass via a Gaussian-blur difference, tuned to 1-3 px
///     features so it picks up the grain that Edges under-emphasizes. Sharp
///     edges still give the strongest response (see `grainImage`).
///
/// Cost on an Intel Mac: edges ~10-25ms / grain ~15-30ms per 1056×704 frame.
/// Filters are created on each call. Core Image compiles and caches the
/// graph internally.
enum FocusPeaking {

    /// Eight high-contrast peaking colors. Cycle via Cmd-Shift-P. Bound to
    /// AppModel.focusPeakingColor and persisted via AppSettings.
    enum PeakColor: String, CaseIterable, Codable {
        case cyan
        case magenta
        case yellow
        case white
        case lime
        case hotPink   = "hot-pink"
        case azure     = "azure"
        case orange

        var displayName: String {
            switch self {
            case .cyan:     return "Cyan"
            case .magenta:  return "Magenta"
            case .yellow:   return "Yellow"
            case .white:    return "White"
            case .lime:     return "Lime"
            case .hotPink:  return "Hot pink"
            case .azure:    return "Azure"
            case .orange:   return "Orange"
            }
        }

        /// SwiftUI `Color`-style RGB tuple for the swatch fill (0..1).
        var swatchRGB: (r: Double, g: Double, b: Double) {
            switch self {
            case .cyan:     return (0,    1,    1)
            case .magenta:  return (1,    0,    1)
            case .yellow:   return (1,    1,    0)
            case .white:    return (1,    1,    1)
            case .lime:     return (0.5,  1,    0)
            case .hotPink:  return (1,    0.2,  0.6)
            case .azure:    return (0.1,  0.6,  1)
            case .orange:   return (1,    0.55, 0)
            }
        }

        /// (r, g, b) channel amplifications for ColorMatrix. Tuned so each
        /// color stays vivid even when composited over a bright preview.
        var amplifiers: (r: CGFloat, g: CGFloat, b: CGFloat) {
            switch self {
            case .cyan:     return (0, 4, 4)
            case .magenta:  return (4, 0, 4)
            case .yellow:   return (4, 4, 0)
            case .white:    return (4, 4, 4)
            case .lime:     return (1, 4, 0)
            case .hotPink:  return (4, 1, 2)
            case .azure:    return (0, 2, 4)
            case .orange:   return (4, 2, 0)
            }
        }
    }

    enum Mode: String, CaseIterable, Codable {
        /// CIEdges, Sobel-like operator. Good general-purpose.
        case edges
        /// Gaussian-blur difference, a high-pass tuned for 1-3 px features.
        case grain

        var displayName: String {
            switch self {
            case .edges: return "Edges (general)"
            case .grain: return "Grain (film scanning)"
            }
        }
    }

    /// Composite peaking highlights over `inputCI` and return the result.
    /// Returns nil if the filter graph fails, and the caller then shows the
    /// unpeaked frame rather than nothing.
    ///
    /// Works at the `CIImage` level rather than JPEG-to-JPEG so it can be one
    /// stage of `PreviewPipeline`, where the frame is decoded once for all the
    /// host-side adjustments together instead of once per effect.
    ///
    /// `intensity` controls sensitivity. 1.0 = obvious edges only, 3.0+
    /// picks up subtle texture (film grain, fine fabric, pixel-scale noise).
    ///
    /// `mode` defaults to `.edges` here. The app's own setting defaults to
    /// `.grain` (Settings → Live View), which is tuned conservatively (lower
    /// alpha multiplier) so it lights up grain instead of solid-tinting flat
    /// regions.
    static func overlay(
        on inputCI: CIImage,
        mode: Mode = .edges,
        intensity: Float = 3.0,
        color: PeakColor = .cyan
    ) -> CIImage? {
        let highFreq: CIImage?
        switch mode {
        case .edges: highFreq = edgesImage(inputCI, intensity: intensity)
        case .grain: highFreq = grainImage(inputCI, intensity: intensity)
        }
        guard let highFreq else { return nil }

        // Tint the high-frequency image, where bright = strong feature.
        // The aVector multiplier sets how aggressively weak features
        // bleed through. Edges produces hard near-binary output (Sobel
        // threshold is steep) so a high aVector (3,3,3) preserves
        // edge sharpness. Grain output is softer and noisier so it gets a
        // lower aVector to keep flat regions transparent.
        let amps = color.amplifiers
        let aGain: CGFloat = (mode == .grain) ? 1.0 : 3.0
        let tint = CIFilter.colorMatrix()
        tint.inputImage = highFreq
        tint.rVector = CIVector(x: amps.r, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: amps.g, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: amps.b, w: 0)
        tint.aVector = CIVector(x: aGain, y: aGain, z: aGain, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let tinted = tint.outputImage else { return nil }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = tinted
        composite.backgroundImage = inputCI
        return composite.outputImage?.cropped(to: inputCI.extent)
    }

    private static func edgesImage(_ input: CIImage, intensity: Float) -> CIImage? {
        let f = CIFilter.edges()
        f.inputImage = input
        f.intensity = intensity
        return f.outputImage
    }

    /// High-pass filter optimized for the spatial frequency of film grain
    /// (roughly 1-3 pixels in a 7D EVF preview at 1056×704).
    ///
    /// Pipeline:
    ///   1. Gaussian blur (radius 1.5) kills features < ~1-2 pixels.
    ///   2. `differenceBlendMode(input, blurred)` = |input - blurred|,
    ///      the magnitude of high-frequency residue. Flat regions → near 0,
    ///      grain peaks → moderate, sharp edges → strong.
    ///   3. Linear gain `intensity` via ColorMatrix multiplies the residue so
    ///      subtle grain rises above noise floor.
    ///
    /// There is no contrast or colorMonochrome step. CIColorControls at
    /// contrast 4.5 pushes everything to extremes (peaking shows an almost
    /// entirely white view instead of discrete points) because the
    /// post-difference residue is already small and noisy in the 7D LV preview.
    /// The pipeline relies on the downstream tint's alpha gain (kept low for
    /// `.grain` in `overlay(on:)`) to threshold weak residue into
    /// transparency, instead of trying to threshold here.
    private static func grainImage(_ input: CIImage, intensity: Float) -> CIImage? {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input
        blur.radius = 1.5
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return nil }

        // |input - blurred| via difference blend, not subtract. Subtract
        // returns max(0, A-B) and loses half the magnitude.
        let diff = CIFilter.differenceBlendMode()
        diff.inputImage = input
        diff.backgroundImage = blurred
        guard let residue = diff.outputImage else { return nil }

        // Multiply each channel by the intensity gain. With no bias, flat
        // regions stay near black and residue scales upward. Values past 1 are
        // clamped when the frame renders to an 8-bit bitmap. Weak residue gets
        // a low alpha from the tint in `overlay(on:)` and stays nearly
        // transparent.
        let gain = CGFloat(intensity)
        let amp = CIFilter.colorMatrix()
        amp.inputImage = residue
        amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        amp.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        amp.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        amp.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        amp.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return amp.outputImage
    }
}
