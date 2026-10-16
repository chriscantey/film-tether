import XCTest
@testable import FilmSidecar

/// The two develop-stage color axes, in printer points. The unit and its sources are in
/// the `ColourAxes` doc comment.
final class ColourAxesTests: XCTestCase {

    /// A real file on disk, because `SidecarStore.source(for:)` reads its size, date and
    /// fingerprint.
    private var image: URL!

    override func setUpWithError() throws {
        image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axes-\(UUID().uuidString).CR2")
        try Data(repeating: 0x42, count: 2048).write(to: image)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: image) }

    private func live() throws -> SidecarSource { try SidecarStore.source(for: image) }

    private func withAxes(_ axes: ColourAxes) throws -> Sidecar {
        var sc = Sidecar(source: try live())
        sc.develop = DevelopSettings(stock: "kodak-gold-200", tone: .flat,
                                     autoBalance: true, base: BaseSettings(mode: .anchor, anchor: 40000))
        sc.develop?.colourAxes = axes
        return sc
    }

    // MARK: the unit

    func testDensityPerPointIsPinned() {
        XCTAssertEqual(ColourAxes.densityPerPoint, 0.025, accuracy: 0)
    }

    /// The cross-check that ties the unit to a film gamma, rather than to a citation alone.
    /// Kodak H-61d puts 7 printer lights at one camera stop, a stop is 0.30 logE at the scene,
    /// and a C-41 film gamma of 0.56 turns that into density on the negative: 6.72 points,
    /// 4 percent off Kodak's 7. The assertion allows 5 percent.
    func testSevenPrinterPointsIsAboutOneStopAtGamma056() {
        let c41FilmGamma = 0.56
        let points = (0.30 * c41FilmGamma) / ColourAxes.densityPerPoint
        XCTAssertEqual(points, 6.72, accuracy: 0.01)
        XCTAssertLessThan(abs(points - 7) / 7, 0.05, "within 5 percent of Kodak's figure")
    }

    // MARK: green is held, exactly

    /// Tone placement and the physics normalization read only the green histogram, so an
    /// exact zero here is what keeps these sliders from moving the tone curve or the exposure.
    func testGreenOffsetIsExactlyZeroForEveryInput() {
        for w in stride(from: -50.0, through: 50.0, by: 6.5) {
            for g in stride(from: -50.0, through: 50.0, by: 6.5) {
                XCTAssertEqual(ColourAxes(warm: w, green: g).logOffsets.g, 0, accuracy: 0,
                               "warm \(w) green \(g) moved the held channel")
            }
        }
    }

    // MARK: polarity, labeled by what the picture does

    func testWarmRaisesRedAndLowersBlueByTheSameDensity() {
        let o = ColourAxes(warm: 4, green: 0).logOffsets
        XCTAssertEqual(o.r, 4 * ColourAxes.densityPerPoint, accuracy: 1e-12)
        XCTAssertEqual(o.b, -4 * ColourAxes.densityPerPoint, accuracy: 1e-12)
        XCTAssertEqual(o.r, -o.b, accuracy: 1e-12, "warm is a pure opponent move")
    }

    func testGreenAxisMovesRedAndBlueTogetherAgainstTheHeldChannel() {
        let o = ColourAxes(warm: 0, green: 4).logOffsets
        XCTAssertEqual(o.r, o.b, accuracy: 1e-12, "the green axis is common mode on red and blue")
        XCTAssertGreaterThan(o.r, 0, "positive is toward magenta")
    }

    /// The two axes must be independent, or one slider silently drags the other.
    func testTheAxesAreIndependent() {
        let both = ColourAxes(warm: 3, green: 5).logOffsets
        let w = ColourAxes(warm: 3, green: 0).logOffsets
        let g = ColourAxes(warm: 0, green: 5).logOffsets
        XCTAssertEqual(both.r, w.r + g.r, accuracy: 1e-12)
        XCTAssertEqual(both.b, w.b + g.b, accuracy: 1e-12)
    }

    // MARK: a delta, never an absolute

    /// Stored as a delta so it composes with whatever base the edge reader finds. An
    /// absolute would fix the base at the value read when the axes were set.
    func testTheAxesAreAMultiplicativeDeltaOnTheResolvedRatios() {
        let resolved = BaseRatios(rg: 0.465, bg: 0.7356)
        let out = ColourAxes(warm: 7, green: 0).applied(to: resolved)
        XCTAssertEqual(out.rg, resolved.rg * pow(10, 7 * ColourAxes.densityPerPoint), accuracy: 1e-12)
        XCTAssertEqual(out.bg, resolved.bg * pow(10, -7 * ColourAxes.densityPerPoint), accuracy: 1e-12)

        // A different resolved base gets the same delta, not the same result.
        let other = BaseRatios(rg: 0.9, bg: 0.5)
        let outOther = ColourAxes(warm: 7, green: 0).applied(to: other)
        XCTAssertEqual(outOther.rg / other.rg, out.rg / resolved.rg, accuracy: 1e-12)
    }

    /// At rest the control cannot touch anything.
    func testIdentityChangesNothingAtAll() {
        let r = BaseRatios(rg: 0.465, bg: 0.7356)
        let out = ColourAxes.identity.applied(to: r)
        XCTAssertEqual(out.rg, r.rg, accuracy: 0)
        XCTAssertEqual(out.bg, r.bg, accuracy: 0)
        XCTAssertTrue(ColourAxes.identity.isIdentity)
        XCTAssertTrue(ColourAxes(warm: 0, green: 0).isIdentity)
        XCTAssertFalse(ColourAxes(warm: 0.001, green: 0).isIdentity)
    }

    // MARK: the sidecar contract

    func testAxesSurviveAnEncodeAndDecode() throws {
        let sc = try withAxes(ColourAxes(warm: 6.5, green: -3.25))
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live())
        XCTAssertEqual(back.develop?.colourAxes.warm, 6.5)
        XCTAssertEqual(back.develop?.colourAxes.green, -3.25)
    }

    /// An untouched frame gains no attribute, so a file that never used the axes never
    /// mentions them.
    func testIdentityAxesWriteNoAttributeAtAll() throws {
        let sc = try withAxes(.identity)
        let xml = String(decoding: try sc.encoded(), as: UTF8.self)
        XCTAssertFalse(xml.contains("BaseWarmPoints"), "an untouched frame must not gain the attribute")
        XCTAssertFalse(xml.contains("BaseGreenPoints"))
    }

    /// And the other direction: a file with no axes reads as identity rather than as garbage.
    func testASidecarWithoutTheAttributesReadsAsIdentity() throws {
        let sc = try withAxes(.identity)
        let back = try Sidecar.decode(try sc.encoded(), liveSource: try live())
        XCTAssertTrue(back.develop?.colourAxes.isIdentity ?? false)
    }
}
