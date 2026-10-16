import XCTest
@testable import Camera

/// The camera clock must read this Mac's local wall time in summer and
/// winter. The 7D keeps its zone on standard time (PST in these fixtures) and
/// has no DST, so it stamps EXIF as `written + (-8 h)`. Writing true UTC leaves
/// it an hour behind during daylight saving time.
final class CameraClockTests: XCTestCase {
    let la = TimeZone(identifier: "America/Los_Angeles")!

    /// What the camera shows for `written`, given the zone it keeps.
    private func cameraWallClock(_ written: Int32, zone: TimeZone) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                  from: Date(timeIntervalSince1970: TimeInterval(written)))
    }

    private func hostWallClock(_ date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: s)!
    }

    private let pstFixed = TimeZone(secondsFromGMT: -8 * 3600)!

    func testA7DInJulyShowsLocalWallTime() {
        let now = date("2026-07-15T19:00:00Z")   // 12:00 PDT
        let w = CameraClock.datetimeUTCValue(now: now, hostZone: la, cameraObservesDST: false)
        XCTAssertEqual(cameraWallClock(w, zone: pstFixed), hostWallClock(now))
        XCTAssertEqual(Int(w) - Int(now.timeIntervalSince1970), 3600, "an hour added in daylight saving time")
    }

    func testA7DInJanuaryShowsLocalWallTime() {
        let now = date("2026-01-15T20:00:00Z")   // 12:00 PST
        let w = CameraClock.datetimeUTCValue(now: now, hostZone: la, cameraObservesDST: false)
        XCTAssertEqual(cameraWallClock(w, zone: pstFixed), hostWallClock(now))
        XCTAssertEqual(Int(w), Int(now.timeIntervalSince1970), "nothing added in standard time")
    }

    /// Writing true UTC leaves the 7D an hour behind in September, and the
    /// corrected value does not.
    func testTrueUTCLeavesThe7DAnHourBehindInSeptember() {
        let now = date("2026-09-28T07:00:24Z")   // 00:00:24 PDT
        let trueUTC = Int32(now.timeIntervalSince1970)
        XCTAssertEqual(cameraWallClock(trueUTC, zone: pstFixed).hour, 23)
        let corrected = CameraClock.datetimeUTCValue(now: now, hostZone: la, cameraObservesDST: false)
        XCTAssertEqual(cameraWallClock(corrected, zone: pstFixed), hostWallClock(now))
    }

    /// A body that applies DST itself, such as the R5, gets true UTC in both seasons.
    func testABodyObservingDSTIsNotCorrectedTwice() {
        for s in ["2026-07-15T19:00:00Z", "2026-01-15T20:00:00Z"] {
            let now = date(s)
            let w = CameraClock.datetimeUTCValue(now: now, hostZone: la, cameraObservesDST: true)
            XCTAssertEqual(Int(w), Int(now.timeIntervalSince1970), s)
            XCTAssertEqual(cameraWallClock(w, zone: la), hostWallClock(now), s)
        }
    }

    func testTheSettingsOffsetStillAddsOnTop() {
        let now = date("2026-01-15T20:00:00Z")
        let w = CameraClock.datetimeUTCValue(now: now, hostZone: la, cameraObservesDST: false, extraOffsetMinutes: 60)
        XCTAssertEqual(Int(w) - Int(now.timeIntervalSince1970), 3600)
    }

    func testOnlyTheVerifiedBodyObservesDST() {
        XCTAssertTrue(CameraClock.observesDST(model: "Canon EOS R5"))
        XCTAssertFalse(CameraClock.observesDST(model: "Canon EOS 7D"))
        XCTAssertFalse(CameraClock.observesDST(model: nil), "an unread model is treated as the 7D")
    }

    func testTheModelIsReadFromTheSummary() {
        let summary = "Manufacturer: Canon Inc.\nModel: Canon EOS 7D\n  Version: 3-2.0.6\n"
        XCTAssertEqual(CameraSession.parseModel(from: summary), "Canon EOS 7D")
        XCTAssertNil(CameraSession.parseModel(from: "Manufacturer: Canon Inc.\n"))
    }
}
