import XCTest
import FilmSidecar
@testable import Camera

final class MetadataWriterTests: XCTestCase {

    /// A fixed source identity so packets are byte-stable across runs. The
    /// real writer takes it from the RAW on disk.
    fileprivate var src: SidecarSource {
        SidecarSource(name: "IMG_0001.CR2", size: 12345,
                      mtime: Date(timeIntervalSince1970: 1_700_000_000), fingerprint: "sha256:abc")
    }

    /// A fresh packet (no existing sidecar to merge into).
    fileprivate func packet(_ m: CaptureMetadata) -> String? {
        try! m.xmpPacket(source: src)
    }

    // MARK: - Camera → Make / Model

    func testKnownMakerSplits() {
        let m = CaptureMetadata(camera: "Leica M6", film: "")
        XCTAssertEqual(m.makeAndModel.make, "Leica")
        XCTAssertEqual(m.makeAndModel.model, "Leica M6")   // full name in Model, OEM convention
    }

    func testKnownMakerCaseInsensitive() {
        let m = CaptureMetadata(camera: "nikon F3", film: "")
        XCTAssertEqual(m.makeAndModel.make, "nikon")   // preserves user's casing
        XCTAssertEqual(m.makeAndModel.model, "nikon F3")
    }

    func testMultiWordModelKeepsRest() {
        let m = CaptureMetadata(camera: "Hasselblad 500 C/M", film: "")
        XCTAssertEqual(m.makeAndModel.make, "Hasselblad")
        XCTAssertEqual(m.makeAndModel.model, "Hasselblad 500 C/M")
    }

    func testUnknownMakerGoesAllToModel() {
        let m = CaptureMetadata(camera: "Frankencamera 9000", film: "")
        XCTAssertNil(m.makeAndModel.make)
        XCTAssertEqual(m.makeAndModel.model, "Frankencamera 9000")
    }

    func testSingleTokenIsModelOnly() {
        let m = CaptureMetadata(camera: "M6", film: "")
        XCTAssertNil(m.makeAndModel.make)
        XCTAssertEqual(m.makeAndModel.model, "M6")
    }

    // MARK: - Film maker

    func testFilmMakerDerived() {
        XCTAssertEqual(CaptureMetadata(camera: "", film: "Kodak Portra 400").filmMaker, "Kodak")
        XCTAssertEqual(CaptureMetadata(camera: "", film: "Ilford HP5 Plus").filmMaker, "Ilford")
    }

    func testFilmMakerUnknownIsNil() {
        XCTAssertNil(CaptureMetadata(camera: "", film: "SomeBrand 200").filmMaker)
    }

    // MARK: - Caption / keyword

    func testCaptionCombinesBoth() {
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400")
        XCTAssertEqual(m.caption, "Leica M6 - Kodak Portra 400")  // ASCII separator by contract
    }

    func testCaptionWithOnlyFilm() {
        XCTAssertEqual(CaptureMetadata(camera: "", film: "Cinestill 800T").caption, "Cinestill 800T")
    }

    func testFilmKeyword() {
        XCTAssertEqual(CaptureMetadata(camera: "", film: "Tri-X 400").filmKeyword, "Film: Tri-X 400")
        XCTAssertNil(CaptureMetadata(camera: "Leica M6", film: "").filmKeyword)
    }

    // MARK: - Empties

    func testEmptyMetadataIsEmpty() {
        XCTAssertTrue(CaptureMetadata(camera: "  ", film: "\n").isEmpty)
        XCTAssertNil(packet(CaptureMetadata(camera: "", film: "")))
    }

    // MARK: - XMP packet

    func testXmpContainsAllFields() {
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400")
        let xmp = packet(m)!
        XCTAssertTrue(xmp.contains("tiff:Make=\"Leica\""))
        XCTAssertTrue(xmp.contains("tiff:Model=\"Leica M6\""))   // full name, OEM convention
        XCTAssertTrue(xmp.contains("AnalogExif:Film=\"Kodak Portra 400\""))
        XCTAssertTrue(xmp.contains("AnalogExif:FilmMaker=\"Kodak\""))
        XCTAssertTrue(xmp.contains("Film: Kodak Portra 400"))           // dc:subject keyword
        XCTAssertTrue(xmp.contains("Leica M6 - Kodak Portra 400"))      // dc:description caption
        XCTAssertTrue(xmp.contains("http://analogexif.sourceforge.net/ns"))
    }

    func testXmpEscapesSpecialCharacters() {
        let m = CaptureMetadata(camera: "", film: "Fuji <Velvia> & \"50\"")
        let xmp = packet(m)!
        XCTAssertTrue(xmp.contains("&lt;Velvia&gt;"))
        XCTAssertTrue(xmp.contains("&amp;"))
        XCTAssertTrue(xmp.contains("&quot;50&quot;"))
        XCTAssertFalse(xmp.contains("<Velvia>"))   // raw angle brackets must not leak
    }

    func testXmpOmitsMakeWhenUnknown() {
        let m = CaptureMetadata(camera: "Frankencamera 9000", film: "")
        let xmp = packet(m)!
        XCTAssertFalse(xmp.contains("tiff:Make="))
        XCTAssertTrue(xmp.contains("tiff:Model=\"Frankencamera 9000\""))
    }

    // MARK: - Sidecar path

    func testSidecarURLDropsRawExtension() {
        let raw = URL(fileURLWithPath: "/tmp/scan/IMG_0001.CR2")
        XCTAssertEqual(MetadataWriter.sidecarURL(forRAW: raw).lastPathComponent, "IMG_0001.xmp")
    }

    func testSidecarRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let raw = dir.appendingPathComponent("IMG_0001.CR2")
        try Data("not-a-real-raw".utf8).write(to: raw)

        let m = CaptureMetadata(camera: "Nikon F3", film: "Kodak Gold 200")
        let out = try MetadataWriter.write(m, forRAW: raw)
        XCTAssertEqual(out?.lastPathComponent, "IMG_0001.xmp")

        let written = try String(contentsOf: out!, encoding: .utf8)
        XCTAssertTrue(written.contains("tiff:Make=\"Nikon\""))
        XCTAssertTrue(written.contains("AnalogExif:Film=\"Kodak Gold 200\""))

        // The RAW must be untouched by metadata writing.
        XCTAssertEqual(try String(contentsOf: raw, encoding: .utf8), "not-a-real-raw")
    }

    // MARK: - Treatment record (FilmTether: namespace)

    private var fullTreatment: TreatmentRecord {
        TreatmentRecord(
            baseSample: .init(r: 0.543, g: 0.372, b: 0.19),
            previewGains: .init(r: 0.6782, g: 0.9901, b: 1.9385),
            inverted: true,
            monochrome: false
        )
    }

    func testTreatmentFieldsInPacket() {
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400",
                                treatment: fullTreatment)
        let xmp = packet(m)!
        XCTAssertTrue(xmp.contains("xmlns:FilmTether=\"https://github.com/chriscantey/film-tether/ns/1.0/\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleR=\"0.5430\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleG=\"0.3720\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleB=\"0.1900\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewGainR=\"0.6782\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewGainB=\"1.9385\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewInverted=\"True\""))
        // False booleans must be absent, not written as False.
        XCTAssertFalse(xmp.contains("PreviewMonochrome"))
    }

    func testEmptyTreatmentWritesNoFilmTetherFields() {
        let m = CaptureMetadata(camera: "Leica M6", film: "",
                                treatment: TreatmentRecord())
        let xmp = packet(m)!
        XCTAssertFalse(xmp.contains("FilmTether:BaseSample"))
        XCTAssertFalse(xmp.contains("FilmTether:PreviewGain"))
        XCTAssertFalse(xmp.contains("FilmTether:PreviewInverted"))
    }

    func testEmptyTreatmentAloneIsNoPacket() {
        // No camera, no film and a default treatment: nothing to write.
        let m = CaptureMetadata(camera: "", film: "", treatment: TreatmentRecord())
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(packet(m))
    }

    func testTreatmentAloneStillWrites() {
        // A treatment with data, here only monochrome, is worth a packet even
        // with no camera or film typed in.
        let m = CaptureMetadata(camera: "", film: "",
                                treatment: TreatmentRecord(monochrome: true))
        XCTAssertFalse(m.isEmpty)
        let xmp = packet(m)!
        XCTAssertTrue(xmp.contains("FilmTether:PreviewMonochrome=\"True\""))
        XCTAssertFalse(xmp.contains("tiff:Model"))
        XCTAssertFalse(xmp.contains("AnalogExif:"))
    }

    func testTreatmentSidecarRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("IMG_0002.CR2")
        try Data("not-a-real-raw".utf8).write(to: raw)

        let m = CaptureMetadata(camera: "", film: "Ilford HP5 Plus", treatment: fullTreatment)
        let out = try MetadataWriter.write(m, forRAW: raw)
        let written = try String(contentsOf: out!, encoding: .utf8)
        XCTAssertTrue(written.contains("FilmTether:BaseSampleR=\"0.5430\""))
        XCTAssertTrue(written.contains("FilmTether:PreviewInverted=\"True\""))
    }

    func testTreatmentEmbeddedRoundTrip() throws {
        // Same fields must survive the embedded backend: splice into a minimal
        // little-endian TIFF, read the file back, find the packet.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("IMG_0003.CR2")
        try minimalTIFF().write(to: raw)

        let saved = MetadataWriter.backend
        MetadataWriter.backend = .embedded
        defer { MetadataWriter.backend = saved }

        let m = CaptureMetadata(camera: "Nikon F3", film: "", treatment: fullTreatment)
        let out = try MetadataWriter.write(m, forRAW: raw)
        XCTAssertEqual(out, raw)   // embedded backend writes into the RAW

        let bytes = try String(decoding: Data(contentsOf: raw), as: UTF8.self)
        XCTAssertTrue(bytes.contains("FilmTether:BaseSampleB=\"0.1900\""))
        XCTAssertTrue(bytes.contains("FilmTether:PreviewGainG=\"0.9901\""))
        XCTAssertTrue(bytes.contains("FilmTether:PreviewInverted=\"True\""))
    }

    /// Minimal valid little-endian TIFF (header → 2-entry IFD0 → payload),
    /// enough for XMPEmbedder to accept and splice into.
    private func minimalTIFF() -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        let payloadOffset = 8 + 2 + 2 * 12 + 4
        d.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        u16(2)
        u16(256); u16(3); u32(1); u32(256)                    // ImageWidth
        u16(273); u16(4); u32(1); u32(UInt32(payloadOffset))  // strip pointer
        u32(0)
        d.append(Data(repeating: 0xAB, count: 64))
        return d
    }
}

// MARK: - Crop in the treatment record

/// The crop is a judgment about where the negative ends, made against a live
/// view that is gone once the session ends, so it cannot be recomputed from
/// the RAW.
extension MetadataWriterTests {

    private var crop: TreatmentRecord.Crop {
        .init(x: 0.125, y: 0.2, width: 0.5, height: 0.333333,
              straightenDegrees: -1.25, filmSizeID: 3)
    }

    func testCropFieldsInPacket() {
        let m = CaptureMetadata(camera: "", film: "",
                                treatment: TreatmentRecord(crop: crop))
        let xmp = packet(m)!
        // The crop is shared state, so it lives in the Film namespace the
        // package writes, not in Tether's own. Six decimals, trailing zeros
        // trimmed by the package (0.5 is 0.5, 0.333333 keeps all six).
        XCTAssertTrue(xmp.contains("Film:CropX=\"0.125\""))
        XCTAssertTrue(xmp.contains("Film:CropY=\"0.2\""))
        XCTAssertTrue(xmp.contains("Film:CropW=\"0.5\""))
        XCTAssertTrue(xmp.contains("Film:CropH=\"0.333333\""))
        XCTAssertTrue(xmp.contains("Film:StraightenDeg=\"-1.25\""))
        XCTAssertTrue(xmp.contains("Film:FilmSizeID=\"3\""))
        // No FilmTether:Crop* field is written, so the crop lives in one place.
        XCTAssertFalse(xmp.contains("FilmTether:Crop"))
    }

    /// A crop and nothing else is worth a packet. This is the ordinary case:
    /// an operator who cropped and left the preview alone.
    func testACropAloneIsWorthWriting() {
        let t = TreatmentRecord(crop: crop)
        XCTAssertFalse(t.isEmpty)
        XCTAssertNotNil(packet(CaptureMetadata(camera: "", film: "", treatment: t)))
    }

    /// The shared codec writes the geometry block whole (a zero angle beside
    /// the rectangle), but the film size still appears only when the session
    /// had one, and no FilmTether:Crop* field appears at all.
    func testAnUnstraightenedCropWritesNoFilmSizeAndNoLegacyCrop() {
        let flat = TreatmentRecord.Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let xmp = packet(CaptureMetadata(camera: "", film: "",
                                         treatment: TreatmentRecord(crop: flat)))!
        XCTAssertTrue(xmp.contains("Film:CropX=\"0.1\""))
        XCTAssertTrue(xmp.contains("Film:StraightenDeg=\"0\""))
        XCTAssertFalse(xmp.contains("Film:FilmSizeID"))
        XCTAssertFalse(xmp.contains("FilmTether:Crop"))
    }

    /// A box with no area is not a crop. It would reach a reader as a divide by
    /// zero, and the empty-record no-op has to survive it too.
    func testADegenerateCropIsNotWritten() {
        let flat = TreatmentRecord.Crop(x: 0.5, y: 0.5, width: 0, height: 0.4)
        let t = TreatmentRecord(crop: flat)
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(packet(CaptureMetadata(camera: "", film: "", treatment: t)))
        let withCamera = CaptureMetadata(camera: "Leica M6", film: "", treatment: t)
        XCTAssertFalse(packet(withCamera)!.contains("Film:Crop"))
        // Identity geometry writes no geometry block at all.
        XCTAssertFalse(packet(withCamera)!.contains("Film:Rotate"))
    }

    /// A record with no crop writes no crop fields, whether `crop` is left at
    /// its default or passed as nil.
    func testANilCropLeavesThePacketUnchanged() {
        let without = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400",
                                      treatment: fullTreatment)
        let explicitlyNoCrop = CaptureMetadata(
            camera: "Leica M6", film: "Kodak Portra 400",
            treatment: TreatmentRecord(
                baseSample: fullTreatment.baseSample,
                previewGains: fullTreatment.previewGains,
                inverted: fullTreatment.inverted,
                monochrome: fullTreatment.monochrome,
                crop: nil))
        XCTAssertEqual(packet(without), packet(explicitlyNoCrop))
        XCTAssertFalse(packet(without)!.contains("Film:Crop"))
    }

    /// Everything else in the packet still lands when there is a crop.
    func testACropDoesNotDisplaceTheOtherTreatmentFields() {
        let both = TreatmentRecord(
            baseSample: .init(r: 0.5, g: 0.4, b: 0.3),
            previewGains: nil, inverted: true, monochrome: true, crop: crop)
        let xmp = packet(CaptureMetadata(camera: "Leica M6", film: "", treatment: both))!
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleR=\"0.5000\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewInverted=\"True\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewMonochrome=\"True\""))
        XCTAssertTrue(xmp.contains("Film:CropW=\"0.5\""))
        XCTAssertTrue(xmp.contains("tiff:Make=\"Leica\""))
    }
}

// MARK: - The shared sidecar (Film namespace, via the FilmSidecar package)

/// Film Positive reads the same `<base>.xmp`, so the Film namespace is written
/// by the package's codec, never hand-formatted. Film Positive's own sections
/// have to survive a Tether write, or the operator's develop is lost the
/// moment they re-tag a frame.
extension MetadataWriterTests {

    private var sharedTreatment: TreatmentRecord {
        TreatmentRecord(
            baseSample: .init(r: 0.5, g: 0.4, b: 0.3),
            crop: .init(x: 0.125, y: 0.2, width: 0.5, height: 0.333333,
                        straightenDegrees: -1.25, filmSizeID: 3),
            rotate: 90, flip: true, samplePoint: .init(x: 0.25, y: 0.75))
    }

    func testRotateFlipAndSamplePointGoToTheSharedNamespace() {
        let xmp = packet(CaptureMetadata(camera: "", film: "", treatment: sharedTreatment))!
        XCTAssertTrue(xmp.contains("Film:Rotate=\"90\""))
        XCTAssertTrue(xmp.contains("Film:Flip=\"True\""))
        XCTAssertTrue(xmp.contains("Film:BaseSampleX=\"0.25\""))
        XCTAssertTrue(xmp.contains("Film:BaseSampleY=\"0.75\""))
        // The eyedropper RGB stays Tether's own.
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleR=\"0.5000\""))
        XCTAssertFalse(xmp.contains("Film:BaseSampleR"))
    }

    /// Straighten, then Clear Crop: the preview is still straightened with no
    /// box on it, and the angle must still be written on its own. With a crop
    /// present the crop's own angle is the one written.
    func testALoneStraightenIsWrittenAndACropsAngleWins() {
        let lone = TreatmentRecord(straightenDegrees: 0.75)
        XCTAssertFalse(lone.isEmpty)
        let xmp = packet(CaptureMetadata(camera: "", film: "", treatment: lone))!
        XCTAssertTrue(xmp.contains("Film:StraightenDeg=\"0.75\""))
        XCTAssertFalse(xmp.contains("Film:CropX"))
        let withCrop = TreatmentRecord(
            crop: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8, straightenDegrees: -1.25),
            straightenDegrees: 0.75)
        let xmp2 = packet(CaptureMetadata(camera: "", film: "", treatment: withCrop))!
        XCTAssertTrue(xmp2.contains("Film:StraightenDeg=\"-1.25\""))
    }

    /// A turned or mirrored preview is state about the frame that a reader of
    /// the sidecar applies, so it is worth a packet on its own.
    func testARotatedPreviewAloneIsWorthWriting() {
        XCTAssertFalse(TreatmentRecord(rotate: 180).isEmpty)
        XCTAssertFalse(TreatmentRecord(flip: true).isEmpty)
        XCTAssertFalse(TreatmentRecord(samplePoint: .init(x: 0.1, y: 0.1)).isEmpty)
        XCTAssertTrue(TreatmentRecord(rotate: 0, flip: false).isEmpty)
    }

    func testSourceIdentityAndSchemaVersionAreWritten() {
        let xmp = packet(CaptureMetadata(camera: "Leica M6", film: ""))!
        XCTAssertTrue(xmp.contains("Film:Version=\"1\""))
        XCTAssertTrue(xmp.contains("Film:SourceName=\"IMG_0001.CR2\""))
        XCTAssertTrue(xmp.contains("Film:SourceSize=\"12345\""))
        XCTAssertTrue(xmp.contains("Film:SourceFingerprint=\"sha256:abc\""))
        XCTAssertTrue(xmp.contains("xmlns:Film=\"https://github.com/chriscantey/film-sidecar/ns/1.0/\""))
    }

    /// A round trip through the package's own reader: fed Tether's bytes, it
    /// sees exactly what Tether wrote. Scanner fields stay absent by
    /// design (the RAW's EXIF is the scanner).
    func testThePackageReadsBackWhatTetherWrote() throws {
        let at = Date(timeIntervalSince1970: 1_726_000_000)
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400",
                                treatment: sharedTreatment, capturedAt: at)
        let data = try XCTUnwrap(try m.xmpData(source: src))
        let sc = try Sidecar.decode(data, liveSource: src)
        XCTAssertEqual(sc.version, 1)
        XCTAssertEqual(sc.source, src)
        XCTAssertEqual(sc.capture?.camera, "Leica M6")
        XCTAssertEqual(sc.capture?.cameraMake, "Leica")
        XCTAssertEqual(sc.capture?.film, "Kodak Portra 400")
        XCTAssertEqual(sc.capture?.filmMaker, "Kodak")
        XCTAssertEqual(sc.capture?.filmSizeID, "3")
        XCTAssertEqual(sc.capture?.capturedAt, at)
        XCTAssertNil(sc.capture?.scannerMake)
        XCTAssertNil(sc.capture?.scannerModel)
        let g = try XCTUnwrap(sc.geometry)
        XCTAssertEqual(g.rotate, 90)
        XCTAssertTrue(g.flip)
        XCTAssertEqual(g.straightenDegrees, -1.25, accuracy: 1e-9)
        XCTAssertEqual(g.crop, CropRect(x: 0.125, y: 0.2, w: 0.5, h: 0.333333))
        XCTAssertEqual(sc.samplePoint, NormalizedPoint(x: 0.25, y: 0.75))
        XCTAssertNil(sc.develop)
        XCTAssertNil(sc.enhance)
        XCTAssertNil(sc.look)
    }

    /// Film Positive developed the frame first. A Tether rewrite of the same
    /// sidecar must carry its develop, enhance and look through untouched.
    func testAnExistingFilmPositiveDevelopSurvivesATetherWrite() throws {
        var theirs = Sidecar(source: src)
        theirs.develop = DevelopSettings(stock: "kodak-portra-400", light: "rig",
                                         base: BaseSettings(mode: .anchor, anchor: 3000))
        theirs.enhance = EnhanceSettings(exposure: 0.25, warmth: -0.1)
        theirs.look = "warm-print"
        theirs.geometry = GeometrySettings(rotate: 270)
        let existing = try theirs.encoded()

        let m = CaptureMetadata(camera: "Nikon F3", film: "Ilford HP5 Plus", treatment: sharedTreatment)
        let data = try XCTUnwrap(try m.xmpData(source: src, mergingInto: existing))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("FilmPositive:Stock=\"kodak-portra-400\""))
        XCTAssertTrue(text.contains("FilmPositive:Look=\"warm-print\""))
        XCTAssertTrue(text.contains("tiff:Model=\"Nikon F3\""))

        let sc = try Sidecar.decode(data, liveSource: src)
        XCTAssertEqual(sc.develop, theirs.develop)
        XCTAssertEqual(sc.enhance, theirs.enhance)
        XCTAssertEqual(sc.look, "warm-print")
        // Tether had geometry of its own, so it wins over the stale 270.
        XCTAssertEqual(sc.geometry?.rotate, 90)
    }

    /// A re-tag that names only the camera keeps the film the file already
    /// carries, and the keyword and caption are rebuilt from the kept value so
    /// the packet never says two different films.
    func testAReTagWithoutFilmKeepsTheExistingFilmEverywhere() throws {
        let first = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400")
        let existing = try XCTUnwrap(try first.xmpData(source: src))
        let second = CaptureMetadata(camera: "Nikon F3", film: "")
        let data = try XCTUnwrap(try second.xmpData(source: src, mergingInto: existing))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("tiff:Model=\"Nikon F3\""))
        XCTAssertTrue(text.contains("AnalogExif:Film=\"Kodak Portra 400\""))
        XCTAssertTrue(text.contains("Film: Kodak Portra 400"))            // dc:subject names the kept film
        XCTAssertTrue(text.contains("Nikon F3 - Kodak Portra 400"))      // caption rebuilt
        XCTAssertFalse(text.contains("Leica M6"))
        let sc = try Sidecar.decode(data, liveSource: src)
        XCTAssertEqual(sc.capture?.film, "Kodak Portra 400")
        XCTAssertEqual(sc.capture?.filmMaker, "Kodak")
        XCTAssertEqual(sc.capture?.cameraMake, "Nikon")
    }

    /// A Tether write with nothing to say about geometry leaves the existing
    /// geometry alone.
    func testATetherWriteWithoutGeometryKeepsTheExistingGeometry() throws {
        var theirs = Sidecar(source: src)
        theirs.geometry = GeometrySettings(rotate: 270, crop: CropRect(x: 0.1, y: 0.1, w: 0.8, h: 0.8))
        let m = CaptureMetadata(camera: "Nikon F3", film: "")
        let data = try XCTUnwrap(try m.xmpData(source: src, mergingInto: try theirs.encoded()))
        let sc = try Sidecar.decode(data, liveSource: src)
        XCTAssertEqual(sc.geometry, theirs.geometry)
    }

    /// A file can carry FilmTether:Crop*. Rewriting it removes the old fields,
    /// so a reader never sees two crops that could disagree.
    func testRewritingALegacyPacketRetiresFilmTetherCrop() throws {
        let legacy = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmTether">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:AnalogExif="http://analogexif.sourceforge.net/ns"
            xmlns:FilmTether="https://github.com/chriscantey/film-tether/ns/1.0/"
            tiff:Make="Leica" tiff:Model="Leica M6"
            FilmTether:BaseSampleR="0.5431" FilmTether:BaseSampleG="0.3722" FilmTether:BaseSampleB="0.1903"
            FilmTether:CropX="0.071234" FilmTether:CropY="0.088765" FilmTether:CropW="0.851111" FilmTether:CropH="0.827222"
            FilmTether:CropStraightenDeg="0.350" FilmTether:CropFilmSizeID="3">
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Leica M6</rdf:li></rdf:Alt></dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400", treatment: sharedTreatment)
        let data = try XCTUnwrap(try m.xmpData(source: src, mergingInto: Data(legacy.utf8)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("FilmTether:Crop"))
        XCTAssertTrue(text.contains("Film:CropX=\"0.125\""))
        XCTAssertTrue(text.contains("FilmTether:BaseSampleR=\"0.5000\""))
        XCTAssertFalse(text.contains("0.5431"))   // the stale sample is replaced, not duplicated
        XCTAssertEqual(text.components(separatedBy: "dc:description>").count, 3)   // one open, one close
        XCTAssertTrue(text.contains("Leica M6 - Kodak Portra 400"))
        XCTAssertFalse(text.contains(">Leica M6<"))   // the old caption is gone
    }

    /// Through the real writer, against a sidecar on disk that already carries
    /// a develop section.
    func testSidecarWriteMergesIntoTheFileBesideTheRAW() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("IMG_0004.CR2")
        try Data("not-a-real-raw".utf8).write(to: raw)

        var theirs = Sidecar(source: try SidecarStore.source(for: raw))
        theirs.develop = DevelopSettings(stock: "ilford-hp5", light: "rig", base: BaseSettings(mode: .anchor))
        try SidecarStore().save(theirs, for: raw)

        let m = CaptureMetadata(camera: "Nikon F3", film: "Ilford HP5 Plus", treatment: sharedTreatment)
        let out = try XCTUnwrap(try MetadataWriter.write(m, forRAW: raw))
        XCTAssertEqual(out, SidecarStore.sidecarURL(for: raw))

        let loaded = try XCTUnwrap(try SidecarStore().load(for: raw))
        XCTAssertEqual(loaded.status, .ok)   // the recorded size and fingerprint match the RAW on disk
        XCTAssertEqual(loaded.sidecar.develop?.stock, "ilford-hp5")
        XCTAssertEqual(loaded.sidecar.capture?.camera, "Nikon F3")
        XCTAssertEqual(loaded.sidecar.geometry?.rotate, 90)
        XCTAssertEqual(loaded.sidecar.samplePoint, NormalizedPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(try String(contentsOf: raw, encoding: .utf8), "not-a-real-raw")
    }

    /// The sidecar writer never overwrites a sidecar from a newer schema, since
    /// that would lose fields this app does not know. The scan itself is
    /// unaffected.
    func testANewerSidecarIsNeverOverwritten() throws {
        var theirs = Sidecar(source: src)
        theirs.version = Sidecar.currentVersion + 1
        let existing = try theirs.encoded()
        let m = CaptureMetadata(camera: "Nikon F3", film: "")
        XCTAssertThrowsError(try m.xmpData(source: src, mergingInto: existing)) { error in
            XCTAssertEqual(error as? CaptureMetadata.WriteError,
                           .newerSidecar(version: Sidecar.currentVersion + 1))
        }
    }

    // MARK: - Taken (Film:TakenOn) and the film size, in the shared namespace

    func testTakenOnIsWrittenAsTheSharedKey() throws {
        let m = CaptureMetadata(camera: "", film: "Kodak Portra 400", takenOn: "2026-09-14")
        let xmp = try XCTUnwrap(packet(m))
        XCTAssertTrue(xmp.contains("Film:TakenOn=\"2026-09-14\""), xmp)
        let sc = try Sidecar.decode(try XCTUnwrap(try m.xmpData(source: src)), liveSource: src)
        XCTAssertEqual(sc.capture?.takenOn, "2026-09-14", "a sidecar reader sees the same field")
    }

    func testAMalformedTakenOnIsNeverWritten() throws {
        for bad in ["2026-9-14", "14/09/2026", "2026-02-30", "yesterday", ""] {
            let m = CaptureMetadata(camera: "", film: "Portra", takenOn: bad)
            XCTAssertNil(m.takenOn, bad)
            XCTAssertFalse(try XCTUnwrap(packet(m)).contains("TakenOn"), bad)
        }
    }

    func testTheFilmSizeIsWrittenWithoutACrop() throws {
        let m = CaptureMetadata(camera: "", film: "Portra", filmSizeID: 12)
        let sc = try Sidecar.decode(try XCTUnwrap(try m.xmpData(source: src)), liveSource: src)
        XCTAssertEqual(sc.capture?.filmSizeID, "12", "the same Film:FilmSizeID the crop writes, not a second field")
    }

    /// The plain name is written beside the id as Film:FilmSizeName.
    func testTheSizeNameIsWrittenBesideTheId() throws {
        let m = CaptureMetadata(camera: "", film: "Portra", filmSizeID: 14, filmSizeName: "120 6x7")
        let xmp = try XCTUnwrap(packet(m))
        XCTAssertTrue(xmp.contains("Film:FilmSizeName=\"120 6x7\""), xmp)
        let sc = try Sidecar.decode(try XCTUnwrap(try m.xmpData(source: src)), liveSource: src)
        XCTAssertEqual(sc.capture?.filmSizeID, "14")
        XCTAssertEqual(sc.capture?.filmSizeName, "120 6x7")
    }

    /// Other: the typed text with no id, and a blank one writes nothing.
    func testOtherWritesTheTextWithNoId() throws {
        let m = CaptureMetadata(camera: "", film: "Portra", filmSizeName: " 127 roll ")
        let sc = try Sidecar.decode(try XCTUnwrap(try m.xmpData(source: src)), liveSource: src)
        XCTAssertNil(sc.capture?.filmSizeID)
        XCTAssertEqual(sc.capture?.filmSizeName, "127 roll")
        XCTAssertNil(CaptureMetadata(camera: "", film: "", filmSizeName: "   ").filmSizeName)
        XCTAssertFalse(CaptureMetadata(camera: "", film: "", filmSizeName: "127").isEmpty)
    }

    /// A re-tag to Other drops the old id, and a re-tag to a row replaces the
    /// old name.
    func testARetagReplacesTheIdAndNameTogether() throws {
        let first = try XCTUnwrap(try CaptureMetadata(camera: "", film: "Portra", filmSizeID: 4, filmSizeName: "35mm").xmpData(source: src))
        let other = try XCTUnwrap(try CaptureMetadata(camera: "", film: "", filmSizeName: "127").xmpData(source: src, mergingInto: first))
        var sc = try Sidecar.decode(other, liveSource: src)
        XCTAssertNil(sc.capture?.filmSizeID)
        XCTAssertEqual(sc.capture?.filmSizeName, "127")
        let back = try XCTUnwrap(try CaptureMetadata(camera: "", film: "", filmSizeID: 2, filmSizeName: "120 6x6").xmpData(source: src, mergingInto: other))
        sc = try Sidecar.decode(back, liveSource: src)
        XCTAssertEqual(sc.capture?.filmSizeID, "2")
        XCTAssertEqual(sc.capture?.filmSizeName, "120 6x6")
        let untouched = try XCTUnwrap(try CaptureMetadata(camera: "Nikon F3", film: "").xmpData(source: src, mergingInto: back))
        XCTAssertEqual(try Sidecar.decode(untouched, liveSource: src).capture?.filmSizeName, "120 6x6", "a re-tag naming no size keeps it")
    }

    func testTakenOnOrSizeAloneIsNotEmpty() {
        XCTAssertFalse(CaptureMetadata(camera: "", film: "", takenOn: "2026-09-14").isEmpty)
        XCTAssertFalse(CaptureMetadata(camera: "", film: "", filmSizeID: 4).isEmpty)
    }

    /// A re-tag that does not name a day keeps the day the file already carries.
    func testAReTagWithoutTakenOnKeepsTheExistingDay() throws {
        let first = try XCTUnwrap(try CaptureMetadata(camera: "", film: "Portra", takenOn: "2026-09-14").xmpData(source: src))
        let retag = try XCTUnwrap(try CaptureMetadata(camera: "Nikon F3", film: "").xmpData(source: src, mergingInto: first))
        let sc = try Sidecar.decode(retag, liveSource: src)
        XCTAssertEqual(sc.capture?.takenOn, "2026-09-14")
        XCTAssertEqual(sc.capture?.camera, "Nikon F3")
    }

    /// The sidecar writer never overwrites a sidecar that is not XMP. It throws
    /// and the capture path logs it (the scan is already safe on disk).
    func testACorruptSidecarIsNeverOverwritten() throws {
        let m = CaptureMetadata(camera: "Nikon F3", film: "")
        XCTAssertThrowsError(try m.xmpData(source: src, mergingInto: Data("<not xml".utf8)))
    }
}
