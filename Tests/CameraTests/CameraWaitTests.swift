import XCTest
@testable import Camera

/// The status line's wait glyph (CameraWait): when it shows and what it says.
final class CameraWaitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testNothingShowsBeforeFiveSeconds() {
        let w = CameraWait(activity: .connecting, since: t0)
        XCTAssertFalse(w.isVisible(at: t0))
        XCTAssertFalse(w.isVisible(at: t0.addingTimeInterval(4.9)))
        XCTAssertTrue(w.isVisible(at: t0.addingTimeInterval(5)))
        XCTAssertTrue(w.isVisible(at: t0.addingTimeInterval(44)))
    }

    func testTheTooltipIsTheShortLineAndThePopoverSaysUpToAMinute() {
        for a in [CameraWait.Activity.connecting, .startingLiveView] {
            let w = CameraWait(activity: a, since: t0)
            XCTAssertEqual(w.tooltip, "Waiting for the camera")
            XCTAssertTrue(w.popover.contains("up to a minute"), w.popover)
            XCTAssertTrue(w.popover.contains("nothing to do yet"), w.popover)
        }
        XCTAssertTrue(CameraWait(activity: .connecting, since: t0).popover.contains("connecting"))
        XCTAssertTrue(CameraWait(activity: .startingLiveView, since: t0).popover.contains("starting live view"))
    }

    func testTheCopyNamesNoBrandAndNoInternals() {
        for a in [CameraWait.Activity.connecting, .startingLiveView] {
            let w = CameraWait(activity: a, since: t0)
            for bad in ["Canon", "EOS", "7D", "libgphoto2", "config", "PTP", "budget"] {
                XCTAssertFalse(w.popover.contains(bad), "\(bad) in \(w.popover)")
                XCTAssertFalse(w.tooltip.contains(bad), bad)
            }
        }
    }


    /// The first stall's card asks for a power cycle, never a Mac restart, and
    /// keeps the stage behind the icon.
    func testAFirstStallsCardSaysPowerCycleAndNoRestart() {
        let a = CameraAdvice.advice(for: .notAnswering(stage: "first config read"), during: .connect,
                                    cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.hint, "Turn it off, wait three seconds, and turn it back on. Film Tether reconnects on its own.")
        XCTAssertFalse(a.hint!.contains("restart"), "a restart only on the signature (StallHistoryTests)")
        XCTAssertEqual(a.detail, "No answer to the first config read in time.")
    }
}
