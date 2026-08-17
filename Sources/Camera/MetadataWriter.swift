import Foundation

/// The preview treatment the operator had applied at capture time, recorded so
/// the frame can be interpreted later without the app session. Every field
/// earns its place by the admission test "does this help interpret the FRAME
/// later" (app-session state, zoom, peaking, histogram, is excluded):
///
///   - `baseSample`: the eyedropper's raw film-base measurement (encoded sRGB
///     0...1). Unrecoverable later (the frame it was sampled from is gone) and
///     not derivable from the gains (clamping is lossy). Film Positive uses it
///     to cross-check its spectral base prediction against an empirical sample.
///   - `previewGains`: the per-channel correction the operator visually
///     approved on screen.
///   - `inverted`: the operator judged the positive, declares the frame is a
///     negative.
///   - `monochrome`: the operator declares a B&W roll, so downstream tools can
///     skip color-mask handling.
///
/// Field names/namespace are the FilmTether side of a small cross-app metadata
/// contract, so a downstream tool can read what the operator was looking at.
public struct TreatmentRecord: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public let r: Double
        public let g: Double
        public let b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
    }

    public var baseSample: RGB?
    public var previewGains: RGB?
    public var inverted: Bool
    public var monochrome: Bool

    public init(baseSample: RGB? = nil, previewGains: RGB? = nil,
                inverted: Bool = false, monochrome: Bool = false) {
        self.baseSample = baseSample
        self.previewGains = previewGains
        self.inverted = inverted
        self.monochrome = monochrome
    }

    /// Nothing worth writing: absence in the XMP means "no treatment", so an
    /// all-default record must not emit fields.
    public var isEmpty: Bool {
        baseSample == nil && previewGains == nil && !inverted && !monochrome
    }
}

/// User-entered provenance for a film scan: the original camera the negative
/// was shot on and the film stock. The Canon DSLR is only the scanner, so this
/// is what photo apps should display as the "camera" and (where they can) the
/// film. Both fields are free-form and may be empty.
public struct CaptureMetadata: Sendable, Equatable {
    public let camera: String
    public let film: String
    /// Preview treatment active at capture, or nil/empty for none.
    public let treatment: TreatmentRecord?

    public init(camera: String, film: String, treatment: TreatmentRecord? = nil) {
        self.camera = camera.trimmingCharacters(in: .whitespacesAndNewlines)
        self.film = film.trimmingCharacters(in: .whitespacesAndNewlines)
        self.treatment = treatment
    }

    public var isEmpty: Bool {
        camera.isEmpty && film.isEmpty && (treatment?.isEmpty ?? true)
    }

    // MARK: - Camera → Make / Model

    /// Manufacturers we recognize as the leading token of a camera string.
    /// Used only to decide where to split "Leica M6" into Make=Leica, Model=M6.
    /// Not a built-in camera list, there are no canned camera *models*; this is
    /// purely a brand dictionary for the split heuristic.
    static let knownMakers: [String] = [
        "Leica", "Nikon", "Canon", "Hasselblad", "Contax", "Pentax", "Mamiya",
        "Rollei", "Rolleiflex", "Minolta", "Olympus", "Fuji", "Fujifilm",
        "Yashica", "Voigtländer", "Voigtlander", "Konica", "Bronica", "Zeiss",
        "Polaroid", "Ricoh", "Sigma", "Sony", "Plaubel", "Linhof", "Graflex",
        "Zenza", "Zorki", "Kiev", "Bessa", "Chamonix", "Intrepid", "Horseman",
    ]

    /// Split the free-form camera string into EXIF Make/Model. If the first
    /// word is a recognized manufacturer it becomes Make; Model is always the
    /// FULL string ("Olympus Infinity Zoom 230", not "Infinity Zoom 230"),
    /// that's what every OEM does (Canon writes Model="Canon EOS 7D") and the
    /// cross-app metadata contract with Film Positive standardizes on it.
    /// A populated Model with empty Make degrades gracefully everywhere.
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
    /// AnalogExif:FilmMaker field. nil when unknown, we never guess wrong.
    public var filmMaker: String? {
        guard let sp = film.firstIndex(of: " ") else {
            return Self.knownFilmMakers.contains(where: { $0.caseInsensitiveCompare(film) == .orderedSame }) ? film : nil
        }
        let firstWord = String(film[..<sp])
        return Self.knownFilmMakers.contains(where: { $0.caseInsensitiveCompare(firstWord) == .orderedSame }) ? firstWord : nil
    }

    /// Human-readable caption combining what's set: "Leica M6 - Kodak Portra 400".
    /// Film folds into the caption for maximum visibility. ASCII-only separator
    /// by contract: downstream tools mirror this into EXIF ImageDescription
    /// (JXL visibility in Photos), where non-ASCII is the one thing strict
    /// parsers mangle.
    public var caption: String {
        [camera, film].filter { !$0.isEmpty }.joined(separator: " - ")
    }

    /// The searchable keyword for film, the one field both Apple Photos and
    /// Lightroom display and filter on. nil when no film is set.
    public var filmKeyword: String? {
        film.isEmpty ? nil : "Film: \(film)"
    }

    // MARK: - XMP packet

    /// Build a standalone XMP packet (RDF/XML) carrying the camera and film
    /// provenance. Suitable for a `.xmp` sidecar or for embedding. Namespaces:
    ///   tiff:        camera Make/Model (XMP mirror of EXIF)
    ///   dc:          subject (keyword) + description (caption)
    ///   AnalogExif:  the de-facto structured film schema exiftool speaks
    ///   FilmTether:  this app's treatment record (base sample, gains, flags)
    /// Returns nil if there is nothing to write.
    public func xmpPacket() -> String? {
        guard !isEmpty else { return nil }
        let (make, model) = makeAndModel

        var attrs: [String] = []
        if let make { attrs.append("tiff:Make=\"\(Self.esc(make))\"") }
        if !model.isEmpty { attrs.append("tiff:Model=\"\(Self.esc(model))\"") }
        if !film.isEmpty { attrs.append("AnalogExif:Film=\"\(Self.esc(film))\"") }
        if let maker = filmMaker { attrs.append("AnalogExif:FilmMaker=\"\(Self.esc(maker))\"") }

        // Treatment record: every field written ONLY when it carries data,
        // absence means "no treatment", so readers never see default-valued
        // noise. Booleans appear only as True ("XMP Boolean" spelling).
        if let t = treatment, !t.isEmpty {
            func num(_ v: Double) -> String { String(format: "%.4f", v) }
            if let s = t.baseSample {
                attrs.append("FilmTether:BaseSampleR=\"\(num(s.r))\"")
                attrs.append("FilmTether:BaseSampleG=\"\(num(s.g))\"")
                attrs.append("FilmTether:BaseSampleB=\"\(num(s.b))\"")
            }
            if let g = t.previewGains {
                attrs.append("FilmTether:PreviewGainR=\"\(num(g.r))\"")
                attrs.append("FilmTether:PreviewGainG=\"\(num(g.g))\"")
                attrs.append("FilmTether:PreviewGainB=\"\(num(g.b))\"")
            }
            if t.inverted { attrs.append("FilmTether:PreviewInverted=\"True\"") }
            if t.monochrome { attrs.append("FilmTether:PreviewMonochrome=\"True\"") }
        }

        var elements: [String] = []
        if let kw = filmKeyword {
            elements.append("""
               <dc:subject><rdf:Bag><rdf:li>\(Self.esc(kw))</rdf:li></rdf:Bag></dc:subject>
            """)
        }
        let cap = caption
        if !cap.isEmpty {
            elements.append("""
               <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(Self.esc(cap))</rdf:li></rdf:Alt></dc:description>
            """)
        }

        let attrBlock = attrs.isEmpty ? "" : "\n      " + attrs.joined(separator: "\n      ")
        let elementBlock = elements.isEmpty ? "" : "\n" + elements.joined(separator: "\n")

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmTether">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:AnalogExif="http://analogexif.sourceforge.net/ns"
            xmlns:FilmTether="https://github.com/chriscantey/film-tether/ns/1.0/"\(attrBlock)>\(elementBlock)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// Minimal XML attribute/text escaping.
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Writes `CaptureMetadata` alongside / into a captured RAW. The backend is
/// chosen at build time; see `write(_:forRAW:)`. All paths are RAW-safe: the
/// sidecar path never touches the CR2 at all.
public enum MetadataWriter {
    public enum Backend: String, Sendable {
        /// Write a standalone `<basename>.xmp` next to the CR2. Zero risk to the
        /// RAW (it is never opened). Read by Lightroom, Capture One, darktable,
        /// digiKam, Bridge, and exiftool pipelines.
        case sidecar
        /// Splice the XMP packet into the CR2 itself via `XMPEmbedder`
        /// (append-only, sensor bytes untouched by construction, atomic swap).
        /// Falls back to sidecar automatically when the container isn't a
        /// classic little-endian TIFF (future CR3 etc.). Per the cross-app
        /// contract, a successful embed removes any stale sidecar so the two
        /// can never disagree (embedded wins).
        case embedded
    }

    /// Current backend. Sidecar by default (zero-risk). The user chooses in
    /// Settings → Metadata; AppModel pushes the choice here on launch and on
    /// change.
    public static var backend: Backend = .sidecar

    /// Write metadata for `rawURL`. No-op when there's nothing to write.
    /// Returns the URL actually written, or nil if no-op.
    @discardableResult
    public static func write(_ meta: CaptureMetadata, forRAW rawURL: URL) throws -> URL? {
        guard let xmp = meta.xmpPacket() else { return nil }
        switch backend {
        case .sidecar:
            return try writeSidecar(xmp, forRAW: rawURL)
        case .embedded:
            do {
                try XMPEmbedder.embedFile(packet: xmp, at: rawURL)
                // Contract: embedded wins; never leave a stale sidecar behind.
                try? FileManager.default.removeItem(at: sidecarURL(forRAW: rawURL))
                return rawURL
            } catch XMPEmbedder.EmbedError.unsupportedContainer {
                // Unknown container shape (not classic II/42 TIFF): never
                // guess on the user's RAW, take the zero-risk path.
                return try writeSidecar(xmp, forRAW: rawURL)
            }
        }
    }

    private static func writeSidecar(_ xmp: String, forRAW rawURL: URL) throws -> URL {
        let sidecar = sidecarURL(forRAW: rawURL)
        try xmp.data(using: .utf8)?.write(to: sidecar, options: .atomic)
        return sidecar
    }

    /// Sidecar path convention: `<basename>.xmp` (drop the .CR2 extension).
    /// This is the Adobe/Lightroom default and the most broadly recognized
    /// form. (darktable-style `<basename>.CR2.xmp` is the alternative; switch
    /// here if a target app needs it.)
    public static func sidecarURL(forRAW rawURL: URL) -> URL {
        rawURL.deletingPathExtension().appendingPathExtension("xmp")
    }
}
