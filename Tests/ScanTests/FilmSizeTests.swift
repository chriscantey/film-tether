import XCTest
import CoreGraphics
@testable import Scan

final class FilmSizeTests: XCTestCase {

    private let catalog = FilmSize.seedCatalog

    // MARK: - Catalog integrity

    /// Along the strip over across it, per row. The across side is the gauge's
    /// 24, 56 or 13 mm. Sheet film has no strip and keeps long over short.
    func testAlongOverAcrossPerRow() throws {
        let expected: [Int: Double?] = [
            1: nil,
            2: 1.0,                 // 120 6x6
            3: 127 / 101.6,         // 4x5 sheet
            4: 36.0 / 24,           // 35mm
            5: 36.0 / 24,           // 35mm slide
            6: 254 / 203.2,         // 8x10 sheet
            7: 355.6 / 279.4,       // 11x14 sheet
            8: 84.0 / 56,           // 120 6x9
            9: 177.8 / 127,         // 5x7 sheet
            10: 105.0 / 80,         // 3.25x4.25
            11: 82.55 / 57.15,      // 2.25x3.25
            12: 18.0 / 24,          // 35mm half frame
            13: 41.5 / 56,          // 120 6x4.5
            14: 70.0 / 56,          // 120 6x7
            15: 17.0 / 13,          // 110
        ]
        let rows = FilmSize.seedCatalog + FilmSize.pickerOnlyRows
        XCTAssertEqual(Set(rows.map(\.id)), Set(expected.keys))
        for size in rows {
            let want = try XCTUnwrap(expected[size.id])
            if let want {
                XCTAssertEqual(try XCTUnwrap(size.alongOverAcross), want, accuracy: 1e-12, size.name)
            } else {
                XCTAssertNil(size.alongOverAcross, size.name)
            }
        }
    }

    /// The perforation rung's ratio, pinned per row. Only the 35mm rows read it
    /// along over across. Every other row with a size keeps long over short.
    func testThePerforationRungsRatioPerRow() throws {
        let expected: [Int: Double] = [
            1: 1.5,
            2: 1.0,
            3: 127 / 101.6,
            4: 36.0 / 24,
            5: 36.0 / 24,
            6: 254 / 203.2,
            7: 355.6 / 279.4,
            8: 84.0 / 56,
            9: 177.8 / 127,
            10: 105.0 / 80,
            11: 82.55 / 57.15,
            12: 18.0 / 24,
            13: 56 / 41.5,
            14: 70.0 / 56,
            15: 17.0 / 13,
        ]
        let rows = FilmSize.seedCatalog + FilmSize.pickerOnlyRows
        XCTAssertEqual(Set(rows.map(\.id)), Set(expected.keys))
        for size in rows {
            let want = try XCTUnwrap(expected[size.id])
            XCTAssertEqual(AutoCrop.perforationWant(expecting: size), want, accuracy: 1e-12, size.name)
        }
        XCTAssertEqual(AutoCrop.perforationWant(expecting: nil), 1.5)
    }

    /// The ids go into sidecars as `Film:FilmSizeID`, so a renumbering would
    /// silently mislabel every scan already recorded.
    func testCatalogIdsAndNamesAreFrozen() {
        let expected: [(Int, String)] = [
            (1, "unknown"), (2, "120mm Rollei"), (3, "4x5"), (4, "35mm"),
            (5, "35mm slide"), (6, "8x10"), (7, "11x14"), (8, "6x9"),
            (9, "5x7"), (10, "3.25x4.25 (80mm x 105mm)"), (11, "2.25x3.25"),
            (12, "35mm half-frame"),
        ]
        XCTAssertEqual(catalog.count, expected.count)
        for (size, want) in zip(catalog, expected) {
            XCTAssertEqual(size.id, want.0)
            XCTAssertEqual(size.name, want.1)
        }
    }

    // MARK: - The Size picker

    func testThePickerOffersTheSizeList() {
        let names = FilmSize.pickerSizes(including: nil).map(\.displayName)
        XCTAssertEqual(names, ["Not set", "35mm", "35mm Half", "35mm Slide", "120 6x4.5", "120 6x6",
                               "120 6x7", "120 6x9", "4x5", "110"])
    }

    func testNoPickerNameCarriesABrandOr120mm() {
        for size in catalog + FilmSize.pickerOnlyRows {
            for bad in ["Rollei", "Kodak", "Fuji", "Ilford", "Hasselblad", "Mamiya", "120mm"] {
                XCTAssertFalse(size.displayName.contains(bad), size.displayName)
            }
        }
    }

    /// The perforation rung gates on a name containing "half" and reads the
    /// millimeters, so the half row, shown as "35mm Half", must keep both
    /// underneath.
    func testTheHalfRowGatesThePerforationRung() throws {
        let half = try XCTUnwrap(FilmSize.pickerSizes(including: nil).first { $0.id == 12 })
        XCTAssertEqual(half.displayName, "35mm Half")
        XCTAssertTrue(half.name.lowercased().contains("half"))
        XCTAssertEqual(half.widthMM, 18)
        XCTAssertEqual(half.heightMM, 24)
        for id in FilmSize.pickerIDs where id != 12 {
            XCTAssertFalse(try XCTUnwrap(FilmSize.resolve(id: id)).name.lowercased().contains("half"), "id \(id) would open the mat path")
        }
    }

    /// The picker-only rows' ids never collide with the catalog's or with each
    /// other.
    func testPickerOnlyRowsStayOutOfTheMatchersCatalog() {
        let seedIDs = Set(catalog.map(\.id))
        for row in FilmSize.pickerOnlyRows {
            XCTAssertFalse(seedIDs.contains(row.id), "id \(row.id)")
            XCTAssertNotNil(row.aspectRatio, row.name)
        }
        XCTAssertEqual(Set(FilmSize.pickerOnlyRows.map(\.id)).count, FilmSize.pickerOnlyRows.count)
    }

    /// Rows left out of the menu still resolve by id.
    func testRowsLeftOutOfThePickerStillResolve() {
        for id in [6, 7, 9, 10, 11] {
            XCTAssertNotNil(FilmSize.resolve(id: id), "id \(id)")
            XCTAssertFalse(FilmSize.pickerIDs.contains(id))
        }
    }

    func testAHiddenSelectionStillShows() throws {
        let fiveBySeven = try XCTUnwrap(FilmSize.resolve(id: 9))
        XCTAssertEqual(FilmSize.pickerSizes(including: fiveBySeven).last?.id, 9)
        XCTAssertEqual(FilmSize.pickerSizes(including: FilmSize.resolve(id: 4)).count, 10, "no duplicate row")
        XCTAssertEqual(FilmSize.pickerSizes(including: FilmSize.unknown).count, 10)
    }

    func testEveryPickerIdResolves() {
        for id in FilmSize.pickerIDs { XCTAssertNotNil(FilmSize.resolve(id: id), "id \(id)") }
    }

    /// A 6x7 frame matches 4x5 (the same shape), which must not flip a chosen
    /// 6x7. A different shape still may, and Other is never replaced.
    func testTheDetectorDoesNotOverrideAPickerOnlyRowOfTheSameShape() throws {
        let sixBySeven = try XCTUnwrap(FilmSize.resolve(id: 14))
        let fourByFive = try XCTUnwrap(FilmSize.resolve(id: 3))
        let thirtyFive = try XCTUnwrap(FilmSize.resolve(id: 4))
        XCTAssertFalse(FilmSize.detectionMayReplace(sixBySeven, other: false, with: fourByFive))
        XCTAssertTrue(FilmSize.detectionMayReplace(sixBySeven, other: false, with: thirtyFive))
        XCTAssertFalse(FilmSize.detectionMayReplace(nil, other: true, with: thirtyFive))
        XCTAssertTrue(FilmSize.detectionMayReplace(thirtyFive, other: false, with: fourByFive), "a catalog row may be replaced by a different shape")
        XCTAssertTrue(FilmSize.detectionMayReplace(nil, other: false, with: fourByFive))
        XCTAssertFalse(FilmSize.detectionMayReplace(thirtyFive, other: false, with: FilmSize.unknown))
    }

    func testOnlyUnknownLacksDimensions() {
        for size in catalog {
            XCTAssertEqual(size.isUnknown, size.id == 1, "\(size.name)")
        }
    }

    func testAspectRatioIsOrientationIndependent() {
        let portrait = FilmSize(id: 99, name: "t", widthMM: 24, heightMM: 36)
        let landscape = FilmSize(id: 99, name: "t", widthMM: 36, heightMM: 24)
        XCTAssertEqual(portrait.aspectRatio!, landscape.aspectRatio!, accuracy: 1e-9)
        XCTAssertEqual(portrait.aspectRatio!, 1.5, accuracy: 1e-9)
    }

    // MARK: - The ambiguity this catalog contains

    /// These pairs are indistinguishable by shape alone, so any UI that shows a
    /// single auto-detected answer without a scale is guessing between them.
    func testFormatsThatShareAnAspectRatio() throws {
        func ratio(_ id: Int) throws -> Double {
            try XCTUnwrap(catalog.first { $0.id == id }?.aspectRatio)
        }
        XCTAssertEqual(try ratio(3), try ratio(6), accuracy: 1e-9, "4x5 vs 8x10")
        XCTAssertEqual(try ratio(4), try ratio(8), accuracy: 1e-9, "35mm vs 6x9")
    }

    /// These groups are the same physical frame, so no amount of measurement
    /// will ever separate them and the UI must let the operator pick.
    func testSomeFormatsAreGeometricallyIdentical() throws {
        for group in FilmSize.indistinguishableGroups {
            let sizes = group.compactMap { id in catalog.first { $0.id == id } }
            XCTAssertEqual(sizes.count, group.count)
            let diagonals = sizes.compactMap(\.diagonalMM)
            let spread = (diagonals.max()! - diagonals.min()!) / diagonals.min()!
            XCTAssertLessThan(spread, 0.01,
                              "\(sizes.map(\.name)) should be within 1% in size")
            let ratios = sizes.compactMap(\.aspectRatio)
            let ratioSpread = (ratios.max()! - ratios.min()!) / ratios.min()!
            XCTAssertLessThan(ratioSpread, 0.01,
                              "\(sizes.map(\.name)) should be within 1% in shape")
        }
    }

    /// The catalog has 6x9 at 56x84 mm and 2.25x3.25 at 57.15x82.55 mm. Their
    /// diagonals differ by 0.55% and their shapes by about 4%, so they are
    /// confusable rather than identical. Both should show up as candidates
    /// for a crop between the two ratios.
    func testSixByNineAndTwoAndAQuarterAreBothOfferedForAnInBetweenCrop() throws {
        let sixNine = try XCTUnwrap(catalog.first { $0.id == 8 })
        let twoQuarter = try XCTUnwrap(catalog.first { $0.id == 11 })
        let sizeSpread = abs(sixNine.diagonalMM! - twoQuarter.diagonalMM!) / sixNine.diagonalMM!
        XCTAssertLessThan(sizeSpread, 0.01, "same overall size")
        XCTAssertGreaterThan(
            abs(sixNine.aspectRatio! - twoQuarter.aspectRatio!) / sixNine.aspectRatio!,
            0.02, "but distinguishable shapes"
        )
        let between = (sixNine.aspectRatio! + twoQuarter.aspectRatio!) / 2
        let crop = CGSize(width: 1000, height: 1000 * between)
        let ids = Set(FilmSizeMatcher.candidates(forCropSize: crop, in: catalog).map(\.size.id))
        XCTAssertTrue(ids.isSuperset(of: [8, 11]))
    }

    func testWithoutScaleAmbiguousFormatsBothSurvive() {
        // A 3:2 crop: 35mm and 6x9 are both perfectly consistent with it.
        let matches = FilmSizeMatcher.candidates(
            forCropSize: CGSize(width: 1000, height: 1500), in: catalog
        )
        let ids = Set(matches.map(\.size.id))
        XCTAssertTrue(ids.contains(4), "35mm should be a candidate")
        XCTAssertTrue(ids.contains(8), "6x9 should be a candidate")
    }

    // MARK: - Scale-aware matching

    /// With a scale, absolute size separates the formats that shape can't.
    func testScaleSeparates35mmFrom6x9() throws {
        // Crop 1000x1500 px. At 0.024 mm/px that's 24x36mm, a 35mm frame, not 6x9.
        let small = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1000, height: 1500),
            in: catalog, mmPerPixel: 24.0 / 1000.0
        )
        XCTAssertEqual(small.id, 4, "expected 35mm, got \(small.name)")

        // Same shape, but each pixel is worth more, so the negative is 56x84mm.
        let large = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1000, height: 1500),
            in: catalog, mmPerPixel: 56.0 / 1000.0
        )
        XCTAssertEqual(large.id, 8, "expected 6x9, got \(large.name)")
    }

    func testScaleSeparates4x5From8x10() throws {
        let fourByFive = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 960, height: 1200),
            in: catalog, mmPerPixel: 0.1
        )
        XCTAssertEqual(fourByFive.id, 3, "expected 4x5, got \(fourByFive.name)")

        let eightByTen = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 960, height: 1200),
            in: catalog, mmPerPixel: 194.0 / 960.0
        )
        XCTAssertEqual(eightByTen.id, 6, "expected 8x10, got \(eightByTen.name)")
    }

    func testSquareCropMatchesSixBySix() {
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 1200, height: 1200), in: catalog
        )
        XCTAssertEqual(match.id, 2)
    }

    func testAWildlyOffShapeFallsBackToUnknown() {
        // 5:1 panorama matches nothing in the catalog.
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: CGSize(width: 500, height: 2500), in: catalog
        )
        XCTAssertTrue(match.isUnknown)
    }

    func testDegenerateCropYieldsNoCandidates() {
        XCTAssertTrue(FilmSizeMatcher.candidates(forCropSize: .zero, in: catalog).isEmpty)
        XCTAssertTrue(
            FilmSizeMatcher.candidates(
                forCropSize: CGSize(width: 100, height: 0), in: catalog
            ).isEmpty
        )
    }

    func testUnknownIsNeverOfferedAsACandidate() {
        let matches = FilmSizeMatcher.candidates(
            forCropSize: CGSize(width: 1000, height: 1500), in: catalog
        )
        XCTAssertFalse(matches.contains { $0.size.isUnknown })
    }

    // MARK: - Calibration

    func testCalibrationRecoversTheScaleUsedToBuildTheCrop() throws {
        let thirtyFive = try XCTUnwrap(catalog.first { $0.id == 4 })
        // A 35mm frame photographed at 1000 px across its 24mm edge.
        let crop = CGSize(width: 1000, height: 1500)
        let scale = try XCTUnwrap(
            FilmSizeMatcher.mmPerPixel(cropSize: crop, isSize: thirtyFive)
        )
        XCTAssertEqual(scale, 24.0 / 1000.0, accuracy: 1e-6)
    }

    /// Calibrate on one negative, then identify a different format shot on the
    /// same rig.
    func testCalibratingOn35mmThenIdentifying6x9() throws {
        let thirtyFive = try XCTUnwrap(catalog.first { $0.id == 4 })
        let scale = try XCTUnwrap(FilmSizeMatcher.mmPerPixel(
            cropSize: CGSize(width: 1000, height: 1500), isSize: thirtyFive
        ))
        // Same rig, a 6x9 negative now fills proportionally more of the frame.
        let sixByNine = CGSize(width: 56.0 / scale, height: 84.0 / scale)
        let match = FilmSizeMatcher.bestMatch(
            forCropSize: sixByNine, in: catalog, mmPerPixel: scale
        )
        XCTAssertEqual(match.id, 8, "expected 6x9, got \(match.name)")
    }

    func testCalibrationRefusesUnknown() {
        XCTAssertNil(FilmSizeMatcher.mmPerPixel(
            cropSize: CGSize(width: 100, height: 100), isSize: FilmSize.unknown
        ))
    }

    func testCatalogRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(catalog)
        XCTAssertEqual(try JSONDecoder().decode([FilmSize].self, from: data), catalog)
    }
}
