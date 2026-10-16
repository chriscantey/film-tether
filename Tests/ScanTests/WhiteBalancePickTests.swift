import XCTest
@testable import Scan

/// Arming the eyedropper over an inverted preview shows the negative
/// for the pick and restores the positive after, without the temporary state
/// ever reaching what is saved or recorded.
final class WhiteBalancePickTests: XCTestCase {

    private let positive = PreviewAdjustments(
        monochrome: true, invert: true,
        whiteBalance: ChannelGains(red: 1.2, green: 1.0, blue: 0.8),
        baseSample: BaseSample(red: 0.6, green: 0.4, blue: 0.3))
    private let negative = PreviewAdjustments(monochrome: false, invert: false)

    func testArmingFromInvertedShowsTheNegative() {
        var pick = WhiteBalancePick()
        pick.arm()
        XCTAssertFalse(pick.displayed(positive).invert)
        XCTAssertTrue(pick.showsNegativeForPick(positive))
    }

    func testArmingChangesNothingButInvert() {
        var pick = WhiteBalancePick()
        pick.arm()
        var expected = positive
        expected.invert = false
        XCTAssertEqual(pick.displayed(positive), expected)
    }

    func testArmingFromNegativeChangesNothing() {
        var pick = WhiteBalancePick()
        pick.arm()
        XCTAssertEqual(pick.displayed(negative), negative)
        XCTAssertFalse(pick.showsNegativeForPick(negative))
    }

    func testACaptureWhileArmedRecordsTheUsersInvert() {
        var pick = WhiteBalancePick()
        pick.arm()
        XCTAssertTrue(pick.recorded(positive).invert)
        XCTAssertEqual(pick.recorded(positive), positive)
    }

    func testDisarmRestoresThePositive() {
        var pick = WhiteBalancePick()
        pick.arm()
        pick.disarm()
        XCTAssertEqual(pick.displayed(positive), positive)
        pick.disarm()
        XCTAssertEqual(pick.displayed(positive), positive, "a second disarm is harmless")
    }

    func testSecondPressCancelsAndRestores() {
        var pick = WhiteBalancePick()
        pick.toggle()
        XCTAssertTrue(pick.isArmed)
        pick.toggle()
        XCTAssertFalse(pick.isArmed)
        XCTAssertEqual(pick.displayed(positive), positive)
    }

    /// Reset White Balance clears the gains and the sample and disarms. This
    /// replays those three steps by hand rather than calling the app's reset.
    func testClearingGainsAndDisarmingRestoresThePositive() {
        var pick = WhiteBalancePick()
        var user = positive
        pick.arm()
        user.whiteBalance = nil
        user.baseSample = nil
        pick.disarm()
        XCTAssertTrue(pick.displayed(user).invert)
        XCTAssertNil(pick.displayed(user).whiteBalance)
    }

    /// While the pick shows the negative, the toggle means "show me the
    /// positive": the pick ends and invert stays on.
    func testInvertToggleMidPickFromInvertedLeavesThePositive() {
        var pick = WhiteBalancePick()
        var user = positive
        pick.arm()
        XCTAssertTrue(pick.toggleInvert(&user))
        XCTAssertFalse(pick.isArmed)
        XCTAssertTrue(user.invert)
        XCTAssertTrue(pick.displayed(user).invert)
    }

    func testInvertToggleMidPickFromNegativeInverts() {
        var pick = WhiteBalancePick()
        var user = negative
        pick.arm()
        XCTAssertTrue(pick.toggleInvert(&user))
        XCTAssertFalse(pick.isArmed)
        XCTAssertTrue(user.invert)
        XCTAssertTrue(pick.displayed(user).invert)
    }

    func testInvertToggleUnarmedIsAPlainFlip() {
        var pick = WhiteBalancePick()
        var user = positive
        XCTAssertFalse(pick.toggleInvert(&user))
        XCTAssertFalse(user.invert)
        XCTAssertFalse(pick.toggleInvert(&user))
        XCTAssertTrue(user.invert)
    }

    /// Arm, sample, disarm: nothing the sidecar reads ever shows the
    /// temporary negative.
    func testRecordedNeverSeesTheTemporaryNegative() {
        var pick = WhiteBalancePick()
        var user = positive
        XCTAssertTrue(pick.recorded(user).invert)
        pick.arm()
        XCTAssertTrue(pick.recorded(user).invert)
        user.whiteBalance = ChannelGains(red: 1.1, green: 1.0, blue: 0.9)
        pick.disarm()
        XCTAssertTrue(pick.recorded(user).invert)
    }
}
