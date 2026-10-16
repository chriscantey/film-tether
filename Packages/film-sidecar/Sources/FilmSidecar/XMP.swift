import Foundation

// XMP codec for the shared sidecar. One `<base>.xmp` per image holds:
//   standard open namespaces (tiff, dc, AnalogExif),
//   Film:          the shared namespace, one copy of every value both apps edit,
//   FilmTether:    what only Tether owns,
//   FilmPositive:  what only Film Positive owns (develop, enhance, look, colorAuto).
// Everything else in the file (Adobe's crs:, extra rdf:Description blocks, elements)
// is preserved on rewrite. The fields this codec reads and writes are flat
// attributes on rdf:Description.

public enum XMPNamespace {
    public static let x = "adobe:ns:meta/"
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let tiff = "http://ns.adobe.com/tiff/1.0/"
    public static let dc = "http://purl.org/dc/elements/1.1/"
    public static let analogExif = "http://analogexif.sourceforge.net/ns"
    public static let film = "https://github.com/chriscantey/film-sidecar/ns/1.0/"
    public static let tether = "https://github.com/chriscantey/film-tether/ns/1.0/"
    public static let positive = "https://github.com/chriscantey/film-positive/ns/1.0/"

    /// Preferred prefix per namespace when this codec has to declare one.
    static let prefix: [String: String] = [
        tiff: "tiff", dc: "dc", analogExif: "AnalogExif", film: "Film", tether: "FilmTether", positive: "FilmPositive",
    ]
}

/// A field key: namespace URI plus local name, independent of whatever prefix a file used.
public struct XMPKey: Hashable, Sendable, CustomStringConvertible {
    public let ns: String
    public let name: String
    public init(_ ns: String, _ name: String) { self.ns = ns; self.name = name }
    public var description: String { (XMPNamespace.prefix[ns] ?? ns) + ":" + name }
}

public enum XMPError: Error, CustomStringConvertible {
    case notXMP(String)
    public var description: String {
        switch self { case .notXMP(let m): return "not an XMP packet: \(m)" }
    }
}

/// The fields this codec knows, by namespace.
enum XMPField {
    // Film: shared
    static let version = XMPKey(XMPNamespace.film, "Version")
    static let sourceName = XMPKey(XMPNamespace.film, "SourceName")
    static let sourceSize = XMPKey(XMPNamespace.film, "SourceSize")
    static let sourceMTime = XMPKey(XMPNamespace.film, "SourceMTime")
    static let sourceFingerprint = XMPKey(XMPNamespace.film, "SourceFingerprint")
    static let rotate = XMPKey(XMPNamespace.film, "Rotate")
    static let flip = XMPKey(XMPNamespace.film, "Flip")
    static let straighten = XMPKey(XMPNamespace.film, "StraightenDeg")
    static let cropX = XMPKey(XMPNamespace.film, "CropX")
    static let cropY = XMPKey(XMPNamespace.film, "CropY")
    static let cropW = XMPKey(XMPNamespace.film, "CropW")
    static let cropH = XMPKey(XMPNamespace.film, "CropH")
    static let sampleX = XMPKey(XMPNamespace.film, "BaseSampleX")
    static let sampleY = XMPKey(XMPNamespace.film, "BaseSampleY")
    static let filmSizeID = XMPKey(XMPNamespace.film, "FilmSizeID")
    /// The format as a person reads it: the size row's plain name, or what they typed
    /// under Other. Beside the id so a reader that does not know an id can still show it.
    static let filmSizeName = XMPKey(XMPNamespace.film, "FilmSizeName")
    static let scannerMake = XMPKey(XMPNamespace.film, "ScannerMake")
    static let scannerModel = XMPKey(XMPNamespace.film, "ScannerModel")
    static let capturedAt = XMPKey(XMPNamespace.film, "CapturedAt")
    /// The day the frame was shot, "YYYY-MM-DD", no time and no zone (see
    /// `CaptureInfo.takenOn`). Typed by a person (Tether at capture, Positive after).
    static let takenOn = XMPKey(XMPNamespace.film, "TakenOn")
    static let filmKnown: Set<String> = ["Version", "SourceName", "SourceSize", "SourceMTime", "SourceFingerprint",
                                         "Rotate", "Flip", "StraightenDeg", "CropX", "CropY", "CropW", "CropH",
                                         "BaseSampleX", "BaseSampleY", "FilmSizeID", "FilmSizeName", "ScannerMake", "ScannerModel", "CapturedAt", "TakenOn"]

    // standard provenance
    static let make = XMPKey(XMPNamespace.tiff, "Make")
    static let model = XMPKey(XMPNamespace.tiff, "Model")
    static let film = XMPKey(XMPNamespace.analogExif, "Film")
    static let filmMaker = XMPKey(XMPNamespace.analogExif, "FilmMaker")

    // Crop fields in the FilmTether namespace. Fallbacks only: decode(_:liveSource:strict:)
    // reads the crop and straighten when the file has none of Film:CropX, Rotate, Flip and
    // StraightenDeg, and the size id when Film:FilmSizeID is absent.
    static let tetherCropX = XMPKey(XMPNamespace.tether, "CropX")
    static let tetherCropY = XMPKey(XMPNamespace.tether, "CropY")
    static let tetherCropW = XMPKey(XMPNamespace.tether, "CropW")
    static let tetherCropH = XMPKey(XMPNamespace.tether, "CropH")
    static let tetherStraighten = XMPKey(XMPNamespace.tether, "CropStraightenDeg")
    static let tetherFilmSizeID = XMPKey(XMPNamespace.tether, "CropFilmSizeID")

    // FilmPositive
    static func positive(_ n: String) -> XMPKey { XMPKey(XMPNamespace.positive, n) }
    /// **Never name a field so that an existing field's name in the same namespace ends
    /// with it.** Foundation's `XMLElement.addAttribute` silently drops such an attribute,
    /// and assigning the whole `attributes` array does the same thing. Probed on macOS 26.5
    /// with names in one namespace: adding `AutoTone` then
    /// `Tone` leaves only `AutoTone`, and `Look` then `ok` leaves only `Look`. The reverse
    /// order keeps both. Nothing throws and nothing logs, so the field is simply not in the
    /// file.
    ///
    /// That is why the tone mode is stored as `ToneMode` rather than `Tone`.
    /// `testEncodeLandsEveryAttribute` is the canary for the class: it encodes a sidecar
    /// and asserts every key in `attributes(for:)` came back, so a colliding name that the
    /// test sets fails a test instead of losing somebody's edit.
    ///
    /// `Light` stays in this set though nothing reads or writes it (the retired
    /// scanner calibration id): an old sidecar carrying it must still pass a
    /// strict decode, and every key in our namespace is stripped on rewrite, so it drops
    /// out of a file the first time that file is saved.
    static let positiveKnown: Set<String> = Set(["Stock", "Light", "AutoTone", "ToneMode", "AutoBalance",
                                                 "BaseMode", "BaseAnchor", "BaseRG", "BaseBG",
                                                 "BaseMeasured", "BaseWarmPoints", "BaseGreenPoints", "Look",
                                                 "ColorAuto", "ToneAdjust", "Stretch", "HighlightAxes", "Levels",
                                                 "CurveRGB", "CurveRed", "CurveGreen", "CurveBlue"]).union(EnhanceSettings.sliderKeys.map { $0.xmpName })
}

extension String {
    /// "blackPoint" -> "BlackPoint": XMP attribute names are capitalized.
    var xmpName: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - formatting

enum XMPFormat {
    static func num(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }
    static func bool(_ b: Bool) -> String { b ? "True" : "False" }
    static func parseBool(_ s: String?) -> Bool? {
        guard let s else { return nil }
        switch s.lowercased() { case "true": return true; case "false": return false; default: return nil }
    }
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    /// Exactly `count` finite numbers separated by spaces, or nil. Every token must parse,
    /// so "1 x 2" is not two numbers.
    static func numbers(_ s: String?, count: Int) -> [Double]? {
        guard let parts = s?.split(separator: " ").map({ Double($0) }), parts.count == count else { return nil }
        let v = parts.compactMap { $0 }.filter(\.isFinite)
        return v.count == count ? v : nil
    }

    /// A curve written "x,y x,y ...", read strictly: single spaces between points, one comma
    /// in each, both numbers finite and in 0...1, 2 to `CurvePoints.maxPoints` points, and x
    /// strictly increasing once held to 4 decimals. Anything else is nil.
    static func curve(_ s: String?) -> CurvePoints? {
        guard let s else { return nil }
        var points: [CurvePoint] = []
        for token in s.split(separator: " ", omittingEmptySubsequences: false) {
            let xy = token.split(separator: ",", omittingEmptySubsequences: false)
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]),
                  (0...1).contains(x), (0...1).contains(y) else { return nil }
            let p = CurvePoint(x: round4(x), y: round4(y))
            if let last = points.last, !(last.x < p.x) { return nil }
            points.append(p)
        }
        guard (2...CurvePoints.maxPoints).contains(points.count) else { return nil }
        return CurvePoints(points: points)
    }

    static func curve(_ c: CurvePoints) -> String {
        c.points.map { num($0.x, decimals: 4) + "," + num($0.y, decimals: 4) }.joined(separator: " ")
    }
}

// MARK: - the codec

public enum XMPSidecarCodec {

    /// A parsed packet: attributes from the rdf:Description elements, keyed by namespace
    /// and local name, plus the document for preserving rewrites.
    public struct Packet {
        public let document: XMLDocument
        public let fields: [XMPKey: String]
    }

    public static func parse(_ data: Data) throws -> Packet {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: [.nodePreserveAll]) }
        catch { throw XMPError.notXMP("XML parse failed: \(error)") }
        guard let rdf = rdfElement(in: doc) else { throw XMPError.notXMP("no rdf:RDF element") }
        var fields: [XMPKey: String] = [:]
        for d in descriptions(in: rdf) {
            for a in d.attributes ?? [] {
                guard let name = a.name, let local = a.localName, let value = a.stringValue else { continue }
                guard let ns = d.resolveNamespace(forName: name)?.stringValue else { continue }
                fields[XMPKey(ns, local)] = value
            }
        }
        return Packet(document: doc, fields: fields)
    }

    /// The rdf:RDF element of a packet. Public so a co-writer can work on the same document.
    public static func rdfElement(in doc: XMLDocument) -> XMLElement? {
        guard let root = doc.rootElement() else { return nil }
        if root.localName == "RDF" { return root }
        return (root.children ?? []).compactMap { $0 as? XMLElement }.first { $0.localName == "RDF" }
    }

    public static func descriptions(in rdf: XMLElement) -> [XMLElement] {
        (rdf.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "Description" }
    }

    /// An empty packet, the shape Adobe tools and Film Tether write.
    public static func emptyPacket() -> XMLDocument {
        let s = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmSidecar">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return try! XMLDocument(xmlString: s, options: [.nodePreserveAll])
    }

    // MARK: decode

    /// Keys in our namespaces that this codec does not know.
    public static func unknownKeys(_ fields: [XMPKey: String]) -> [String] {
        fields.keys.filter {
            ($0.ns == XMPNamespace.film && !XMPField.filmKnown.contains($0.name)) ||
            ($0.ns == XMPNamespace.positive && !XMPField.positiveKnown.contains($0.name))
        }.map(\.description).sorted()
    }

    /// Build a Sidecar from parsed fields. `liveSource` fills `source` when the file was
    /// written by a tool that does not record it (Tether 0.3.0, an Adobe sidecar).
    public static func decode(_ f: [XMPKey: String], liveSource: SidecarSource, strict: Bool = false) throws -> Sidecar {
        if strict {
            let unknown = unknownKeys(f)
            if !unknown.isEmpty { throw SidecarDecodeError.unknownKeys(unknown) }
        }
        let version = f[XMPField.version].flatMap(Int.init) ?? Sidecar.currentVersion

        var source = liveSource
        if let n = f[XMPField.sourceName], let s = f[XMPField.sourceSize].flatMap(Int.init),
           let m = f[XMPField.sourceMTime].flatMap(XMPFormat.iso.date(from:)), let fp = f[XMPField.sourceFingerprint] {
            source = SidecarSource(name: n, size: s, mtime: m, fingerprint: fp)
        }

        var capture: CaptureInfo? = nil
        let cap = CaptureInfo(camera: f[XMPField.model], cameraMake: f[XMPField.make],
                              film: f[XMPField.film], filmMaker: f[XMPField.filmMaker],
                              filmSizeID: f[XMPField.filmSizeID] ?? f[XMPField.tetherFilmSizeID],
                              filmSizeName: f[XMPField.filmSizeName].flatMap(CaptureInfo.cleanName),
                              scannerMake: f[XMPField.scannerMake], scannerModel: f[XMPField.scannerModel],
                              capturedAt: f[XMPField.capturedAt].flatMap(XMPFormat.iso.date(from:)),
                              takenOn: f[XMPField.takenOn].flatMap(CaptureInfo.validDay))
        if cap != CaptureInfo() { capture = cap }

        var geometry: GeometrySettings? = nil
        let d = { (k: XMPKey) -> Double? in f[k].flatMap(Double.init) }
        let hasShared = f[XMPField.cropX] != nil || f[XMPField.rotate] != nil || f[XMPField.flip] != nil || f[XMPField.straighten] != nil
        let hasTether = f[XMPField.tetherCropX] != nil || f[XMPField.tetherStraighten] != nil
        if hasShared || hasTether {
            var g = GeometrySettings()
            g.rotate = f[XMPField.rotate].flatMap(Int.init) ?? 0
            g.flip = XMPFormat.parseBool(f[XMPField.flip]) ?? false
            g.straightenDegrees = d(XMPField.straighten) ?? (hasShared ? 0 : (d(XMPField.tetherStraighten) ?? 0))
            if let x = d(XMPField.cropX), let y = d(XMPField.cropY), let w = d(XMPField.cropW), let h = d(XMPField.cropH) {
                g.crop = CropRect(x: x, y: y, w: w, h: h)
            } else if !hasShared, let x = d(XMPField.tetherCropX), let y = d(XMPField.tetherCropY),
                      let w = d(XMPField.tetherCropW), let h = d(XMPField.tetherCropH) {
                g.crop = CropRect(x: x, y: y, w: w, h: h)
            }
            geometry = g
        }

        var samplePoint: NormalizedPoint? = nil
        if let x = d(XMPField.sampleX), let y = d(XMPField.sampleY) { samplePoint = NormalizedPoint(x: x, y: y) }

        var develop: DevelopSettings? = nil
        // `Light`, the retired scanner calibration id, is not required and not read. An
        // older reader that still requires it will not see the develop layer in a sidecar
        // written without it.
        if let stock = f[XMPField.positive("Stock")] {
            let mode = BaseSettings.Mode(rawValue: f[XMPField.positive("BaseMode")] ?? "anchor") ?? .anchor
            var base = BaseSettings(mode: mode)
            base.anchor = f[XMPField.positive("BaseAnchor")].flatMap(Int.init)
            if let rg = d(XMPField.positive("BaseRG")), let bg = d(XMPField.positive("BaseBG")) { base.ratios = BaseRatios(rg: rg, bg: bg) }
            // Absent reads as identity.
            let axes = ColourAxes(warm: d(XMPField.positive("BaseWarmPoints")) ?? 0,
                                  green: d(XMPField.positive("BaseGreenPoints")) ?? 0)
            if let m = f[XMPField.positive("BaseMeasured")] {
                let parts = m.split(separator: " ").compactMap { Int($0) }
                if parts.count == 3 { base.measured = parts }
            }
            // Tone: `ToneMode` wins. Without it, `AutoTone` True reads as `flat` and False as
            // `none`, and a file with neither reads as `flat`.
            let tone = f[XMPField.positive("ToneMode")].flatMap(ToneMode.init(rawValue:))
                ?? ((XMPFormat.parseBool(f[XMPField.positive("AutoTone")]) ?? true) ? .flat : .none)
            // Absent means on: every sidecar written before this field existed was
            // rendered with the base measured from the frame when one was readable.
            let autoBalance = XMPFormat.parseBool(f[XMPField.positive("AutoBalance")]) ?? true
            var dv = DevelopSettings(stock: stock, tone: tone,
                                     autoBalance: autoBalance, base: base)
            dv.colourAxes = axes
            // Absent or malformed reads as the preset's own tone (nil) and identity highlight
            // axes.
            if let t = XMPFormat.numbers(f[XMPField.positive("ToneAdjust")], count: 4) {
                dv.toneAdjust = ToneAdjust(exposure: t[0], contrast: t[1], black: t[2], white: t[3])
            }
            // Absent or malformed reads as nil (a stretch of 1). A finite value outside 0...1
            // is clamped into it, so a hand-edited 1.5 reads as 1.
            if let s = XMPFormat.numbers(f[XMPField.positive("Stretch")], count: 1) {
                dv.stretch = min(max(s[0], 0), 1)
            }
            if let h = XMPFormat.numbers(f[XMPField.positive("HighlightAxes")], count: 2) {
                dv.highlightAxes = ColourAxes(warm: h[0], green: h[1])
            }
            develop = dv
        }

        var enhance: EnhanceSettings? = nil
        var e = EnhanceSettings()
        var any = false
        for (i, key) in EnhanceSettings.sliderKeys.enumerated() {
            if let v = d(XMPField.positive(key.xmpName)) { e[slider: i] = v; any = true }
        }
        // Absent or malformed reads as identity and costs nothing else: a bad curve leaves
        // the other three and the rest of the file as they were.
        if let l = XMPFormat.numbers(f[XMPField.positive("Levels")], count: 5) {
            e.levels = Levels(inBlack: l[0], gamma: l[1], inWhite: l[2], outBlack: l[3], outWhite: l[4])
        }
        if let c = XMPFormat.curve(f[XMPField.positive("CurveRGB")]) { e.curves.rgb = c }
        if let c = XMPFormat.curve(f[XMPField.positive("CurveRed")]) { e.curves.red = c }
        if let c = XMPFormat.curve(f[XMPField.positive("CurveGreen")]) { e.curves.green = c }
        if let c = XMPFormat.curve(f[XMPField.positive("CurveBlue")]) { e.curves.blue = c }
        if !e.levels.isIdentity || !e.curves.isIdentity { any = true }
        if any { enhance = e }

        // "warmth tint": tokens that do not parse as numbers are dropped, and the record is
        // read when exactly two remain, so "1 x 2" reads as (1, 2) and "nan" and "inf"
        // parse. Otherwise it reads as no record, which only costs the Color Auto its lit
        // state, never an edit.
        var colorAuto: WarmthTint? = nil
        if let parts = f[XMPField.positive("ColorAuto")]?.split(separator: " ").compactMap({ Double($0) }),
           parts.count == 2 {
            colorAuto = WarmthTint(warmth: parts[0], tint: parts[1])
        }

        return Sidecar(version: version, source: source, capture: capture, geometry: geometry, samplePoint: samplePoint,
                       develop: develop, enhance: enhance, look: f[XMPField.positive("Look")], colorAuto: colorAuto)
    }

    // MARK: encode

    /// The attributes a sidecar writes, taken from its quantized copy. Absent optional
    /// sections write nothing.
    public static func attributes(for scIn: Sidecar) -> [XMPKey: String] {
        let sc = scIn.quantized()
        var a: [XMPKey: String] = [:]
        a[XMPField.version] = String(sc.version)
        a[XMPField.sourceName] = sc.source.name
        a[XMPField.sourceSize] = String(sc.source.size)
        a[XMPField.sourceMTime] = XMPFormat.iso.string(from: sc.source.mtime)
        a[XMPField.sourceFingerprint] = sc.source.fingerprint
        if let c = sc.capture {
            if let v = c.camera { a[XMPField.model] = v }
            if let v = c.cameraMake { a[XMPField.make] = v }
            if let v = c.film { a[XMPField.film] = v }
            if let v = c.filmMaker { a[XMPField.filmMaker] = v }
            if let v = c.filmSizeID { a[XMPField.filmSizeID] = v }
            if let v = c.filmSizeName.flatMap(CaptureInfo.cleanName) { a[XMPField.filmSizeName] = v }
            if let v = c.scannerMake { a[XMPField.scannerMake] = v }
            if let v = c.scannerModel { a[XMPField.scannerModel] = v }
            if let v = c.capturedAt { a[XMPField.capturedAt] = XMPFormat.iso.string(from: v) }
            if let v = c.takenOn.flatMap(CaptureInfo.validDay) { a[XMPField.takenOn] = v }
        }
        if let g = sc.geometry {
            a[XMPField.rotate] = String(g.rotate)
            a[XMPField.flip] = XMPFormat.bool(g.flip)
            a[XMPField.straighten] = XMPFormat.num(g.straightenDegrees, decimals: 6)
            if let c = g.crop {
                a[XMPField.cropX] = XMPFormat.num(c.x, decimals: 6); a[XMPField.cropY] = XMPFormat.num(c.y, decimals: 6)
                a[XMPField.cropW] = XMPFormat.num(c.w, decimals: 6); a[XMPField.cropH] = XMPFormat.num(c.h, decimals: 6)
            }
        }
        if let p = sc.samplePoint {
            a[XMPField.sampleX] = XMPFormat.num(p.x, decimals: 6); a[XMPField.sampleY] = XMPFormat.num(p.y, decimals: 6)
        }
        if let dv = sc.develop {
            a[XMPField.positive("Stock")] = dv.stock
            a[XMPField.positive("ToneMode")] = dv.tone.rawValue
            a[XMPField.positive("AutoBalance")] = XMPFormat.bool(dv.autoBalance)
            // Kept for a build that predates ToneMode: it reads AutoTone and ignores the
            // rest, so a three-state tone has to degrade to the nearest two-state answer.
            // `print` is lab-print contrast, which is closer to the anchored tone than to
            // no tone at all, so it writes True.
            a[XMPField.positive("AutoTone")] = XMPFormat.bool(dv.appliesTone)
            a[XMPField.positive("BaseMode")] = dv.base.mode.rawValue
            if let v = dv.base.anchor { a[XMPField.positive("BaseAnchor")] = String(v) }
            if let r = dv.base.ratios {
                a[XMPField.positive("BaseRG")] = XMPFormat.num(r.rg, decimals: 4); a[XMPField.positive("BaseBG")] = XMPFormat.num(r.bg, decimals: 4)
            }
            if !dv.colourAxes.isIdentity {
                a[XMPField.positive("BaseWarmPoints")] = XMPFormat.num(dv.colourAxes.warm, decimals: 3)
                a[XMPField.positive("BaseGreenPoints")] = XMPFormat.num(dv.colourAxes.green, decimals: 3)
            }
            if let m = dv.base.measured, m.count == 3 { a[XMPField.positive("BaseMeasured")] = m.map(String.init).joined(separator: " ") }
            // Same number formats as ColorAuto (4 decimals) and BaseWarmPoints (3 decimals),
            // held to that grain by quantized(). A non-finite value is not written: it would
            // read back as absent anyway.
            if let t = dv.toneAdjust, t.values.allSatisfy(\.isFinite) {
                a[XMPField.positive("ToneAdjust")] = t.values.map { XMPFormat.num($0, decimals: 4) }.joined(separator: " ")
            }
            // Written whenever set, 1 included: whether 1 means "unset" is the app's call.
            if let s = dv.stretch, s.isFinite {
                a[XMPField.positive("Stretch")] = XMPFormat.num(s, decimals: 4)
            }
            let h = dv.highlightAxes
            if !h.isIdentity, h.warm.isFinite, h.green.isFinite {
                a[XMPField.positive("HighlightAxes")] = XMPFormat.num(h.warm, decimals: 3) + " " + XMPFormat.num(h.green, decimals: 3)
            }
        }
        if let e = sc.enhance {
            for (i, key) in EnhanceSettings.sliderKeys.enumerated() where e[slider: i] != 0 {
                a[XMPField.positive(key.xmpName)] = XMPFormat.num(e[slider: i], decimals: 4)
            }
            // A non-finite level is not written: it would read back as absent anyway. Curves
            // are already sanitized by quantized().
            if !e.levels.isIdentity, e.levels.values.allSatisfy(\.isFinite) {
                a[XMPField.positive("Levels")] = e.levels.values.map { XMPFormat.num($0, decimals: 4) }.joined(separator: " ")
            }
            for (name, c) in [("CurveRGB", e.curves.rgb), ("CurveRed", e.curves.red),
                              ("CurveGreen", e.curves.green), ("CurveBlue", e.curves.blue)] where !c.isIdentity {
                a[XMPField.positive(name)] = XMPFormat.curve(c)
            }
        }
        if let l = sc.look { a[XMPField.positive("Look")] = l }
        if let c = sc.colorAuto {
            a[XMPField.positive("ColorAuto")] = XMPFormat.num(c.warmth, decimals: 4) + " " + XMPFormat.num(c.tint, decimals: 4)
        }
        return a
    }

    /// Namespaces this codec owns outright: every attribute in them is removed before
    /// ours are written, so a dropped optional field does not linger.
    static let ownedNamespaces: Set<String> = [XMPNamespace.film, XMPNamespace.positive]
    /// Standard fields we may rewrite when the struct carries them.
    static let standardKeys: Set<XMPKey> = [XMPField.make, XMPField.model, XMPField.film, XMPField.filmMaker]

    /// Write the sidecar into `document` (an existing file's packet, or `emptyPacket()`),
    /// preserving everything that is not ours, and return the bytes.
    public static func encode(_ sc: Sidecar, into document: XMLDocument) throws -> Data {
        guard let rdf = rdfElement(in: document) else { throw XMPError.notXMP("no rdf:RDF element") }
        var descs = descriptions(in: rdf)
        if descs.isEmpty {
            let d = XMLElement(name: "rdf:Description")
            d.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
            rdf.addChild(d)
            descs = [d]
        }
        let attrs = attributes(for: sc)

        for d in descs {
            for a in d.attributes ?? [] {
                guard let name = a.name, let local = a.localName,
                      let ns = d.resolveNamespace(forName: name)?.stringValue else { continue }
                let key = XMPKey(ns, local)
                if ownedNamespaces.contains(ns) || (standardKeys.contains(key) && attrs[key] != nil) {
                    d.removeAttribute(forName: name)
                }
            }
        }

        let target = descs[0]
        for (key, value) in attrs.sorted(by: { $0.key.description < $1.key.description }) {
            let prefix = declaredPrefix(for: key.ns, on: target)
            target.addAttribute(XMLNode.attribute(withName: "\(prefix):\(key.name)", stringValue: value) as! XMLNode)
        }

        var data = document.xmlData(options: [.nodePrettyPrint])
        if data.last != 0x0A { data.append(0x0A) }
        return data
    }

    /// The prefix bound to `ns` in scope of `element`, declaring a new one on `element` if
    /// none is.
    public static func declaredPrefix(for ns: String, on element: XMLElement) -> String {
        var node: XMLElement? = element
        while let e = node {
            for n in e.namespaces ?? [] where n.stringValue == ns {
                if let p = n.name, !p.isEmpty { return p }
            }
            node = e.parent as? XMLElement
        }
        var prefix = XMPNamespace.prefix[ns] ?? "ns"
        // the preferred prefix may already be bound to something else in scope
        if let bound = element.resolveNamespace(forName: prefix + ":x")?.stringValue, bound != ns {
            var i = 1
            while element.resolveNamespace(forName: "\(prefix)\(i):x") != nil { i += 1 }
            prefix = "\(prefix)\(i)"
        }
        element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: ns) as! XMLNode)
        return prefix
    }
}

extension EnhanceSettings {
    /// Index access in sliderKeys order, for codecs.
    subscript(slider i: Int) -> Double {
        get { values[i] }
        set {
            switch i {
            case 0: radiance = newValue; case 1: exposure = newValue; case 2: highlights = newValue
            case 3: shadows = newValue; case 4: contrast = newValue; case 5: brightness = newValue
            case 6: blackPoint = newValue; case 7: vibrance = newValue; case 8: saturation = newValue
            case 9: warmth = newValue; case 10: tint = newValue; case 11: definition = newValue
            case 12: sharpness = newValue; case 13: noiseReduction = newValue; case 14: vignette = newValue
            case 15: glow = newValue; case 16: halation = newValue; case 17: softness = newValue
            case 18: richness = newValue; case 19: vignetteSize = newValue; case 20: vignetteFeather = newValue
            default: preconditionFailure("slider index \(i) is past sliderKeys")
            }
        }
    }
}
