import XCTest
@testable import FilmSidecar

/// A packet with standard provenance, dc elements, and eyedropper and crop fields in the
/// FilmTether namespace, with no Film or FilmPositive fields. The fallback reader accepts
/// this shape.
final class TetherFixtureTests: XCTestCase {
    /// Tests/Fixtures/<name>.xmp, located from this file so no resource bundle is needed.
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name + ".xmp")
        return try Data(contentsOf: url)
    }

    private var live: SidecarSource {
        SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00")
    }

    func testReadsTether040CropFixture() throws {
        let sc = try Sidecar.decode(try fixture("tether-040-crop"), liveSource: live)
        XCTAssertEqual(sc.capture?.camera, "Leica M6")
        XCTAssertEqual(sc.capture?.cameraMake, "Leica")
        XCTAssertEqual(sc.capture?.film, "Kodak Portra 400")
        XCTAssertEqual(sc.capture?.filmMaker, "Kodak")
        XCTAssertEqual(sc.capture?.filmSizeID, "3")
        let g = try XCTUnwrap(sc.geometry)
        XCTAssertEqual(g.crop, CropRect(x: 0.071234, y: 0.088765, w: 0.851111, h: 0.827222))
        XCTAssertEqual(g.straightenDegrees, 0.35, accuracy: 1e-9)
        XCTAssertEqual(g.rotate, 0)
        XCTAssertFalse(g.flip)
        // Tether's own eyedropper numbers are not the shared sample point.
        XCTAssertNil(sc.samplePoint)
        XCTAssertNil(sc.develop)
        // No Film:Source* in this fixture: the live image fills it in.
        XCTAssertEqual(sc.source, live)
    }

    func testFixtureIsWholeAndForeignFieldsSurviveADevelop() throws {
        let data = try fixture("tether-040-crop")
        var sc = try Sidecar.decode(data, liveSource: live)
        sc.develop = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        let packet = try XMPSidecarCodec.parse(data)
        let out = try XMPSidecarCodec.encode(sc, into: packet.document)
        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        // Tether's namespace is untouched, and its own crop fields stay as written.
        XCTAssertTrue(text.contains("FilmTether:BaseSampleR=\"0.5431\""))
        XCTAssertTrue(text.contains("FilmTether:CropX=\"0.071234\""))
        XCTAssertTrue(text.contains("Leica M6 - Kodak Portra 400"))
        XCTAssertTrue(text.contains("FilmPositive:Stock=\"kodak-portra-400\""))
        // The shared crop is now written too, so a second reader never needs the fallback.
        XCTAssertTrue(text.contains("Film:CropX=\"0.071234\""))
    }
}
