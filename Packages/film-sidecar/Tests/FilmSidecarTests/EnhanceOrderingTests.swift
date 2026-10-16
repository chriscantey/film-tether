import XCTest
@testable import FilmSidecar

/// `EnhanceSettings` carries the slider set in three parallel orderings that must agree
/// or a sidecar silently reads one control into another:
///
///   1. `EnhanceSettings.sliderKeys`, the wire names, in index order
///   2. `EnhanceSettings.values`, the array the index subscript reads
///   3. `subscript(slider:)` in `XMP.swift`, the hardcoded index switch
///
/// Nothing in the type system ties them together.
///
/// The fourth listing below is written out by hand on purpose. A test that reached for
/// `sliderKeys` or `values` to drive itself would be checking one of the orderings
/// against itself.
final class EnhanceOrderingTests: XCTestCase {
    /// key name, a setter that writes only that stored property by name, and a getter
    /// that reads it back by name.
    static let byName: [(key: String, set: (inout EnhanceSettings) -> Void, get: (EnhanceSettings) -> Double)] = [
        ("radiance", { $0.radiance = 0.5 }, { $0.radiance }),
        ("exposure", { $0.exposure = 0.5 }, { $0.exposure }),
        ("highlights", { $0.highlights = 0.5 }, { $0.highlights }),
        ("shadows", { $0.shadows = 0.5 }, { $0.shadows }),
        ("contrast", { $0.contrast = 0.5 }, { $0.contrast }),
        ("brightness", { $0.brightness = 0.5 }, { $0.brightness }),
        ("blackPoint", { $0.blackPoint = 0.5 }, { $0.blackPoint }),
        ("vibrance", { $0.vibrance = 0.5 }, { $0.vibrance }),
        ("saturation", { $0.saturation = 0.5 }, { $0.saturation }),
        ("warmth", { $0.warmth = 0.5 }, { $0.warmth }),
        ("tint", { $0.tint = 0.5 }, { $0.tint }),
        ("definition", { $0.definition = 0.5 }, { $0.definition }),
        ("sharpness", { $0.sharpness = 0.5 }, { $0.sharpness }),
        ("noiseReduction", { $0.noiseReduction = 0.5 }, { $0.noiseReduction }),
        ("vignette", { $0.vignette = 0.5 }, { $0.vignette }),
        ("glow", { $0.glow = 0.5 }, { $0.glow }),
        ("halation", { $0.halation = 0.5 }, { $0.halation }),
        ("softness", { $0.softness = 0.5 }, { $0.softness }),
        ("richness", { $0.richness = 0.5 }, { $0.richness }),
        ("vignetteSize", { $0.vignetteSize = 0.5 }, { $0.vignetteSize }),
        ("vignetteFeather", { $0.vignetteFeather = 0.5 }, { $0.vignetteFeather }),
    ]

    func testTheWireNamesAreInTheOrderTheCodecIndexesThem() {
        XCTAssertEqual(Self.byName.map(\.key), EnhanceSettings.sliderKeys,
                       "sliderKeys no longer matches the order listed here. Unless values and subscript(slider:) moved with it, a named field reads into a different slider.")
    }

    func testValuesAndTheIndexSubscriptAgreeWithTheNamedProperties() {
        for (i, entry) in Self.byName.enumerated() {
            var byProperty = EnhanceSettings()
            entry.set(&byProperty)
            XCTAssertEqual(byProperty.values[i], 0.5, "values is out of order at index \(i), key \(entry.key)")
            XCTAssertEqual(byProperty.values.filter { $0 != 0 }.count, 1,
                           "setting \(entry.key) moved more than one entry of values")

            var byIndex = EnhanceSettings()
            byIndex[slider: i] = 0.5
            XCTAssertEqual(entry.get(byIndex), 0.5,
                           "subscript(slider: \(i)) writes a different field than \(entry.key)")
            XCTAssertEqual(byIndex, byProperty,
                           "subscript(slider:) and the named property disagree at \(entry.key)")
            XCTAssertEqual(byIndex.values[i], byProperty.values[i])
        }
    }

    func testTheIndexSubscriptReadsBackWhatItWrote() {
        var e = EnhanceSettings()
        for i in 0..<EnhanceSettings.sliderKeys.count { e[slider: i] = Double(i + 1) / 100 }
        for i in 0..<EnhanceSettings.sliderKeys.count {
            XCTAssertEqual(e[slider: i], Double(i + 1) / 100, accuracy: 1e-12, "index \(i) did not survive")
        }
        XCTAssertEqual(e.values.count, EnhanceSettings.sliderKeys.count)
    }

    /// Write a sidecar carrying contrast and brightness, read it back, and require both to
    /// land where they started.
    ///
    /// Encode and decode both walk the same `sliderKeys` by index, so a symmetric change
    /// still round trips, and this test catches only an asymmetric shift. The ordering assertions above catch a symmetric one, and
    /// `testAFrozenFileStillReadsItsContrastAsContrast` below covers files already on disk.
    func testContrastAndBrightnessSurviveAWriteAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)

        var enhance = EnhanceSettings()
        enhance.contrast = 0.4
        enhance.brightness = -0.2
        let sc = Sidecar(source: try SidecarStore.source(for: image), enhance: enhance)

        let store = SidecarStore()
        _ = try store.save(sc, for: image)
        let back = try XCTUnwrap(try store.load(for: image)).sidecar.enhance

        XCTAssertEqual(back?.contrast, 0.4, "contrast came back as something else")
        XCTAssertEqual(back?.brightness, -0.2, "brightness came back as something else")
        XCTAssertEqual(back, enhance, "the whole enhance section must survive unchanged")
    }

    /// A file frozen as text, the guard for sidecars already on disk. The round trips above
    /// write and read through the same code, so a symmetric change (`sliderKeys` reordered,
    /// say) still round trips. This file's bytes do not change when the
    /// code does, so it catches that change.
    func testAFrozenFileStillReadsItsContrastAsContrast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)

        let packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmPositive">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:FilmPositive="https://github.com/chriscantey/film-positive/ns/1.0/"
            FilmPositive:Contrast="0.4" FilmPositive:Brightness="-0.2" FilmPositive:Saturation="0.35"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(packet.utf8).write(to: SidecarStore.sidecarURL(for: image))

        let e = try XCTUnwrap(try XCTUnwrap(try SidecarStore().load(for: image)).sidecar.enhance)
        XCTAssertEqual(e.contrast, 0.4, "a file on disk read its Contrast as something else")
        XCTAssertEqual(e.brightness, -0.2, "a file on disk read its Brightness as something else")
        XCTAssertEqual(e.saturation, 0.35)
        XCTAssertEqual(e.values.filter { $0 != 0 }.count, 3, "the file carried three sliders and nothing else")
    }

    /// Every key, not just the pair above: each slider written alone must come back alone.
    func testEverySliderSurvivesAWriteAndReadOnItsOwn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidecarStore()

        for (i, entry) in Self.byName.enumerated() {
            let image = dir.appendingPathComponent("IMG_\(i).CR2")
            try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)
            var enhance = EnhanceSettings()
            entry.set(&enhance)
            _ = try store.save(Sidecar(source: try SidecarStore.source(for: image), enhance: enhance), for: image)
            let back = try XCTUnwrap(try XCTUnwrap(try store.load(for: image)).sidecar.enhance)
            XCTAssertEqual(entry.get(back), 0.5, "\(entry.key) did not survive the round trip")
            XCTAssertEqual(back.values.filter { $0 != 0 }.count, 1, "\(entry.key) came back with company")
        }
    }

    /// A sidecar that names only the first fifteen sliders must read with every one of them
    /// where it was, and with Glow, Halation, Softness and Richness at identity.
    func testAFifteenSliderFileReadsGlowThroughRichnessAsZero() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)

        let old = Array(EnhanceSettings.sliderKeys.prefix(15))
        let attrs = old.enumerated().map { i, k in
            "FilmPositive:\(k.prefix(1).uppercased() + k.dropFirst())=\"\(Double(i + 1) / 100)\""
        }.joined(separator: " ")
        let packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmPositive">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:FilmPositive="https://github.com/chriscantey/film-positive/ns/1.0/"
            \(attrs)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(packet.utf8).write(to: SidecarStore.sidecarURL(for: image))

        let e = try XCTUnwrap(try XCTUnwrap(try SidecarStore().load(for: image)).sidecar.enhance)
        for i in 0..<15 { XCTAssertEqual(e[slider: i], Double(i + 1) / 100, accuracy: 1e-9, "\(old[i]) moved") }
        XCTAssertEqual(e.glow, 0)
        XCTAssertEqual(e.halation, 0)
        XCTAssertEqual(e.softness, 0)
        XCTAssertEqual(e.richness, 0)
    }

    /// Richness follows the first eighteen sliders. A sidecar that names only those eighteen
    /// must read with every one of them where it was, and with Richness at identity.
    func testAnEighteenSliderFileReadsRichnessAsZero() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-18-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)

        let old = Array(EnhanceSettings.sliderKeys.prefix(18))
        XCTAssertFalse(old.contains("richness"))
        let attrs = old.enumerated().map { i, k in
            "FilmPositive:\(k.prefix(1).uppercased() + k.dropFirst())=\"\(Double(i + 1) / 100)\""
        }.joined(separator: " ")
        let packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="FilmPositive">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:FilmPositive="https://github.com/chriscantey/film-positive/ns/1.0/"
            \(attrs)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(packet.utf8).write(to: SidecarStore.sidecarURL(for: image))

        let e = try XCTUnwrap(try XCTUnwrap(try SidecarStore().load(for: image)).sidecar.enhance)
        for i in 0..<18 { XCTAssertEqual(e[slider: i], Double(i + 1) / 100, accuracy: 1e-9, "\(old[i]) moved") }
        XCTAssertEqual(e.richness, 0)
    }

    /// The JSON form (look files) reads a document with no richness key as 0 and writes none
    /// for 0.
    func testLookJSONWithoutRichnessReadsZeroAndWritesNone() throws {
        let e = try JSONDecoder().decode(EnhanceSettings.self, from: Data(#"{"vibrance":0.2}"#.utf8))
        XCTAssertEqual(e.richness, 0)
        let out = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        XCTAssertFalse(out.contains("richness"))
        var r = e; r.richness = 0.4
        let back = try JSONDecoder().decode(EnhanceSettings.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.richness, 0.4)
    }

    /// Every slider at once, through the real encoder and back. The canary for Foundation
    /// dropping an attribute whose name another one ends with.
    func testEverySliderSurvivesTheEncoder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("IMG_0001.CR2")
        try Data((0..<2000).map { UInt8($0 & 0xFF) }).write(to: image)

        var e = EnhanceSettings()
        for i in 0..<EnhanceSettings.sliderKeys.count { e[slider: i] = Double(i + 1) / 100 }
        XCTAssertEqual(EnhanceSettings.sliderKeys.count, 21)
        let sc = Sidecar(source: try SidecarStore.source(for: image), enhance: e)
        _ = try SidecarStore().save(sc, for: image)
        let back = try XCTUnwrap(try SidecarStore().load(for: image)).sidecar.enhance
        XCTAssertEqual(back, e, "a slider was dropped or moved on the way through the file")
    }
}
