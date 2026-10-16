import XCTest
@testable import FilmSidecar

final class SidecarTests: XCTestCase {
    var dir: URL!
    var image: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("film-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<200_000).map { UInt8($0 & 0xFF) }).write(to: image)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func full() throws -> Sidecar {
        Sidecar(
            source: try SidecarStore.source(for: image),
            capture: CaptureInfo(camera: "Leica M6", cameraMake: "Leica", film: "Kodak Gold 200", filmMaker: "Kodak",
                                 filmSizeID: "135-full", filmSizeName: "35mm", scannerMake: "Canon", scannerModel: "Canon EOS 7D"),
            geometry: GeometrySettings(rotate: 90, flip: true, straightenDegrees: 0.4,
                                       crop: CropRect(x: 0.076, y: 0.086, w: 0.848, h: 0.828)),
            samplePoint: NormalizedPoint(x: 0.02, y: 0.5),
            develop: DevelopSettings(stock: "kodak-gold-200", autoTone: true,
                                     base: BaseSettings(mode: .anchor, anchor: 43850, ratios: BaseRatios(rg: 0.465, bg: 0.7356))),
            enhance: EnhanceSettings(radiance: 0.35, highlights: -0.12, shadows: 0.10, vibrance: 0.12, saturation: 0.22, warmth: 0.05),
            look: "pop")
    }

    /// A packet with nothing in the Film or FilmPositive namespaces: standard provenance,
    /// eyedropper and preview fields and the fallback crop fields in the FilmTether
    /// namespace, and a dc:description element.
    static let tetherLegacy = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmTether">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:AnalogExif="http://analogexif.sourceforge.net/ns"
        xmlns:FilmTether="https://github.com/chriscantey/film-tether/ns/1.0/"
        tiff:Make="Olympus" tiff:Model="Olympus XA" AnalogExif:Film="Kodak UltraMax 400" AnalogExif:FilmMaker="Kodak"
        FilmTether:BaseSampleR="0.9123" FilmTether:BaseSampleG="0.7011" FilmTether:BaseSampleB="0.5502"
        FilmTether:PreviewInverted="True"
        FilmTether:CropX="0.1" FilmTether:CropY="0.12" FilmTether:CropW="0.8" FilmTether:CropH="0.76"
        FilmTether:CropStraightenDeg="0.5" FilmTether:CropFilmSizeID="135-full">
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Olympus XA, Kodak UltraMax 400</rdf:li></rdf:Alt></dc:description>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    func live() throws -> SidecarSource { try SidecarStore.source(for: image) }

    func testRoundTrip() throws {
        let sc = try full()
        let data = try sc.encoded()
        let back = try Sidecar.decode(data, liveSource: try live(), strict: true)
        XCTAssertEqual(back, sc.quantized())
        XCTAssertEqual(back.version, 1)
        XCTAssertTrue(back.isDeveloped)
        XCTAssertEqual(back.capture?.camera, "Leica M6")
        XCTAssertEqual(back.geometry?.rotate, 90)
        XCTAssertEqual(back.samplePoint, NormalizedPoint(x: 0.02, y: 0.5))
    }

    func testPacketShapeIsXMP() throws {
        let s = String(decoding: try full().encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("<x:xmpmeta"))
        XCTAssertTrue(s.contains("xmlns:Film=\"https://github.com/chriscantey/film-sidecar/ns/1.0/\""))
        XCTAssertTrue(s.contains("xmlns:FilmPositive=\"https://github.com/chriscantey/film-positive/ns/1.0/\""))
        XCTAssertTrue(s.contains("Film:Version=\"1\""))
        XCTAssertTrue(s.contains("Film:CropX=\"0.076\""))
        XCTAssertTrue(s.contains("tiff:Model=\"Leica M6\""))
        XCTAssertTrue(s.contains("AnalogExif:Film=\"Kodak Gold 200\""))
        XCTAssertTrue(s.contains("FilmPositive:Stock=\"kodak-gold-200\""))
        XCTAssertTrue(s.contains("FilmPositive:Radiance=\"0.35\""))
        XCTAssertFalse(s.contains("FilmPositive:Exposure"), "zero sliders are absent, not written as 0")
        XCTAssertTrue(s.contains("Film:Flip=\"True\""))
        XCTAssertLessThan(s.utf8.count, 8 * 1024)
        XCTAssertNoThrow(try XMLDocument(data: Data(s.utf8)))
    }

    func testQuantizationIsFixedQuantum() throws {
        var sc = try full()
        sc.enhance?.radiance = 0.123456789
        sc.geometry?.crop?.x = 0.1234567891
        sc.develop?.base.ratios?.rg = 0.46512345
        sc.samplePoint?.y = 0.5000000004
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live())
        XCTAssertEqual(back.enhance?.radiance, 0.1235)
        XCTAssertEqual(back.geometry?.crop?.x, 0.123457)
        XCTAssertEqual(back.develop?.base.ratios?.rg, 0.4651)
        XCTAssertEqual(back.samplePoint?.y, 0.5)
        XCTAssertEqual(sc.enhance?.radiance, 0.123456789, "live state untouched")
    }

    func testAbsentSectionsMeanUndevelopedAndIdentity() throws {
        let sc = Sidecar(source: try live())
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live(), strict: true)
        XCTAssertFalse(back.isDeveloped)
        XCTAssertNil(back.capture)
        XCTAssertNil(back.enhance)
        XCTAssertNil(back.geometry)
        XCTAssertNil(back.samplePoint)
        XCTAssertNil(back.look)
    }

    /// Reading a file in that shape: provenance from the standard fields, crop and
    /// straighten from Tether's own namespace, source filled from the live image.
    func testReadsTetherLegacyFile() throws {
        let store = SidecarStore()
        try Data(Self.tetherLegacy.utf8).write(to: SidecarStore.sidecarURL(for: image))
        let loaded = try XCTUnwrap(try store.load(for: image))
        XCTAssertEqual(loaded.status, .ok, "no fingerprint recorded means nothing to contradict")
        let sc = loaded.sidecar
        XCTAssertEqual(sc.capture?.camera, "Olympus XA")
        XCTAssertEqual(sc.capture?.cameraMake, "Olympus")
        XCTAssertEqual(sc.capture?.film, "Kodak UltraMax 400")
        XCTAssertEqual(sc.capture?.filmMaker, "Kodak")
        XCTAssertEqual(sc.capture?.filmSizeID, "135-full")
        XCTAssertEqual(sc.geometry?.crop, CropRect(x: 0.1, y: 0.12, w: 0.8, h: 0.76))
        XCTAssertEqual(sc.geometry?.straightenDegrees, 0.5)
        XCTAssertEqual(sc.geometry?.rotate, 0)
        XCTAssertEqual(sc.source.name, "IMG_0001.CR2")
        XCTAssertFalse(sc.isDeveloped)
    }

    /// Developing a frame in that shape: Tether's fields and elements survive, the
    /// crop is written into the shared namespace too, and our sections are added.
    func testDevelopPreservesTetherContent() throws {
        let store = SidecarStore()
        let url = SidecarStore.sidecarURL(for: image)
        try Data(Self.tetherLegacy.utf8).write(to: url)
        var sc = try XCTUnwrap(try store.load(for: image)).sidecar
        sc.develop = DevelopSettings(stock: "kodak-ultramax-400", base: BaseSettings(mode: .anchor, anchor: 40000))
        sc.enhance = EnhanceSettings(radiance: 0.2)
        sc.look = "pop"
        XCTAssertEqual(try store.save(sc, for: image), .written)

        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("FilmTether:BaseSampleR=\"0.9123\""), "Tether's own fields preserved")
        XCTAssertTrue(s.contains("FilmTether:PreviewInverted=\"True\""))
        XCTAssertTrue(s.contains("Olympus XA, Kodak UltraMax 400"), "dc:description element preserved")
        XCTAssertTrue(s.contains("Film:CropX=\"0.1\""), "crop written into the shared namespace too")
        XCTAssertTrue(s.contains("FilmPositive:Stock=\"kodak-ultramax-400\""))
        XCTAssertTrue(s.contains("Film:SourceFingerprint=\"sha256:"))

        let back = try XCTUnwrap(try store.load(for: image)).sidecar
        XCTAssertEqual(back.capture?.camera, "Olympus XA")
        XCTAssertEqual(back.geometry?.crop, CropRect(x: 0.1, y: 0.12, w: 0.8, h: 0.76))
        XCTAssertEqual(back.develop?.stock, "kodak-ultramax-400")
        XCTAssertEqual(back.enhance?.radiance, 0.2)
        XCTAssertEqual(try store.load(for: image)?.status, .ok)
    }

    /// Adobe's raw tools write their own namespace (`crs:`), often in a second
    /// rdf:Description. Its attributes must survive our rewrite intact.
    func testForeignNamespaceAndSecondDescriptionPreserved() throws {
        let store = SidecarStore()
        let url = SidecarStore.sidecarURL(for: image)
        try store.save(try full(), for: image)
        var s = try String(contentsOf: url, encoding: .utf8)
        let lr = """
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.35" crs:Version="15.0"/>
        """
        s = s.replacingOccurrences(of: "</rdf:RDF>", with: lr + "\n </rdf:RDF>")
        try Data(s.utf8).write(to: url)

        var sc = try XCTUnwrap(try store.load(for: image)).sidecar
        sc.look = "sunroom"
        XCTAssertEqual(try store.save(sc, for: image), .written)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("crs:Exposure2012=\"+0.35\""))
        XCTAssertTrue(after.contains("crs:Version=\"15.0\""))
        XCTAssertTrue(after.contains("FilmPositive:Look=\"sunroom\""))
        XCTAssertEqual(after.components(separatedBy: "FilmPositive:Look=").count - 1, 1, "written once")
    }

    func testMissingSliderDecodesAsZeroAndAutoToneDefaultsOn() throws {
        var s = try String(decoding: Sidecar(source: try live()).encoded(), as: UTF8.self)
        s = s.replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" xmlns:FilmPositive=\"https://github.com/chriscantey/film-positive/ns/1.0/\" FilmPositive:Radiance=\"0.3\" FilmPositive:Stock=\"bw-generic\" FilmPositive:Light=\"retired-light-id\"")
        let sc = try Sidecar.decode(Data(s.utf8), liveSource: try live(), strict: true)
        XCTAssertEqual(sc.enhance?.radiance, 0.3)
        XCTAssertEqual(sc.enhance?.vignette, 0)
        XCTAssertFalse(sc.enhance!.isIdentity)
        XCTAssertEqual(sc.develop?.autoTone, true)
        XCTAssertEqual(sc.develop?.base.mode, .anchor)
    }

    func testStrictDecodeRejectsUnknownOwnedFieldButNotForeign() throws {
        var s = String(decoding: try full().encoded(), as: UTF8.self)
        s = s.replacingOccurrences(of: "Film:Version=\"1\"", with: "Film:Version=\"1\" Film:Rotate2=\"90\" FilmPositive:Clarity=\"0.5\" xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" crs:Exposure2012=\"0\"")
        XCTAssertThrowsError(try Sidecar.decode(Data(s.utf8), liveSource: try live(), strict: true)) { err in
            XCTAssertEqual(err as? SidecarDecodeError, .unknownKeys(["Film:Rotate2", "FilmPositive:Clarity"]))
        }
        let lenient = try Sidecar.decode(Data(s.utf8), liveSource: try live(), strict: false)
        XCTAssertEqual(lenient.enhance?.radiance, 0.35)
    }

    func testNewerVersionIsReadOnly() throws {
        let url = SidecarStore.sidecarURL(for: image)
        var s = String(decoding: try full().encoded(), as: UTF8.self)
        s = s.replacingOccurrences(of: "Film:Version=\"1\"", with: "Film:Version=\"2\" Film:Future=\"x\"")
        try Data(s.utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let store = SidecarStore()
        let loaded = try XCTUnwrap(try store.load(for: image))
        XCTAssertEqual(loaded.status, .readOnly)
        XCTAssertEqual(loaded.sidecar.look, "pop")
        XCTAssertThrowsError(try store.save(loaded.sidecar, for: image))
        XCTAssertEqual(try Data(contentsOf: url), before, "read-only sidecar must not be rewritten")
    }

    func testCorruptFileIsNeverOverwritten() throws {
        let url = SidecarStore.sidecarURL(for: image)
        try Data("this is not xmp".utf8).write(to: url)
        let store = SidecarStore()
        XCTAssertThrowsError(try store.load(for: image))
        XCTAssertThrowsError(try store.save(try full(), for: image))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "this is not xmp")
    }

    func testFilename() throws {
        let url = SidecarStore.sidecarURL(for: image)
        XCTAssertEqual(url.lastPathComponent, "IMG_0001.xmp")
        XCTAssertTrue(SidecarStore.isSidecar(url))
        XCTAssertFalse(SidecarStore.isSidecar(image))
    }

    func testAtomicWriteSurvivesCrashBeforeReplace() throws {
        let store = SidecarStore()
        let first = try full()
        XCTAssertEqual(try store.save(first, for: image), .written)
        let url = SidecarStore.sidecarURL(for: image)
        let firstBytes = try Data(contentsOf: url)

        var second = first
        second.look = "sunroom"
        struct Crash: Error {}
        var crashing = SidecarStore()
        crashing.beforeReplace = { throw Crash() }
        XCTAssertThrowsError(try crashing.save(second, for: image))
        XCTAssertEqual(try Data(contentsOf: url), firstBytes, "old file intact after the simulated crash")
        let temps = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        XCTAssertEqual(temps.count, 1)
        // A crash leaves the temp behind. Once it is older than a minute, a load sweeps it.
        let leftover = dir.appendingPathComponent(try XCTUnwrap(temps.first))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)],
                                              ofItemAtPath: leftover.path)
        _ = try store.load(for: image)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }.count, 0)
        XCTAssertEqual(try store.save(second, for: image), .written)
        XCTAssertEqual(try XCTUnwrap(try store.load(for: image)).sidecar.look, "sunroom")
    }

    /// A temp under a minute old may be another app's save in progress in the same
    /// folder, so a load leaves it where it is.
    func testLoadLeavesAFreshTempAlone() throws {
        let store = SidecarStore()
        try store.save(try full(), for: image)
        let fresh = dir.appendingPathComponent(".IMG_0001.xmp.tmp-\(UUID().uuidString)")
        try Data("in flight".utf8).write(to: fresh)
        _ = try store.load(for: image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        SidecarStore.sweepStaleTemps(in: dir, now: Date().addingTimeInterval(SidecarStore.staleTempAge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testNoopSaveWritesNothing() throws {
        let store = SidecarStore()
        let sc = try full()
        try store.save(sc, for: image)
        let url = SidecarStore.sidecarURL(for: image)
        let m1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(try store.save(sc, for: image), .unchanged)
        let m2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        XCTAssertEqual(m1, m2, "mtime unchanged after a null edit")
    }

    func testSourceChangedDetectedByFingerprint() throws {
        let store = SidecarStore()
        try store.save(try full(), for: image)
        XCTAssertEqual(try store.load(for: image)?.status, .ok)
        try Data((0..<200_000).map { UInt8(($0 &+ 7) & 0xFF) }).write(to: image)
        XCTAssertEqual(try store.load(for: image)?.status, .sourceChanged)
    }

    func testRemoveLeavesNoSidecar() throws {
        let store = SidecarStore()
        try store.save(try full(), for: image)
        try store.remove(for: image)
        XCTAssertNil(try store.load(for: image))
    }

    func testFingerprintCoversFirst64KBOnly() throws {
        let a = try SidecarStore.fingerprint(of: image)
        var bytes = try Data(contentsOf: image)
        bytes[100_000] ^= 0xFF
        try bytes.write(to: image)
        XCTAssertEqual(try SidecarStore.fingerprint(of: image), a)
        bytes[10] ^= 0xFF
        try bytes.write(to: image)
        XCTAssertNotEqual(try SidecarStore.fingerprint(of: image), a)
        XCTAssertTrue(a.hasPrefix("sha256:"))
        XCTAssertEqual(a.count, 7 + 64)
    }

    // MARK: tone and auto balance

    /// All three tone states survive a write and a read, and so does auto balance in both
    /// positions. The point of the round trip is the key names: a typo in the key the
    /// decoder reads would read as a default rather than as an error.
    func testToneAndAutoBalanceRoundTripInAllStates() throws {
        for tone in [ToneMode.none, .flat, .print] {
            for balance in [true, false] {
                var sc = try full()
                sc.develop = DevelopSettings(stock: "kodak-gold-200", tone: tone,
                                             autoBalance: balance, base: BaseSettings(mode: .anchor, anchor: 40000))
                let back = try Sidecar.decode(try sc.encoded(), liveSource: sc.source, strict: true)
                XCTAssertEqual(back.develop?.tone, tone, "tone \(tone) did not survive")
                XCTAssertEqual(back.develop?.autoBalance, balance, "autoBalance \(balance) did not survive")
            }
        }
    }

    /// A sidecar with `AutoTone` and no `ToneMode`: True reads as `flat`, False as `none`.
    func testOldAutoToneMigratesToToneMode() throws {
        for (old, expected) in [(true, ToneMode.flat), (false, ToneMode.none)] {
            var a = XMPSidecarCodec.attributes(for: try full())
            a[XMPField.positive("AutoTone")] = XMPFormat.bool(old)
            a[XMPField.positive("ToneMode")] = nil
            let sc = try XMPSidecarCodec.decode(a, liveSource: try SidecarStore.source(for: image), strict: true)
            XCTAssertEqual(sc.develop?.tone, expected)
            XCTAssertEqual(sc.develop?.autoTone, old)
        }
    }

    /// A sidecar with neither key reads as the pair of defaults: the anchored tone, and
    /// auto balance on. Both are what those frames actually rendered with.
    func testMissingToneAndBalanceKeysReadAsDefaults() throws {
        var a = XMPSidecarCodec.attributes(for: try full())
        a[XMPField.positive("AutoTone")] = nil
        a[XMPField.positive("ToneMode")] = nil
        a[XMPField.positive("AutoBalance")] = nil
        let sc = try XMPSidecarCodec.decode(a, liveSource: try SidecarStore.source(for: image), strict: true)
        XCTAssertEqual(sc.develop?.tone, .flat)
        XCTAssertEqual(sc.develop?.autoBalance, true)
    }

    /// `ToneMode` wins over `AutoTone` when both are present, because a build that writes both
    /// writes `ToneMode` as the truth and `AutoTone` as the degraded copy for older readers.
    func testToneWinsOverAutoToneWhenBothPresent() throws {
        var a = XMPSidecarCodec.attributes(for: try full())
        a[XMPField.positive("ToneMode")] = ToneMode.none.rawValue
        a[XMPField.positive("AutoTone")] = XMPFormat.bool(true)
        let sc = try XMPSidecarCodec.decode(a, liveSource: try SidecarStore.source(for: image), strict: true)
        XCTAssertEqual(sc.develop?.tone, ToneMode.none)
    }

    /// The canary for a class of silent data loss. Foundation's `XMLElement.addAttribute`
    /// drops an attribute whose local name is a suffix of one already on the element in the
    /// same namespace (the case probed), with no error anywhere. In the codec's sorted write
    /// order a key named `Tone` would be lost this way behind `AutoTone`, and the packet
    /// would still parse.
    ///
    /// So this asserts that every attribute the codec says it writes is in the bytes
    /// afterwards. A future field named `Lights` next to `Highlights`, or `Mode` next to
    /// `BaseMode`, fails here once this test sets it.
    func testEncodeLandsEveryAttribute() throws {
        var sc = try full()
        sc.develop?.tone = .print
        sc.develop?.autoBalance = false
        // Each field below is written only when set or moved off identity, so each is set
        // here, or the check at the end could not see it.
        sc.develop?.colourAxes = ColourAxes(warm: 6.5, green: -3.25)
        sc.colorAuto = WarmthTint(warmth: 0.1234, tint: -0.05)
        sc.develop?.toneAdjust = ToneAdjust(exposure: 0.15, contrast: 1.1, black: 0.02, white: 0.97)
        sc.develop?.highlightAxes = ColourAxes(warm: 2.5, green: -1.25)
        sc.develop?.stretch = 0.65
        sc.enhance?.vignetteSize = 0.3
        sc.enhance?.vignetteFeather = -0.4
        sc.enhance?.levels = Levels(inBlack: 0.05, gamma: 1.2, inWhite: 0.95, outBlack: 0.02, outWhite: 0.98)
        let bent = CurvePoints(sanitising: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
        sc.enhance?.curves = Curves(rgb: bent, red: bent, green: bent, blue: bent)
        let expected = XMPSidecarCodec.attributes(for: sc)
        for name in ["VignetteSize", "VignetteFeather", "Levels", "CurveRGB", "CurveRed", "CurveGreen", "CurveBlue"] {
            XCTAssertNotNil(expected[XMPField.positive(name)], "the canary must carry \(name) to cover it")
        }
        XCTAssertNotNil(expected[XMPField.positive("ColorAuto")], "the canary must carry ColorAuto to cover it")
        XCTAssertNotNil(expected[XMPField.positive("ToneAdjust")], "the canary must carry ToneAdjust to cover it")
        XCTAssertNotNil(expected[XMPField.positive("HighlightAxes")], "the canary must carry HighlightAxes to cover it")
        XCTAssertNotNil(expected[XMPField.positive("Stretch")], "the canary must carry Stretch to cover it")
        let written = try XMPSidecarCodec.parse(try sc.encoded()).fields
        for (key, value) in expected {
            XCTAssertEqual(written[key], value, "\(key) did not survive encode")
        }
    }

    /// The Color Auto record round-trips as "warmth tint" at the slider grain, so a
    /// pair written beside the sliders still equals them once the file is read back.
    func testColorAutoRoundTripsAtTheSliderGrain() throws {
        var sc = try full()
        sc.enhance?.warmth = 0.123456
        sc.enhance?.tint = -0.0712
        sc.colorAuto = WarmthTint(warmth: 0.123456, tint: -0.0712)
        let data = try sc.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("FilmPositive:ColorAuto=\"0.1235 -0.0712\""))
        let back = try Sidecar.decode(data, liveSource: try live(), strict: true)
        XCTAssertEqual(back.colorAuto, WarmthTint(warmth: 0.1235, tint: -0.0712))
        XCTAssertEqual(back.colorAuto?.warmth, back.enhance?.warmth, "the record equals the slider it was written beside")
        XCTAssertEqual(back.colorAuto?.tint, back.enhance?.tint)
        XCTAssertEqual(back, sc.quantized())
    }

    /// A sidecar with no Color Auto record writes none back and rewrites to the same
    /// bytes, and the malformed values below read as no record rather than failing the file.
    func testASidecarWithoutColorAutoWritesNoneAndReadsJunkAsNoRecord() throws {
        let old = try full()
        XCTAssertNil(old.colorAuto)
        let bytes = try old.encoded()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("ColorAuto"), "no record, no attribute")
        let back = try Sidecar.decode(bytes, liveSource: try live(), strict: true)
        XCTAssertNil(back.colorAuto)
        XCTAssertEqual(try back.encoded(), bytes, "an untouched old file rewrites to the same bytes")

        for junk in ["0.1", "a b", "0.1 0.2 0.3", ""] {
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "FilmPositive:Stock=", with: "FilmPositive:ColorAuto=\"\(junk)\" FilmPositive:Stock=")
            let read = try Sidecar.decode(Data(text.utf8), liveSource: try live(), strict: true)
            XCTAssertNil(read.colorAuto, "\(junk) is not a record")
            XCTAssertEqual(read.enhance, old.enhance?.quantized(), "and the rest of the file is intact")
        }
    }

    /// We keep writing `AutoTone` so a build that predates `ToneMode` still reads something
    /// sensible. `print` degrades to True: lab-print contrast is nearer the anchored tone
    /// than it is to no tone step.
    func testStillWritesAutoToneForOlderReaders() throws {
        for (tone, expected) in [(ToneMode.none, "False"), (.flat, "True"), (.print, "True")] {
            var sc = try full()
            sc.develop = DevelopSettings(stock: "s", tone: tone, autoBalance: true,
                                         base: BaseSettings(mode: .anchor))
            XCTAssertEqual(XMPSidecarCodec.attributes(for: sc)[XMPField.positive("AutoTone")], expected)
        }
    }

    /// The retired `Light` field (the scanner calibration id): an old
    /// sidecar carrying it still opens with its develop layer intact, strict decode included,
    /// and the file written back from it no longer contains it.
    func testARetiredLightFieldStillReadsAndIsNeverWritten() throws {
        let store = SidecarStore()
        let url = SidecarStore.sidecarURL(for: image)
        var old = String(decoding: try full().encoded(), as: UTF8.self)
        XCTAssertFalse(old.contains("FilmPositive:Light="), "a new sidecar wrote the retired Light field")
        old = old.replacingOccurrences(of: "FilmPositive:Stock=", with: "FilmPositive:Light=\"retired-light-id\" FilmPositive:Stock=")
        XCTAssertTrue(old.contains("FilmPositive:Light=\"retired-light-id\""), "the fixture did not get its Light field")
        try Data(old.utf8).write(to: url)

        let strict = try Sidecar.decode(Data(old.utf8), liveSource: try live(), strict: true)
        XCTAssertEqual(strict.develop?.stock, "kodak-gold-200", "an old sidecar lost its develop layer")
        XCTAssertEqual(strict.develop, try full().develop, "the Light field changed what was read")

        var sc = try XCTUnwrap(try store.load(for: image)).sidecar
        XCTAssertEqual(sc.develop?.stock, "kodak-gold-200")
        sc.look = "sunroom"
        XCTAssertEqual(try store.save(sc, for: image), .written)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("Light="), "the rewrite kept the retired Light field")
        XCTAssertTrue(written.contains("FilmPositive:Stock=\"kodak-gold-200\""))
        XCTAssertNil(XMPSidecarCodec.attributes(for: sc)[XMPField.positive("Light")])
    }

    /// A sidecar with a Stock and no Light at all, which is what the codec writes, reads
    /// back its develop layer.
    func testADevelopLayerWithNoLightFieldReads() throws {
        var s = try String(decoding: Sidecar(source: try live()).encoded(), as: UTF8.self)
        s = s.replacingOccurrences(of: "rdf:about=\"\"", with: "rdf:about=\"\" xmlns:FilmPositive=\"https://github.com/chriscantey/film-positive/ns/1.0/\" FilmPositive:Stock=\"kodak-gold-200\" FilmPositive:ToneMode=\"none\"")
        let sc = try Sidecar.decode(Data(s.utf8), liveSource: try live(), strict: true)
        XCTAssertEqual(sc.develop?.stock, "kodak-gold-200")
        XCTAssertEqual(sc.develop?.tone, ToneMode.none)
    }

    /// `Film:TakenOn`: the day a frame was shot, round-tripped beside the other capture
    /// fields, and a malformed day neither written nor read.
    func testTakenOnRoundTripsAndABadDayIsDropped() throws {
        var sc = try full()
        sc.capture?.takenOn = "2026-06-14"
        let text = String(decoding: try sc.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("TakenOn=\"2026-06-14\""), "written as a plain day")
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live(), strict: true)
        XCTAssertEqual(back.capture?.takenOn, "2026-06-14")
        XCTAssertEqual(back.capture?.camera, "Leica M6", "the capture fields beside it survive")

        for bad in ["2026-02-30", "26-06-14", "2026-6-14", "June 14", ""] {
            XCTAssertNil(CaptureInfo.validDay(bad), bad)
            sc.capture?.takenOn = bad
            XCTAssertFalse(String(decoding: try sc.encoded(), as: UTF8.self).contains("TakenOn="), "\(bad) is not written")
        }
        XCTAssertEqual(CaptureInfo.validDay("2024-02-29"), "2024-02-29", "a leap day is a day")
    }

    /// Film:FilmSizeName: the plain name rides beside the id, free text rides
    /// alone, and a blank one is neither written nor read.
    func testFilmSizeNameRoundTripsWithAndWithoutAnId() throws {
        var sc = try full()
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live(), strict: true)
        XCTAssertEqual(back.capture?.filmSizeName, "35mm")
        XCTAssertEqual(back.capture?.filmSizeID, "135-full", "the id beside it survives")

        sc.capture?.filmSizeID = nil
        sc.capture?.filmSizeName = "  127 roll "
        let text = String(decoding: try sc.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("FilmSizeName=\"127 roll\""), "free text written trimmed")
        XCTAssertFalse(text.contains("FilmSizeID="), "no id when there is none")
        XCTAssertEqual(try Sidecar.decode(try sc.encoded(), liveSource: try live(), strict: true).capture?.filmSizeName, "127 roll")

        sc.capture?.filmSizeName = "   "
        XCTAssertFalse(String(decoding: try sc.encoded(), as: UTF8.self).contains("FilmSizeName="), "a blank name is not written")
    }

    /// An older sidecar with only the id still reads, with no name.
    func testASidecarWithOnlyAnIdReadsWithNoName() throws {
        var sc = try full()
        sc.capture?.filmSizeName = nil
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live(), strict: true)
        XCTAssertEqual(back.capture?.filmSizeID, "135-full")
        XCTAssertNil(back.capture?.filmSizeName)
    }
}
