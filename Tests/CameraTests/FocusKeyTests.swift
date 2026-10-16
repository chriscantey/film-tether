import XCTest
@testable import Camera

/// The keyboard half of manual focus: which key means which pulse.
final class FocusKeyTests: XCTestCase {
    typealias Step = CameraProperties.ManualFocusStep

    /// Bare keys take the medium step (Near 2, Far 2).
    func testBareKeysAreTheSmallStep() {
        XCTAssertEqual(Step.forFocusKey(",", option: false, control: false), .farSmall)
        XCTAssertEqual(Step.forFocusKey(".", option: false, control: false), .nearSmall)
    }

    func testOptionIsTheTinyStep() {
        XCTAssertEqual(Step.forFocusKey(",", option: true, control: false), .farTiny)
        XCTAssertEqual(Step.forFocusKey(".", option: true, control: false), .nearTiny)
    }

    func testControlIsTheLargeStep() {
        XCTAssertEqual(Step.forFocusKey(",", option: false, control: true), .farLarge)
        XCTAssertEqual(Step.forFocusKey(".", option: false, control: true), .nearLarge)
    }

    func testControlOutranksOptionWhenBothAreHeld() {
        XCTAssertEqual(Step.forFocusKey(".", option: true, control: true), .nearLarge)
    }

    /// Shift holds the momentary punch-in, and `charactersIgnoringModifiers`
    /// still applies Shift, so the same physical keys arrive as < and >.
    /// Focus has to step while zoomed in.
    func testShiftedFormsStillStepWhileThePunchInIsHeld() {
        XCTAssertEqual(Step.forFocusKey("<", option: false, control: false), .farSmall)
        XCTAssertEqual(Step.forFocusKey(">", option: false, control: false), .nearSmall)
        XCTAssertEqual(Step.forFocusKey(">", option: true, control: false), .nearTiny)
        XCTAssertEqual(Step.forFocusKey("<", option: false, control: true), .farLarge)
    }

    func testOtherKeysAreNotFocusKeys() {
        XCTAssertNil(Step.forFocusKey("m", option: false, control: false))
        XCTAssertNil(Step.forFocusKey("", option: true, control: true))
        XCTAssertNil(Step.forFocusKey("/", option: false, control: false))
    }
}
