import XCTest
@testable import Camera

/// The autofocus sequence runner (`AFTrialRunner`), driven by a fake body on
/// a virtual clock so timeouts cost nothing.
final class AFProbeTests: XCTestCase {

    /// A body on a virtual clock. Events are scheduled at absolute ms, and a
    /// write costs `writeCostMs` and can be told to fail.
    final class FakeBody: AFProbeIO {
        var now = 0
        var scheduled: [(ms: Int, text: String)]
        var writes: [(ms: Int, write: AFWidgetWrite)] = []
        var failOn: AFWidgetWrite?
        /// Event reads throw once a DoAf has gone out (a body that stops answering).
        var eventsThrowAfterDoAf = false
        var writeCostMs = 10
        /// Events are only "generated" once a DoAf has gone out, the way the
        /// body only reports focus after it was asked to focus.
        var eventsNeedDoAf = true

        init(events: [(Int, String)] = []) {
            scheduled = events.map { (ms: $0.0, text: $0.1) }
        }

        struct Refused: Error, CustomStringConvertible {
            var description: String { "libgphoto2 error -110" }
        }

        func write(_ w: AFWidgetWrite) async throws {
            writes.append((now, w))
            now += writeCostMs
            if w == failOn { throw Refused() }
        }

        func nextEvent(timeoutMs: Int) async throws -> String? {
            let armed = !eventsNeedDoAf || writes.contains { $0.write == .doAf }
            if eventsThrowAfterDoAf, writes.contains(where: { $0.write == .doAf }) { throw Refused() }
            if armed, let i = scheduled.firstIndex(where: { $0.ms <= now + timeoutMs }) {
                let e = scheduled.remove(at: i)
                now = max(now, e.ms)
                return e.text
            }
            now += timeoutMs
            return nil
        }

        func elapsedMs() -> Int { now }

        var wireOrder: [AFWidgetWrite] { writes.map(\.write) }
    }

    // MARK: - Wire mapping

    func testEachSequenceMapsToExactlyTheNamedWidgetWrites() {
        func writes(_ steps: [AFStep]) -> [AFWidgetWrite] {
            steps.compactMap { if case .write(let w) = $0 { return w } else { return nil } }
        }
        XCTAssertEqual(writes(AFSequence.s2.steps), [.doAf])
        XCTAssertEqual(writes(AFSequence.s2.cleanup), [.afCancel])
        XCTAssertEqual(AFSequence.s2.steps.first, .bestEffort(.afCancel), "S2 clears a stale latch first")
    }

    func testTheWidgetsAreTheOnesLibgphoto2Names() {
        XCTAssertEqual(AFWidgetWrite.doAf, .toggle(name: "autofocusdrive", value: 1))
        XCTAssertEqual(AFWidgetWrite.afCancel, .toggle(name: "cancelautofocus", value: 1))
    }

    /// `autofocusdrive=0` is AfCancel on the wire. No `.write` step in any
    /// sequence uses it.
    func testNoSequenceWritesAutofocusdriveZero() {
        for s in AFSequence.allCases {
            for step in s.steps + s.cleanup {
                if case .write(let w) = step {
                    XCTAssertNotEqual(w, .toggle(name: "autofocusdrive", value: 0), s.rawValue)
                }
            }
        }
    }

    // MARK: - Cancel ordering

    func testS2CancelsOnlyAfterTheInFocusEvent() async {
        let body = FakeBody(events: [(400, "PTP Property d108 changed"),
                                     (900, "Focus Info 000000000101")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
        let finalCancel = body.writes.last!.ms
        XCTAssertGreaterThanOrEqual(finalCancel, 900, "the closing cancel waited for the body")
        XCTAssertEqual(t.completion, "event")
        XCTAssertEqual(t.completionSignal, .inFocus)
        XCTAssertEqual(t.completionMs, 900)
        XCTAssertNil(t.error)
    }

    func testS2IgnoresRunningAndIdleFocusInfo() async {
        let body = FakeBody(events: [(100, "Focus Info 000000000001"),
                                     (200, "Focus Info 000000000000"),
                                     (1200, "Focus Info 000000000202")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.completionSignal, .failed, "a failed AF still ends the wait")
        XCTAssertEqual(t.completionMs, 1200)
        XCTAssertEqual(t.events.prefix(3).map(\.signal), [.running, .idle, .failed])
    }

    func testS2AcceptsAfResultAsCompletion() async {
        let body = FakeBody(events: [(700, "unhandled EOS event AfResult (size 12)")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.completion, "event")
        XCTAssertEqual(t.completionSignal, .afResult)
    }

    // MARK: - Timeout path

    func testS2TimesOutAtSixSecondsAndStillCancels() async {
        let body = FakeBody(events: [(500, "PTP Property d102 changed, \"shutterspeed\" to \"1/10\"")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.completion, "timeout")
        XCTAssertNil(t.completionSignal)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel],
                       "a timeout still closes the latch")
        let doAf = body.writes[1].ms, cancel = body.writes[2].ms
        XCTAssertGreaterThanOrEqual(cancel - doAf, AFSequence.completionTimeoutMs)
        XCTAssertLessThan(cancel - doAf, AFSequence.completionTimeoutMs + 200)
        XCTAssertEqual(t.events.count, 1, "the property event was recorded, not acted on")
    }


    /// A refused DoAf ends the sequence, and the closing cancel still goes out.
    func testARefusedDoAfStillSendsTheClosingCancel() async {
        let seqs: [AFSequence] = [.s2]
        for seq in seqs {
            let body = FakeBody()
            body.failOn = .doAf
            let t = await AFTrialRunner.run(seq, io: body)
            XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel], seq.rawValue)
            XCTAssertEqual(t.commands.last?.cleanup, true)
            XCTAssertEqual(t.error, "libgphoto2 error -110")
            XCTAssertNil(t.completion)
        }
    }

    func testAThrowingEventReadStillSendsTheClosingCancel() async {
        let body = FakeBody()
        body.eventsThrowAfterDoAf = true
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
        XCTAssertNotNil(t.error)
    }

    /// The leading cancel may be refused by a body with nothing latched. The
    /// trial carries on to the DoAf.
    func testARefusedLeadingCancelIsNotFatal() async {
        let body = FakeBody(events: [(900, "Focus Info 000000000101")])
        body.failOn = .afCancel
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
        XCTAssertEqual(t.completionSignal, .inFocus)
        XCTAssertNotNil(t.commands.first?.error)
        XCTAssertEqual(t.cleanupError, "libgphoto2 error -110", "the closing cancel's refusal is still reported")
    }

    /// A failed record that arrives before the body says AF is running is a
    /// leftover, not this DoAf's result.
    func testAStaleFailedRecordDoesNotEndTheWait() async {
        let body = FakeBody(events: [(0, "Focus Info 000000000200"),
                                     (1000, "Focus Info 000000000001"),
                                     (1400, "Focus Info 000000000101")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.completionSignal, .inFocus)
        XCTAssertEqual(t.completionMs, 1400)
        XCTAssertEqual(t.completionEvent, "Focus Info 000000000101")
    }

    func testTheClearWindowSitsBetweenCancelAndDoAf() async {
        let body = FakeBody()
        _ = await AFTrialRunner.run(.s2, io: body)
        let cancel = body.writes[0].ms, doAf = body.writes[1].ms
        XCTAssertGreaterThanOrEqual(doAf - cancel, AFSequence.clearMs)
    }

    func testCommandsRecordWhenTheWriteReturned() async {
        let body = FakeBody()
        body.writeCostMs = 250
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.commands.first?.ms, 0)
        XCTAssertEqual(t.commands.first?.endMs, 250)
    }

    func testTheTailReadsThePostCancelBurst() async {
        let body = FakeBody(events: [(300, "Focus Info 000000000101"),
                                     (420, "Focus Info 000000000000")])
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.events.map(\.signal), [.inFocus, .idle])
    }


    // MARK: - Focus signal parsing

    func testFocusInfoClassification() {
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000101"), .inFocus)
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 00000000010100"), .inFocus, "R8's seventh byte")
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000001"), .running)
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000202"), .failed)
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000200"), .failed)
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000100"), .idle)
        XCTAssertEqual(AFFocusSignal.classify("Focus Info 000000000000"), .idle)
        XCTAssertNil(AFFocusSignal.classify("Focus Info"))
        XCTAssertNil(AFFocusSignal.classify("Focus Mask 00000000000000"))
        XCTAssertNil(AFFocusSignal.classify("Focus Points {}"), "FocusInfoEx is data, not a completion")
        XCTAssertEqual(AFFocusSignal.classify("unhandled EOS event AfResult (size 8)"), .afResult)
    }

}
