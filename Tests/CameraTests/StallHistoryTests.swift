import XCTest
@testable import Camera

/// The restart-the-Mac line appears only on one measured signature: a stall,
/// a camera power cycle, a stall again right after it (StallHistory). No
/// other path tells people to reboot.
final class StallHistoryTests: XCTestCase {
    let stage = "first config read"

    func testAFirstStallGetsThePlainPowerCycleHint() {
        let h = StallHistory()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnswering(stage: stage))
    }

    func testStallPowerCycleStallIsTheSignature() {
        let h = StallHistory()
        h.recordStall(stage: stage)
        h.cameraLeft()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnsweringAfterPowerCycle(stage: stage))
        XCTAssertEqual(h.lastStall, .notAnsweringAfterPowerCycle(stage: stage))
    }

    func testTwoStallsWithNoPowerCycleBetweenAreNotTheSignature() {
        let h = StallHistory()
        h.recordStall(stage: stage)
        XCTAssertEqual(h.recordStall(stage: stage), .notAnswering(stage: stage))
    }

    func testTheCameraLeavingBeforeAnyStallDoesNotArmIt() {
        let h = StallHistory()
        h.cameraLeft()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnswering(stage: stage))
    }

    func testACleanReadyStartsTheCountOver() {
        let h = StallHistory()
        h.recordStall(stage: stage)
        h.cameraLeft()
        h.ready()
        XCTAssertNil(h.lastStall)
        XCTAssertEqual(h.recordStall(stage: stage), .notAnswering(stage: stage))
    }

    func testEachPowerCycleNeedsItsOwnStallBefore() {
        let h = StallHistory()
        h.recordStall(stage: stage)
        h.cameraLeft()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnsweringAfterPowerCycle(stage: stage))
        // Another stall with no power cycle since the last one is plain again.
        XCTAssertEqual(h.recordStall(stage: stage), .notAnswering(stage: stage))
        h.cameraLeft()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnsweringAfterPowerCycle(stage: stage))
    }

    func testTheSignatureCrossesStages() {
        // A live view stall, the power cycle, then the reconnect's first read stalls.
        let h = StallHistory()
        h.recordStall(stage: "live view start")
        h.cameraLeft()
        XCTAssertEqual(h.recordStall(stage: stage), .notAnsweringAfterPowerCycle(stage: stage))
    }

    // MARK: - The two cards

    func testTheFirstStallsCardKeepsTheReconnectHint() {
        let a = CameraAdvice.advice(for: .notAnswering(stage: stage), during: .connect,
                                    cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, "The camera is not answering.")
        XCTAssertEqual(a.hint, "Turn it off, wait three seconds, and turn it back on. Film Tether reconnects on its own.")
        XCTAssertFalse(a.hint!.contains("restart"))
    }

    func testTheSignaturesCardAddsTheMacRestart() {
        for op in [CameraAdvice.Operation.connect, .liveView] {
            let a = CameraAdvice.advice(for: .notAnsweringAfterPowerCycle(stage: stage), during: op,
                                        cameraAppsRunning: false, ptpDaemonRunning: false)
            XCTAssertEqual(a.message, "The camera is not answering.")
            XCTAssertEqual(a.hint, "Turn it off, wait three seconds, and turn it back on. If it stalls again right after a power cycle, restart the Mac: that clears a stuck USB state on the Mac side.")
            XCTAssertTrue(a.detail!.contains("power cycled"), "the signature stays behind the icon")
        }
    }
}
