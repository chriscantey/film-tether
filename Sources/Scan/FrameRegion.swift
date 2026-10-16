import Foundation
import CoreGraphics

/// Finds the frame as a *region* rather than as a set of edges: threshold the
/// picture to the band of densities that exposed film occupies, then take the
/// connected blob the lens is pointed at.
///
/// Projections and line votes both reduce the picture to one dimension before
/// deciding anything, and a boundary that is thin, or partly obscured, or
/// shared with a busy photograph, does not survive that reduction.
/// Connectivity keeps the second dimension: a frame is a contiguous area of
/// exposed film bounded on all sides by film that isn't, and that statement can
/// be tested directly.
///
/// Taking the largest contour assumes one negative in view, and on a strip it
/// returns several frames joined by whatever the threshold let through, or the
/// wrong frame. Growing from the point under the lens returns the frame being
/// scanned, and needs no assumption about how many there are.
///
/// The region's minimum-area rectangle is oriented, so a negative sitting a
/// degree or two off square is measured as the rectangle it is rather than as
/// the larger upright box containing it. No other rung returns an angle.
public enum FrameRegion {

    public struct Result: Sendable, Equatable {
        /// Center of the frame, normalized [0,1]², y-down.
        public let center: CGPoint
        /// Size of the frame, normalized to the picture's dimensions.
        public let size: CGSize
        /// Rotation clockwise in degrees, positive turning the frame's top edge
        /// to the right. Small in practice: a negative on a copy stand is
        /// nearly square to the sensor.
        public let angle: Double
        /// Fraction of the picture the region covers. Very high means the
        /// threshold let everything through and the answer is meaningless.
        public let coverage: Double
        /// True if the region touches the picture's border.
        public let touchesBorder: Bool

        /// Axis-aligned bounding box of the rotated rectangle. `size` is normalized per
        /// axis, so the box is exact only at zero angle or on a square grid.
        public var boundingRect: CGRect {
            let r = abs(angle) * .pi / 180
            let w = size.width * cos(r) + size.height * sin(r)
            let h = size.width * sin(r) + size.height * cos(r)
            return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        }

        public init(center: CGPoint, size: CGSize, angle: Double,
                    coverage: Double, touchesBorder: Bool) {
            self.center = center
            self.size = size
            self.angle = angle
            self.coverage = coverage
            self.touchesBorder = touchesBorder
        }
    }

    /// The band of luminance that counts as exposed film. The sweep pins one
    /// bound at 0 or 1 and moves the other.
    public struct Band: Sendable, Equatable {
        public let low: Double, high: Double

        public init(low: Double, high: Double) {
            self.low = min(low, high)
            self.high = max(low, high)
        }

        public func contains(_ v: Double) -> Bool { v >= low && v <= high }
    }

    /// Erosion radius, in working-grid pixels.
    ///
    /// Dust, scratches and grain survive thresholding as speckle. Eroding then
    /// dilating by this radius removes that speckle while leaving the frame's
    /// own shape where it was. It also breaks the one-pixel bridges that would
    /// otherwise let the region leak through a soft edge into its neighbor.
    public static let erosionRadius = 2

    /// Reject a region covering more than this fraction of the picture: the
    /// threshold has admitted everything and there is no frame to speak of.
    public static let maxCoverage = 0.92

    /// Working width. Higher than a projection method needs, because
    /// connectivity is decided pixel by pixel, so a boundary only has to be one
    /// pixel thick to hold, but it does have to survive the downsample.
    public static let analysisWidth = 512

    /// Angles searched for the minimum-area rectangle, in degrees either way.
    ///
    /// Bounded deliberately. A copy stand holds the negative nearly square, so a
    /// large answer means the region is the wrong shape rather than the negative
    /// being at 40°, and searching wide would let a badly-grown region justify
    /// itself with an implausible angle.
    public static let maxAngle = 8.0
    public static let angleStep = 0.25

    public static func detect(in grid: ColorGrid, around center: CGPoint, band: Band) -> Result? {
        var mask = [Bool](repeating: false, count: grid.width * grid.height)
        for y in 0..<grid.height {
            for x in 0..<grid.width where band.contains(grid[x, y].luminance) {
                mask[y * grid.width + x] = true
            }
        }
        return detect(mask: mask, width: grid.width, height: grid.height, around: center)
    }

    /// Grow from a mask worked out by the caller.
    ///
    /// A luminance band is enough on some negatives. On others the picture's
    /// bright areas are brighter than the unexposed film and no threshold on
    /// level separates them: on a real capture the picture reaches 0.682 and
    /// the rebate sits at 0.65.
    public static func detect(
        mask rawMask: [Bool], width w: Int, height h: Int,
        around center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> Result? {
        guard w > 8, h > 8, rawMask.count == w * h else { return nil }
        let mask = opened(rawMask, width: w, height: h, radius: erosionRadius)

        // Start at the lens. If thresholding happened to reject that exact pixel
        // (a speck, a dark line), search outward for one it kept, so a single
        // unlucky pixel doesn't cost the whole detection.
        let sx = min(max(Int(center.x * Double(w)), 0), w - 1)
        let sy = min(max(Int(center.y * Double(h)), 0), h - 1)
        guard let seed = nearestSet(in: mask, width: w, height: h, x: sx, y: sy) else { return nil }

        let (points, touchesBorder) = grow(mask, width: w, height: h, from: seed)
        guard points.count > 16 else { return nil }
        let coverage = Double(points.count) / Double(w * h)
        guard coverage <= maxCoverage else { return nil }

        let (centerP, sizeP, angle) = minimumAreaRect(points)
        return Result(
            center: CGPoint(x: centerP.x / Double(w), y: centerP.y / Double(h)),
            size: CGSize(width: sizeP.width / Double(w), height: sizeP.height / Double(h)),
            angle: angle,
            coverage: coverage,
            touchesBorder: touchesBorder
        )
    }

    // MARK: - Threshold sweep

    public struct SweepResult: Sendable, Equatable {
        public let frame: Result
        /// How many consecutive thresholds agreed on this rectangle. This is the
        /// confidence: it says the boundary the region stopped at survived the
        /// threshold being moved, which is what a real edge does and what a
        /// coincidence doesn't.
        public let stableSteps: Int
        /// The span of thresholds over which it held.
        public let thresholds: ClosedRange<Double>

        public init(frame: Result, stableSteps: Int, thresholds: ClosedRange<Double>) {
            self.frame = frame
            self.stableSteps = stableSteps
            self.thresholds = thresholds
        }
    }

    /// Rectangles this close together, as a fraction of the picture, count as
    /// the same answer.
    public static let stabilityTolerance = 0.02

    /// Consecutive thresholds that must agree before the answer is believed.
    public static let minStableSteps = 4

    /// The same bar for a run that never touches the picture's border.
    ///
    /// It is lower because the ranking in `detectBySweep` prefers a
    /// non-bordering plateau over a longer bordering one, since a region running
    /// off the picture is a lower bound on the frame rather than a measurement
    /// of it. With one bar for both kinds, the length filter in `sweep` would
    /// discard a short non-bordering run before the ranking ever saw it, and
    /// the only surviving candidate would be the flooded one the ranking exists
    /// to reject.
    ///
    /// Measured over 114 frames: 41 of them have a non-bordering plateau that
    /// is shorter than `minStableSteps`, including 20 of the 37 Arista 400
    /// frames, whose median non-bordering run is 2 steps against 6 on both
    /// color rolls. Only 10 Arista frames have no non-bordering plateau at any
    /// threshold at all.
    ///
    /// Two is the floor rather than one because a single sample is not a
    /// plateau: stability across a moved threshold is the evidence, and
    /// one threshold demonstrates none of it. When a format is expected, a short
    /// run still has to survive `CropPlanner.accept`, which checks its shape
    /// against that format and, when they disagree, demands `confidentSteps`.
    public static let minFreeSteps = 2

    public static let sweepStep = 0.03

    /// Sweep the threshold instead of choosing one, and return the rectangle
    /// that holds still.
    ///
    /// Choosing a threshold is the hard part of every region method, and it
    /// cannot be done well from the histogram alone on negatives where the
    /// picture's own tones overlap the unexposed film's outright. Sweeping
    /// sidesteps the choice: a real frame keeps its shape while the threshold
    /// moves, because the boundary it stops at is a real discontinuity, and it
    /// collapses only when the threshold finally crosses that discontinuity and
    /// the region floods.
    ///
    /// The run length is returned rather than discarded, because it answers a
    /// question the rectangle alone can't: *is there a threshold answer here at
    /// all*. One capture can show the same rectangle over seven consecutive
    /// thresholds while another never repeats a rectangle once, and on the
    /// second kind every threshold method is guessing.
    ///
    /// Both polarities are swept, since unexposed film reads bright on a
    /// negative and dark on a positive, and the ranking below picks among
    /// their plateaus.
    ///
    /// Takes the grid rather than an image: the one caller, `CropPlanner`,
    /// samples at `analysisWidth` and reuses that grid for the edge vote, so
    /// the sweep sees the same 512-wide picture the rest of the planner does.
    public static func detectBySweep(
        in grid: ColorGrid, around center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> SweepResult? {
        // The sweep starts from the picture's own level, the median of the
        // block spanning the middle quarter of each axis.
        var block: [Double] = []
        for y in (grid.height * 3 / 8)..<(grid.height * 5 / 8) {
            for x in (grid.width * 3 / 8)..<(grid.width * 5 / 8) {
                block.append(grid[x, y].luminance)
            }
        }
        guard !block.isEmpty else { return nil }
        block.sort()
        let picture = block[block.count / 2]

        let plateaus = sweep(grid, center: center, from: picture, rising: true)
            + sweep(grid, center: center, from: picture, rising: false)
        // A region that has leaked across most of the picture is also stable,
        // and over a wider span than the real frame, because the real frame's
        // plateau ends as soon as the threshold crosses its boundary. On a
        // capture whose true plateau runs seven steps, a flooded one can run
        // nineteen.
        //
        // A frame wholly inside the picture is the thing being looked for, so
        // those are preferred outright, and only among equals does length
        // decide.
        return plateaus.max { a, b in
            let ai = a.frame.touchesBorder ? 0 : 1, bi = b.frame.touchesBorder ? 0 : 1
            return ai == bi ? a.stableSteps < b.stableSteps : ai < bi
        }
    }

    /// Every run of agreeing thresholds that clears the length bar, not just
    /// the longest. The caller ranks them.
    private static func sweep(
        _ grid: ColorGrid, center: CGPoint, from picture: Double, rising: Bool
    ) -> [SweepResult] {
        var samples: [(threshold: Double, result: Result?)] = []
        var t = rising ? picture + sweepStep : picture - sweepStep
        while rising ? t <= 0.99 : t >= 0.01 {
            let band = rising ? Band(low: 0, high: t) : Band(low: t, high: 1)
            samples.append((t, detect(in: grid, around: center, band: band)))
            t += rising ? sweepStep : -sweepStep
        }

        var runs: [[(threshold: Double, result: Result)]] = []
        var run: [(threshold: Double, result: Result)] = []
        func close() {
            // A run that never touches the border clears a lower bar, because the
            // ranking downstream prefers it outright and a single bar here would
            // deny it the chance. See `minFreeSteps`.
            let free = !run.contains { $0.result.touchesBorder }
            if run.count >= minStableSteps || (free && run.count >= minFreeSteps) {
                runs.append(run)
            }
            run = []
        }
        for s in samples {
            guard let r = s.result else { close(); continue }
            if let last = run.last?.result, !agree(last, r) { close() }
            run.append((s.threshold, r))
        }
        close()

        return runs.map { r in
            let first = r.first!.threshold, last = r.last!.threshold
            return SweepResult(
                frame: median(r.map(\.result)),
                stableSteps: r.count,
                thresholds: min(first, last)...max(first, last)
            )
        }
    }

    static func agree(_ a: Result, _ b: Result) -> Bool {
        abs(a.center.x - b.center.x) <= stabilityTolerance
            && abs(a.center.y - b.center.y) <= stabilityTolerance
            && abs(a.size.width - b.size.width) <= stabilityTolerance
            && abs(a.size.height - b.size.height) <= stabilityTolerance
    }

    /// Component-wise median. Neighboring members of a run agree within
    /// `stabilityTolerance`, and a median keeps the result from being pulled by
    /// the one sample at the end of the run where the region has just begun to
    /// spill.
    static func median(_ results: [Result]) -> Result {
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let cx = mid(results.map { Double($0.center.x) })
        let cy = mid(results.map { Double($0.center.y) })
        let sw = mid(results.map { Double($0.size.width) })
        let sh = mid(results.map { Double($0.size.height) })
        let angle = mid(results.map { $0.angle })
        let coverage = mid(results.map { $0.coverage })
        return Result(
            center: CGPoint(x: cx, y: cy),
            size: CGSize(width: sw, height: sh),
            angle: angle,
            coverage: coverage,
            touchesBorder: results.contains { $0.touchesBorder }
        )
    }

    // MARK: - Morphology

    /// Erode then dilate by the same radius: removes speckle and thin bridges,
    /// and puts the surviving region back at its original size.
    static func opened(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        return dilate(erode(mask, width: w, height: h, radius: radius),
                      width: w, height: h, radius: radius)
    }

    /// Separable, so the cost is linear in the radius rather than quadratic.
    static func erode(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        morph(mask, width: w, height: h, radius: radius, keepIf: false)
    }

    static func dilate(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        morph(mask, width: w, height: h, radius: radius, keepIf: true)
    }

    /// One separable pass each way. `keepIf` true dilates (any neighbor set),
    /// false erodes (every neighbor set).
    private static func morph(
        _ mask: [Bool], width w: Int, height h: Int, radius: Int, keepIf any: Bool
    ) -> [Bool] {
        // Unsafe buffers throughout: this runs twice per detection, over every
        // pixel, the innermost loop in the detector.
        // Bounds-checked indexing here costs 292 seconds across the planner's
        // tests.
        var horizontal = [Bool](repeating: false, count: w * h)
        var out = [Bool](repeating: false, count: w * h)
        mask.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { mid in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var acc = !any
                        for d in -radius...radius {
                            let j = min(max(x + d, 0), w - 1)
                            let v = src[row + j]
                            acc = any ? (acc || v) : (acc && v)
                        }
                        mid[row + x] = acc
                    }
                }
            }
            horizontal.withUnsafeBufferPointer { mid in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        for x in 0..<w {
                            var acc = !any
                            for d in -radius...radius {
                                let i = min(max(y + d, 0), h - 1)
                                let v = mid[i * w + x]
                                acc = any ? (acc || v) : (acc && v)
                            }
                            dst[y * w + x] = acc
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Region growing

    /// A masked pixel near (x, y), searched outwards in square rings that visit
    /// only their perimeter, each perimeter pixel once.
    ///
    /// A full `(2r+1)²` block per ring is cubic overall, 5.3 seconds for
    /// thirteen small test cases, nearly all of it on an empty mask where every
    /// ring gets walked.
    static func nearestSet(in mask: [Bool], width w: Int, height h: Int,
                           x: Int, y: Int) -> Int? {
        if mask[y * w + x] { return y * w + x }
        func at(_ nx: Int, _ ny: Int) -> Int? {
            guard nx >= 0, nx < w, ny >= 0, ny < h, mask[ny * w + nx] else { return nil }
            return ny * w + nx
        }
        let limit = max(w, h)
        for r in 1..<limit {
            // Top and bottom edges of the ring, corners included.
            for dx in -r...r {
                if let i = at(x + dx, y - r) { return i }
                if let i = at(x + dx, y + r) { return i }
            }
            // Left and right edges, corners already covered.
            for dy in (-r + 1)...(r - 1) {
                if let i = at(x - r, y + dy) { return i }
                if let i = at(x + r, y + dy) { return i }
            }
        }
        return nil
    }

    /// Four-connected flood fill. Diagonal connectivity is deliberately not
    /// used: it would let a region cross a boundary that touches only at a
    /// corner, which after the opening is exactly the kind of contact left between
    /// two frames whose separator is nearly gone.
    static func grow(_ mask: [Bool], width w: Int, height h: Int,
                     from seed: Int) -> (points: [(x: Int, y: Int)], touchesBorder: Bool) {
        var seen = [Bool](repeating: false, count: w * h)
        var stack = [seed]
        seen[seed] = true
        var points: [(x: Int, y: Int)] = []
        var touchesBorder = false
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            points.append((x, y))
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
            func visit(_ j: Int) {
                guard mask[j], !seen[j] else { return }
                seen[j] = true
                stack.append(j)
            }
            if x > 0 { visit(i - 1) }
            if x < w - 1 { visit(i + 1) }
            if y > 0 { visit(i - w) }
            if y < h - 1 { visit(i + w) }
        }
        return (points, touchesBorder)
    }

    // MARK: - Minimum-area rectangle

    /// Smallest oriented rectangle containing the points, searched over a narrow
    /// range of angles.
    ///
    /// Run against the convex hull rather than every point, so the search is
    /// over a handful of vertices however large the region.
    static func minimumAreaRect(
        _ points: [(x: Int, y: Int)]
    ) -> (center: CGPoint, size: CGSize, angle: Double) {
        let hull = convexHull(points)
        guard hull.count >= 3 else {
            let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return (CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                    CGSize(width: maxX - minX + 1, height: maxY - minY + 1), 0)
        }
        var best: (area: Double, center: CGPoint, size: CGSize, angle: Double) =
            (.infinity, .zero, .zero, 0)
        var a = -maxAngle
        while a <= maxAngle {
            let r = a * .pi / 180
            let c = cos(r), s = sin(r)
            var minU = Double.infinity, maxU = -Double.infinity
            var minV = Double.infinity, maxV = -Double.infinity
            for p in hull {
                let u = p.x * c + p.y * s
                let v = -p.x * s + p.y * c
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
            }
            let width = maxU - minU, height = maxV - minV
            let area = width * height
            if area < best.area {
                // Rotate the center back into the picture's own axes.
                let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
                best = (area,
                        CGPoint(x: cu * c - cv * s, y: cu * s + cv * c),
                        CGSize(width: width, height: height),
                        a)
            }
            a += angleStep
        }
        return (best.center, best.size, best.angle)
    }

    /// Convex hull by monotone chain.
    static func convexHull(_ points: [(x: Int, y: Int)]) -> [CGPoint] {
        guard points.count >= 3 else { return points.map { CGPoint(x: $0.x, y: $0.y) } }
        var sorted: [CGPoint] = points.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
        sorted.sort { a, b in a.x == b.x ? a.y < b.y : a.x < b.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
