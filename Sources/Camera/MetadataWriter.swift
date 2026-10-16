import Foundation
import FilmSidecar

/// The preview treatment the operator had applied at capture time, recorded so
/// the frame can be interpreted later without the app session. A field is
/// written only if it helps interpret the frame later (app-session state such
/// as zoom, peaking and the histogram is left out):
///
///   - `baseSample`: the eyedropper's raw film-base measurement (encoded sRGB
///     0...1). Unrecoverable later (the frame it was sampled from is gone) and
///     not derivable from the gains (clamping is lossy).
///   - `previewGains`: the per-channel correction the operator visually
///     approved on screen.
///   - `inverted`: the operator viewed the frame inverted, which declares it
///     a negative.
///   - `monochrome`: the operator declares a B&W roll, so downstream tools can
///     skip color-mask handling.
///   - `crop`: the rectangle the operator settled on, and the straightening
///     under it. Like the base sample, it cannot be re-derived from the RAW:
///     it is the operator's judgment of where the negative ends.
///   - `rotate` / `flip`: the quarter turn and the mirror the operator had the
///     preview under. Display-only in Tether, but Film Positive applies them
///     to the developed image, so a frame scanned sideways comes out upright.
///   - `samplePoint`: where the eyedropper was clicked.
///
/// Two namespaces carry this into the sidecar. Crop, straighten, rotate, flip,
/// sample point and film size are the shared half (`Film:`, defined by the
/// FilmSidecar package, which Film Positive also reads). The eyedropper RGB,
/// gains and the two preview flags are Tether's own (`FilmTether:`). Fields are
/// only added from 0.4.0 on, never renamed or repurposed. A `FilmTether:Crop*`
/// attribute already in a file is removed when the file is rewritten
/// (`writeOwnFields`), so it never sits beside the shared `Film:Crop*`.
/// Tether's own fields are written only when they carry data, so a reader of
/// an older packet sees absence rather than a wrong value.
public struct TreatmentRecord: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public let r: Double
        public let g: Double
        public let b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
    }

    /// A normalized point in crop space (original orientation, y-down, after
    /// straightening).
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// Where the negative is in the frame, and how far it was off level.
    ///
    /// The contract: the rectangle is normalized [0,1]², y-down,
    /// against the frame in the camera's own orientation: the RAW as saved,
    /// not the preview as displayed. The display's quarter turn is deliberately
    /// not part of it, so a downstream tool never has to know how the operator
    /// happened to have the preview turned.
    ///
    /// It is a two-step recipe, in this order: rotate the image
    /// `straightenDegrees` clockwise about its own center, keeping its
    /// dimensions, then take `x`/`y`/`width`/`height` of the result. The
    /// rectangle is axis-aligned in the straightened frame and is a tilted
    /// quadrilateral in the unstraightened one, so a crop always carries the
    /// angle it was drawn at. A straighten with no crop uses the record's own
    /// `straightenDegrees`. This is the same contract as the shared sidecar's
    /// (straighten, crop, rotate, flip).
    public struct Crop: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// Degrees clockwise, applied before the rectangle. Zero when the
        /// frame is not straightened.
        public var straightenDegrees: Double
        /// The film format catalog's own numeric id, when the operator's
        /// session had one. An id travels unchanged into the sidecar, where a
        /// name would break on a rename.
        public var filmSizeID: Int?

        public init(x: Double, y: Double, width: Double, height: Double,
                    straightenDegrees: Double = 0, filmSizeID: Int? = nil) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.straightenDegrees = straightenDegrees
            self.filmSizeID = filmSizeID
        }

        /// Guards against a zero-area box reaching the packet, where a reader
        /// would divide by it.
        public var isUsable: Bool { width > 0 && height > 0 }
    }

    public var baseSample: RGB?
    public var previewGains: RGB?
    public var inverted: Bool
    public var monochrome: Bool
    public var crop: Crop?
    /// Quarter turns clockwise the preview was displayed under: 0, 90, 180, 270.
    public var rotate: Int
    /// Mirrored horizontally, applied after `rotate` (emulsion-side scans).
    public var flip: Bool
    public var samplePoint: Point?
    /// Straightening with no crop under it, degrees clockwise. The angle is
    /// set from the crop box's rotate band, but Clear Crop leaves it in place
    /// (and it is remembered across launches), so the preview can be
    /// straightened with no box on it. Film Positive applies a lone angle, so
    /// it is written whenever it is non-zero. When a usable crop is present its
    /// own `straightenDegrees` is the one that counts.
    public var straightenDegrees: Double

    public init(baseSample: RGB? = nil, previewGains: RGB? = nil,
                inverted: Bool = false, monochrome: Bool = false,
                crop: Crop? = nil, rotate: Int = 0, flip: Bool = false,
                samplePoint: Point? = nil, straightenDegrees: Double = 0) {
        self.baseSample = baseSample
        self.previewGains = previewGains
        self.inverted = inverted
        self.monochrome = monochrome
        self.crop = crop
        self.rotate = rotate
        self.flip = flip
        self.samplePoint = samplePoint
        self.straightenDegrees = straightenDegrees
    }

    /// Nothing worth writing: absence in the XMP means "no treatment", so an
    /// all-default record must not emit fields.
    ///
    /// A crop on its own is enough to make a record worth writing. So is a
    /// turned or mirrored preview: Film Positive applies it, so it is state
    /// about the frame, not the session.
    public var isEmpty: Bool {
        baseSample == nil && previewGains == nil && !inverted && !monochrome
            && !(crop?.isUsable ?? false) && rotate == 0 && !flip && samplePoint == nil
            && straightenDegrees == 0
    }

    /// The shared geometry this record contributes, or nil when it is the
    /// identity. Absent geometry in the sidecar means "nothing to apply".
    var sharedGeometry: GeometrySettings? {
        let usable = crop.flatMap { $0.isUsable ? $0 : nil }
        let g = GeometrySettings(
            rotate: rotate, flip: flip,
            straightenDegrees: usable?.straightenDegrees ?? straightenDegrees,
            crop: usable.map { CropRect(x: $0.x, y: $0.y, w: $0.width, h: $0.height) })
        return g.isIdentity ? nil : g
    }
}

/// User-entered provenance for a film scan: the original camera the negative
/// was shot on and the film stock. The Canon body is only the scanner, so this
/// is what photo apps should display as the "camera" and (where they can) the
/// film. Both fields are free-form and may be empty.
public struct CaptureMetadata: Sendable, Equatable {
    public let camera: String
    public let film: String
    /// Preview treatment active at capture, or nil/empty for none.
    public let treatment: TreatmentRecord?
    /// When the scan was made (`Film:CapturedAt`). Nil when the packet is
    /// written for an existing file rather than at the shutter.
    public let capturedAt: Date?
    /// The day the roll was shot, "YYYY-MM-DD" (`Film:TakenOn`, the key Film
    /// Positive reads too). Anything that is not a real calendar day is
    /// dropped here, so a half-typed date is never written.
    public let takenOn: String?
    /// The film format (`Film:FilmSizeID`, the catalog id), written whether or
    /// not there is a crop. A crop's own id wins when it carries one.
    public let filmSizeID: Int?
    /// The format in words (`Film:FilmSizeName`): the Size row's plain
    /// name beside its id, or the text typed under Other with no id. Blank is nil.
    public let filmSizeName: String?

    public init(camera: String, film: String, treatment: TreatmentRecord? = nil,
                capturedAt: Date? = nil, takenOn: String? = nil, filmSizeID: Int? = nil,
                filmSizeName: String? = nil) {
        self.camera = camera.trimmingCharacters(in: .whitespacesAndNewlines)
        self.film = film.trimmingCharacters(in: .whitespacesAndNewlines)
        self.treatment = treatment
        self.capturedAt = capturedAt
        self.takenOn = takenOn.flatMap { CaptureMetadata.validTakenOn($0) }
        self.filmSizeID = filmSizeID
        self.filmSizeName = filmSizeName.flatMap(CaptureInfo.cleanName)
    }

    /// `value` when it is a real calendar day written "YYYY-MM-DD", else nil.
    /// This is film-sidecar's own check, the one its readers run too.
    public static func validTakenOn(_ value: String) -> String? {
        CaptureInfo.validDay(value)
    }

    public var isEmpty: Bool {
        camera.isEmpty && film.isEmpty && (treatment?.isEmpty ?? true) && takenOn == nil && filmSizeID == nil
            && filmSizeName == nil
    }

    // MARK: - Camera → Make / Model

    /// Brand names recognized as the first word of a camera string, which
    /// then becomes EXIF Make. Model keeps the full string.
    static let knownMakers: [String] = [
        "Leica", "Nikon", "Canon", "Hasselblad", "Contax", "Pentax", "Mamiya",
        "Rollei", "Rolleiflex", "Minolta", "Olympus", "Fuji", "Fujifilm",
        "Yashica", "Voigtländer", "Voigtlander", "Konica", "Bronica", "Zeiss",
        "Polaroid", "Ricoh", "Sigma", "Sony", "Plaubel", "Linhof", "Graflex",
        "Zenza", "Zorki", "Kiev", "Bessa", "Chamonix", "Intrepid", "Horseman",
    ]

    /// Split the free-form camera string into EXIF Make/Model. If the first
    /// word is a recognized manufacturer it becomes Make. Model is always the
    /// full string ("Olympus Infinity Zoom 230", not "Infinity Zoom 230"), the
    /// way Canon writes Model="Canon EOS 7D", and Film Positive reads it that
    /// way.
    public var makeAndModel: (make: String?, model: String) {
        guard !camera.isEmpty else { return (nil, "") }
        guard let sp = camera.firstIndex(of: " ") else { return (nil, camera) }
        let firstWord = String(camera[..<sp])
        let rest = camera[camera.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty,
           Self.knownMakers.contains(where: { $0.caseInsensitiveCompare(firstWord) == .orderedSame }) {
            return (firstWord, camera)
        }
        return (nil, camera)
    }

    // MARK: - Film → maker

    static let knownFilmMakers: [String] = [
        "Kodak", "Fuji", "Fujifilm", "Ilford", "Cinestill", "Lomography",
        "Lomo", "Agfa", "Rollei", "Foma", "Fomapan", "Kentmere", "Adox",
        "Bergger", "Ferrania", "Polaroid", "Harman", "Washi", "Kosmo",
    ]

    /// Best-effort film manufacturer (leading token if recognized), for the
    /// AnalogExif:FilmMaker field. nil when the first word is not a known
    /// film maker.
    public var filmMaker: String? {
        guard let sp = film.firstIndex(of: " ") else {
            return Self.knownFilmMakers.contains(where: { $0.caseInsensitiveCompare(film) == .orderedSame }) ? film : nil
        }
        let firstWord = String(film[..<sp])
        return Self.knownFilmMakers.contains(where: { $0.caseInsensitiveCompare(firstWord) == .orderedSame }) ? firstWord : nil
    }

    /// Human-readable caption combining what's set: "Leica M6 - Kodak Portra 400".
    /// The separator is ASCII so it survives a copy into EXIF ImageDescription.
    /// The camera and film text are passed through as entered, trimmed.
    public var caption: String {
        [camera, film].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    /// The searchable keyword for film (`dc:subject`), the one field common
    /// photo libraries display and filter on. nil when no film is set.
    public var filmKeyword: String? {
        film.isEmpty ? nil : "Film: \(film)"
    }

    // MARK: - The shared sidecar

    /// The sidecar this capture contributes, layered over `existing` when the
    /// image already has one. Tether owns `source` and `capture` and writes the
    /// shared `geometry` and `samplePoint` when it has them. Film Positive's
    /// sections pass through untouched, which is why this builds on the
    /// existing struct rather than a fresh one.
    ///
    /// Scanner make/model are deliberately not written: the RAW's own EXIF
    /// Make/Model is the scanner, and a copy that can drift is worse than none.
    public func sidecar(source: SidecarSource, merging existing: Sidecar? = nil) -> Sidecar {
        var sc = existing ?? Sidecar(source: source)
        sc.version = Sidecar.currentVersion
        sc.source = source

        var cap = existing?.capture ?? CaptureInfo()
        let (make, model) = makeAndModel
        cap.camera = model.isEmpty ? nil : model
        cap.cameraMake = make
        cap.film = film.isEmpty ? nil : film
        cap.filmMaker = filmMaker
        // The id and its name travel as a pair: a size given now replaces both,
        // so a re-tag never leaves an old name beside a new id, and Other
        // (a name with no id) clears the id.
        let sizeID = treatment?.crop?.filmSizeID ?? filmSizeID
        if sizeID != nil || filmSizeName != nil {
            cap.filmSizeID = sizeID.map { String($0) }
            cap.filmSizeName = filmSizeName
        }
        if let at = capturedAt { cap.capturedAt = at }
        if let day = takenOn { cap.takenOn = day }
        sc.capture = cap == CaptureInfo() ? nil : cap

        if let g = treatment?.sharedGeometry { sc.geometry = g }
        if let p = treatment?.samplePoint { sc.samplePoint = NormalizedPoint(x: p.x, y: p.y) }
        return sc
    }

    public enum WriteError: Error, Equatable, CustomStringConvertible {
        /// The existing sidecar was written by a newer schema. The package
        /// refuses to rewrite such a file and so do we, because a rewrite
        /// would drop the fields a newer Film Positive wrote and we do not
        /// know.
        case newerSidecar(version: Int)
        public var description: String {
            switch self {
            case .newerSidecar(let v): return "sidecar is schema v\(v), newer than this app writes, so it is not overwritten"
            }
        }
    }

    // MARK: - XMP packet

    /// Build the XMP packet (RDF/XML) for this capture, merged into `existing`
    /// (the bytes of the sidecar already beside the image) when there is one,
    /// or into a fresh packet. Namespaces:
    ///   tiff:         film camera Make/Model, not the scanner's  (via FilmSidecar)
    ///   AnalogExif:   the de-facto structured film schema         (via FilmSidecar)
    ///   Film:         the shared crop/rotate/flip/sample/source   (via FilmSidecar)
    ///   dc:           subject (keyword) + description (caption)   (ours)
    ///   FilmTether:   eyedropper RGB, gains, preview flags        (ours)
    /// Everything the packet already held outside these namespaces and Film
    /// Positive's (an editor's crs:) is preserved. Film Positive's FilmPositive:
    /// fields are decoded and written back by the shared codec, so a key it
    /// does not know is dropped. Returns nil if there is nothing to write.
    public func xmpData(source: SidecarSource, mergingInto existing: Data? = nil) throws -> Data? {
        guard !isEmpty else { return nil }
        let packet = try existing.map { try XMPSidecarCodec.parse($0) }
        let prior = try packet.map { try XMPSidecarCodec.decode($0.fields, liveSource: source) }
        if let prior, prior.version > Sidecar.currentVersion {
            throw WriteError.newerSidecar(version: prior.version)
        }
        // An empty camera or film here means "not given", not "erase": a re-tag
        // that names only the camera must not drop the film the file already
        // carries. Fill from the existing sidecar so the shared fields, the dc
        // caption and the keyword are all built from the same values and can
        // never disagree with each other.
        let effective = CaptureMetadata(
            camera: camera.isEmpty ? (prior?.capture?.camera ?? "") : camera,
            film: film.isEmpty ? (prior?.capture?.film ?? "") : film,
            treatment: treatment, capturedAt: capturedAt, takenOn: takenOn, filmSizeID: filmSizeID,
            filmSizeName: filmSizeName)
        let document = packet?.document ?? XMPSidecarCodec.emptyPacket()
        try effective.writeOwnFields(into: document)
        return try XMPSidecarCodec.encode(effective.sidecar(source: source, merging: prior), into: document)
    }

    /// `xmpData` as text.
    public func xmpPacket(source: SidecarSource, mergingInto existing: Data? = nil) throws -> String? {
        try xmpData(source: source, mergingInto: existing).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Tether's own namespace and its dc elements, written onto the packet's
    /// first rdf:Description before the shared codec adds the Film fields.
    /// Every FilmTether attribute already there is removed first, so an old
    /// `FilmTether:Crop*` never sits beside the shared `Film:Crop*`.
    private func writeOwnFields(into document: XMLDocument) throws {
        guard let rdf = XMPSidecarCodec.rdfElement(in: document) else {
            throw XMPError.notXMP("no rdf:RDF element")
        }
        var descs = XMPSidecarCodec.descriptions(in: rdf)
        if descs.isEmpty {
            let d = XMLElement(name: "rdf:Description")
            d.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
            rdf.addChild(d)
            descs = [d]
        }
        for d in descs {
            for a in d.attributes ?? [] {
                guard let name = a.name,
                      d.resolveNamespace(forName: name)?.stringValue == XMPNamespace.tether else { continue }
                d.removeAttribute(forName: name)
            }
            for child in (d.children ?? []).compactMap({ $0 as? XMLElement }) {
                guard let name = child.name, let local = child.localName,
                      child.resolveNamespace(forName: name)?.stringValue == XMPNamespace.dc,
                      local == "subject" || local == "description" else { continue }
                child.detach()
            }
        }

        let target = descs[0]
        // Treatment record: every field is written only when it carries data.
        // Absence means "no treatment", so readers never see default-valued
        // noise. Booleans appear only as True ("XMP Boolean" spelling).
        var attrs: [(String, String)] = []
        if let t = treatment, !t.isEmpty {
            func num(_ v: Double) -> String { String(format: "%.4f", v) }
            if let s = t.baseSample {
                attrs += [("BaseSampleR", num(s.r)), ("BaseSampleG", num(s.g)), ("BaseSampleB", num(s.b))]
            }
            if let g = t.previewGains {
                attrs += [("PreviewGainR", num(g.r)), ("PreviewGainG", num(g.g)), ("PreviewGainB", num(g.b))]
            }
            if t.inverted { attrs.append(("PreviewInverted", "True")) }
            if t.monochrome { attrs.append(("PreviewMonochrome", "True")) }
        }
        if !attrs.isEmpty {
            let ft = XMPSidecarCodec.declaredPrefix(for: XMPNamespace.tether, on: target)
            for (name, value) in attrs {
                target.addAttribute(XMLNode.attribute(withName: "\(ft):\(name)", stringValue: value) as! XMLNode)
            }
        }

        let kw = filmKeyword
        let cap = caption
        if kw != nil || !cap.isEmpty {
            let dc = XMPSidecarCodec.declaredPrefix(for: XMPNamespace.dc, on: target)
            let rdfp = XMPSidecarCodec.declaredPrefix(for: XMPNamespace.rdf, on: target)
            if let kw {
                let li = XMLElement(name: "\(rdfp):li", stringValue: kw)
                let bag = XMLElement(name: "\(rdfp):Bag"); bag.addChild(li)
                let subject = XMLElement(name: "\(dc):subject"); subject.addChild(bag)
                target.addChild(subject)
            }
            if !cap.isEmpty {
                let li = XMLElement(name: "\(rdfp):li", stringValue: cap)
                li.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as! XMLNode)
                let alt = XMLElement(name: "\(rdfp):Alt"); alt.addChild(li)
                let description = XMLElement(name: "\(dc):description"); description.addChild(alt)
                target.addChild(description)
            }
        }
    }
}

/// Writes `CaptureMetadata` alongside / into a captured RAW. The backend is
/// chosen at runtime (`backend`), see `write(_:forRAW:)`. The sidecar path only
/// reads the capture (CR2, CR3 or JPG) and never writes it.
public enum MetadataWriter {
    public enum Backend: String, Sendable {
        /// Write a standalone `<basename>.xmp` next to the capture, the same file
        /// Film Positive reads and writes. The RAW is only read (its first
        /// 64 KB are hashed for the source fields), never written. Raw editors
        /// and catalogs that follow the XMP sidecar convention read it, and so
        /// does exiftool.
        case sidecar
        /// Splice the XMP packet into the CR2 itself via `XMPEmbedder`
        /// (append-only, sensor bytes untouched by construction, atomic swap).
        /// Falls back to the sidecar when the container is not classic
        /// little-endian TIFF. The R5's CR3 is not, so it always gets a sidecar. A
        /// successful embed tries to remove any sidecar beside the RAW so the
        /// two do not disagree (embedded wins). The packet is built without
        /// reading that sidecar, so its other sections are not carried over.
        /// The packet's Film:Source* fields describe the file before the embed
        /// grew it.
        case embedded
    }

    /// Current backend. Sidecar by default, which never writes the RAW. The
    /// user chooses with "Write metadata into the RAW file" on the Capture
    /// tab of Settings. AppSettings pushes the choice here on launch and on
    /// change.
    public static var backend: Backend = .sidecar

    /// Write metadata for `rawURL`. No-op when there's nothing to write.
    /// Returns the URL written, or nil if no-op.
    @discardableResult
    public static func write(_ meta: CaptureMetadata, forRAW rawURL: URL) throws -> URL? {
        guard !meta.isEmpty else { return nil }
        let source = try SidecarStore.source(for: rawURL)
        switch backend {
        case .sidecar:
            return try writeSidecar(meta, source: source, forRAW: rawURL)
        case .embedded:
            guard let xmp = try meta.xmpPacket(source: source) else { return nil }
            do {
                try XMPEmbedder.embedFile(packet: xmp, at: rawURL)
                try? FileManager.default.removeItem(at: sidecarURL(forRAW: rawURL))
                return rawURL
            } catch XMPEmbedder.EmbedError.unsupportedContainer {
                // Unknown container shape (not classic II/42 TIFF). Never
                // guess on the user's RAW: write the sidecar instead.
                return try writeSidecar(meta, source: source, forRAW: rawURL)
            }
        }
    }

    /// Merge into the sidecar already beside the RAW (Film Positive may have
    /// developed this frame), or create it. Atomic: a temp file in the same
    /// directory swapped into place, so a crash mid-write leaves the old file.
    private static func writeSidecar(_ meta: CaptureMetadata, source: SidecarSource,
                                     forRAW rawURL: URL) throws -> URL? {
        let sidecar = sidecarURL(forRAW: rawURL)
        let existing = FileManager.default.fileExists(atPath: sidecar.path)
            ? try Data(contentsOf: sidecar) : nil
        guard let data = try meta.xmpData(source: source, mergingInto: existing) else { return nil }
        try data.write(to: sidecar, options: .atomic)
        return sidecar
    }

    /// Sidecar path: `<basename>.xmp` (drop the .CR2 extension), the usual XMP
    /// sidecar convention. SidecarStore in the shared package decides it, so
    /// Film Positive finds the same file.
    public static func sidecarURL(forRAW rawURL: URL) -> URL {
        SidecarStore.sidecarURL(for: rawURL)
    }
}
