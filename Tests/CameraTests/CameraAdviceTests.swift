import XCTest
@testable import Camera

/// A code a user can hit yields a plain sentence, a hint saying what to try
/// when there is one, and the raw code kept for the info icon.
final class CameraAdviceTests: XCTestCase {
    private typealias A = CameraAdvice

    private func advice(_ code: Int32, _ op: A.Operation,
                        apps: Bool = false, daemon: Bool = false) -> A {
        A.advice(for: .libGPhoto(code: code, message: "msg"), during: op,
                 cameraAppsRunning: apps, ptpDaemonRunning: daemon)
    }

    func testClaimCodesSayAnotherAppAtEveryStep() {
        for code: Int32 in [-53, -60] {
            for op: A.Operation in [.connect, .liveView, .capture, .control] {
                let a = advice(code, op)
                XCTAssertEqual(a.message, A.otherAppMessage, "code \(code) \(op)")
                XCTAssertEqual(a.hint, A.otherAppHint, "code \(code) \(op)")
                XCTAssertEqual(a.detail, "libgphoto2 error \(code): msg")
            }
        }
    }

    func testUSBClaimDeniedSaysAnotherApp() {
        let a = A.advice(for: .usbClaimDenied(underlying: -53), during: .connect,
                         cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, A.otherAppMessage)
        XCTAssertEqual(a.hint, A.otherAppHint)
        XCTAssertNotNil(a.detail)
    }

    func testTheHintNamesTheThreeApps() {
        XCTAssertEqual(A.otherAppMessage + " " + A.otherAppHint,
                       "Another app is using the camera. Quit Preview, Image Capture and Photos, then try again.")
    }

    /// With Preview open, a transport code does not prove Preview holds the camera, so it says
    /// "may be" and keeps the recovery step after the quit-the-apps hint.
    func testTransportFailureWithPreviewOpenSaysAnotherAppMayBe() {
        for code: Int32 in [-7, -10, -34, -35, -110] {
            for op: A.Operation in [.connect, .liveView, .capture, .control] {
                let a = advice(code, op, apps: true)
                XCTAssertEqual(a.message, "Another app may be using the camera.", "code \(code) \(op)")
                XCTAssertTrue(a.hint?.hasPrefix(A.otherAppHint) ?? false, "code \(code) \(op)")
            }
        }
        XCTAssertTrue(advice(-10, .liveView, apps: true).hint?.contains("remove the battery for five seconds") ?? false,
                      "a live view refusal with Preview open still reaches the battery step")
    }

    func testTheDaemonAloneCountsOnlyAtConnect() {
        XCTAssertEqual(advice(-7, .connect, daemon: true).message, A.maybeOtherAppMessage)
        XCTAssertEqual(advice(-10, .liveView, daemon: true).message, A.liveViewMessage)
        XCTAssertEqual(advice(-7, .capture, daemon: true).message, "The camera did not take the picture.")
    }

    func testModelNotFoundIsAnotherAppOnlyWithEvidence() {
        XCTAssertEqual(advice(-105, .connect, daemon: true).message, A.otherAppMessage)
        XCTAssertEqual(advice(-105, .connect, apps: true).hint, A.otherAppHint)
        let bare = advice(-105, .connect)
        XCTAssertEqual(bare.message, "No camera found on USB.")
        XCTAssertEqual(bare.hint, A.ptpHint)
        XCTAssertEqual(bare.detail, "libgphoto2 error -105: msg")
    }

    func testAnyOtherLiveViewFailureGetsTheLiveViewAdvice() {
        for e: CameraError in [.liveViewNotActive, .connectionLost, .unexpected("CancellationError()")] {
            let a = A.advice(for: e, during: .liveView, cameraAppsRunning: false, ptpDaemonRunning: false)
            XCTAssertEqual(a.message, A.liveViewMessage, "\(e)")
            XCTAssertEqual(a.hint, A.liveViewHint, "\(e)")
            XCTAssertNotNil(a.detail, "\(e)")
        }
    }

    func testUnexpectedErrorKeepsTheRawTextBehindTheIcon() {
        let a = A.advice(for: .unexpected("CancellationError()"), during: .capture,
                         cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, "The camera did not take the picture.")
        XCTAssertEqual(a.detail, "CancellationError()")
    }

    func testLiveViewTransportFailureSaysPullTheBattery() {
        for code: Int32 in [-7, -10, -110, -34, -35] {
            let a = advice(code, .liveView)
            XCTAssertEqual(a.message, "The camera did not enter live view.", "code \(code)")
            XCTAssertEqual(a.hint, "Turn it off, remove the battery for five seconds, put it back, then relaunch Film Tether.")
            XCTAssertEqual(a.detail, "libgphoto2 error \(code): msg")
        }
    }

    func testCaptureTimeoutKeepsTheStuckHint() {
        let a = advice(-10, .capture)
        XCTAssertEqual(a.message, "The camera did not take the picture.")
        XCTAssertEqual(a.hint, A.stuckHint)
    }

    func testUnknownCodeFallsBackToAPlainSentenceWithTheCodeBehindTheIcon() {
        let expected: [A.Operation: String] = [
            .connect: "Film Tether could not connect to the camera.",
            .liveView: "The camera did not enter live view.",
            .capture: "The camera did not take the picture.",
            .control: "The camera did not accept that change.",
        ]
        for (op, line) in expected {
            let a = advice(-999, op)
            XCTAssertEqual(a.message, line)
            XCTAssertNil(a.hint)
            XCTAssertEqual(a.detail, "libgphoto2 error -999: msg")
            XCTAssertFalse(a.message.contains("libgphoto2"), "the raw string stays off the surface")
        }
    }

    // MARK: - A connect series that ends on a code other than the claim

    /// A connect series can run -53 (the claim) and end on -4 "Error loading a
    /// library", as it does with Image Capture open. The earlier claim alone still
    /// means another app, even when no camera app is detected.
    func testAClaimEarlierInTheSeriesSaysAnotherApp() {
        let a = A.advice(for: .libGPhoto(code: -4, message: "Error loading a library"), during: .connect,
                         cameraAppsRunning: false, ptpDaemonRunning: false, claimSeenInSeries: true)
        XCTAssertEqual(a.message, A.otherAppMessage)
        XCTAssertEqual(a.hint, A.otherAppHint)
        XCTAssertEqual(a.detail, "libgphoto2 error -4: Error loading a library", "the real last code stays behind the icon")
    }

    func testThePTPHelperWithACameraAppSaysAnotherAppForANonTransportCode() {
        let a = A.advice(for: .libGPhoto(code: -4, message: "Error loading a library"), during: .connect,
                         cameraAppsRunning: true, ptpDaemonRunning: true)
        XCTAssertEqual(a.message, A.otherAppMessage)
        XCTAssertEqual(a.hint, A.otherAppHint)
    }

    /// macOS starts ptpcamerad whenever a PTP body attaches, so on its own it
    /// does not turn a real library failure into "another app".
    func testThePTPHelperAloneKeepsThePlainCard() {
        let a = A.advice(for: .libGPhoto(code: -4, message: "Error loading a library"), during: .connect,
                         cameraAppsRunning: false, ptpDaemonRunning: true)
        XCTAssertEqual(a.message, "Film Tether could not connect to the camera.")
        XCTAssertNil(a.hint)
    }

    func testACameraAppAloneKeepsThePlainCardForMinus4() {
        let a = A.advice(for: .libGPhoto(code: -4, message: "Error loading a library"), during: .connect,
                         cameraAppsRunning: true, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, "Film Tether could not connect to the camera.")
    }

    /// A real library failure with no claim and no helper is never disguised.
    func testABareMinus4StaysThePlainCard() {
        let a = A.advice(for: .libGPhoto(code: -4, message: "Error loading a library"), during: .connect,
                         cameraAppsRunning: false, ptpDaemonRunning: false, claimSeenInSeries: false)
        XCTAssertEqual(a.message, "Film Tether could not connect to the camera.")
        XCTAssertNil(a.hint)
        XCTAssertEqual(a.detail, "libgphoto2 error -4: Error loading a library")
    }

    func testTheSeriesRuleIsForConnectOnly() {
        for op: A.Operation in [.liveView, .capture, .control] {
            let a = A.advice(for: .libGPhoto(code: -4, message: "m"), during: op,
                             cameraAppsRunning: false, ptpDaemonRunning: true, claimSeenInSeries: true)
            XCTAssertNotEqual(a.message, A.otherAppMessage, "\(op)")
        }
    }

    func testATransportCodeAtConnectWithThePTPHelperAndNoAppSaysMayBe() {
        // A transport code at connect with ptpcamerad running and no camera app says "may be".
        let a = A.advice(for: .libGPhoto(code: -7, message: "m"), during: .connect,
                         cameraAppsRunning: false, ptpDaemonRunning: true, claimSeenInSeries: false)
        XCTAssertEqual(a.message, A.maybeOtherAppMessage)
    }

    func testTheClaimCodesAreMinus53AndMinus60() {
        XCTAssertTrue(CameraConnection.isClaim(.usbClaimDenied(underlying: -53)))
        XCTAssertTrue(CameraConnection.isClaim(.libGPhoto(code: -60, message: "")))
        XCTAssertFalse(CameraConnection.isClaim(.libGPhoto(code: -4, message: "")))
        XCTAssertFalse(CameraConnection.isClaim(.libGPhoto(code: -7, message: "")))
    }

    func testFirmwareAndPTPHintsAreKept() {
        let fw = A.advice(for: .firmwareTooOld(detected: "1.0.0"), during: .connect,
                          cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(fw.hint, A.firmwareHint)
        XCTAssertTrue(fw.message.contains("1.0.0"))
        let nf = A.advice(for: .cameraNotFound, during: .connect,
                          cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(nf.hint, A.ptpHint)
    }

    func testNonCameraErrorGetsThePlainLine() {
        struct Odd: Error {}
        let a = A.advice(forOther: Odd(), during: .capture)
        XCTAssertEqual(a.message, "The camera did not take the picture.")
        XCTAssertNotNil(a.detail)
    }

    /// House style for the listed advice strings: no em-dash and no semicolon.
    func testNoSurfaceStringCarriesAnEmDashOrSemicolon() {
        let all = [A.otherAppMessage, A.otherAppHint, A.liveViewMessage, A.liveViewHint,
                   A.stuckHint, A.firmwareHint, A.ptpHint, A.maybeOtherAppMessage,
                   A.recovery(for: .liveView), A.recovery(for: .capture)]
            + [A.Operation.connect, .liveView, .capture, .control].map(A.plainLine)
        for s in all {
            XCTAssertFalse(s.contains("\u{2014}"), s)
            XCTAssertFalse(s.contains(";"), s)
        }
    }

    /// The live-view-off card names the button it points at, in the same
    /// imperative, no-period shape as the no-camera card, with no brand or
    /// code in it.
    func testLiveViewOffCardNamesTheButtonPlainly() {
        let s = CameraAdvice.liveViewOffMessage
        XCTAssertEqual(s, "Turn on Live View")
    }

    /// The hint names the button and its shortcut, and keeps the house style of no em-dash.
    func testLiveViewOffHintNamesTheButtonAndTheShortcutWithNoEmDash() {
        let h = CameraAdvice.liveViewOffHint
        XCTAssertTrue(h.contains("Live View"))
        XCTAssertTrue(h.contains("Cmd-L"))
        XCTAssertFalse(h.contains("\u{2014}"))
    }
}
