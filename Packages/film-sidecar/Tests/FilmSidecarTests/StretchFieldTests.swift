import XCTest
@testable import FilmSidecar

/// The Tone row's Stretch (`FilmPositive:Stretch`, one number in 0...1). Storage only.
final class StretchFieldTests: XCTestCase {
    private var live: SidecarSource {
        SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00")
    }

    private func developed(stretch: Double? = nil) -> Sidecar {
        var dv = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        dv.stretch = stretch
        return Sidecar(source: live, develop: dv)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The bytes with `attr` spliced in beside Stock, the way another writer might put it there.
    private func with(_ attr: String, in data: Data) -> Data {
        Data(text(data).replacingOccurrences(of: "FilmPositive:Stock=", with: "\(attr) FilmPositive:Stock=").utf8)
    }

    /// The value read back from bytes carrying `FilmPositive:Stretch="<raw>"`.
    private func read(_ raw: String) throws -> DevelopSettings? {
        let data = with("FilmPositive:Stretch=\"\(raw)\"", in: try developed().encoded())
        return try Sidecar.decode(data, liveSource: live, strict: true).develop
    }

    func testDefaultIsNil() {
        XCTAssertNil(DevelopSettings(stock: "x", base: BaseSettings(mode: .anchor)).stretch)
    }

    func testHalfRoundTripsThroughStrictDecode() throws {
        let sc = developed(stretch: 0.5)
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Stretch=\"0.5\""), text(data))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.stretch, 0.5)
        XCTAssertEqual(back, sc.quantized())
        XCTAssertEqual(try back.encoded(), data, "a second write is the same bytes")
    }

    /// Nil writes no attribute at all, so a frame nobody stretched never mentions it.
    func testNilWritesNoAttribute() throws {
        let data = try developed().encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Stock="), "canary: the develop section was written")
        XCTAssertFalse(text(data).contains("Stretch"), text(data))
    }

    func testAbsentReadsNil() throws {
        let back = try Sidecar.decode(try developed().encoded(), liveSource: live, strict: true)
        XCTAssertNotNil(back.develop)
        XCTAssertNil(back.develop?.stretch)
    }

    /// 1 set explicitly is written and reads back as 1, not nil. Whether 1 means
    /// "unset" is the app's decision, not the package's.
    func testOneSetExplicitlyIsWrittenAndReadsBackAsOne() throws {
        let sc = developed(stretch: 1.0)
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Stretch=\"1\""), text(data))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.stretch, 1)
        XCTAssertEqual(back, sc.quantized())
    }

    /// The four decimal form a hand edit or another writer might use reads the same.
    func testFourDecimalFormReadsBack() throws {
        XCTAssertEqual(try read("1.0000")?.stretch, 1)
        XCTAssertEqual(try read("0.2500")?.stretch, 0.25)
    }

    /// Values finer than the written grain are held to it, so the read-back equals the
    /// quantized copy exactly.
    func testValueIsHeldToTheWrittenGrain() throws {
        let sc = developed(stretch: 0.123456)
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Stretch=\"0.1235\""), text(data))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.stretch, 0.1235)
        XCTAssertEqual(back, sc.quantized())
    }

    /// A finite value outside 0...1 is clamped on read, so the app never sees one.
    func testOutOfRangeClampsOnRead() throws {
        XCTAssertEqual(try read("1.5")?.stretch, 1)
        XCTAssertEqual(try read("-0.2")?.stretch, 0)
        XCTAssertEqual(try read("0")?.stretch, 0)
        XCTAssertEqual(try read("1")?.stretch, 1)
    }

    /// A malformed value reads as nil and costs nothing else in the file.
    func testMalformedReadsNil() throws {
        for junk in ["", "x", "half", "0.5 0.5", "0,5", "nan", "inf", "-inf", "1e"] {
            let dv = try read(junk)
            XCTAssertNil(dv?.stretch, "\(junk) is not a Stretch")
            XCTAssertEqual(dv?.stock, "kodak-portra-400", "and the rest of the file is intact")
        }
    }

    /// A non-finite value in memory is not written: it would read back as absent anyway.
    func testNonFiniteIsNotWritten() throws {
        for v in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(text(try developed(stretch: v).encoded()).contains("Stretch"), "\(v)")
        }
    }
}
