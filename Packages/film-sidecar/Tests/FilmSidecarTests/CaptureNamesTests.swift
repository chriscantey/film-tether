import XCTest
@testable import FilmSidecar

final class CaptureNamesTests: XCTestCase {
    func testFilmMakerIsTheLeadingTokenWhenKnown() {
        XCTAssertEqual(CaptureNames.filmMaker(film: "Kodak Gold 200"), "Kodak")
        XCTAssertEqual(CaptureNames.filmMaker(film: "Ilford"), "Ilford")
    }

    func testFilmMakerIsNilForAMakerNotOnTheList() {
        XCTAssertNil(CaptureNames.filmMaker(film: "Reflx Lab 320D"))
        XCTAssertNil(CaptureNames.filmMaker(film: "Lucky"))
    }

    func testMakeAndModelKeepsTheFullModel() {
        let split = CaptureNames.makeAndModel(camera: "Leica M6")
        XCTAssertEqual(split.make, "Leica")
        XCTAssertEqual(split.model, "Leica M6")
        let unknown = CaptureNames.makeAndModel(camera: "Holga 120N")
        XCTAssertNil(unknown.make)
        XCTAssertEqual(unknown.model, "Holga 120N")
    }

    func testSettersTrimDeriveAndClear() {
        var c = CaptureInfo()
        c.setCamera("  Canon AE-1 ")
        c.setFilm("Kodak Portra 400")
        XCTAssertEqual(c.camera, "Canon AE-1")
        XCTAssertEqual(c.cameraMake, "Canon")
        XCTAssertEqual(c.film, "Kodak Portra 400")
        XCTAssertEqual(c.filmMaker, "Kodak")
        c.setCamera("")
        c.setFilm(nil)
        XCTAssertEqual(c, CaptureInfo())
    }
}
