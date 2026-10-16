import XCTest
@testable import Camera

/// The quit path drains the EVF-exit burst until it goes quiet, capped,
/// before gp_camera_exit.
final class QuitSettleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func t(_ ms: Int) -> Date { t0.addingTimeInterval(Double(ms) / 1000) }

    func testNoEventsGoesQuietAfterTheQuietWindow() {
        let w = QuietWindow(start: t0, quietMs: 300, capMs: 1500)
        XCTAssertEqual(w.verdict(at: t(299)), .keepDraining)
        XCTAssertEqual(w.verdict(at: t(300)), .quiet)
    }

    func testEachEventRestartsTheQuietWindow() {
        var w = QuietWindow(start: t0, quietMs: 300, capMs: 1500)
        w.noteEvent(at: t(250))
        XCTAssertEqual(w.verdict(at: t(400)), .keepDraining)
        w.noteEvent(at: t(500))
        XCTAssertEqual(w.verdict(at: t(799)), .keepDraining)
        XCTAssertEqual(w.verdict(at: t(800)), .quiet)
        XCTAssertEqual(w.events, 2)
    }

    func testAStreamThatNeverStopsIsCapped() {
        var w = QuietWindow(start: t0, quietMs: 300, capMs: 1500)
        for ms in stride(from: 100, through: 1400, by: 100) { w.noteEvent(at: t(ms)) }
        XCTAssertEqual(w.verdict(at: t(1450)), .keepDraining)
        XCTAssertEqual(w.verdict(at: t(1500)), .capped)
    }

    /// The default cap of 1.5 s sits well inside the 8 s force-quit timer in
    /// `applicationShouldTerminate`. The timer lives in the app target, so this
    /// pins the cap rather than comparing against it.
    func testTheCapFitsTheEightSecondQuitBudget() {
        let w = QuietWindow(start: t0)
        XCTAssertLessThanOrEqual(w.capMs, 1500)
        XCTAssertLessThan(w.quietMs, w.capMs)
    }
}
