import XCTest
@testable import FilmSidecar

/// The Tone row's Adjust (`FilmPositive:ToneAdjust`, four numbers) and
/// the Stock row's Adjust (`FilmPositive:HighlightAxes`, two numbers). Storage only.
final class AdjustFieldsTests: XCTestCase {
    private var live: SidecarSource {
        SidecarSource(name: "IMG_0001.CR2", size: 1, mtime: Date(timeIntervalSince1970: 0), fingerprint: "sha256:00")
    }

    private func developed(tone: ToneAdjust? = nil, highlight: ColourAxes = .identity) -> Sidecar {
        var dv = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        dv.toneAdjust = tone
        dv.highlightAxes = highlight
        return Sidecar(source: live, develop: dv)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// The bytes with `attr` spliced in beside Stock, the way another writer might put it there.
    private func with(_ attr: String, in data: Data) -> Data {
        Data(text(data).replacingOccurrences(of: "FilmPositive:Stock=", with: "\(attr) FilmPositive:Stock=").utf8)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name + ".xmp")
        return try Data(contentsOf: url)
    }

    func testDefaultsAreNilAndIdentity() {
        let dv = DevelopSettings(stock: "x", base: BaseSettings(mode: .anchor))
        XCTAssertNil(dv.toneAdjust)
        XCTAssertTrue(dv.highlightAxes.isIdentity)
    }

    func testToneAdjustAloneRoundTrips() throws {
        let sc = developed(tone: ToneAdjust(exposure: -0.3, contrast: 1.25, black: 0.015, white: 0.985))
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:ToneAdjust=\"-0.3 1.25 0.015 0.985\""), text(data))
        XCTAssertFalse(text(data).contains("HighlightAxes"))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.toneAdjust, ToneAdjust(exposure: -0.3, contrast: 1.25, black: 0.015, white: 0.985))
        XCTAssertTrue(back.develop?.highlightAxes.isIdentity ?? false)
        XCTAssertEqual(back, sc.quantized())
    }

    func testHighlightAxesAloneRoundTrips() throws {
        let sc = developed(highlight: ColourAxes(warm: 4.5, green: -2.125))
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:HighlightAxes=\"4.5 -2.125\""), text(data))
        XCTAssertFalse(text(data).contains("ToneAdjust"))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.highlightAxes, ColourAxes(warm: 4.5, green: -2.125))
        XCTAssertNil(back.develop?.toneAdjust)
        XCTAssertEqual(back, sc.quantized())
    }

    /// Both together, beside the Base row's own axes, each kept to its own field.
    func testBothTogetherRoundTripAndStayApartFromTheBaseAxes() throws {
        var sc = developed(tone: ToneAdjust(exposure: 0.15, contrast: 0.9, black: 0, white: 1),
                           highlight: ColourAxes(warm: -3, green: 1.5))
        sc.develop?.colourAxes = ColourAxes(warm: 6.5, green: -3.25)
        let back = try Sidecar.decode(try sc.encoded(), liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.toneAdjust, ToneAdjust(exposure: 0.15, contrast: 0.9, black: 0, white: 1))
        XCTAssertEqual(back.develop?.highlightAxes, ColourAxes(warm: -3, green: 1.5))
        XCTAssertEqual(back.develop?.colourAxes, ColourAxes(warm: 6.5, green: -3.25))
        XCTAssertEqual(back, sc.quantized())
        XCTAssertEqual(try back.encoded(), try sc.encoded(), "a second write is the same bytes")
    }

    /// Values finer than the written grain are held to it, so the read-back equals the
    /// quantized copy exactly rather than approximately.
    func testValuesAreHeldToTheWrittenGrain() throws {
        let sc = developed(tone: ToneAdjust(exposure: 0.123456, contrast: 1.000049, black: 0.00004, white: 0.99996),
                           highlight: ColourAxes(warm: 1.23456, green: -0.0004))
        let data = try sc.encoded()
        XCTAssertTrue(text(data).contains("FilmPositive:ToneAdjust=\"0.1235 1 0 1\""), text(data))
        XCTAssertTrue(text(data).contains("FilmPositive:HighlightAxes=\"1.235 0\""), text(data))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertEqual(back, sc.quantized())
    }

    /// Nil and identity write nothing, so a frame nobody adjusted never mentions either.
    func testNilAndIdentityWriteNothing() throws {
        let data = try developed().encoded()
        XCTAssertFalse(text(data).contains("ToneAdjust"))
        XCTAssertFalse(text(data).contains("HighlightAxes"))
        let back = try Sidecar.decode(data, liveSource: live, strict: true)
        XCTAssertNil(back.develop?.toneAdjust)
        XCTAssertTrue(back.develop?.highlightAxes.isIdentity ?? false)
    }

    /// A malformed value reads as nil / identity and costs nothing else in the file.
    func testMalformedReadsAsNilAndIdentity() throws {
        let base = try developed().encoded()
        for junk in ["", "0.1", "0.1 1 0", "0.1 1 0 1 0", "0.1 x 0 1", "a b c d", "nan 1 0 1", "0.1 inf 0 1", "0.1,1,0,1"] {
            let read = try Sidecar.decode(with("FilmPositive:ToneAdjust=\"\(junk)\"", in: base), liveSource: live, strict: true)
            XCTAssertNil(read.develop?.toneAdjust, "\(junk) is not a ToneAdjust")
            XCTAssertEqual(read.develop?.stock, "kodak-portra-400", "and the rest of the file is intact")
        }
        for junk in ["", "1", "1 2 3", "1 x", "x 1", "nan 0", "0 -inf", "1,2"] {
            let read = try Sidecar.decode(with("FilmPositive:HighlightAxes=\"\(junk)\"", in: base), liveSource: live, strict: true)
            XCTAssertTrue(read.develop?.highlightAxes.isIdentity ?? false, "\(junk) is not a HighlightAxes")
            XCTAssertEqual(read.develop?.stock, "kodak-portra-400")
        }
    }

    /// No name in `checked` is a suffix of any name on the element and none of those is a
    /// suffix of a name in `checked`, compared case-insensitively. Foundation's XML writer
    /// drops such an attribute silently within one namespace (see XMPField.positiveKnown),
    /// and this test holds these names to the rule across namespaces as well. The list covers every name this codec writes plus
    /// Film Tether's own namespace, which shares the element. The predicate is checked
    /// against the known AutoTone / Tone collision first, so it cannot pass by being blind.
    func testAdjustAndEnhanceFieldNamesShareNoSuffix() {
        func collides(_ a: String, _ b: String) -> Bool {
            let x = a.lowercased(), y = b.lowercased()
            return x.hasSuffix(y) || y.hasSuffix(x)
        }
        XCTAssertTrue(collides("AutoTone", "Tone"), "canary: the predicate must see the known collision")
        let tether = ["BaseSampleR", "BaseSampleG", "BaseSampleB", "CropX", "CropY", "CropW", "CropH",
                      "CropStraightenDeg", "CropFilmSizeID", "PreviewGain", "PreviewGainR", "PreviewGainG",
                      "PreviewGainB", "PreviewInverted", "PreviewMonochrome"]
        let standard = ["Make", "Model", "Film", "FilmMaker", "about"]
        let checked = ["ToneAdjust", "Stretch", "HighlightAxes", "VignetteSize", "VignetteFeather", "Levels",
                     "CurveRGB", "CurveRed", "CurveGreen", "CurveBlue"]
        XCTAssertTrue(collides("VignetteSoftness", "Softness"), "canary: the obvious name for the third vignette slider collides")
        XCTAssertTrue(collides("ToneStretch", "Stretch"), "canary: a Stretch qualified by its row would collide")
        let others = XMPField.filmKnown.union(XMPField.positiveKnown).union(tether).union(standard)
        for n in checked {
            for o in others.union(checked) where o != n {
                XCTAssertFalse(collides(n, o), "\(n) and \(o): one is a suffix of the other")
            }
        }
        // Every slider's wire name, read from sliderKeys rather than typed here, so a slider
        // renamed in the source (vignetteFeather to vignetteSoftness, say) fails this test too.
        for n in EnhanceSettings.sliderKeys.map(\.xmpName) {
            for o in others.union(checked) where o != n {
                XCTAssertFalse(collides(n, o), "slider \(n) and \(o): one is a suffix of the other")
            }
        }
    }

    /// The Tether fixture, developed with neither field set, rewrites byte-identical:
    /// decode what we wrote and write it back into its own document.
    ///
    /// The comparison starts at the second write on purpose. The first write into a Tether
    /// file gains `<?xml version="1.0"?>`, and Foundation reads that back and writes it as
    /// `standalone="yes"` once, then never again. That comes from Foundation, not from these
    /// fields.
    func testUntouchedFixtureRewritesByteIdentical() throws {
        let data = try fixture("tether-040-crop")
        var sc = try Sidecar.decode(data, liveSource: live)
        sc.develop = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        var bytes = try XMPSidecarCodec.encode(sc, into: try XMPSidecarCodec.parse(data).document)
        XCTAssertFalse(text(bytes).contains("ToneAdjust"))
        XCTAssertFalse(text(bytes).contains("HighlightAxes"))

        func rewrite(_ d: Data) throws -> Data {
            let packet = try XMPSidecarCodec.parse(d)
            let reread = try XMPSidecarCodec.decode(packet.fields, liveSource: live, strict: true)
            XCTAssertNil(reread.develop?.toneAdjust)
            XCTAssertTrue(reread.develop?.highlightAxes.isIdentity ?? false)
            return try XMPSidecarCodec.encode(reread, into: packet.document)
        }
        bytes = try rewrite(bytes)
        XCTAssertEqual(try rewrite(bytes), bytes, "an untouched sidecar rewrites to the same bytes")
        XCTAssertFalse(text(bytes).contains("ToneAdjust"))
        XCTAssertFalse(text(bytes).contains("HighlightAxes"))
    }

    /// And the fixture with both set carries both values and keeps Tether's `BaseSampleR`.
    func testFixtureCarriesBothAndKeepsForeignFields() throws {
        let data = try fixture("tether-040-crop")
        var sc = try Sidecar.decode(data, liveSource: live)
        var dv = DevelopSettings(stock: "kodak-portra-400", base: BaseSettings(mode: .anchor, anchor: 3000))
        dv.toneAdjust = ToneAdjust(exposure: 0.3, contrast: 1.2, black: 0.01, white: 0.99)
        dv.highlightAxes = ColourAxes(warm: 1, green: 2)
        sc.develop = dv
        let out = try XMPSidecarCodec.encode(sc, into: try XMPSidecarCodec.parse(data).document)
        XCTAssertTrue(text(out).contains("FilmPositive:ToneAdjust=\"0.3 1.2 0.01 0.99\""))
        XCTAssertTrue(text(out).contains("FilmPositive:HighlightAxes=\"1 2\""))
        XCTAssertTrue(text(out).contains("FilmTether:BaseSampleR=\"0.5431\""))
        let back = try Sidecar.decode(out, liveSource: live, strict: true)
        XCTAssertEqual(back.develop?.toneAdjust, dv.toneAdjust)
        XCTAssertEqual(back.develop?.highlightAxes, dv.highlightAxes)
    }
}
