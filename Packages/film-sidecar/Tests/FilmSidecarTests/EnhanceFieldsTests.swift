import XCTest
@testable import FilmSidecar

/// Levels (`FilmPositive:Levels`, five numbers), the four
/// tone curves (`FilmPositive:CurveRGB`, `CurveRed`, `CurveGreen`, `CurveBlue`, "x,y x,y"),
/// and the vignette's size and softness (`VignetteSize`, `VignetteFeather`). Storage only.
final class EnhanceFieldsTests: XCTestCase {
    private var live: SidecarSource {
        SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00")
    }

    private static let levelsCurveAndVignetteNames = ["VignetteSize", "VignetteFeather", "Levels", "CurveRGB", "CurveRed", "CurveGreen", "CurveBlue"]

    private static let levels = Levels(inBlack: 0.05, gamma: 1.2, inWhite: 0.95, outBlack: 0.02, outWhite: 0.98)
    private static let bent = CurvePoints(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.3),
                                                   CurvePoint(x: 0.75, y: 0.8), CurvePoint(x: 1, y: 0.95)])
    private static let bentText = "0,0 0.25,0.3 0.75,0.8 1,0.95"

    /// An enhance layer with Vibrance moved, so the enhance block is written either way.
    private func enhanced(_ edit: (inout EnhanceSettings) -> Void = { _ in }) -> Sidecar {
        var e = EnhanceSettings(vibrance: 0.2)
        edit(&e)
        return Sidecar(source: live, enhance: e)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The bytes with `attr` spliced in beside Vibrance, the way another writer might put it there.
    private func with(_ attr: String, in data: Data) -> Data {
        Data(text(data).replacingOccurrences(of: "FilmPositive:Vibrance=", with: "\(attr) FilmPositive:Vibrance=").utf8)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name + ".xmp")
        return try Data(contentsOf: url)
    }

    private func json(_ e: EnhanceSettings) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return text(try enc.encode(e))
    }

    // MARK: defaults and identity

    func testDefaultsAreIdentity() {
        let e = EnhanceSettings()
        XCTAssertEqual(e.vignetteSize, 0)
        XCTAssertEqual(e.vignetteFeather, 0)
        XCTAssertEqual(e.levels, .identity)
        XCTAssertEqual(e.curves, .identity)
        XCTAssertTrue(e.isIdentity)
        XCTAssertEqual(Levels.identity.values, [0, 1, 1, 0, 1])
        XCTAssertEqual(CurvePoints.identity.points, [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
    }

    func testIsIdentityIsFalseWithAnyOneLevelsCurveOrVignetteFieldSet() {
        let edits: [(String, (inout EnhanceSettings) -> Void)] = [
            ("vignetteSize", { $0.vignetteSize = 0.1 }),
            ("vignetteFeather", { $0.vignetteFeather = -0.1 }),
            ("levels", { $0.levels.gamma = 1.1 }),
            ("curves.rgb", { $0.curves.rgb = Self.bent }),
            ("curves.red", { $0.curves.red = Self.bent }),
            ("curves.green", { $0.curves.green = Self.bent }),
            ("curves.blue", { $0.curves.blue = Self.bent }),
        ]
        for (name, edit) in edits {
            var e = EnhanceSettings()
            edit(&e)
            XCTAssertFalse(e.isIdentity, "only \(name) set is not identity")
        }
        XCTAssertFalse(Self.levels.isIdentity)
        XCTAssertFalse(Curves(blue: Self.bent).isIdentity)
    }

    /// Pins the last three names in `sliderKeys` and Vignette's index. A file carries each
    /// slider by name, so this pins the order in memory, not anything in the file.
    func testRichnessVignetteSizeAndFeatherAreLastInSliderOrder() {
        XCTAssertEqual(EnhanceSettings.sliderKeys.suffix(3), ["richness", "vignetteSize", "vignetteFeather"])
        XCTAssertEqual(EnhanceSettings.sliderKeys.firstIndex(of: "vignette"), 14)
        XCTAssertEqual(EnhanceSettings.sliderKeys.map(\.xmpName).suffix(2), ["VignetteSize", "VignetteFeather"])
    }

    // MARK: XMP, each alone and all together

    func testVignetteSizeAndFeatherEachRoundTripAlone() throws {
        for (name, edit) in [("VignetteSize", { (e: inout EnhanceSettings) in e.vignetteSize = 0.35 }),
                             ("VignetteFeather", { (e: inout EnhanceSettings) in e.vignetteFeather = -0.35 })] {
            let sc = enhanced(edit)
            let data = try sc.encoded()
            for other in Self.levelsCurveAndVignetteNames where other != name {
                XCTAssertFalse(text(data).contains("FilmPositive:\(other)="), "\(name) alone wrote \(other)")
            }
            XCTAssertTrue(text(data).contains("FilmPositive:\(name)=\"\(name == "VignetteSize" ? "0.35" : "-0.35")\""), text(data))
            let back = try Sidecar.decode(data, liveSource: live, strict: true)
            XCTAssertEqual(back, sc.quantized())
        }
    }

    func testLevelsAloneRoundTrips() throws {
        let sc = enhanced { $0.levels = Self.levels }
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Levels=\"0.05 1.2 0.95 0.02 0.98\""), text(data))
        for other in Self.levelsCurveAndVignetteNames where other != "Levels" { XCTAssertFalse(text(data).contains("FilmPositive:\(other)=")) }
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.enhance?.levels, Self.levels)
        XCTAssertEqual(back, sc.quantized())
    }

    func testEachCurveRoundTripsAlone() throws {
        let channels: [(String, WritableKeyPath<Curves, CurvePoints>)] =
            [("CurveRGB", \.rgb), ("CurveRed", \.red), ("CurveGreen", \.green), ("CurveBlue", \.blue)]
        for (name, path) in channels {
            let sc = enhanced { $0.curves[keyPath: path] = Self.bent }
            let data = try sc.encoded()
            XCTAssertTrue(text(data).contains("FilmPositive:\(name)=\"\(Self.bentText)\""), text(data))
            for other in Self.levelsCurveAndVignetteNames where other != name {
                XCTAssertFalse(text(data).contains("FilmPositive:\(other)="), "\(name) alone wrote \(other)")
            }
            let back = try Sidecar.decode(data, liveSource: live, strict: true)
            XCTAssertEqual(back.enhance?.curves[keyPath: path], Self.bent)
            for (_, otherPath) in channels where otherPath != path {
                XCTAssertTrue(back.enhance?.curves[keyPath: otherPath].isIdentity ?? false)
            }
            XCTAssertEqual(back, sc.quantized())
        }
    }

    func testAllTogetherRoundTripAndRewriteToTheSameBytes() throws {
        let other = CurvePoints(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
        let sc = enhanced {
            $0.vignette = -0.5; $0.vignetteSize = 0.25; $0.vignetteFeather = 0.75
            $0.levels = Self.levels
            $0.curves = Curves(rgb: Self.bent, red: other, green: Self.bent, blue: other)
        }
        let data = try sc.encoded()
        for name in Self.levelsCurveAndVignetteNames { XCTAssertTrue(text(data).contains("FilmPositive:\(name)="), "\(name) missing") }
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back, sc.quantized())
        XCTAssertEqual(back.enhance?.curves.red, other)
        XCTAssertEqual(try back.encoded(), data, "a second write is the same bytes")
    }

    /// A file carrying only a curve still has an enhance layer: the curve is not lost because
    /// no slider moved.
    func testAFileWithOnlyACurveHasAnEnhanceLayer() throws {
        let sc = Sidecar(source: live, enhance: EnhanceSettings(curves: Curves(green: Self.bent)))
        let back = try Sidecar.decode(try sc.encoded(), liveSource: live, strict: true)
        XCTAssertEqual(back.enhance?.curves.green, Self.bent)
        XCTAssertEqual(back, sc.quantized())
    }

    /// Values finer than the written grain are held to it, and of two points that meet at the
    /// grain quantized() keeps the first, so the writer never emits a curve the reader refuses.
    func testValuesAreHeldToTheWrittenGrain() throws {
        let curve = CurvePoints(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.50001, y: 0.4),
                                         CurvePoint(x: 0.50004, y: 0.6), CurvePoint(x: 0.123456, y: 0.654321),
                                         CurvePoint(x: 1, y: 1)])
        let sc = enhanced {
            $0.levels = Levels(inBlack: 0.123456, gamma: 0.99996, inWhite: 1, outBlack: 0.00004, outWhite: 1)
            $0.curves.rgb = curve
            $0.vignetteSize = 0.123456
        }
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:Levels=\"0.1235 1 1 0 1\""), text(data))
        XCTAssertTrue(text(data).contains("FilmPositive:CurveRGB=\"0,0 0.1235,0.6543 0.5,0.4 1,1\""), text(data))
        XCTAssertTrue(text(data).contains("FilmPositive:VignetteSize=\"0.1235\""), text(data))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.enhance?.curves.rgb.points.count, 4, "the two points that meet at the grain were not reduced to one")
        XCTAssertEqual(back, sc.quantized())
    }

    /// Zero and identity write nothing, so a frame nobody touched never mentions them.
    func testIdentityWritesNothing() throws {
        for sc in [enhanced(), Sidecar(source: live, enhance: EnhanceSettings())] {
            let data = try sc.encoded()
            for name in Self.levelsCurveAndVignetteNames { XCTAssertFalse(text(data).contains(name), "\(name) written at identity") }
        }
        XCTAssertNil(try Sidecar.decode(try Sidecar(source: live, enhance: .identity).encoded(), liveSource: live).enhance)
    }

    // MARK: malformed reads as identity

    func testMalformedLevelsReadAsIdentity() throws {
        let base = try enhanced().encoded()
        for junk in ["", "0", "0 1 1 0", "0 1 1 0 1 0", "0 x 1 0 1", "a b c d e", "nan 1 1 0 1", "0 inf 1 0 1",
                     "0 1 -inf 0 1", "0,1,1,0,1"] {
            let read = try Sidecar.decode(with("FilmPositive:Levels=\"\(junk)\"", in: base), liveSource: live, strict: true)
            XCTAssertEqual(read.enhance?.levels, .identity, "\(junk) is not Levels")
            XCTAssertEqual(read.enhance?.vibrance, 0.2, "and the rest of the file is intact")
        }
    }

    func testMalformedCurvesReadAsIdentityAndLeaveTheOthers() throws {
        let base = try enhanced { $0.curves.rgb = Self.bent }.encoded()
        let seventeen = (0...16).map { "\(XMPFormat.num(Double($0) / 16, decimals: 4)),0.5" }.joined(separator: " ")
        let junk = ["", "0,0", "0.5,0.5", "0,0 1,1 0.5,0.5", "0,0 0,1", "0,0 0.5,0.5 0.5,0.6 1,1",
                    "0,0 1.5,1", "0,-0.1 1,1", "-0.1,0 1,1", "nan,0 1,1", "0,inf 1,1", "0,0 1,nan",
                    "0,0  1,1", " 0,0 1,1", "0,0 1,1 ", "0;0 1;1", "0,0,0 1,1", "0 0 1 1", "0, 0 1,1",
                    "x,0 1,1", "0.00001,0 0.00004,1", seventeen]
        for j in junk {
            for name in ["CurveRed", "CurveBlue"] {
                let read = try Sidecar.decode(with("FilmPositive:\(name)=\"\(j)\"", in: base), liveSource: live, strict: true)
                XCTAssertTrue((name == "CurveRed" ? read.enhance?.curves.red : read.enhance?.curves.blue)?.isIdentity ?? false,
                              "\(j) is not a curve")
                XCTAssertEqual(read.enhance?.curves.rgb, Self.bent, "a bad \(name) costs the RGB curve nothing")
                XCTAssertEqual(read.enhance?.vibrance, 0.2, "and the rest of the file is intact")
            }
        }
        // The edges that are legal: exactly 16 points, exactly 2, and the identity text itself.
        let sixteen = (0...15).map { "\(XMPFormat.num(Double($0) / 15, decimals: 4)),0.5" }.joined(separator: " ")
        XCTAssertEqual(XMPFormat.curve(sixteen)?.points.count, 16)
        XCTAssertEqual(XMPFormat.curve("0,0.2 1,0.8")?.points.count, 2)
        XCTAssertEqual(XMPFormat.curve("0,0 1,1"), .identity)
        XCTAssertNil(XMPFormat.curve(seventeen))
    }

    // MARK: the sanitizer

    func testSanitizerSortsClampsAndDropsRepeatsAndNonFinite() {
        let c = CurvePoints(sanitising: [CurvePoint(x: 1.2, y: 1.5), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: -0.1, y: -0.2),
                                         CurvePoint(x: 0.5, y: 0.9), CurvePoint(x: .nan, y: 0.5), CurvePoint(x: 0.3, y: .infinity),
                                         CurvePoint(x: 0.70001, y: 0.7), CurvePoint(x: 0.70004, y: 0.1)])
        XCTAssertEqual(c.points, [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 0.7, y: 0.7), CurvePoint(x: 1, y: 1)],
                       "first in input order wins a repeated x, at the written grain")
    }

    func testSanitizerCapsTheCountAndKeepsBothEnds() {
        let raw = (0..<20).map { CurvePoint(x: Double($0) / 19, y: Double($0) / 19) }.reversed()
        let c = CurvePoints(sanitising: Array(raw))
        XCTAssertEqual(c.points.count, CurvePoints.maxPoints)
        XCTAssertEqual(c.points.first, CurvePoint(x: 0, y: 0))
        XCTAssertEqual(c.points.last, CurvePoint(x: 1, y: 1))
    }

    func testSanitizerWithFewerThanTwoPointsIsIdentity() {
        XCTAssertEqual(CurvePoints(sanitising: []), .identity)
        XCTAssertEqual(CurvePoints(sanitising: [CurvePoint(x: 0.5, y: 0.5)]), .identity)
        XCTAssertEqual(CurvePoints(sanitising: [CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.5, y: 0.7)]), .identity)
        XCTAssertEqual(CurvePoints(sanitising: [CurvePoint(x: .nan, y: 0), CurvePoint(x: 1, y: 1)]), .identity)
    }

    /// Whatever goes in, the reader accepts what comes out, unchanged.
    func testSanitizedCurvesAlwaysPassTheReader() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let n = Int.random(in: 0...24, using: &rng)
            let raw = (0..<n).map { _ in
                CurvePoint(x: [Double.random(in: -0.2...1.2), 0.5, 0.50002, .nan].randomElement(using: &rng)!,
                           y: Double.random(in: -0.2...1.2, using: &rng))
            }
            let c = CurvePoints(sanitising: raw)
            XCTAssertEqual(XMPFormat.curve(XMPFormat.curve(c)), c, "\(raw) sanitized to a curve the reader refuses")
        }
    }

    // MARK: JSON (look files)

    func testJSONRoundTripsEachFieldAloneAndTogether() throws {
        let edits: [(String, (inout EnhanceSettings) -> Void)] = [
            ("vignetteSize", { $0.vignetteSize = 0.3 }),
            ("vignetteFeather", { $0.vignetteFeather = -0.3 }),
            ("levels", { $0.levels = Self.levels }),
            ("curves", { $0.curves.red = Self.bent }),
            ("all", { $0.vignetteSize = 0.3; $0.vignetteFeather = -0.3; $0.levels = Self.levels
                      $0.curves = Curves(rgb: Self.bent, red: Self.bent, green: Self.bent, blue: Self.bent) }),
        ]
        for (name, edit) in edits {
            var e = EnhanceSettings()
            edit(&e)
            let s = try json(e)
            if name != "all" { XCTAssertTrue(s.contains("\"\(name)\""), s) }
            let back = try JSONDecoder().decode(EnhanceSettings.self, from: Data(s.utf8))
            XCTAssertEqual(back, e, "\(name) did not survive JSON")
        }
    }

    func testJSONIdentityIsAnEmptyObjectAndIdentityCurvesAreOmitted() throws {
        XCTAssertEqual(try json(EnhanceSettings()), "{}")
        let s = try json(EnhanceSettings(curves: Curves(green: Self.bent)))
        XCTAssertTrue(s.contains("\"green\""), s)
        for absent in ["\"rgb\"", "\"red\"", "\"blue\"", "\"levels\"", "vignetteSize", "vignetteFeather"] {
            XCTAssertFalse(s.contains(absent), "\(absent) written at identity: \(s)")
        }
        XCTAssertEqual(try JSONDecoder().decode(Curves.self, from: Data("{}".utf8)), .identity)
    }

    /// These slider-only look files, already in sorted key order with no zero values, decode
    /// and re-encode to the same bytes.
    func testAnExistingLookFileDecodesUnchanged() throws {
        for old in [#"{"vibrance":0.2}"#, #"{"contrast":0.15,"richness":0.1,"vignette":-0.3,"warmth":0.05}"#] {
            let e = try JSONDecoder().decode(EnhanceSettings.self, from: Data(old.utf8))
            XCTAssertEqual(e.levels, .identity)
            XCTAssertEqual(e.curves, .identity)
            XCTAssertEqual(e.vignetteSize, 0)
            XCTAssertEqual(e.vignetteFeather, 0)
            XCTAssertEqual(try json(e), old, "an old look file re-encodes to the same bytes")
        }
        XCTAssertEqual(try JSONDecoder().decode(EnhanceSettings.self, from: Data(#"{"vibrance":0.2}"#.utf8)),
                       EnhanceSettings(vibrance: 0.2))
    }

    // MARK: the real Tether fixture

    /// The fixture, developed and enhanced with no levels or curves and no vignette size or
    /// feather set, rewrites byte-identical from its second write and never mentions them.
    /// The second write, not
    /// the first, for the reason in `AdjustFieldsTests.testUntouchedFixtureRewritesByteIdentical`:
    /// Foundation adds `standalone="yes"` once.
    func testUntouchedFixtureRewritesByteIdentical() throws {
        let data = try fixture("tether-040-crop")
        for name in Self.levelsCurveAndVignetteNames { XCTAssertFalse(text(data).contains(name)) }
        var sc = try Sidecar.decode(data, liveSource: live)
        sc.develop = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        sc.enhance = EnhanceSettings(vibrance: 0.2, vignette: -0.3)
        var bytes = try XMPSidecarCodec.encode(sc, into: try XMPSidecarCodec.parse(data).document)

        func rewrite(_ d: Data) throws -> Data {
            let packet = try XMPSidecarCodec.parse(d)
            let reread = try XMPSidecarCodec.decode(packet.fields, liveSource: live, strict: true)
            XCTAssertEqual(reread.enhance?.levels, .identity)
            XCTAssertEqual(reread.enhance?.curves, .identity)
            return try XMPSidecarCodec.encode(reread, into: packet.document)
        }
        bytes = try rewrite(bytes)
        XCTAssertEqual(try rewrite(bytes), bytes, "an untouched sidecar rewrites to the same bytes")
        for name in Self.levelsCurveAndVignetteNames { XCTAssertFalse(text(bytes).contains(name), "\(name) appeared in an untouched file") }
    }

    /// And the fixture with levels, all four curves and vignette size and feather set
    /// carries them all and keeps Tether's `BaseSampleR`.
    func testFixtureCarriesEveryLevelsCurveAndVignetteFieldAndKeepsForeignFields() throws {
        let data = try fixture("tether-040-crop")
        var sc = try Sidecar.decode(data, liveSource: live)
        sc.enhance = EnhanceSettings(vignetteSize: 0.2, vignetteFeather: 0.4, levels: Self.levels,
                                     curves: Curves(rgb: Self.bent, red: Self.bent, green: Self.bent, blue: Self.bent))
        let out = try XMPSidecarCodec.encode(sc, into: try XMPSidecarCodec.parse(data).document)
        XCTAssertTrue(text(out).contains("FilmTether:BaseSampleR=\"0.5431\""))
        for name in Self.levelsCurveAndVignetteNames { XCTAssertTrue(text(out).contains("FilmPositive:\(name)="), "\(name) missing") }
        let back = try Sidecar.decode(out, liveSource: live, strict: true)
        XCTAssertEqual(back.enhance, sc.enhance?.quantized())
    }
}
