import XCTest
@testable import Camera

/// The app's AF button, the pure half: the d1c0 marker, the 6 s cap, the
/// order of the two cancels, the lens-switch gate, the sharpness verdict and
/// the advice. Event strings are the ones libgphoto2 2.5.33 printed for the 7D.
final class AppAutofocusTests: XCTestCase {
    typealias FakeBody = AFProbeTests.FakeBody
    typealias AF = AppAutofocus

    static let flash = AFCompletionSignalTests.flash
    static let expSim = AFCompletionSignalTests.expSim
    static let oneShotRaw = AFCompletionSignalTests.oneShotRaw
    /// One recorded S2 run on the 7D.
    static let timeline: [(Int, String)] = [(659, expSim), (659, oneShotRaw), (2548, flash), (2795, expSim)]

    private func commands(_ o: AF.Outcome) -> [AFCommandRecord] { o.trace.commands }

    // MARK: - The sequence

    func testTheAppRunsS2WithTheD1c0MarkerAndA6sCap() {
        XCTAssertEqual(AF.sequence, .s2)
        XCTAssertEqual(AF.marker, .d1c0)
        XCTAssertEqual(AF.capMs, 6000)
    }

    func testTheMarkerEndsTheWaitAtTheFirstD1c0() async {
        let body = FakeBody(events: Self.timeline)
        let o = await AF.run(io: body)
        XCTAssertEqual(o.completion, .marker)
        XCTAssertEqual(o.trace.completionMs, 2548)
        XCTAssertEqual(o.trace.completionEvent, Self.flash)
        XCTAssertFalse(o.failed)
    }

    func testWithoutAMarkerTheWaitRunsToTheCapAndStillCancels() async {
        let body = FakeBody(events: [(659, Self.expSim), (659, Self.oneShotRaw)])
        let o = await AF.run(io: body)
        XCTAssertEqual(o.completion, .timeout)
        XCTAssertFalse(o.failed, "the cap is not a failure, the sharpness check decides")
        let doAf = commands(o).first { $0.widget == "autofocusdrive" }!
        let closing = commands(o).last!
        XCTAssertEqual(closing.widget, "cancelautofocus")
        XCTAssertTrue(closing.cleanup)
        XCTAssertGreaterThanOrEqual(closing.ms - doAf.endMs, AF.capMs)
    }

    /// Cancel, DoAf, cancel go out on the wire, each once, with no retry and
    /// nothing else.
    func testEveryWriteGoesOutOnceInOrder() async {
        let body = FakeBody(events: Self.timeline)
        _ = await AF.run(io: body)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
    }

    /// Cancelling at 1.5 s (sequence S3) aborts the drive. The closing cancel must
    /// never go out before the marker.
    func testTheClosingCancelComesAfterTheMarkerNeverBefore() async {
        let body = FakeBody(events: Self.timeline)
        let o = await AF.run(io: body)
        let closing = commands(o).last!
        XCTAssertTrue(closing.cleanup)
        XCTAssertGreaterThanOrEqual(closing.ms, o.trace.completionMs!)
        let leading = commands(o).first!
        let doAf = commands(o)[1]
        XCTAssertEqual(leading.widget, "cancelautofocus")
        XCTAssertFalse(leading.cleanup)
        XCTAssertLessThan(leading.ms, doAf.ms, "the latch is cleared before the DoAf")
    }

    /// A d1c0 caused by the leading cancel lands in the clear window, before
    /// the DoAf, and must not pass for AF finishing.
    func testAD1c0BeforeTheDoAfIsNotTheMarker() async {
        let body = FakeBody(events: [(100, Self.flash)] + Self.timeline)
        body.eventsNeedDoAf = false
        let o = await AF.run(io: body)
        XCTAssertEqual(o.completion, .marker)
        XCTAssertEqual(o.trace.completionMs, 2548)
    }

    /// The two fixed reads of the sequence: 300 ms after the leading
    /// cancel, before the DoAf, and 300 ms after the closing cancel, so the
    /// cancel's own burst is read by this run and not by the live-view drain.
    func testTheClearReadAndTheTailReadBothRun() async {
        let body = FakeBody(events: Self.timeline + [(2700, "Focus Points {}")])
        let o = await AF.run(io: body)
        let leading = commands(o)[0], doAf = commands(o)[1], closing = commands(o)[2]
        XCTAssertGreaterThanOrEqual(doAf.ms - leading.endMs, AFSequence.clearMs)
        XCTAssertGreaterThanOrEqual(o.trace.elapsedMs - closing.endMs, AFSequence.tailMs)
        XCTAssertTrue(o.trace.events.contains { $0.text == "Focus Points {}" }, "the tail read consumed it")
    }

    // MARK: - Failures

    func testARefusedLeadingCancelIsNotAFailure() async {
        let body = LeadingCancelRefused(FakeBody(events: Self.timeline))
        let o = await AF.run(io: body)
        XCTAssertFalse(o.failed)
        XCTAssertEqual(o.completion, .marker)
        XCTAssertNotNil(commands(o).first?.error)
    }

    func testARefusedDoAfFailsAndTheClosingCancelStillGoesOut() async {
        let body = FakeBody(events: Self.timeline)
        body.failOn = .doAf
        let o = await AF.run(io: body)
        XCTAssertTrue(o.failed)
        XCTAssertNil(o.completion)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
    }

    func testADeadEventPipeFailsAndStillCancels() async {
        let body = FakeBody(events: Self.timeline)
        body.eventsThrowAfterDoAf = true
        let o = await AF.run(io: body)
        XCTAssertTrue(o.failed)
        XCTAssertEqual(body.wireOrder.last, .afCancel)
    }

    // MARK: - Log lines

    func testEveryStepIsLoggedWithItsMs() async {
        let body = FakeBody(events: Self.timeline)
        let lines = AF.logLines(await AF.run(io: body))
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("af: ") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("af: cancelautofocus=1 at 0 ms") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("af: autofocusdrive=1 at ") }, "\(lines)")
        XCTAssertTrue(lines.contains("af: event at 2548 ms: \(Self.flash)"), "\(lines)")
        XCTAssertTrue(lines.contains("af: done by d1c0 at 2548 ms"), "\(lines)")
        XCTAssertTrue(lines.last!.hasPrefix("af: finished in "), "\(lines)")
        let doAf = lines.firstIndex { $0.hasPrefix("af: autofocusdrive") }!
        let marker = lines.firstIndex { $0.contains(Self.flash) }!
        XCTAssertLessThan(doAf, marker, "lines run in time order")
    }

    // MARK: - The lens-switch gate

    func testManualMeansTheLensSwitchIsOnMF() {
        XCTAssertTrue(AF.blockedByLensSwitch(focusMode: "Manual"))
        XCTAssertTrue(AF.blockedByLensSwitch(focusMode: "manual "))
        for mode in ["One Shot", "AI Servo", "AI Focus"] {
            XCTAssertFalse(AF.blockedByLensSwitch(focusMode: mode), mode)
        }
    }

    func testAnUnreadFocusModeDoesNotCloseTheGate() {
        XCTAssertFalse(AF.blockedByLensSwitch(focusMode: nil))
        XCTAssertFalse(AF.blockedByLensSwitch(focusMode: ""))
    }

    // MARK: - The key

    func testSlashIsTheAFKeyAndSurvivesThePunchInShift() {
        XCTAssertTrue(AF.isAutofocusKey("/", command: false))
        XCTAssertTrue(AF.isAutofocusKey("?", command: false))
        XCTAssertFalse(AF.isAutofocusKey("/", command: true))
        for other in [",", ".", "<", ">", "a", ""] {
            XCTAssertFalse(AF.isAutofocusKey(other, command: false), other)
        }
    }

    func testTheAFKeyIsNotAFocusStepKey() {
        for k in ["/", "?"] {
            XCTAssertNil(CameraProperties.ManualFocusStep.forFocusKey(k, option: false, control: false))
        }
    }

    // MARK: - The result glyph

    func testADefocusedStartThatSharpensIsConfirmed() {
        // A measured S2 run: about 4 before, about 700 after.
        XCTAssertEqual(AF.verdict(before: 3.9, after: 700.1), .confirmed)
        XCTAssertNil(AF.verdict(before: 3.9, after: 700.1).advice)
    }

    func testARiseInsideTheNoiseFloorIsNotConfirmed() {
        // 342 is the parked mean, with a spread of 13%.
        XCTAssertFalse(AF.verdict(before: 342, after: 380).isConfirmed)
        XCTAssertEqual(AF.verdict(before: 342, after: 400), .confirmed)
        XCTAssertFalse(AF.verdict(before: 700, after: 650).isConfirmed)
    }

    func testNothingToMeasureIsNotConfirmed() {
        XCTAssertEqual(AF.verdict(before: nil, after: 700), AF.notConfirmed(.nothingToMeasure))
        XCTAssertEqual(AF.verdict(before: 4, after: nil), AF.notConfirmed(.nothingToMeasure))
        XCTAssertFalse(AF.verdict(before: 0, after: 0.5).isConfirmed, "a blank frame cannot confirm")
    }

    // MARK: - Every result that is not a confirmation says what to try

    func testNotConfirmedAdviceKeepsTheNumbersInDetail() {
        let a = AF.verdict(before: 342, after: 380).advice!
        XCTAssertEqual(a.message, CameraAdvice.autofocusNotConfirmedMessage)
        XCTAssertEqual(a.hint, CameraAdvice.autofocusNotConfirmedHint)
        XCTAssertTrue(a.hint!.contains("a few steps"))
        XCTAssertEqual(a.detail, "sharpness 342.0 before, 380.0 after, a rise under the 15% noise floor")
        XCTAssertFalse(a.message.contains("342"), "numbers stay behind the icon")
    }

    func testEveryReasonButNoDriveHasItsOwnDetailAndTheSameHint() {
        let reasons: [AF.NotConfirmedReason] = [.flat(before: 1, after: 1), .nothingToMeasure,
                                                .noFrame(waitSeconds: 3), .zoomChanged]
        let advice = reasons.map { AF.notConfirmed($0).advice! }
        XCTAssertEqual(Set(advice.map { $0.detail ?? "" }).count, reasons.count)
        XCTAssertTrue(advice.allSatisfy { $0.hint == CameraAdvice.autofocusNotConfirmedHint })
        XCTAssertEqual(AF.notConfirmed(.noFrame(waitSeconds: 3)).advice?.detail, "no live view frame within 3 s after the run")
    }

    func testTheFailureHintNamesWhatToTry() {
        let hint = CameraAdvice.autofocusHint
        for needle in ["lens switch is on AF", "manual focus", "live view is on", "a few steps"] {
            XCTAssertTrue(hint.contains(needle), needle)
        }
    }

    func testAFailureThatIsNotACameraErrorKeepsItsTextBehindTheIcon() {
        struct Trace: Error, CustomStringConvertible { var description: String { "autofocusdrive: PTP I/O error" } }
        let a = CameraAdvice.advice(forOther: Trace(), during: .autofocus)
        XCTAssertEqual(a.message, CameraAdvice.autofocusMessage)
        XCTAssertEqual(a.hint, CameraAdvice.autofocusHint)
        XCTAssertEqual(a.detail, "autofocusdrive: PTP I/O error")
    }

    func testTheNotConfirmedCopyNamesNoBrandAndNoCode() {
        for s in [CameraAdvice.autofocusNotConfirmedMessage, CameraAdvice.autofocusNotConfirmedHint, CameraAdvice.autofocusHint] {
            for bad in ["Canon", "EOS", "7D", "libgphoto2", "-1", "PTP"] {
                XCTAssertFalse(s.contains(bad), "\(bad) in \(s)")
            }
        }
    }

    // MARK: - A lock on a frame already in focus is a confirmation

    /// AF pressed again after a good lock beeps with both frames sharp and a
    /// flat rise. With the lock marker and a sharp before frame the run is
    /// confirmed.
    func testALockOnAnAlreadySharpFrameIsConfirmed() {
        XCTAssertTrue(AF.verdict(before: 561.3, after: 570.0, markerArrived: true).isConfirmed)
        // The 5x punch-in scores far lower when sharp (a measured 50.9).
        XCTAssertTrue(AF.verdict(before: 50.9, after: 48.0, markerArrived: true).isConfirmed)
    }

    func testAFlatResultWithNoMarkerIsNotConfirmed() {
        let v = AF.verdict(before: 561.3, after: 560.0, markerArrived: false)
        XCTAssertFalse(v.isConfirmed, "a flat result with no lock is still not confirmed")
    }

    /// A marker with a blank before frame is not a hold.
    func testALowBeforeScoreIsNotConfirmedEvenWithAMarker() {
        let v = AF.verdict(before: 3.7, after: 3.7, markerArrived: true)
        XCTAssertFalse(v.isConfirmed)
        let justUnder = AF.verdict(before: AF.alreadySharpScore - 0.1, after: AF.alreadySharpScore - 0.1, markerArrived: true)
        XCTAssertFalse(justUnder.isConfirmed)
        XCTAssertTrue(AF.verdict(before: AF.alreadySharpScore, after: AF.alreadySharpScore, markerArrived: true).isConfirmed)
    }

    /// A lock that left the frame softer than the noise floor allows is not a
    /// hold.
    func testASharpFrameThatFellAfterTheLockIsNotConfirmed() {
        let v = AF.verdict(before: 561.3, after: 300.0, markerArrived: true)
        XCTAssertFalse(v.isConfirmed)
        XCTAssertTrue(AF.heldFocus(before: 561.3, after: 561.3 * 0.86, markerArrived: true), "inside the 15% floor")
        XCTAssertFalse(AF.heldFocus(before: 561.3, after: 561.3 * 0.84, markerArrived: true))
    }

    func testTheHeldFloorSitsBetweenTheMeasuredBlankAndSharpScores() {
        XCTAssertGreaterThan(AF.alreadySharpScore, 4.7 * 3, "three times over the highest blank score")
        XCTAssertLessThan(AF.alreadySharpScore, 50.9, "under the sharp punch-in score")
    }

    func testARiseStillConfirmsWithoutAMarker() {
        XCTAssertTrue(AF.verdict(before: 2.9, after: 570.0).isConfirmed)
        XCTAssertTrue(AF.verdict(before: 2.9, after: 570.0, markerArrived: false).isConfirmed)
    }

    // MARK: - Advice

    func testAnAFFailureGetsAHintAndNoRawCodeOnTheSurface() {
        let a = CameraAdvice.advice(for: .libGPhoto(code: -1, message: "Unspecified error"), during: .autofocus,
                                    cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, CameraAdvice.autofocusMessage)
        XCTAssertEqual(a.hint, CameraAdvice.autofocusHint)
        XCTAssertFalse(a.message.contains("libgphoto2"))
        XCTAssertFalse(a.hint!.contains("-1"))
        XCTAssertEqual(a.detail, "libgphoto2 error -1: Unspecified error", "the raw code stays behind the icon")
    }

    func testABusyBodyDuringAFGetsTheStuckHint() {
        let a = CameraAdvice.advice(for: .libGPhoto(code: -110, message: "busy"), during: .autofocus,
                                    cameraAppsRunning: false, ptpDaemonRunning: false)
        XCTAssertEqual(a.message, CameraAdvice.autofocusMessage)
        XCTAssertEqual(a.hint, CameraAdvice.stuckHint)
    }

    // MARK: - A body that never drove is not retried

    /// A trace with only events and the completion the runner recorded.
    private func outcome(events: [String], completion: String) -> AF.Outcome {
        var t = AFTrialTrace()
        t.events = events.enumerated().map { AFEventRecord(ms: 700 + $0.offset * 100, text: $0.element, signal: nil) }
        t.completion = completion
        return AF.Outcome(trace: t)
    }

    /// Ten measured runs that read only d1c3 and hit the cap every time. That
    /// body never drove.
    func testOnlyTheOneShotPropertyIsNoDrive() {
        let o = outcome(events: [Self.oneShotRaw, Self.oneShotRaw], completion: "timeout")
        XCTAssertEqual(o.completion, .timeout)
        XCTAssertFalse(o.bodyDrove)
    }

    func testTheDrivePropertyCountsAsDrivingWithoutAMarker() {
        XCTAssertTrue(outcome(events: [Self.oneShotRaw, Self.expSim], completion: "timeout").bodyDrove)
        XCTAssertTrue(outcome(events: ["Focus Points {}"], completion: "timeout").bodyDrove)
    }

    func testTheMarkerAloneCountsAsDriving() {
        XCTAssertTrue(outcome(events: [], completion: "d1c0").bodyDrove)
        XCTAssertTrue(outcome(events: [], completion: "event").bodyDrove)
    }

    /// A run where the body never drove says so, whatever the scores.
    func testNoDriveSaysTheCameraDidNotStartFocusing() {
        let r = AF.conclusion(before: 125.1, after: 125.7, markerArrived: false, bodyDrove: false)
        XCTAssertFalse(r.isConfirmed)
        XCTAssertEqual(r.advice?.message, CameraAdvice.autofocusNoDriveMessage)
        XCTAssertEqual(r.advice?.hint, CameraAdvice.autofocusNoDriveHint)
    }

    /// A run that drove and came back softer is shown as not confirmed (a
    /// measured run went 122.7 to 85.0).
    func testADriveThatCameBackSofterIsNotConfirmed() {
        let r = AF.conclusion(before: 122.7, after: 85.0, markerArrived: true, bodyDrove: true)
        XCTAssertFalse(r.isConfirmed)
        XCTAssertEqual(r.advice?.message, CameraAdvice.autofocusNotConfirmedMessage)
    }

    /// If the frames show the lens moved into focus, the run is confirmed even
    /// with no drive event read.
    func testARiseConfirmsEvenWithNoDriveEvent() {
        XCTAssertTrue(AF.conclusion(before: 4.5, after: 665.6, markerArrived: false, bodyDrove: false).isConfirmed)
    }

    func testTheNoDriveCopyNamesNoBrandAndNoCode() {
        for s in [CameraAdvice.autofocusNoDriveMessage, CameraAdvice.autofocusNoDriveHint] {
            for bad in ["Canon", "EOS", "7D", "libgphoto2", "PTP", "d1b7"] {
                XCTAssertFalse(s.contains(bad), "\(bad) in \(s)")
            }
        }
    }

    func testTheAFHintNamesNoBrand() {
        for brand in ["Canon", "EOS", "7D"] {
            XCTAssertFalse(CameraAdvice.autofocusHint.contains(brand), brand)
            XCTAssertFalse(CameraAdvice.autofocusMessage.contains(brand), brand)
        }
    }
}

/// A body that refuses only the first cancel, the one before the DoAf.
private final class LeadingCancelRefused: AFProbeIO {
    let inner: AFProbeTests.FakeBody
    private var refused = false
    init(_ inner: AFProbeTests.FakeBody) { self.inner = inner }

    func write(_ w: AFWidgetWrite) async throws {
        if w == .afCancel && !refused {
            refused = true
            try? await inner.write(w)
            throw AFProbeTests.FakeBody.Refused()
        }
        try await inner.write(w)
    }
    func nextEvent(timeoutMs: Int) async throws -> String? { try await inner.nextEvent(timeoutMs: timeoutMs) }
    func elapsedMs() -> Int { inner.elapsedMs() }
}
