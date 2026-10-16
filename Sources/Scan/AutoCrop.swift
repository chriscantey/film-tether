import Foundation
import CoreGraphics

/// Which detector answered, and how far to believe it.
///
/// It lives in Scan, not beside the crop editor, so the rule the app uses can be tested
/// without the app.
public enum AutoCrop {

    /// Which of the six rungs produced a box. The first five are listed best first by their
    /// scores on 114 hand-cropped frames, decoded from raw at half size. The app crops
    /// live-view frames, and those score differently.
    public enum Route: String, Sendable {
        /// `CropPlanner` returned its sweep and `accept` passed it. 46 of 114, median aspect
        /// error 0.77%, area 1.058x the hand-kept crop.
        case plannerDetected
        /// `FrameFinder` closed a box on all four sides. 63 of 114 on its own, and 29 of those
        /// are frames the planner gives up on, so both are kept. 2.38% aspect error, area
        /// 1.048x.
        case frameFinderBounded
        /// `CropPlanner` disbelieved the sweep and built the box from the expected format,
        /// sliding it onto one detected edge when one is close enough. The shape is right
        /// because it was built to be, so its shape score says nothing. Area runs 1.243x,
        /// noticeably loose.
        case plannerAnchored
        /// `FrameFinder` found edges but could not close the box, a strip running off the
        /// picture. A real measurement of the sides it did find.
        case frameFinderPartial
        /// A rough box, the last resort. `CropPlanner`'s rough region when it has one, a
        /// sweep that ran off the picture with no format to build from. Otherwise
        /// `CropDetector`, a box around everything that is not background, and wrong
        /// whenever more than one frame is in view.
        case coarse
        /// `PerforationFrame` anchored the box on the film's own sprocket holes. It runs ahead
        /// of the other rungs and has no per-route score of its own, so it is listed last
        /// rather than ranked.
        ///
        /// It counts as a measurement although the format's ratio bounds its width.
        /// `plannerAnchored` assumes the whole box and slides it until one side touches
        /// something. This rung measures the top and bottom edges against the perforations,
        /// scores both side edges by their own gradient and polarity, and uses the ratio to
        /// choose among nearby widths. A side with no edge evidence is closed by the ratio at
        /// half weight.
        case perforationAnchored

        /// The box came from the film rather than from a shape we assumed.
        public var isMeasured: Bool {
            self == .plannerDetected || self == .frameFinderBounded || self == .perforationAnchored
        }

        /// What the status line says about this rung. The case names are internal and mean
        /// nothing to a user, so the notice never prints `rawValue`.
        public var plainWords: String {
            switch self {
            case .plannerDetected, .frameFinderBounded: return "Found the frame edges"
            case .perforationAnchored: return "Found the sprocket holes"
            case .plannerAnchored: return "Built from the film size. Check the edges"
            case .frameFinderPartial: return "Found some of the frame edges. Check the rest"
            case .coarse: return "No frame edges found, so this is a rough box. Adjust it by hand"
            }
        }
    }

    public struct Result: Sendable {
        public let route: Route
        public let rect: CGRect
        /// Rotation the planner measured, degrees clockwise, zero on every other rung.
        /// Carried and deliberately not applied: straighten is the user's own control, and
        /// autocrop never turns the picture as a side effect.
        public let angle: Double
        /// The `expecting` format passed in, echoed back on `perforationAnchored` and on
        /// `plannerDetected` when the planner built on one, and nil on the other routes. It
        /// is not a measured format.
        public let size: FilmSize?
        /// Sides the route reports as unmeasured: on `frameFinderPartial` and on `coarse`
        /// from `CropDetector` where the film ran past what the camera could see, on `coarse`
        /// from `CropPlanner` every side, and on `plannerAnchored` every side except the
        /// pinned one. The other routes report none.
        public let unboundedEdges: Set<CropDetector.Edge>

        public var isFullyBounded: Bool { unboundedEdges.isEmpty }

        public init(route: Route, rect: CGRect, angle: Double, size: FilmSize?,
                    unboundedEdges: Set<CropDetector.Edge>) {
            self.route = route; self.rect = rect; self.angle = angle
            self.size = size; self.unboundedEdges = unboundedEdges
        }
    }

    /// The line the status bar shows after Auto-Crop: the rung in plain words, then the box
    /// size in pixels when there is one. No size means no "0 × 0".
    public static func notice(for route: Route, pixelSize: CGSize?) -> String {
        guard let px = pixelSize, px.width >= 1, px.height >= 1 else { return route.plainWords + "." }
        return String(format: "%@. Crop %.0f × %.0f", route.plainWords, px.width, px.height)
    }

    /// Run the perforation rung ahead of everything else. On by default. Scored against 114
    /// hand-kept crops on half-size raw decodes, separately from the route figures above:
    /// with the rung the chain measures 109 frames instead of 79, calibrated area error
    /// 5.65% to 5.01%, Vision3 18.3% to 4.9%, Arista 17.8% to 5.5%. Live-view frames score
    /// differently.
    public static var perforationEnabled = true

    /// When the perforation rung and the chain both measure a frame, the chain's box passes
    /// `plausibleFrame`, and the two boxes overlap less than this, the chain's box is kept.
    /// The rung was tested on one copy stand, one holder and one format, so a referee that
    /// needs no ground truth is what catches a confidently wrong box on another setup. Only
    /// measured chain routes referee: an anchored or coarse box is a guess and cannot outvote
    /// a measurement.
    public static var refereeMinOverlap = 0.5

    /// What `perforationProbe` returns.
    public struct PerforationProbe: Sendable {
        public let found: PerforationFrame.Result
        public let sideways: Bool
        public let want: Double
        public let gridWidth: Int
        public let gridHeight: Int
    }

    /// The rung up to and including `PerforationFrame.detect`, with none of the guards after
    /// it. `perforation` calls this and then applies its guards, so the two cannot drift.
    public static func perforationProbe(in frame: CGImage, expecting: FilmSize?,
                                        negative: CGImage? = nil) -> PerforationProbe? {
        guard var grid = ColorGrid.sample(frame, width: FrameRegion.analysisWidth) else { return nil }
        var negativeGrid = negative.flatMap { ColorGrid.sample($0, width: FrameRegion.analysisWidth) }
        let want = perforationWant(expecting: expecting)
        // The half-frame preset is the gate for the mat path and for the sideways case: a
        // half frame is shown upright, so the strip may arrive turned through a quarter and
        // the hole rows then run down the sides. Detect on the transposed grids and turn the
        // box back. Neither runs unless that preset is selected.
        let half = expecting?.name.lowercased().contains("half") ?? false
        let sideways = half && grid.height > grid.width
        if sideways {
            grid = transposed(grid)
            negativeGrid = negativeGrid.map(transposed)
        }
        guard let found = PerforationFrame.detect(in: grid, negative: negativeGrid,
                                                  aspect: want, mat: half)
        else { return nil }
        return PerforationProbe(found: found, sideways: sideways, want: want,
                                gridWidth: grid.width, gridHeight: grid.height)
    }

    /// The ratio the perforation rung builds its box to. The rung measures the height across
    /// the strip, between the hole rows, and builds the width along it, so for 35mm it needs
    /// along over across: 36/24 for a full frame, 18/24 for a half frame, read through
    /// `FilmSize.alongOverAcross`. Sprocket holes are a 35mm feature, so any other format
    /// gets its long over short ratio, and no format at all gets 1.5.
    static func perforationWant(expecting: FilmSize?) -> Double {
        if let e = expecting, e.stripAcrossMM == 24, let r = e.alongOverAcross { return r }
        return expecting?.aspectRatio ?? 1.5
    }

    /// The perforation rung on its own, guards included. `detect` runs it first.
    public static func perforation(in frame: CGImage, expecting: FilmSize?,
                                   negative: CGImage? = nil) -> Result? {
        guard let probe = perforationProbe(in: frame, expecting: expecting, negative: negative)
        else { return nil }
        let found = probe.found
        let want = probe.want
        // A box that ran off the picture is a lower bound on the frame, so its shape says
        // nothing. Same rule as `CropPlanner.accept`.
        guard !found.touchesBorder else { return nil }
        let w = Double(found.rect.width) * Double(probe.gridWidth)
        let h = Double(found.rect.height) * Double(probe.gridHeight)
        guard w > 0, h > 0 else { return nil }
        // A matted width is a measurement of the holder's window, not a ratio, so it is not
        // checked against one. Everything else must be the shape it was built to be.
        if !found.matted {
            let got = w / h
            guard abs(got - want) / want <= CropPlanner.aspectTolerance else { return nil }
        }
        var rect = found.rect
        if probe.sideways {
            rect = CGRect(x: found.rect.minY, y: found.rect.minX,
                          width: found.rect.height, height: found.rect.width)
        }
        return Result(route: .perforationAnchored, rect: rect, angle: 0,
                      size: expecting, unboundedEdges: [])
    }

    /// The grid with rows and columns swapped, so a strip that arrived turned through a
    /// quarter reads as the horizontal strip the rung expects.
    static func transposed(_ g: ColorGrid) -> ColorGrid {
        var px: [ColorGrid.Pixel] = []
        px.reserveCapacity(g.width * g.height)
        for x in 0..<g.width {
            for y in 0..<g.height { px.append(g[x, y]) }
        }
        return ColorGrid(width: g.height, height: g.width, pixels: px)
    }

    /// Autocrop, ordered by what each rung scored on real frames rather than by what each
    /// detector claims about itself.
    ///
    /// With `perforationEnabled` on, the default, the perforation rung answers first and
    /// `chain` runs as its referee. With it off, or when the rung finds nothing, `chain`
    /// answers on its own.
    ///
    /// The two good detectors in `chain` are complementary. On half-size raw decodes there
    /// are 29 frames where `FrameFinder` closes a box and `CropPlanner` gives up, and 12 the
    /// other way. Either alone reaches a confident answer on 40 to 55 percent of the roll,
    /// and chained they reach one on 66 percent.
    ///
    /// Inside `chain`, `CropPlanner` goes first because its detected boxes score best. Its
    /// overall score is higher still and misleading: on the frames where it gives up it
    /// builds a box from the format it was told to expect, so that box has the format's shape
    /// by construction. Only a detected box is evidence of the format, which is also why the
    /// expected format is never learned back from the anchored route.
    ///
    /// - Parameter expecting: the expected format. Without it the
    ///   anchored rung cannot build anything and about a third of a roll drops to the coarse
    ///   box.
    public static func detect(in frame: CGImage, expecting: FilmSize? = nil,
                              negative: CGImage? = nil) -> Result? {
        guard perforationEnabled,
              let anchored = perforation(in: frame, expecting: expecting, negative: negative)
        else { return chain(in: frame, expecting: expecting) }
        // The chain still runs, as the referee. It may overrule only with a box that could be
        // a frame at all: the planner can report "detections" covering 3% or 6% of the
        // picture, which no 35mm frame on a copy stand can be, and deferring to those throws
        // away right boxes.
        if let other = chain(in: frame, expecting: expecting), other.route.isMeasured,
           plausibleFrame(other.rect, expecting: expecting),
           overlap(anchored.rect, other.rect) < refereeMinOverlap {
            return other
        }
        return anchored
    }

    /// Could this box be the frame? A single 35mm frame fills most of a copy-stand capture
    /// (the smallest of 114 hand-kept crops covers 0.70 of the picture) and has the
    /// format's shape. Loose on both counts: this only has to reject the absurd.
    static func plausibleFrame(_ rect: CGRect, expecting: FilmSize?) -> Bool {
        guard Double(rect.width * rect.height) >= 0.35 else { return false }
        guard let want = expecting?.aspectRatio, rect.width > 0, rect.height > 0 else { return true }
        // Long over short of the normalized box, times 1.5 for a 3:2 picture. That is the
        // pixel aspect only when the box's normalized width is its longer side.
        let got = Double(max(rect.width, rect.height) / min(rect.width, rect.height)) * 1.5
        let ratio = max(got, want) / min(got, want)
        return ratio - 1 <= CropPlanner.aspectTolerance * 2
    }

    /// Intersection over union of two normalized boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    /// The ladder without the perforation rung: planner, FrameFinder, anchored plan, partial
    /// FrameFinder, coarse.
    static func chain(in frame: CGImage, expecting: FilmSize?) -> Result? {
        let plan = CropPlanner.plan(in: frame, expecting: expecting)

        if let plan, plan.route == .detected {
            return Result(route: .plannerDetected, rect: plan.rect, angle: plan.angle,
                          size: plan.size, unboundedEdges: [])
        }
        if let found = FrameFinder.detect(in: frame), found.unboundedEdges.isEmpty {
            return Result(route: .frameFinderBounded, rect: found.rect, angle: 0,
                          size: nil, unboundedEdges: [])
        }
        if let plan, plan.route != .rough {
            // Every side except the one it pinned is an assumption, and saying so is what
            // keeps `isFullyBounded` accurate: a useful crop, never a measurement.
            let unbounded = Set(CropDetector.Edge.allCases)
                .subtracting(plan.anchoredEdge.map { [$0] } ?? [])
            return Result(route: .plannerAnchored, rect: plan.rect, angle: plan.angle,
                          size: nil, unboundedEdges: unbounded)
        }
        // FrameFinder may still have an answer, just not a closed one: a strip running off
        // both sides bounds two edges and not the other two. Better than the coarse box,
        // which would put the crop around the whole strip.
        if let found = FrameFinder.detect(in: frame) {
            return Result(route: .frameFinderPartial, rect: found.rect, angle: 0,
                          size: nil, unboundedEdges: found.unboundedEdges)
        }
        // The planner's region ran off the picture and no format could build a box. Its
        // size is a lower bound on the frame, so no side of it is a measurement.
        if let plan, plan.route == .rough {
            return Result(route: .coarse, rect: plan.rect, angle: 0,
                          size: nil, unboundedEdges: Set(CropDetector.Edge.allCases))
        }
        if let coarse = CropDetector.detect(in: frame) {
            return Result(route: .coarse, rect: coarse.rect, angle: 0,
                          size: nil, unboundedEdges: coarse.unboundedEdges)
        }
        return nil
    }
}

/// Frame sizes measured so far, used to resize boxes that were only built.
///
/// The anchored route builds its box from a format's nominal dimensions and whatever scale it
/// can infer from one picture. Measured over 114 frames it lands consistently large:
/// median area 0.9375 of the picture against 0.7647 for the frames the sweep actually
/// measured, a tight band rather than scattered noise. A consistent error with a small spread
/// can be corrected by calibration.
///
/// Remember the size of every measured box, and use the median of those to resize a box
/// that was only built. An operator works a stack of the same film on the same stand, so
/// after a few measured frames the median sizes a built box better than one picture can.
///
/// Only measured routes teach. Learning from an anchored box would feed the fallback its own
/// output.
public struct FrameScale: Sendable {
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []

    public init() {}

    /// How many measurements before the median is worth trusting. At three, a single odd
    /// frame no longer decides the roll.
    public static let minSamples = 3

    public var sampleCount: Int { widths.count }
    public var isCalibrated: Bool { widths.count >= Self.minSamples }

    /// Learn from a result, if it is the kind of result that may teach.
    public mutating func learn(from result: AutoCrop.Result) {
        guard result.route.isMeasured else { return }
        widths.append(result.rect.width)
        heights.append(result.rect.height)
    }

    private func median(_ v: [CGFloat]) -> CGFloat {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// Resize a built box to the size this live-view session has been measuring, holding
    /// the edge the planner pinned so the correction shrinks away from the anchor rather
    /// than sliding the box off the frame it found.
    ///
    /// A measured result is returned untouched. It is the evidence, and correcting it against
    /// a median of itself would only blur it.
    public func refined(_ result: AutoCrop.Result) -> AutoCrop.Result {
        guard result.route == .plannerAnchored, isCalibrated else { return result }
        let w = median(widths), h = median(heights)
        guard w > 0, h > 0 else { return result }

        // Hold the anchored edge still, or the center when no edge is anchored.
        let pinned = Set(CropDetector.Edge.allCases).subtracting(result.unboundedEdges).first
        var x = result.rect.midX - w / 2
        var y = result.rect.midY - h / 2
        switch pinned {
        case .left:   x = result.rect.minX
        case .right:  x = result.rect.maxX - w
        case .top:    y = result.rect.minY
        case .bottom: y = result.rect.maxY - h
        case nil:     break
        }
        return AutoCrop.Result(route: .plannerAnchored,
                               rect: CGRect(x: x, y: y, width: w, height: h),
                               angle: result.angle, size: result.size,
                               unboundedEdges: result.unboundedEdges)
    }
}
