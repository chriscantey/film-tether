import Foundation
import CoreGraphics

/// A film format the scanner knows about.
///
/// `id` is a stable identifier, not a local index. It goes into the
/// sidecar verbatim, where Film Positive reads it, so it must never be
/// renumbered to suit the app's ordering.
///
/// Dimensions are nominal sizes in millimeters (see `seedCatalog`).
public struct FilmSize: Identifiable, Equatable, Codable, Sendable {
    public var id: Int
    public var name: String
    /// Short edge in mm, or nil for a format with no fixed dimensions.
    public var widthMM: Double?
    /// Long edge in mm, or nil.
    public var heightMM: Double?

    public init(id: Int, name: String, widthMM: Double? = nil, heightMM: Double? = nil) {
        self.id = id
        self.name = name
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    /// The placeholder row. Carries no dimensions, so it never participates in
    /// matching.
    public var isUnknown: Bool { widthMM == nil || heightMM == nil }

    /// Long edge ÷ short edge, orientation-independent so a negative laid down
    /// either way matches the same format. Nil for `unknown`.
    public var aspectRatio: Double? {
        guard let w = widthMM, let h = heightMM, w > 0, h > 0 else { return nil }
        return max(w, h) / min(w, h)
    }

    /// The image's extent across the film strip in mm, which a roll or strip
    /// gauge fixes: 24 for 35mm, 56 for 120, 13 for 110. A row is on that gauge
    /// when one of its sides is that number. Nil for sheet film and anything
    /// else with no strip.
    public var stripAcrossMM: Double? {
        guard let w = widthMM, let h = heightMM else { return nil }
        return [24.0, 56.0, 13.0].first { w == $0 || h == $0 }
    }

    /// The image's extent along the strip over its extent across it. A strip
    /// format runs either edge along the strip: 36/24 for 35mm full frame, but
    /// 18/24 for the half frame and 41.5/56 for 6x4.5, which `aspectRatio`
    /// gives as 1.33 and 1.35. Sheet film and anything else with no strip
    /// has no along or across, so it gives long over short. Nil for `unknown`.
    public var alongOverAcross: Double? {
        guard let w = widthMM, let h = heightMM, w > 0, h > 0 else { return nil }
        guard let across = stripAcrossMM else { return aspectRatio }
        return (w == across ? h : w) / across
    }

    /// Diagonal in mm, a single number standing in for overall size when
    /// comparing against a measured crop, and orientation-independent.
    public var diagonalMM: Double? {
        guard let w = widthMM, let h = heightMM else { return nil }
        return (w * w + h * h).squareRoot()
    }

    // MARK: - Catalog

    /// Seed catalog: the formats auto-crop's format matcher knows, and the
    /// rows every id lookup starts from.
    ///
    /// Dimensions are nominal, used consistently rather than per-format guesses
    /// at usable image area. Mixing conventions would fake
    /// distinctions: holder apertures for `4x5` and `8x10` that differ by 1%
    /// would separate two formats that share an aspect ratio exactly.
    public static let seedCatalog: [FilmSize] = [
        FilmSize(id: 1,  name: "unknown"),
        FilmSize(id: 2,  name: "120mm Rollei",              widthMM: 56,    heightMM: 56),
        FilmSize(id: 3,  name: "4x5",                       widthMM: 101.6, heightMM: 127),
        FilmSize(id: 4,  name: "35mm",                      widthMM: 24,    heightMM: 36),
        FilmSize(id: 5,  name: "35mm slide",                widthMM: 24,    heightMM: 36),
        FilmSize(id: 6,  name: "8x10",                      widthMM: 203.2, heightMM: 254),
        FilmSize(id: 7,  name: "11x14",                     widthMM: 279.4, heightMM: 355.6),
        FilmSize(id: 8,  name: "6x9",                       widthMM: 56,    heightMM: 84),
        FilmSize(id: 9,  name: "5x7",                       widthMM: 127,   heightMM: 177.8),
        FilmSize(id: 10, name: "3.25x4.25 (80mm x 105mm)",  widthMM: 80,    heightMM: 105),
        FilmSize(id: 11, name: "2.25x3.25",                 widthMM: 57.15, heightMM: 82.55),
        // Half frame: 18 mm along the strip by the same 24 mm across it. Selecting it is
        // what gates the perforation rung's half-frame path. The rung and the crop fallback
        // read the along-strip ratio through `alongOverAcross`, not `aspectRatio`, which is
        // long over short and cannot tell 18 x 24 from 24 x 18.
        FilmSize(id: 12, name: "35mm half-frame",           widthMM: 18,    heightMM: 24),
    ]

    /// Formats measurement cannot separate, because they are the same frame:
    /// `35mm` and `35mm slide` are both 24×36mm and differ only by having a
    /// cardboard mount around them.
    ///
    /// Does not include `6x9` / `2.25x3.25`. Those are about half a percent
    /// apart on diagonal, 56×84mm against 57.15×82.55mm, but differ by nearly
    /// 4% in aspect ratio, so a clean detection does favor one over the other.
    /// They're easily confused rather than identical, which is what the
    /// candidate list is for.
    public static let indistinguishableGroups: [[Int]] = [[4, 5]]

    // MARK: - The Size picker

    /// Rows the Size picker offers that the seed catalog does not have.
    /// Kept out of `seedCatalog` because auto-crop's format matcher reads
    /// that list, and 6x7 shares 4x5's aspect exactly, 6x4.5 sits 1.2% from
    /// the half frame and 110 0.4% from 3.25x4.25, so adding them there would
    /// change which format a detected crop is taken for. Choosing one sets the
    /// expected aspect for the crop like any row. Ids continue the catalog's
    /// numbering and are written to the sidecar with the name beside them
    /// (`Film:FilmSizeName`), so a reader that does not know an id still shows
    /// the format.
    public static let pickerOnlyRows: [FilmSize] = [
        FilmSize(id: 13, name: "120 6x4.5", widthMM: 41.5, heightMM: 56),
        FilmSize(id: 14, name: "120 6x7",   widthMM: 56,   heightMM: 70),
        FilmSize(id: 15, name: "110",       widthMM: 13,   heightMM: 17),
    ]

    /// The formats the metadata bar's Size picker offers, in menu order, by
    /// id. Other, with free text, follows them. The catalog rows left out
    /// (8x10, 11x14, 5x7, 3.25x4.25, 2.25x3.25) still resolve by id, for
    /// sidecars already written and for the matcher, and a hidden row the
    /// matcher picks still shows while it is the selection.
    public static let pickerIDs: [Int] = [4, 12, 5, 13, 2, 14, 8, 3, 15]

    /// Any id Tether knows, from the catalog or the picker's own rows.
    public static func resolve(id: Int) -> FilmSize? {
        seedCatalog.first { $0.id == id } ?? pickerOnlyRows.first { $0.id == id }
    }

    /// The plain name the picker shows and the sidecar's `Film:FilmSizeName`
    /// carries. The menu drops the brand from "120mm Rollei", says which roll
    /// film 6x9 is on, and names the half frame and the slide "35mm Half" and
    /// "35mm Slide". The half frame's catalog name keeps "half", which is what
    /// gates the perforation rung.
    public var displayName: String {
        switch id {
        case 1: return "Not set"
        case 2: return "120 6x6"
        case 5: return "35mm Slide"
        case 8: return "120 6x9"
        case 12: return "35mm Half"
        default: return name
        }
    }

    /// The picker's rows: "Not set", the short list, and the current
    /// selection when it is a row outside the short list.
    public static func pickerSizes(including current: FilmSize?) -> [FilmSize] {
        var rows = [unknown] + pickerIDs.compactMap(resolve(id:))
        if let c = current, !c.isUnknown, !rows.contains(where: { $0.id == c.id }) { rows.append(c) }
        return rows
    }

    /// Whether a format the crop detector matched may replace the one chosen.
    /// The matcher knows only `seedCatalog`, so it cannot confirm a picker-only
    /// row: a 6x7 frame matches 4x5, the same shape. A chosen picker-only row
    /// stays when the match has its shape (within 2%), and Other is never
    /// replaced, since the person typed what the list lacks. A chosen catalog
    /// row is replaceable by any match that is not unknown.
    public static func detectionMayReplace(_ current: FilmSize?, other: Bool, with match: FilmSize) -> Bool {
        guard !match.isUnknown, !other else { return false }
        guard let c = current, pickerOnlyRows.contains(where: { $0.id == c.id }),
              let a = c.aspectRatio, let b = match.aspectRatio else { return true }
        return abs(a / b - 1) > 0.02
    }

    /// The `unknown` row, used whenever nothing can be identified.
    public static var unknown: FilmSize {
        seedCatalog.first { $0.id == 1 } ?? FilmSize(id: 1, name: "unknown")
    }
}

/// Picks the film size that best explains a detected crop.
public enum FilmSizeMatcher {

    /// One candidate format, with how well it fits.
    public struct Match: Equatable {
        public let size: FilmSize
        /// Relative aspect-ratio error, 0 being exact. 0.02 = 2% out.
        public let aspectError: Double
        /// Relative size error, or nil when no scale is known.
        public let sizeError: Double?

        /// Combined score, lower is better. Size dominates when it's available
        /// because it's the only thing that separates the formats that share an
        /// aspect ratio.
        public var score: Double {
            guard let sizeError else { return aspectError }
            return sizeError * 2 + aspectError
        }
    }

    /// Formats whose aspect ratio is within `tolerance` of the crop's, best
    /// first. With `mmPerPixel` supplied they're additionally ranked, and
    /// separated, by actual size.
    ///
    /// Without a scale this is ambiguous. `4x5` and `8x10` have identical
    /// aspect ratios, as do `35mm` and `6x9`, and nothing in the crop's shape
    /// can tell them apart.
    public static func candidates(
        forCropSize crop: CGSize,
        in catalog: [FilmSize],
        mmPerPixel: Double? = nil,
        tolerance: Double = 0.06
    ) -> [Match] {
        guard crop.width > 0, crop.height > 0 else { return [] }
        let cropAspect = Double(max(crop.width, crop.height) / min(crop.width, crop.height))
        let cropDiagonalPx = Double((crop.width * crop.width + crop.height * crop.height).squareRoot())

        var matches: [Match] = []
        for size in catalog {
            guard let aspect = size.aspectRatio, let diagonal = size.diagonalMM else { continue }
            let aspectError = abs(aspect - cropAspect) / cropAspect
            guard aspectError <= tolerance else { continue }
            var sizeError: Double?
            if let mmPerPixel, mmPerPixel > 0 {
                let measured = cropDiagonalPx * mmPerPixel
                sizeError = abs(measured - diagonal) / diagonal
            }
            matches.append(Match(size: size, aspectError: aspectError, sizeError: sizeError))
        }
        return matches.sorted {
            $0.score == $1.score ? $0.size.id < $1.size.id : $0.score < $1.score
        }
    }

    /// Best single guess, or `unknown` when nothing is close enough.
    public static func bestMatch(
        forCropSize crop: CGSize,
        in catalog: [FilmSize],
        mmPerPixel: Double? = nil,
        tolerance: Double = 0.06
    ) -> FilmSize {
        candidates(forCropSize: crop, in: catalog,
                   mmPerPixel: mmPerPixel, tolerance: tolerance).first?.size
            ?? catalog.first { $0.isUnknown } ?? FilmSize.unknown
    }

    /// Scale implied by a crop known to be `size`.
    ///
    /// Absolute matching needs it because the camera can't report its height
    /// above the copy stand, so mm-per-pixel has to be learned from one known
    /// negative. It stays valid only while the copy-stand geometry is
    /// unchanged. Moving the camera or changing the lens invalidates it.
    public static func mmPerPixel(cropSize crop: CGSize, isSize size: FilmSize) -> Double? {
        guard crop.width > 0, crop.height > 0, let diagonal = size.diagonalMM else { return nil }
        let cropDiagonalPx = Double((crop.width * crop.width + crop.height * crop.height).squareRoot())
        guard cropDiagonalPx > 0 else { return nil }
        return diagonal / cropDiagonalPx
    }
}
