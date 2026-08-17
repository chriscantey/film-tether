import XCTest
@testable import Camera

final class MetadataWriterTests: XCTestCase {

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
        XCTAssertNil(CaptureMetadata(camera: "", film: "").xmpPacket())
    }

    // MARK: - XMP packet

    func testXmpContainsAllFields() {
        let m = CaptureMetadata(camera: "Leica M6", film: "Kodak Portra 400")
        let xmp = m.xmpPacket()!
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
        let xmp = m.xmpPacket()!
        XCTAssertTrue(xmp.contains("&lt;Velvia&gt;"))
        XCTAssertTrue(xmp.contains("&amp;"))
        XCTAssertTrue(xmp.contains("&quot;50&quot;"))
        XCTAssertFalse(xmp.contains("<Velvia>"))   // raw angle brackets must not leak
    }

    func testXmpOmitsMakeWhenUnknown() {
        let m = CaptureMetadata(camera: "Frankencamera 9000", film: "")
        let xmp = m.xmpPacket()!
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
        let xmp = m.xmpPacket()!
        XCTAssertTrue(xmp.contains("xmlns:FilmTether=\"https://github.com/chriscantey/film-tether/ns/1.0/\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleR=\"0.5430\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleG=\"0.3720\""))
        XCTAssertTrue(xmp.contains("FilmTether:BaseSampleB=\"0.1900\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewGainR=\"0.6782\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewGainB=\"1.9385\""))
        XCTAssertTrue(xmp.contains("FilmTether:PreviewInverted=\"True\""))
        // False booleans must be ABSENT, not written as False.
        XCTAssertFalse(xmp.contains("PreviewMonochrome"))
    }

    func testEmptyTreatmentWritesNoFilmTetherFields() {
        let m = CaptureMetadata(camera: "Leica M6", film: "",
                                treatment: TreatmentRecord())
        let xmp = m.xmpPacket()!
        XCTAssertFalse(xmp.contains("FilmTether:BaseSample"))
        XCTAssertFalse(xmp.contains("FilmTether:PreviewGain"))
        XCTAssertFalse(xmp.contains("FilmTether:PreviewInverted"))
    }

    func testEmptyTreatmentAloneIsNoPacket() {
        // Camera/film empty + default treatment == nothing to write: the
        // writer must no-op exactly as it did before treatments existed.
        let m = CaptureMetadata(camera: "", film: "", treatment: TreatmentRecord())
        XCTAssertTrue(m.isEmpty)
        XCTAssertNil(m.xmpPacket())
    }

    func testTreatmentAloneStillWrites() {
        // A treatment with data is worth a packet even with no camera/film
        // typed in, the base sample is unrecoverable later.
        let m = CaptureMetadata(camera: "", film: "",
                                treatment: TreatmentRecord(monochrome: true))
        XCTAssertFalse(m.isEmpty)
        let xmp = m.xmpPacket()!
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
        XCTAssertEqual(out, raw)   // embedded backend writes INTO the RAW

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
