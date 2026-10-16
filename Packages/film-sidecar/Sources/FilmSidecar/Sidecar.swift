import Foundation

// Sidecar schema v1, shared by Film Tether and Film Positive, stored as XMP in
// `<base>.xmp` next to the image (see SidecarStore and XMP.swift for the field layout).
//
// Owners: source (Tether at capture, Positive if absent), capture (Tether), geometry and
// samplePoint (shared, in the Film namespace), develop / enhance / look / colorAuto (Positive).
// A non-owner preserves what it does not own on read-modify-write. The codec preserves
// everything outside the namespaces it writes.
//
// Rules:
//   develop absent  = undeveloped
//   enhance absent  = identity
//   geometry.crop is normalized original-orientation coordinates, y down, measured after
//   straighten, and the apply order is fixed: straighten, crop, rotate, flip
//   look is a named source for enhance and never touches geometry
//   version newer than currentVersion is read for known fields, and SidecarStore.save
//   refuses a sidecar carrying it
//   export mode, format and color space are preferences, never sidecar fields

public struct Sidecar: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var source: SidecarSource
    public var capture: CaptureInfo?
    public var geometry: GeometrySettings?
    /// Where the operator clicked on film base, normalized like crop. Tether records it,
    /// Positive measures the raw at that point. Shared, so it lives outside `develop`.
    public var samplePoint: NormalizedPoint?
    public var develop: DevelopSettings?
    public var enhance: EnhanceSettings?
    public var look: String?
    /// The Warmth and Tint pair Film Positive's Color Auto last wrote to this frame,
    /// so that button can tell whether the layer still holds its write. Absent reads as
    /// "never run". Positive clears it whenever
    /// Warmth or Tint moves away from it.
    public var colorAuto: WarmthTint?

    public init(version: Int = Sidecar.currentVersion, source: SidecarSource, capture: CaptureInfo? = nil,
                geometry: GeometrySettings? = nil, samplePoint: NormalizedPoint? = nil,
                develop: DevelopSettings? = nil, enhance: EnhanceSettings? = nil, look: String? = nil,
                colorAuto: WarmthTint? = nil) {
        self.version = version
        self.source = source
        self.capture = capture
        self.geometry = geometry
        self.samplePoint = samplePoint
        self.develop = develop
        self.enhance = enhance
        self.look = look
        self.colorAuto = colorAuto
    }

    public var isDeveloped: Bool { develop != nil }

    /// A copy rounded to the fixed quantum per field, except `develop.colourAxes`, which
    /// only the writer's number format rounds. Files diff cleanly and no float noise leaks
    /// into the packet. Applied to a copy at encode time, never to live state.
    public func quantized() -> Sidecar {
        var c = self
        // XMP carries whole seconds. Hold the in-memory value to the same grain so a
        // round-trip compares equal.
        c.source.mtime = Date(timeIntervalSince1970: source.mtime.timeIntervalSince1970.rounded(.down))
        c.capture?.capturedAt = capture?.capturedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        c.geometry = geometry?.quantized()
        c.samplePoint = samplePoint.map { NormalizedPoint(x: round6($0.x), y: round6($0.y)) }
        c.develop = develop?.quantized()
        c.enhance = enhance?.quantized()
        c.colorAuto = colorAuto?.quantized()
        return c
    }

    /// Decode a packet. `strict` rejects any attribute in the Film or FilmPositive
    /// namespaces this schema does not know. Lenient reads what it understands. Foreign
    /// namespaces are never an error.
    public static func decode(_ data: Data, liveSource: SidecarSource, strict: Bool = false) throws -> Sidecar {
        let packet = try XMPSidecarCodec.parse(data)
        return try XMPSidecarCodec.decode(packet.fields, liveSource: liveSource, strict: strict)
    }

    /// Canonical bytes for a fresh file (no foreign content to preserve).
    public func encoded() throws -> Data {
        try XMPSidecarCodec.encode(self, into: XMPSidecarCodec.emptyPacket())
    }
}

public struct SidecarSource: Equatable, Sendable {
    public var name: String
    public var size: Int
    public var mtime: Date
    /// "sha256:<hex>" over the first 64 KB of the image file. `SidecarStore.load` compares
    /// it and the size with the live image. Compute with SidecarStore.fingerprint(of:).
    public var fingerprint: String

    public init(name: String, size: Int, mtime: Date, fingerprint: String) {
        self.name = name; self.size = size; self.mtime = mtime; self.fingerprint = fingerprint
    }
}

/// What Film Tether knows at capture. Every field optional, written only when known.
/// `camera` is the film camera (tiff:Model, full name), not the scanner: it becomes the
/// exported Make/Model.
public struct CaptureInfo: Equatable, Sendable {
    public var camera: String?
    public var cameraMake: String?
    public var film: String?
    public var filmMaker: String?
    public var filmSizeID: String?
    /// The format in words (`Film:FilmSizeName`): the size row's plain name ("120 6x7"),
    /// or free text when the person chose Other ("127 roll"). Written beside `filmSizeID`
    /// when there is one, alone when there is not.
    public var filmSizeName: String?
    public var scannerMake: String?
    public var scannerModel: String?
    public var capturedAt: Date?
    /// The day the frame was shot, "YYYY-MM-DD" (`Film:TakenOn`). A calendar day, not an
    /// instant, so it is a string: a Date would drag a time zone into a fact that has none.
    public var takenOn: String?

    public init(camera: String? = nil, cameraMake: String? = nil, film: String? = nil, filmMaker: String? = nil,
                filmSizeID: String? = nil, filmSizeName: String? = nil, scannerMake: String? = nil, scannerModel: String? = nil,
                capturedAt: Date? = nil, takenOn: String? = nil) {
        self.camera = camera; self.cameraMake = cameraMake; self.film = film; self.filmMaker = filmMaker
        self.filmSizeID = filmSizeID; self.filmSizeName = filmSizeName; self.scannerMake = scannerMake; self.scannerModel = scannerModel
        self.capturedAt = capturedAt; self.takenOn = takenOn
    }

    /// A size name trimmed, or nil when nothing is left. The codec runs it on write and read.
    public static func cleanName(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `value`, trimmed, when it reads as a calendar day "YYYY-MM-DD" from the year 1800 on,
    /// else nil. The codec runs it on write and read.
    public static func validDay(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1800...9999).contains(y), (1...12).contains(m), d >= 1 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first), days.contains(d) else { return nil }
        return t
    }
}

public struct NormalizedPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CropRect: Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// Shared geometry. Apply order is fixed: straighten, crop, rotate, flip.
public struct GeometrySettings: Equatable, Sendable {
    /// Quarter turns clockwise: 0, 90, 180 or 270.
    public var rotate: Int
    /// Mirror horizontally (emulsion-side scans).
    public var flip: Bool
    public var straightenDegrees: Double
    public var crop: CropRect?

    public init(rotate: Int = 0, flip: Bool = false, straightenDegrees: Double = 0, crop: CropRect? = nil) {
        self.rotate = rotate; self.flip = flip; self.straightenDegrees = straightenDegrees; self.crop = crop
    }

    public var isIdentity: Bool { rotate == 0 && !flip && straightenDegrees == 0 && crop == nil }

    func quantized() -> GeometrySettings {
        var c = self
        if let r = crop { c.crop = CropRect(x: round6(r.x), y: round6(r.y), w: round6(r.w), h: round6(r.h)) }
        c.straightenDegrees = round6(straightenDegrees)
        return c
    }
}

public struct BaseRatios: Codable, Equatable, Sendable {
    public var rg: Double
    public var bg: Double
    public init(rg: Double, bg: Double) { self.rg = rg; self.bg = bg }
}

/// The two develop-stage color axes, in printer points.
///
/// A printer point is the unit a film lab grades in, 0.025 log exposure units. Kodak
/// H-61d gives that figure, and FIAF's technical glossary defines a point as "a unit of
/// printing light control ... one point is 0.025LogE". These axes offset `log10(base_c)`,
/// an additive log-exposure offset on one channel at the printing stage, which is the
/// operation a printer point measures.
///
/// As a check, Kodak H-61d puts 7 printer lights at one camera stop. A stop is 0.30 logE at
/// the scene, and a C-41 film gamma of 0.56 makes that 0.168 density, or 6.72 points, within
/// 4 percent of Kodak's 7. Published points-per-stop figures run from 6 to 12, because the
/// figure tracks negative gamma.
///
/// Green is held exactly. The tone step and the physics normalization read only the green
/// histogram, so holding green leaves tone placement bit-identical and these sliders cannot
/// change the tone curve or the exposure. Holding red would be very slightly better
/// conditioned, which does not outweigh keeping tone placement unchanged.
///
/// The labels describe what the picture does, not what the printer light does. Lab printer
/// values name the color of the light, so `+R` there makes a print more cyan, and that
/// polarity would invert every label.
public struct ColourAxes: Codable, Equatable, Sendable {
    /// Cool to Warm. Positive is warmer: red up, blue down by the same density.
    public var warm: Double
    /// Green to Magenta. Positive is more magenta: red and blue up together against green.
    public var green: Double

    public init(warm: Double = 0, green: Double = 0) { self.warm = warm; self.green = green }

    public static let identity = ColourAxes()
    public var isIdentity: Bool { warm == 0 && green == 0 }

    /// Held to the 3 decimal grain the XMP writes, so a round trip compares equal.
    func quantized() -> ColourAxes { ColourAxes(warm: round3(warm), green: round3(green)) }

    /// One printer point, in density. FIAF and Kodak both.
    public static let densityPerPoint = 0.025

    /// The per-channel log10 offsets these axes apply to the base. Green is exactly 0,
    /// because tone placement reads the green channel.
    public var logOffsets: (r: Double, g: Double, b: Double) {
        let w = warm * Self.densityPerPoint
        let m = green * Self.densityPerPoint
        return (r: w + m, g: 0, b: -w + m)
    }

    /// The axes applied to a resolved base pair, as a delta rather than an absolute.
    ///
    /// A delta composes with whatever base the edge reader finds, where an absolute would
    /// fix the base at the value read when the axes were set. Because the base is
    /// `[g * rg, g, g * bg]`, offsetting red and blue is exactly a multiplicative delta on the
    /// two ratios, and green never appears.
    public func applied(to r: BaseRatios) -> BaseRatios {
        guard !isIdentity else { return r }
        let o = logOffsets
        return BaseRatios(rg: r.rg * pow(10, o.r), bg: r.bg * pow(10, o.b))
    }
}

public struct BaseSettings: Equatable, Sendable {
    public enum Mode: String, Sendable { case anchor, measured }
    public var mode: Mode
    /// Green base code value for anchor mode (this frame's clip-guarded P99.8 green).
    public var anchor: Int?
    public var ratios: BaseRatios?
    /// Per-channel measured base code values for measured mode.
    public var measured: [Int]?

    public init(mode: Mode, anchor: Int? = nil, ratios: BaseRatios? = nil, measured: [Int]? = nil) {
        self.mode = mode; self.anchor = anchor; self.ratios = ratios; self.measured = measured
    }

    func quantized() -> BaseSettings {
        var c = self
        if let r = ratios { c.ratios = BaseRatios(rg: round4(r.rg), bg: round4(r.bg)) }
        return c
    }
}

/// How the develop pass turns the inverted negative into something to look at.
///
/// `none` is the raw inversion through the preset with no tone step at all. `flat` is the
/// anchored auto tone: a scene-referred, editable base that places the measured black and
/// applies a bounded exponent. `print` is the lab-print contrast operator.
public enum ToneMode: String, Codable, Equatable, Sendable {
    case none, flat
    /// Stored as `print` while the app labels it Bold. The stored value never follows the
    /// label, so renaming the label never changes what a sidecar reads back as.
    case print
}

public struct DevelopSettings: Equatable, Sendable {
    public var stock: String
    // There is no scanner field. A `Light` attribute (a retired scanner calibration id) in
    // an older sidecar is accepted and ignored, and is never written. The deprecated
    // initializers below accept `light:` and ignore it.
    public var tone: ToneMode
    /// Whether the base pair may be measured from this frame (the film edge when one is
    /// readable). Off means the base is exactly the preset and every correction is the
    /// user's, in Enhance.
    ///
    /// Absent from an older sidecar, which read as on, so that is the default here.
    public var autoBalance: Bool
    public var base: BaseSettings
    /// The two manual color axes, in printer points. Identity by default.
    ///
    /// This, `toneAdjust`, `stretch` and `highlightAxes` change only when a person moves a control.
    /// No automatic step may write them.
    public var colourAxes: ColourAxes = .identity
    /// The person's own tone values, set by the Tone row's Adjust. nil is the default
    /// and means the tone preset's own values. Manual only, like `colourAxes`.
    public var toneAdjust: ToneAdjust? = nil
    /// The Tone row's Stretch, 0...1: where white comes from. 1 maps the frame's own
    /// densest green to white, and 0 takes white from the film's own normal density. nil
    /// is the default and means 1. Manual only, like `colourAxes`.
    ///
    /// Stored as given. The codec clamps a finite value outside 0...1 on read, so a
    /// hand-edited file never hands the app an impossible value.
    public var stretch: Double? = nil
    /// The Stock row's Adjust: the same two axes as `colourAxes`, in printer points,
    /// acting on the stock's highlight end rather than on the base. Identity by default,
    /// and manual only, like `colourAxes`.
    public var highlightAxes: ColourAxes = .identity

    /// The two-state tone flag, for call sites that do not use `ToneMode`. `flat` is
    /// `true` and `none` is `false`.
    ///
    /// The setter is lossy on purpose: assigning to it on a sidecar whose tone is `print`
    /// moves it to `flat` or `none`, because a two-state writer has no way to say `print`.
    /// New code sets `tone` directly.
    public var autoTone: Bool {
        get { tone == .flat }
        set { tone = newValue ? .flat : .none }
    }

    /// Whether the develop pass runs a tone step at all.
    ///
    /// This is the one the render path and the legacy `AutoTone` attribute both read, and
    /// it differs from `autoTone` in exactly one case: `print`, which is a tone step.
    public var appliesTone: Bool { tone != .none }

    public init(stock: String, tone: ToneMode = .flat, autoBalance: Bool = true,
                base: BaseSettings) {
        self.stock = stock; self.tone = tone
        self.autoBalance = autoBalance; self.base = base
    }

    /// The two-state spelling: `autoTone: true` is `.flat`, `false` is `.none`.
    public init(stock: String, autoTone: Bool, base: BaseSettings) {
        self.init(stock: stock, tone: autoTone ? .flat : .none, base: base)
    }

    /// Accepts `light`, the retired scanner calibration id, and ignores it, so callers that
    /// still pass it keep compiling.
    @available(*, deprecated, message: "light is ignored. Drop the argument.")
    public init(stock: String, light: String, tone: ToneMode = .flat, autoBalance: Bool = true,
                base: BaseSettings) {
        self.init(stock: stock, tone: tone, autoBalance: autoBalance, base: base)
    }

    /// The two-state spelling with the retired `light`, which is ignored.
    @available(*, deprecated, message: "light is ignored. Drop the argument.")
    public init(stock: String, light: String, autoTone: Bool, base: BaseSettings) {
        self.init(stock: stock, autoTone: autoTone, base: base)
    }

    func quantized() -> DevelopSettings {
        var c = self
        c.base = base.quantized()
        c.toneAdjust = toneAdjust?.quantized()
        c.stretch = stretch.map(round4)
        c.highlightAxes = highlightAxes.quantized()
        return c
    }
}

/// A person's own tone values, set by the Tone row's Adjust. nil means "the preset's own".
public struct ToneAdjust: Equatable, Sendable {
    /// Density units added at the tone step. Positive values darken (one stop is 0.30).
    public var exposure: Double
    /// The slope applied in density space about mid gray. 1.0 is no change.
    public var contrast: Double
    /// Where black is placed in the output, 0...1.
    public var black: Double
    /// Where white is placed in the output, 0...1.
    public var white: Double

    public init(exposure: Double, contrast: Double, black: Double, white: Double) {
        self.exposure = exposure; self.contrast = contrast; self.black = black; self.white = white
    }

    var values: [Double] { [exposure, contrast, black, white] }

    /// Held to the 4 decimal grain the XMP writes, so a round trip compares equal.
    func quantized() -> ToneAdjust {
        ToneAdjust(exposure: round4(exposure), contrast: round4(contrast), black: round4(black), white: round4(white))
    }
}

/// A Warmth and Tint pair on the enhance scale, held to the same 4 decimal grain as the
/// sliders so a pair written beside them compares equal to them after a round trip.
public struct WarmthTint: Equatable, Sendable {
    public var warmth: Double
    public var tint: Double

    public init(warmth: Double, tint: Double) {
        self.warmth = warmth
        self.tint = tint
    }

    func quantized() -> WarmthTint { WarmthTint(warmth: round4(warmth), tint: round4(tint)) }
}

/// The enhance layer: Film Positive's sliders, levels and curves.
/// Sliders are nominally -1...1 with 0 as identity unless noted below.
public struct EnhanceSettings: Equatable, Sendable {
    public var radiance: Double = 0
    public var exposure: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var contrast: Double = 0
    public var brightness: Double = 0
    public var blackPoint: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    public var definition: Double = 0
    public var sharpness: Double = 0
    public var noiseReduction: Double = 0
    public var vignette: Double = 0
    /// A neutral bloom of the highlights. Nominally 0...1 with 0 as identity, and the render
    /// clamps a negative to 0.
    public var glow: Double = 0
    /// Film's red halo around the brightest areas. Nominally 0...1 with 0 as identity.
    public var halation: Double = 0
    /// Fine detail lowered everywhere, a blend with a blurred copy. Nominally 0...1, 0 identity.
    public var softness: Double = 0
    /// The chroma of the less colorful pixels lifted, most in the shadows and least in the
    /// highlights, with hue and lightness held. Negative mutes in the same shape. Nominally
    /// -1...1, 0 identity, and absent reads as 0, so a sidecar without it renders unchanged.
    public var richness: Double = 0
    /// The size of the vignette, the second of its three sliders (`vignette` is the amount).
    /// 0 is the default shape, nominally -1...1 (the app clamps), and absent reads as 0.
    /// Written `FilmPositive:VignetteSize`.
    public var vignetteSize: Double = 0
    /// The softness of the vignette's edge, labeled "Softness" on screen. Stored as
    /// `vignetteFeather` because `VignetteSoftness` and `Softness` share a suffix, which the
    /// naming rule forbids in either direction (see `XMPField.positiveKnown`). 0 is the
    /// default edge, nominally -1...1 (the app clamps), and absent reads as 0. Written
    /// `FilmPositive:VignetteFeather`.
    public var vignetteFeather: Double = 0
    /// Levels on the developed picture. Identity by default, written only when moved.
    public var levels: Levels = .identity
    /// The four tone curves. Identity by default, each written only when moved.
    public var curves: Curves = .identity

    public static let identity = EnhanceSettings()
    /// The slider names, in the order `values` and `subscript(slider:)` use. The three must
    /// change together. The XMP codec writes and reads each slider under its name, so the
    /// order is not in the file.
    public static let sliderKeys = ["radiance", "exposure", "highlights", "shadows", "contrast",
                                    "brightness", "blackPoint", "vibrance", "saturation", "warmth",
                                    "tint", "definition", "sharpness", "noiseReduction", "vignette",
                                    "glow", "halation", "softness", "richness", "vignetteSize",
                                    "vignetteFeather"]

    public init() {}

    public init(radiance: Double = 0, exposure: Double = 0, highlights: Double = 0, shadows: Double = 0,
                contrast: Double = 0, brightness: Double = 0, blackPoint: Double = 0, vibrance: Double = 0,
                saturation: Double = 0, warmth: Double = 0, tint: Double = 0, definition: Double = 0,
                sharpness: Double = 0, noiseReduction: Double = 0, vignette: Double = 0,
                glow: Double = 0, halation: Double = 0, softness: Double = 0, richness: Double = 0,
                vignetteSize: Double = 0, vignetteFeather: Double = 0,
                levels: Levels = .identity, curves: Curves = .identity) {
        self.radiance = radiance; self.exposure = exposure; self.highlights = highlights
        self.shadows = shadows; self.contrast = contrast; self.brightness = brightness
        self.blackPoint = blackPoint; self.vibrance = vibrance; self.saturation = saturation
        self.warmth = warmth; self.tint = tint; self.definition = definition
        self.sharpness = sharpness; self.noiseReduction = noiseReduction; self.vignette = vignette
        self.glow = glow; self.halation = halation; self.softness = softness
        self.richness = richness; self.vignetteSize = vignetteSize; self.vignetteFeather = vignetteFeather
        self.levels = levels; self.curves = curves
    }

    /// The sliders only, in `sliderKeys` order. Levels and curves are not sliders.
    public var values: [Double] {
        [radiance, exposure, highlights, shadows, contrast, brightness, blackPoint, vibrance,
         saturation, warmth, tint, definition, sharpness, noiseReduction, vignette, glow, halation,
         softness, richness, vignetteSize, vignetteFeather]
    }

    public var isIdentity: Bool { values.allSatisfy { $0 == 0 } && levels.isIdentity && curves.isIdentity }

    func quantized() -> EnhanceSettings {
        var c = EnhanceSettings()
        for i in 0..<EnhanceSettings.sliderKeys.count { c[slider: i] = round4(values[i]) }
        c.levels = levels.quantized()
        c.curves = curves.quantized()
        return c
    }
}

/// Levels on the developed picture, set in Enhance. All five on a 0...1 scale except gamma.
/// Written as `FilmPositive:Levels="inBlack gamma inWhite outBlack outWhite"`, at most 4
/// decimals, absent at identity.
public struct Levels: Equatable, Sendable, Codable {
    /// Input black point, default 0.
    public var inBlack: Double
    /// Midtone gamma, default 1, above 1 is brighter.
    public var gamma: Double
    /// Input white point, default 1.
    public var inWhite: Double
    /// Output black, default 0.
    public var outBlack: Double
    /// Output white, default 1.
    public var outWhite: Double

    public init(inBlack: Double = 0, gamma: Double = 1, inWhite: Double = 1, outBlack: Double = 0, outWhite: Double = 1) {
        self.inBlack = inBlack; self.gamma = gamma; self.inWhite = inWhite
        self.outBlack = outBlack; self.outWhite = outWhite
    }

    public static let identity = Levels()
    public var isIdentity: Bool { self == .identity }

    /// In the order the XMP writes them.
    var values: [Double] { [inBlack, gamma, inWhite, outBlack, outWhite] }

    /// Held to the 4 decimal grain the XMP writes, so a round trip compares equal.
    func quantized() -> Levels {
        Levels(inBlack: round4(inBlack), gamma: round4(gamma), inWhite: round4(inWhite),
               outBlack: round4(outBlack), outWhite: round4(outWhite))
    }
}

/// One control point of a tone curve, x and y in 0...1.
public struct CurvePoint: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One tone curve as control points, x and y in 0...1, sorted by x, x strictly increasing.
/// Identity is the two end points (0,0) and (1,1). Only the points live here: how the curve
/// is interpolated between them is the app's business, not this package's.
public struct CurvePoints: Equatable, Sendable, Codable {
    public var points: [CurvePoint]

    /// Stores `points` as given. The app should build a curve with `init(sanitising:)`, which
    /// is what guarantees the reader will accept it.
    public init(points: [CurvePoint]) { self.points = points }

    /// A curve the XMP reader will always accept: non-finite points dropped, x and y clamped
    /// to 0...1 and held to the 4 decimal grain the XMP writes, sorted by x, a point whose x
    /// repeats (at that grain) dropped with the first in input order kept, and the count capped
    /// at `maxPoints` by dropping interior points from the high end so both end points stay.
    /// Fewer than two points left is identity.
    public init(sanitising raw: [CurvePoint]) {
        let held = raw.enumerated()
            .filter { $0.element.x.isFinite && $0.element.y.isFinite }
            .map { (i: $0.offset, p: CurvePoint(x: round4(min(max($0.element.x, 0), 1)),
                                                y: round4(min(max($0.element.y, 0), 1)))) }
            .sorted { $0.p.x != $1.p.x ? $0.p.x < $1.p.x : $0.i < $1.i }
        var kept: [CurvePoint] = []
        for h in held where kept.last.map({ $0.x < h.p.x }) ?? true { kept.append(h.p) }
        if kept.count > Self.maxPoints { kept = Array(kept.prefix(Self.maxPoints - 1)) + [kept[kept.count - 1]] }
        self.points = kept.count >= 2 ? kept : Self.identity.points
    }

    public static let identity = CurvePoints(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
    /// Exactly the two identity end points. A straight line through more points is stored as
    /// the person set it and is not identity.
    public var isIdentity: Bool { self == .identity }
    public static let maxPoints = 16

    /// Held to the written grain, re-sanitized so rounding can never produce a curve the
    /// reader would refuse (two x values that meet at 4 decimals, say).
    func quantized() -> CurvePoints { isIdentity ? self : CurvePoints(sanitising: points) }
}

/// The four curves Enhance carries: all channels together, then red, green and blue alone.
/// Written as `FilmPositive:CurveRGB`, `CurveRed`, `CurveGreen` and `CurveBlue`, each
/// `"x,y x,y ..."` at most 4 decimals and absent when that curve is identity.
public struct Curves: Equatable, Sendable {
    public var rgb: CurvePoints
    public var red: CurvePoints
    public var green: CurvePoints
    public var blue: CurvePoints

    public init(rgb: CurvePoints = .identity, red: CurvePoints = .identity,
                green: CurvePoints = .identity, blue: CurvePoints = .identity) {
        self.rgb = rgb; self.red = red; self.green = green; self.blue = blue
    }

    public static let identity = Curves()
    public var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }

    func quantized() -> Curves {
        Curves(rgb: rgb.quantized(), red: red.quantized(), green: green.quantized(), blue: blue.quantized())
    }
}

/// JSON form: each curve encoded only when not identity, absent decodes as identity, the same
/// absent-means-default rule as the sliders.
extension Curves: Codable {
    enum CodingKeys: String, CodingKey { case rgb, red, green, blue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get(_ k: CodingKeys) throws -> CurvePoints { try c.decodeIfPresent(CurvePoints.self, forKey: k) ?? .identity }
        self.init(rgb: try get(.rgb), red: try get(.red), green: try get(.green), blue: try get(.blue))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ v: CurvePoints, _ k: CodingKeys) throws { if !v.isIdentity { try c.encode(v, forKey: k) } }
        try put(rgb, .rgb); try put(red, .red); try put(green, .green); try put(blue, .blue)
    }
}

@inline(__always) func round3(_ v: Double) -> Double { (v * 1_000).rounded() / 1_000 }
@inline(__always) func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
@inline(__always) func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }

public enum SidecarDecodeError: Error, Equatable, CustomStringConvertible {
    case unknownKeys([String])

    public var description: String {
        switch self {
        case .unknownKeys(let k): return "sidecar has fields outside schema v1: \(k.joined(separator: ", "))"
        }
    }
}

/// JSON form for look files and any other document that carries sliders: keys are the
/// sidecar slider names, absent means zero (so an identity look is an empty object), the
/// same rule the XMP codec applies. `levels` and `curves` follow it too: encoded only when
/// not identity, absent decodes as identity.
extension EnhanceSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case radiance, exposure, highlights, shadows, contrast, brightness, blackPoint, vibrance, saturation, warmth, tint,
             definition, sharpness, noiseReduction, vignette, glow, halation, softness, richness, vignetteSize, vignetteFeather,
             levels, curves
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        self.init(radiance: try get(.radiance), exposure: try get(.exposure), highlights: try get(.highlights), shadows: try get(.shadows),
                  contrast: try get(.contrast), brightness: try get(.brightness), blackPoint: try get(.blackPoint), vibrance: try get(.vibrance),
                  saturation: try get(.saturation), warmth: try get(.warmth), tint: try get(.tint), definition: try get(.definition),
                  sharpness: try get(.sharpness), noiseReduction: try get(.noiseReduction), vignette: try get(.vignette),
                  glow: try get(.glow), halation: try get(.halation), softness: try get(.softness),
                  richness: try get(.richness), vignetteSize: try get(.vignetteSize), vignetteFeather: try get(.vignetteFeather),
                  levels: try c.decodeIfPresent(Levels.self, forKey: .levels) ?? .identity,
                  curves: try c.decodeIfPresent(Curves.self, forKey: .curves) ?? .identity)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ v: Double, _ k: CodingKeys) throws { if v != 0 { try c.encode(v, forKey: k) } }
        try put(radiance, .radiance); try put(exposure, .exposure); try put(highlights, .highlights); try put(shadows, .shadows)
        try put(contrast, .contrast); try put(brightness, .brightness); try put(blackPoint, .blackPoint); try put(vibrance, .vibrance)
        try put(saturation, .saturation); try put(warmth, .warmth); try put(tint, .tint); try put(definition, .definition)
        try put(sharpness, .sharpness); try put(noiseReduction, .noiseReduction); try put(vignette, .vignette)
        try put(glow, .glow); try put(halation, .halation); try put(softness, .softness)
        try put(richness, .richness); try put(vignetteSize, .vignetteSize); try put(vignetteFeather, .vignetteFeather)
        if !levels.isIdentity { try c.encode(levels, forKey: .levels) }
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
    }
}
