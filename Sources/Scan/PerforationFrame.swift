import Foundation
import CoreGraphics

/// Anchor the frame on the film's own perforations instead of on its density.
///
/// The other rungs in `AutoCrop` key on level and texture: the sweep grows a region while the
/// threshold moves, and `FrameFinder` looks for smooth lines away from the picture's level.
/// That works when the rebate sits at a different density from the picture and fails when
/// it does not, which is common on black and white film. The perforations are a different kind of
/// evidence. They are a manufactured feature at a standardized pitch and position on 35mm
/// film, independent of the picture.
///
/// Find the two hole rows, take the distance between their inner edges as the frame's
/// vertical anchor, and measure the top and bottom edges inside a narrow window below and
/// above those holes. Then slide boxes of every width within `widthSlack` of the format's
/// ratio along the strip and keep the one whose side edges score best. On the mat path the
/// width is the mat window's own.
///
/// On by default (`AutoCrop.perforationEnabled`).
public enum PerforationFrame {

    /// A box built on the perforations, and the three numbers needed to judge it.
    public struct Result: Sendable, Equatable {
        /// The crop, normalized [0,1]², y-down, in the coordinates of the grid passed as `image`.
        public let rect: CGRect
        /// The box ran off the left or right of the picture, so its width is a lower bound on
        /// the frame rather than a measurement of it. `CropPlanner.accept` refuses a bordering
        /// region for the same reason, and so does `AutoCrop.perforation`.
        public let touchesBorder: Bool
        /// Perforations that agreed on a row, summed over both rows. Zero for a row that was
        /// predicted from the other one rather than seen.
        public let holesFound: Int
        /// Width the free search wanted, over the measured height. That search tries widths
        /// within `freeSlack` of the format's with no shape penalty, and a 3:2 frame lands
        /// near 1.5 here.
        public let freeRatio: Double
        /// Chosen edge strength over the typical row or column inside the box, whichever is
        /// weaker, and 1 on the mat path. No threshold is applied to it.
        public let confidence: Double
        /// The left and right edges came from a holder mat's window (bare light on both
        /// sides of the film) rather than from the slide. Only the half-frame preset asks
        /// for that path, and a matted width is a measurement, not a ratio.
        public let matted: Bool
    }


    /// Find the frame.
    ///
    /// - Parameter image: the grid to search, at `FrameRegion.analysisWidth`. The dark pass
    ///   runs on it and looks for holes darker than the rebate, as they read on a developed
    ///   positive. The app passes the live-view negative here and again as `negative`.
    /// - Parameter negative: the gamma-encoded negative at the same width, or nil. It exists
    ///   because a color rebate can develop to near black on the positive, which hides the
    ///   holes in it. On the negative arm the holes are bare light against the clear base and
    ///   cannot hide, so it is consulted only for a row the dark pass failed to find.
    /// - Parameter aspect: the frame's width along the strip over its height across it:
    ///   36/24 = 1.5 for a full frame, 18/24 = 0.75 for a half frame.
    /// - Parameter mat: the holder carries a mask cut to the frame (the half-frame preset).
    ///   Then the picture is bounded left and right by bare light, a level feature fixed for
    ///   the whole roll, and that window is taken as the frame when its width agrees with
    ///   the format within `matSlack`. Never set for a full frame: the same test would take
    ///   the whole strip.
    public static func detect(in image: ColorGrid, negative: ColorGrid? = nil,
                              aspect: Double = 1.5, mat: Bool = false) -> Result? {
        let lum = Plane(luminanceOf: image)
        guard lum.width > 8, lum.height > 8 else { return nil }
        let neg = negative.map { Plane(luminanceOf: $0) }
        return detect(lum: lum, negative: neg, aspect: aspect, mat: mat)
    }

    // MARK: - The method

    /// KS-1870, the perforation standard for 35mm still film: pitch 4.75 mm, and the inner
    /// edges of the two rows 25.4 mm apart (35 mm of film less two 4.8 mm perforation bands).
    /// Both are published dimensions, so one row plus its own measured pitch predicts
    /// where the other row's inner edge has to be.
    private static let rowSpanPitches = 25.4 / 4.75

    /// How far the frame edge may sit inside the hole's inner edge, as a fraction of the
    /// distance between the rows. Physically about 0.7 mm of 25 mm, so 0.10 is a search
    /// window, not a measurement.
    private static let gapMax = 0.10
    /// Width slack for the final box. The camera gate is not exactly 3:2 and the ratio is
    /// being used to close a side we did not measure, so 4 percent of give.
    private static let widthSlack = 0.04
    /// Width slack for the unconstrained search, whose only job is to report what shape the
    /// edges wanted before the ratio was imposed.
    private static let freeSlack = 0.25
    /// A smooth rebate-level column band this long is the gap between two frames. At 512 px
    /// wide that is about 3 percent of the picture.
    private static let gapMin = 16
    /// Fallback gradient bar when there is no interior to measure one from.
    private static let contThrFallback = 0.01

    /// Bare light level for the mat window. Film never reads this bright.
    private static let matLevel = 0.8
    /// How far the mat window may sit from the format's nominal width. A half-frame mat can
    /// be 21 mm wide against the 18 mm nominal (0.866 of the height across 50 half-frame
    /// captures), so the slack is wide. A bare strip with two half frames in view is
    /// twice the nominal and falls through to the slide.
    private static let matSlack = 0.20

    private static func detect(lum: Plane, negative: Plane?, aspect: Double, mat: Bool) -> Result? {
        let w = lum.width, h = lum.height
        var rows = sprocketRows(lum, polarity: .dark)

        // A positive can render a color rebate black and swallow its own holes. Consult the
        // negative only for a row the dark pass missed, never for a row it found.
        if let negative, rows[.top] == nil || rows[.bottom] == nil,
           negative.width == w, negative.height == h {
            let alt = sprocketRows(negative, polarity: .bright)
            for side in [RowSide.top, .bottom] where rows[side] == nil {
                if let found = alt[side] { rows[side] = found }
            }
        }
        guard rows[.top] != nil || rows[.bottom] != nil else {
            return nil
        }

        // Inner edges of the two rows, in grid pixels. One row plus the pitch predicts the
        // other, and two rows check each other against the standard.
        let ti: Double, bi: Double
        if let top = rows[.top], let bottom = rows[.bottom] {
            ti = top.inner; bi = bottom.inner
            let pitch = (top.pitch + bottom.pitch) / 2
            // A span that is not 25.4/4.75 pitches means one of these rows is not a
            // perforation row. Twelve percent, which is wide enough for the pitch itself to be
            // a couple of pixels off at 512 and narrow enough to reject a sprocket row paired
            // with something that merely looks like one.
            if abs((bi - ti) / pitch - rowSpanPitches) > 0.12 * rowSpanPitches {
                return nil
            }
        } else if let top = rows[.top] {
            ti = top.inner
            bi = ti + top.pitch * rowSpanPitches
            rows[.bottom] = SprocketRow(inner: bi, holes: 0, pitch: top.pitch)
        } else {
            let bottom = rows[.bottom]!
            bi = bottom.inner
            ti = bi - bottom.pitch * rowSpanPitches
            rows[.top] = SprocketRow(inner: ti, holes: 0, pitch: bottom.pitch)
        }
        guard bi < Double(h), ti >= 0 else {
            return nil
        }
        let span = bi - ti
        // A span under 0.3 of the picture's height is not two rows of a 35mm strip filling the
        // frame. It is two things that happened to look like hole rows.
        guard span >= 0.3 * Double(h) else {
            return nil
        }

        let win = max(3, iround(gapMax * span))
        var gx = scharr(lum, axis: .x).mapped { Swift.abs($0) }
        var gy = scharr(lum, axis: .y).mapped { Swift.abs($0) }
        let out = outsideMask(lum, white: 0.98)
        gx.zeroOut(out)
        gy.zeroOut(out)

        let tiI = iround(ti), biI = iround(bi)
        let x0 = Int(Double(w) * 0.2), x1 = Int(Double(w) * 0.8)

        // Judge edge continuity against the picture's own gradient level. A thin negative
        // whose frame edge is a small step would fail any fixed bar, and the same fixed bar is
        // meaningless on a contrasty one.
        let interior = gy.values(rows: safeRange(tiI + win + 2, biI - win - 2), cols: x0 ..< x1)
        let contThr = interior.isEmpty ? contThrFallback : max(0.002, 0.5 * median(interior))

        // Horizontal edge evidence per row over the central 60 percent of columns, weighted by
        // how much of that width the edge runs across. Squared, because a frame edge
        // runs the whole way and a row of holes is dashed.
        let rowE = (0..<h).map { y -> Double in
            profileScore(gy, along: .row, index: y, from: x0, to: x1, bar: contThr)
        }

        // Search each edge only in the window just inside its hole row, and skip the rows
        // nearest the holes: the hole edge itself is strong and would win every time.
        let tLo = tiI + 2, tHi = tiI + win
        let bLo = biI - win, bHi = biI - 2
        guard tHi < bLo else {
            return nil
        }
        guard let t = argmax(rowE, in: tLo ... tHi), let b = argmax(rowE, in: bLo ... bHi) else {
            return nil
        }
        guard b - t >= 4 else {
            return nil
        }

        let refRows = median(slice(rowE, tHi + 1 ..< bLo)) + 1e-9
        let confTB = min(rowE[t], rowE[b]) / refRows
        let height = Double(b - t)

        // Vertical edge evidence per column, measured only over the rows between the edges we
        // just found, so the holes cannot contribute to it.
        let inner = t + 2 ..< b - 1
        let colE = (0..<w).map { x -> Double in
            profileScore(gx, along: .column, index: x, from: inner.lowerBound, to: inner.upperBound,
                         bar: contThr)
        }

        // Polarity. A frame edge has picture on one side and rebate on the other. The film's
        // own outer edge and the holder's edge both fail that, and so does a rebate sitting
        // beside something dark, which is why the inside band must also look like picture in
        // absolute terms rather than merely beat its neighbor.
        var texture = textureMap(lum, radius: 1)
        texture.zeroOut(out)
        let tm = texture.columnMeans(rows: inner)
        let om = out.columnMeanFractions(rows: inner)
        let band = max(2, iround(0.03 * Double(w)))
        let cT = prefixSums(tm)
        let cO = prefixSums(om)
        let tRef = median(texture.values(rows: h / 4 ..< 3 * h / 4, cols: w / 4 ..< 3 * w / 4)) + 1e-9

        func bandMean(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(w, b)
            return hi > lo ? (cT[hi] - cT[lo]) / Double(hi - lo) : 0
        }
        func outFrac(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(w, b)
            return hi > lo ? (cO[hi] - cO[lo]) / Double(hi - lo) : 0
        }
        func polarity(_ tin: Double, _ tout: Double) -> Double {
            max(tin - tout, 0) / (tin + tout + 1e-9) * min(1.0, tin / (0.3 * tRef))
        }

        var leftE = [Double](repeating: 0, count: w)
        var rightE = [Double](repeating: 0, count: w)
        for x in 0..<w {
            // A side whose outer band is bare light is the film's edge, never the frame's.
            if outFrac(x - 2 - band, x - 2) <= 0.15 {
                leftE[x] = colE[x] * polarity(bandMean(x + 2, x + 2 + band),
                                              bandMean(x - 2 - band, x - 2))
            }
            if outFrac(x + 2, x + 2 + band) <= 0.15 {
                rightE[x] = colE[x] * polarity(bandMean(x - 2 - band, x - 2),
                                               bandMean(x + 2, x + 2 + band))
            }
        }
        // An edge on the picture's own border is a bound, not a measurement. The planner has
        // the same rule.
        leftE[0] = 0; leftE[1] = 0
        rightE[w - 2] = 0; rightE[w - 1] = 0

        let nominal = height * aspect
        let holes = (rows[.top]?.holes ?? 0) + (rows[.bottom]?.holes ?? 0)

        // The mat path: the window between bare-light columns either side of the lens center.
        if mat {
            let level = lum.columnMeans(rows: inner)
            let cx0 = w / 2
            if level[cx0] <= matLevel {
                var li = cx0
                while li > 0, level[li - 1] <= matLevel { li -= 1 }
                var ri = cx0
                while ri < w - 1, level[ri + 1] <= matLevel { ri += 1 }
                let bareLeft = (0..<li).contains { level[$0] > matLevel }
                let bareRight = ((ri + 1)..<w).contains { level[$0] > matLevel }
                let wid = ri - li + 1
                if bareLeft, bareRight, abs(Double(wid) / nominal - 1) <= matSlack {
                    return Result(
                        rect: CGRect(x: Double(li) / Double(w), y: Double(t) / Double(h),
                                     width: Double(wid) / Double(w), height: height / Double(h)),
                        touchesBorder: false, holesFound: holes,
                        freeRatio: Double(wid) / height, confidence: 1, matted: true)
                }
            }
        }
        let gapPrefix = gapColumnPrefix(lum: lum, inner: inner, t: t, b: b, tiI: tiI, biI: biI)

        /// Slide a box of every allowed width along the strip and keep the best position.
        func slide(_ lo: Double, _ hi: Double, penalty: Bool) -> (score: Double, l: Int, r: Int)? {
            var best: (score: Double, l: Int, r: Int)?
            var wid = iround(nominal * lo)
            let widMax = iround(nominal * hi)
            while wid <= widMax {
                defer { wid += 1 }
                if wid >= w || wid < 12 { continue }
                let positions = w - wid
                var bestScore = -Double.infinity
                var bestIndex = 0
                let shapePenalty = penalty ? 1 - 3 * abs(Double(wid) / nominal - 1) : 1
                for i in 0..<positions {
                    let lE = leftE[i], rE = rightE[wid + i]
                    // One-sided evidence is the ratio closing a side we never saw. Allowed,
                    // and halved, because it is half the measurement.
                    var s = (lE + rE) * ((lE > 0 && rE > 0) ? 1.0 : 0.5)
                    if penalty { s *= shapePenalty }
                    // No frame contains a gap between frames, so a position whose interior
                    // holds one is ruled out.
                    if gapPrefix[wid + i] - gapPrefix[4 + i] > 0 { s = -1 }
                    if s > bestScore { bestScore = s; bestIndex = i }
                }
                if positions == 0 || bestScore <= 0 { continue }
                if best == nil || bestScore > best!.score {
                    best = (bestScore, bestIndex, bestIndex + wid)
                }
            }
            return best
        }

        // Unconstrained first, purely to report the shape the edges wanted on their own.
        guard let free = slide(1 - freeSlack, 1 + freeSlack, penalty: false) else {
            return nil
        }
        let freeRatio = Double(free.r - free.l) / height
        guard let best = slide(1 - widthSlack, 1 + widthSlack, penalty: true) else {
            return nil
        }
        let l = best.l, r = best.r

        let touches = l <= 1 || r >= w - 2
        let refCols = median(slice(colE, l + 3 ..< r - 2)) + 1e-9
        let confLR = min(colE[l], colE[r]) / refCols

        return Result(
            rect: CGRect(x: Double(l) / Double(w), y: Double(t) / Double(h),
                         width: Double(r - l) / Double(w), height: height / Double(h)),
            touchesBorder: touches, holesFound: holes,
            freeRatio: freeRatio, confidence: min(confTB, confLR), matted: false)
    }

    /// Columns that are rebate level and smooth, in runs of at least `gapMin` columns: the gap
    /// between two frames, or a half frame seam. Returned as a prefix sum so a candidate
    /// position can be tested in constant time.
    private static func gapColumnPrefix(lum: Plane, inner: Range<Int>, t: Int, b: Int,
                                        tiI: Int, biI: Int) -> [Int] {
        let w = lum.width
        var gap = [Bool](repeating: false, count: w)
        // The rebate level comes from whichever band between hole row and frame edge exists.
        // On a thin negative the bottom edge can land 2 px inside the holes and leave no band
        // there, so requiring both bands would skip this guard on exactly those frames, and a
        // 2 mm rebate seam through the picture would come back as one confident 3:2 box.
        var rebateSamples: [Double] = []
        if t - 1 > tiI + 1 { rebateSamples.append(contentsOf: lum.values(rows: tiI + 1 ..< t - 1, cols: 0 ..< w)) }
        if biI > b + 2 { rebateSamples.append(contentsOf: lum.values(rows: b + 2 ..< biI, cols: 0 ..< w)) }
        if !rebateSamples.isEmpty {
            let rebate = median(rebateSamples)
            let level = lum.columnMeans(rows: inner)
            let deviation = lum.columnDeviations(rows: inner)
            var run = 0
            for x in 0..<w {
                let smooth = abs(level[x] - rebate) < 0.04 && deviation[x] < 0.03
                run = smooth ? run + 1 : 0
                if run >= gapMin {
                    for k in (x - gapMin + 1)...x { gap[k] = true }
                }
            }
        }
        var prefix = [Int](repeating: 0, count: w + 1)
        for x in 0..<w { prefix[x + 1] = prefix[x] + (gap[x] ? 1 : 0) }
        return prefix
    }

    // MARK: - Perforation rows

    private enum RowSide { case top, bottom }
    private enum Polarity { case dark, bright }

    private struct SprocketRow {
        /// Row coordinate of the hole edge nearest the picture, in grid pixels.
        let inner: Double
        let holes: Int
        let pitch: Double
    }

    /// Find the two perforation rows of a 35mm strip running left to right.
    ///
    /// Holes read black on the developed positive and bare light on the negative. Either way
    /// they sit in the smooth rebate as a row of similar blobs at a regular pitch, and it is
    /// the regularity that identifies them: one dark blob is dust, six at an even spacing with
    /// matching widths is a perforation row.
    private static func sprocketRows(_ lum: Plane, polarity: Polarity) -> [RowSide: SprocketRow] {
        let w = lum.width, h = lum.height
        let out = polarity == .dark ? outsideMask(lum, white: 0.98) : outsideMaskAny(lum)
        let rowsOut = (0..<h).map { out.rowMeanFraction($0) > 0.5 }
        let refDepth = max(4, Int(0.08 * Double(h)))
        let bandDepth = 0.22

        var found: [RowSide: SprocketRow] = [:]
        for side in [RowSide.top, .bottom] {
            let bandRows: Range<Int> = side == .top
                ? (0 ..< Int(Double(h) * bandDepth))
                : (Int(Double(h) * (1 - bandDepth)) ..< h)

            // Threshold the holes relative to the rebate they sit in, read just inside the
            // bare light border, so a dense rebate and a clear one are judged the same way.
            let reference: [Double]
            if side == .top {
                let firstInside = (0..<h).first { !rowsOut[$0] } ?? 0
                reference = lum.values(rows: firstInside ..< firstInside + refDepth, cols: 0 ..< w)
            } else {
                let lastInside = (0..<h).reversed().first { !rowsOut[$0] } ?? (h - 1)
                reference = lum.values(rows: lastInside - refDepth ..< lastInside + 1, cols: 0 ..< w)
            }
            let med = median(reference)
            // The 95th percentile of the same samples the median came from. On the bright arm
            // it is what the holes in this band reach, so it is the top of the band's
            // own spread rather than the top of the scale.
            let p95 = percentile(reference, 0.95)
            let threshold: Double
            if polarity == .dark {
                threshold = min(0.3, max(0.03, 0.6 * med))
            } else {
                // The fixed threshold is primary. When it lands at or above the reference
                // rows' p95 it sits above about 95 percent of those samples, so in that case
                // fall to the band's own spread.
                let fixed = med + 0.5 * (1.0 - med)
                threshold = (guardedBrightThreshold && fixed >= p95)
                    ? med + brightSpreadFraction * (p95 - med)
                    : fixed
            }

            var mask = [Bool](repeating: false, count: w * h)
            for y in bandRows {
                for x in 0..<w where !out.flag[y * w + x] {
                    let v = lum[x, y]
                    let on = polarity == .dark ? v < threshold : v > threshold
                    mask[y * w + x] = on
                }
            }

            // Eight-connected, so a hole's corner pixels belong to the hole.
            var blobs: [Blob] = []
            for c in components(mask, width: w, rows: bandRows) {
                let bw = c.maxX - c.minX + 1, bh = c.maxY - c.minY + 1
                // A hole at 512 px is roughly 13 x 10. Too narrow or too short is dust or a
                // scratch. Too wide is not a hole at all. A blob that fills less than 60
                // percent of its own bounding box is not the rounded rectangle a hole is.
                if bw < 3 || bh < 2 || Double(bw) > Double(w) * 0.08 { continue }
                if Double(c.area) < 0.6 * Double(bw * bh) { continue }
                blobs.append(Blob(cx: Double(c.minX) + Double(bw) / 2,
                                  top: Double(c.minY), bottom: Double(c.maxY + 1),
                                  width: Double(bw), height: Double(bh)))
            }
            guard blobs.count >= minHoles else {
                continue
            }
            blobs.sort()

            // Cluster by vertical position and width: holes in one row share their top, their
            // bottom and their width to within a few pixels.
            var best: [Blob]?
            for seed in blobs {
                let group = blobs.filter {
                    abs($0.top - seed.top) <= 3 && abs($0.bottom - seed.bottom) <= 3
                        && abs($0.width - seed.width) <= max(3, 0.3 * seed.width)
                }
                guard group.count >= minHoles else { continue }
                let centers = group.map(\.cx).sorted()
                let gaps = successiveDifferences(centers)
                guard !gaps.isEmpty else { continue }
                // The pitch is the identifying feature. A spread of 0.35 of it or more means
                // these blobs are not evenly spaced and so are not perforations.
                guard standardDeviation(gaps) / max(median(gaps), 1) < 0.35 else { continue }
                if best == nil || group.count > best!.count { best = group }
            }
            guard let row = best else {
                continue
            }

            let tops = median(row.map(\.top)), bottoms = median(row.map(\.bottom))
            let pitch = median(successiveDifferences(row.map(\.cx).sorted()))
            found[side] = SprocketRow(inner: side == .top ? bottoms : tops,
                                      holes: row.count, pitch: pitch)
        }
        return found
    }

    /// Keeps the fixed bright threshold and falls to the band's own spread only when the fixed
    /// threshold is at or above the reference rows' p95. On by default.
    ///
    /// Scored on 114 frames, counting only the bands the bright arm examined (it runs only on
    /// a frame where the dark pass missed a row): it falls to the relative threshold on 51 of
    /// 74 Arista bands and on 0 of 152 Gold and Vision3 bands, so Arista's perforation rung
    /// goes from 12 of 37 to 24 of 37 and Gold and Vision3 are unchanged. Applying the
    /// relative formula everywhere would break Gold, whose p95 is clipped at 1.000.
    ///
    /// A `var` only so the tests can hold one fixture still and toggle the guard around it.
    public static var guardedBrightThreshold = true

    /// How far up the band's own spread, median to 95th percentile, the bright hole threshold
    /// sits. Named rather than inline because the guard above exists to limit it.
    ///
    /// Applied unguarded to 114 frames, Arista improves, rung 12 of 37 to 24 of 37 and median
    /// area error 0.2346 to 0.0976. Gold gets worse, rung 26 of 39 to 10 of 39, because
    /// Gold's rebate band reads 0.965 with a p95 clipped at 1.000, so this formula lowers its
    /// threshold from 0.982 to 0.977 and floods the mask with rebate the cluster search then
    /// cannot resolve. Vision3 goes from 33 of 38 to 30. A spread measured against a clipped
    /// p95 is not a spread, and with the guard on it ran on none of those two stocks' bands.
    private static let brightSpreadFraction = 0.35

    /// The p-th value of `v`: the sorted element at index round((n - 1) × p), with no
    /// interpolation between neighbors. The samples are a whole band of pixels, so neighboring
    /// sorted values sit close together and interpolating would barely move the result.
    private static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let i = Swift.min(s.count - 1, Swift.max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[i]
    }

    /// Fewer than four evenly spaced blobs is a coincidence, not a row.
    private static let minHoles = 4

    private struct Blob: Comparable {
        let cx: Double, top: Double, bottom: Double, width: Double, height: Double
        /// Tuple order, because the cluster search keeps the first largest group and so the
        /// visiting order decides ties.
        static func < (a: Blob, b: Blob) -> Bool {
            (a.cx, a.top, a.bottom, a.width, a.height) < (b.cx, b.top, b.bottom, b.width, b.height)
        }

        static func == (a: Blob, b: Blob) -> Bool {
            (a.cx, a.top, a.bottom, a.width, a.height) == (b.cx, b.top, b.bottom, b.width, b.height)
        }
    }

    // MARK: - Masks

    /// Bare light reads white. Anything at that level connected to
    /// the picture's own border is the holder or the light table, not film.
    private static func outsideMask(_ lum: Plane, white: Double) -> Mask {
        borderConnected(lum.map { $0 >= white })
    }

    /// For the bright arm. Bare light reads white and the holder black on the negative, so the
    /// border-connected region at either extreme is outside the film.
    private static func outsideMaskAny(_ lum: Plane) -> Mask {
        borderConnected(lum.map { $0 >= 0.98 || $0 <= 0.06 })
    }

    /// The four-connected components of `seed` that touch any edge of the picture.
    private static func borderConnected(_ seed: (flag: [Bool], width: Int, height: Int)) -> Mask {
        let w = seed.width, h = seed.height
        var keep = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func push(_ i: Int) {
            if seed.flag[i] && !keep[i] { keep[i] = true; stack.append(i) }
        }
        for x in 0..<w { push(x); push((h - 1) * w + x) }
        for y in 0..<h { push(y * w); push(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { push(i - 1) }
            if x < w - 1 { push(i + 1) }
            if y > 0 { push(i - w) }
            if y < h - 1 { push(i + w) }
        }
        return Mask(flag: keep, width: w, height: h)
    }

    private struct Mask {
        let flag: [Bool]
        let width: Int, height: Int

        func rowMeanFraction(_ y: Int) -> Double {
            var n = 0
            for x in 0..<width where flag[y * width + x] { n += 1 }
            return Double(n) / Double(width)
        }

        /// Per column, the fraction of `rows` that are outside the film.
        func columnMeanFractions(rows: Range<Int>) -> [Double] {
            var out = [Double](repeating: 0, count: width)
            guard !rows.isEmpty else { return out }
            for y in rows {
                for x in 0..<width where flag[y * width + x] { out[x] += 1 }
            }
            let n = Double(rows.count)
            for x in 0..<width { out[x] /= n }
            return out
        }
    }

    private struct Component {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, area = 0
    }

    /// Eight-connected components of `mask` restricted to `rows`, by flood fill.
    private static func components(_ mask: [Bool], width w: Int, rows: Range<Int>) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.count)
        var found: [Component] = []
        var stack: [Int] = []
        for y0 in rows {
            for x0 in 0..<w {
                let start = y0 * w + x0
                guard mask[start], !seen[start] else { continue }
                seen[start] = true
                stack.append(start)
                var c = Component()
                while let i = stack.popLast() {
                    let x = i % w, y = i / w
                    c.area += 1
                    c.minX = min(c.minX, x); c.maxX = max(c.maxX, x)
                    c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                    for dy in -1...1 {
                        let ny = y + dy
                        guard rows.contains(ny) else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            guard nx >= 0, nx < w else { continue }
                            let j = ny * w + nx
                            if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                        }
                    }
                }
                found.append(c)
            }
        }
        return found
    }

    // MARK: - Gradients and texture

    private enum Axis { case x, y }

    /// Scharr 3x3, divided by 16. Edges reflect without repeating the edge pixel, which is the
    /// convention the thresholds below were measured under.
    private static func scharr(_ p: Plane, axis: Axis) -> Plane {
        let w = p.width, h = p.height
        let kx: [Double] = [-3, 0, 3, -10, 0, 10, -3, 0, 3]
        let ky: [Double] = [-3, -10, -3, 0, 0, 0, 3, 10, 3]
        let k = axis == .x ? kx : ky
        var out = [Double](repeating: 0, count: w * h)
        func reflect(_ i: Int, _ n: Int) -> Int {
            if i < 0 { return -i }
            if i >= n { return 2 * n - i - 2 }
            return i
        }
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for dy in -1...1 {
                    let sy = reflect(y + dy, h)
                    for dx in -1...1 {
                        sum += k[(dy + 1) * 3 + (dx + 1)] * p.value[sy * w + reflect(x + dx, w)]
                    }
                }
                out[y * w + x] = sum / 16
            }
        }
        return Plane(value: out, width: w, height: h)
    }

    /// Local mean gradient magnitude. Unexposed film is smooth, picture is not, and a frame
    /// edge is a line of high gradient even where it is not a step in level.
    private static func textureMap(_ lum: Plane, radius: Int) -> Plane {
        let gx = scharr(lum, axis: .x), gy = scharr(lum, axis: .y)
        let w = lum.width, h = lum.height
        var mag = [Double](repeating: 0, count: w * h)
        for i in 0..<mag.count { mag[i] = (gx.value[i] * gx.value[i] + gy.value[i] * gy.value[i]).squareRoot() }
        // Box blur, k = 2r + 1, edge clamped. Clamping and reflecting differ only within
        // `radius` pixels of the picture's border, which is outside the film on every frame
        // measured.
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0.0
                for dy in -radius...radius {
                    let sy = min(max(y + dy, 0), h - 1)
                    for dx in -radius...radius {
                        sum += mag[sy * w + min(max(x + dx, 0), w - 1)]
                    }
                }
                out[y * w + x] = sum / Double((2 * radius + 1) * (2 * radius + 1))
            }
        }
        return Plane(value: out, width: w, height: h)
    }

    private enum ProfileAxis { case row, column }

    /// Mean gradient along a line, times the squared fraction of that line clearing `bar`.
    /// The square is what separates a frame edge, which runs the whole way, from a row of
    /// perforations, which is dashed.
    private static func profileScore(_ g: Plane, along axis: ProfileAxis, index: Int,
                                     from lo: Int, to hi: Int, bar: Double) -> Double {
        let a = max(0, lo), b = axis == .row ? min(g.width, hi) : min(g.height, hi)
        guard b > a else { return 0 }
        var sum = 0.0, clearing = 0
        for k in a..<b {
            let v = axis == .row ? g.value[index * g.width + k] : g.value[k * g.width + index]
            sum += v
            if v > bar { clearing += 1 }
        }
        let n = Double(b - a)
        let share = Double(clearing) / n
        return sum / n * share * share
    }

    // MARK: - A plane of doubles

    private struct Plane {
        var value: [Double]
        let width: Int, height: Int

        init(value: [Double], width: Int, height: Int) {
            self.value = value; self.width = width; self.height = height
        }

        init(luminanceOf grid: ColorGrid) {
            width = grid.width; height = grid.height
            var v = [Double](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width { v[y * width + x] = grid[x, y].luminance }
            }
            value = v
        }

        subscript(x: Int, y: Int) -> Double { value[y * width + x] }

        func map(_ f: (Double) -> Bool) -> (flag: [Bool], width: Int, height: Int) {
            (value.map(f), width, height)
        }

        func mapped(_ f: (Double) -> Double) -> Plane {
            Plane(value: value.map(f), width: width, height: height)
        }

        mutating func zeroOut(_ mask: Mask) {
            for i in 0..<value.count where mask.flag[i] { value[i] = 0 }
        }

        /// Every value in a rectangle, with the bounds clamped to the plane.
        func values(rows: Range<Int>, cols: Range<Int>) -> [Double] {
            let y0 = max(0, rows.lowerBound), y1 = min(height, rows.upperBound)
            let x0 = max(0, cols.lowerBound), x1 = min(width, cols.upperBound)
            guard y1 > y0, x1 > x0 else { return [] }
            var out: [Double] = []
            out.reserveCapacity((y1 - y0) * (x1 - x0))
            for y in y0..<y1 { out.append(contentsOf: value[(y * width + x0)..<(y * width + x1)]) }
            return out
        }

        func columnMeans(rows: Range<Int>) -> [Double] {
            var out = [Double](repeating: 0, count: width)
            guard !rows.isEmpty else { return out }
            for y in rows {
                for x in 0..<width { out[x] += value[y * width + x] }
            }
            let n = Double(rows.count)
            for x in 0..<width { out[x] /= n }
            return out
        }

        /// Population standard deviation per column.
        func columnDeviations(rows: Range<Int>) -> [Double] {
            let means = columnMeans(rows: rows)
            var out = [Double](repeating: 0, count: width)
            guard !rows.isEmpty else { return out }
            for y in rows {
                for x in 0..<width {
                    let d = value[y * width + x] - means[x]
                    out[x] += d * d
                }
            }
            let n = Double(rows.count)
            for x in 0..<width { out[x] = (out[x] / n).squareRoot() }
            return out
        }
    }

    // MARK: - Small numerics

    /// Median of an even count is the mean of the two middle values.
    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    private static func standardDeviation(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        let sq = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sq / Double(v.count)).squareRoot()
    }

    /// Round half to even. Swift's `.rounded()` goes half away from zero, and window edges
    /// derived from a measured span land on a half often enough that the difference is worth
    /// one function.
    private static func iround(_ x: Double) -> Int {
        Int(x.rounded(.toNearestOrEven))
    }

    private static func slice(_ v: [Double], _ r: Range<Int>) -> [Double] {
        let lo = max(0, r.lowerBound), hi = min(v.count, r.upperBound)
        return hi > lo ? Array(v[lo..<hi]) : []
    }

    /// First index of the largest value in a clamped closed range.
    private static func argmax(_ v: [Double], in r: ClosedRange<Int>) -> Int? {
        let lo = max(0, r.lowerBound), hi = min(v.count - 1, r.upperBound)
        guard hi >= lo else { return nil }
        var best = lo
        for i in lo...hi where v[i] > v[best] { best = i }
        return best
    }

    private static func successiveDifferences(_ v: [Double]) -> [Double] {
        guard v.count > 1 else { return [] }
        return (1..<v.count).map { v[$0] - v[$0 - 1] }
    }

    /// A range that collapses to empty rather than trapping when the bounds cross, so a narrow
    /// span yields nothing instead of a crash.
    private static func safeRange(_ lo: Int, _ hi: Int) -> Range<Int> {
        hi > lo ? lo..<hi : lo..<lo
    }

    private static func prefixSums(_ v: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: v.count + 1)
        for i in 0..<v.count { out[i + 1] = out[i] + v[i] }
        return out
    }
}
