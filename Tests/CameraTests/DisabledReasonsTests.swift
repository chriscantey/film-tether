import XCTest
@testable import Camera

/// One info icon, only while a control is off, only where the reason
/// is not already on screen (DisabledReasons).
final class DisabledReasonsTests: XCTestCase {
    typealias R = DisabledReasons

    func testFocusWithLiveViewOffSaysToStartLiveView() {
        XCTAssertEqual(R.focus(liveViewOn: false, focusMode: "One Shot"), R.focusNeedsLiveView)
        XCTAssertEqual(R.focus(liveViewOn: false, focusMode: nil), R.focusNeedsLiveView)
        XCTAssertTrue(R.focusNeedsLiveView.contains("Cmd-L"), "says what to do")
    }

    func testLiveViewOffWinsOverTheLensSwitch() {
        // With live view off the focus mode may not have been read, and
        // starting live view is the first thing to do either way.
        XCTAssertEqual(R.focus(liveViewOn: false, focusMode: "Manual"), R.focusNeedsLiveView)
    }

    func testTheLensSwitchOnMFSaysToSetItToAF() {
        XCTAssertEqual(R.focus(liveViewOn: true, focusMode: "Manual"), R.lensSwitch)
        XCTAssertTrue(R.lensSwitch.contains("switch to AF"))
        XCTAssertTrue(R.lensSwitch.contains("not set to manual focus"))
    }

    func testNoIconWhileFocusIsAvailable() {
        for mode in ["One Shot", "AI Servo", "AI Focus", nil] as [String?] {
            XCTAssertNil(R.focus(liveViewOn: true, focusMode: mode), mode ?? "unread")
        }
    }

    func testTheCopyNamesNoBrand() {
        for s in [R.focusNeedsLiveView, R.lensSwitch] {
            for brand in ["Canon", "EOS", "7D", "libgphoto2"] {
                XCTAssertFalse(s.contains(brand), "\(brand) in \(s)")
            }
        }
    }
}
