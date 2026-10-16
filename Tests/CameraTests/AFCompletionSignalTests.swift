import XCTest
@testable import Camera

/// S2's completion on a body that never reports focus.
/// The strings are the ones libgphoto2 2.5.33 printed for the 7D.
final class AFCompletionSignalTests: XCTestCase {

    static let flash = "PTP Property d1c0 changed, \"flashcharged\" to \"0\""
    static let expSim = "PTP Property d1b7 changed"
    static let oneShotRaw = "PTP Property d1c3 changed, \"oneshotrawon\" to \"0\""

    /// The 7D's timeline after DoAf: d1b7 and d1c3 as AF starts, d1c0 then a
    /// second d1b7 as it ends.
    static let timeline: [(Int, String)] = [(650, expSim), (650, oneShotRaw), (2500, flash), (2800, expSim)]

    typealias FakeBody = AFProbeTests.FakeBody

    // MARK: - Parsing the event text

    func testThePropertyIdComesOutOfTheExactStrings() {
        XCTAssertEqual(AFPropertyEvent.propID(Self.flash), "d1c0")
        XCTAssertEqual(AFPropertyEvent.propID(Self.expSim), "d1b7")
        XCTAssertEqual(AFPropertyEvent.propID(Self.oneShotRaw), "d1c3")
        XCTAssertEqual(AFPropertyEvent.propID("PTP Property D1C0 changed"), "d1c0")
        XCTAssertNil(AFPropertyEvent.propID("Focus Points {}"))
        XCTAssertNil(AFPropertyEvent.propID("Focus Info 000000000101"))
        XCTAssertNil(AFPropertyEvent.propID("PTP Property d1c0"), "no 'changed', not a change event")
        XCTAssertNil(AFPropertyEvent.propID("PTP Property d1c05 changed"), "five digits is not a property id")
        XCTAssertNil(AFPropertyEvent.propID("unhandled EOS event AfResult (size 8)"))
    }

    // MARK: - The matcher

    func testD1c0FiresOnTheFirstFlashChargingChange() {
        var m = AFCompletionMatcher(rule: .d1c0)
        XCTAssertFalse(m.feed(Self.expSim))
        XCTAssertFalse(m.feed(Self.oneShotRaw))
        XCTAssertFalse(m.feed("Focus Points {}"))
        XCTAssertTrue(m.feed(Self.flash))
    }


    func testTimeoutRuleNeverFires() {
        var m = AFCompletionMatcher(rule: .timeout)
        for (_, text) in Self.timeline { XCTAssertFalse(m.feed(text)) }
    }


    // MARK: - S2 end to end on the 7D timeline

    func testS2UnderD1c0CompletesAtTheFlashChangeAndThenCancels() async {
        let body = FakeBody(events: Self.timeline)
        let t = await AFTrialRunner.run(.s2, io: body, completion: .d1c0)
        XCTAssertEqual(t.completion, "d1c0")
        XCTAssertEqual(t.completionMs, 2500)
        XCTAssertEqual(t.completionEvent, Self.flash)
        XCTAssertNil(t.completionSignal, "not a focus event")
        XCTAssertEqual(body.wireOrder, [.afCancel, .doAf, .afCancel])
        XCTAssertGreaterThanOrEqual(body.writes.last!.ms, 2500)
        XCTAssertLessThan(body.writes.last!.ms, 3000, "no 6 s wait")
    }


    func testTheDefaultStillRunsToTheSixSecondCap() async {
        let body = FakeBody(events: Self.timeline)
        let t = await AFTrialRunner.run(.s2, io: body)
        XCTAssertEqual(t.completion, "timeout")
        let doAf = body.writes[1].ms, cancel = body.writes[2].ms
        XCTAssertGreaterThanOrEqual(cancel - doAf, AFSequence.completionTimeoutMs)
    }

    func testTheCapIsTheFallbackWhenTheSignalNeverComes() async {
        let body = FakeBody(events: [(650, Self.expSim), (650, Self.oneShotRaw)])
        let t = await AFTrialRunner.run(.s2, io: body, completion: .d1c0)
        XCTAssertEqual(t.completion, "timeout")
        XCTAssertNil(t.completionMs)
    }

    func testAFocusEventStillWinsUnderAPropertyRule() async {
        let body = FakeBody(events: [(900, "Focus Info 000000000101")] + Self.timeline)
        let t = await AFTrialRunner.run(.s2, io: body, completion: .d1c0)
        XCTAssertEqual(t.completion, "event")
        XCTAssertEqual(t.completionSignal, .inFocus)
    }
}
