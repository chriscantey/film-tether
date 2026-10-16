import XCTest
@testable import Hotkey

/// The hold key keeps working when the system-wide listener cannot start: the
/// monitor falls back to the in-window one with the same key. Permissions are
/// injected, so nothing here reads the real privacy settings, and no test
/// creates a real event tap.
final class HoldKeyFallbackTests: XCTestCase {

    private func config(global: Bool) -> HoldKeyMonitor.Config {
        var c = HoldKeyMonitor.Config()
        c.keyCode = 0x31
        c.globalScope = global
        return c
    }

    private func check(accessibility: Bool, inputMonitoring: Bool) -> HoldKeyMonitor.PermissionCheck {
        HoldKeyMonitor.PermissionCheck(accessibility: { accessibility },
                                       inputMonitoring: { inputMonitoring })
    }

    func testGlobalWithAPermissionDeniedRunsLocally() {
        let cases: [(Bool, Bool, HoldKeyMonitor.PermissionError)] = [
            (false, true, .accessibilityDenied),
            (true, false, .inputMonitoringDenied),
            (false, false, .bothDenied),
        ]
        for (ax, hid, expected) in cases {
            let monitor = HoldKeyMonitor(config: config(global: true),
                                         permissions: check(accessibility: ax, inputMonitoring: hid))
            let reason = monitor.startFallingBackToLocal()
            XCTAssertEqual(monitor.scope, .local, "accessibility \(ax), input monitoring \(hid)")
            XCTAssertEqual(reason as? HoldKeyMonitor.PermissionError, expected)
            monitor.stop()
            XCTAssertNil(monitor.scope)
        }
    }

    /// The strict start refuses, so a caller that wants only the global
    /// scope can tell.
    func testStrictStartStillThrowsAndLeavesTheMonitorStopped() {
        let monitor = HoldKeyMonitor(config: config(global: true),
                                     permissions: check(accessibility: true, inputMonitoring: false))
        XCTAssertThrowsError(try monitor.start())
        XCTAssertNil(monitor.scope)
    }

    /// The permission decision for all four states. Only the decision is checked
    /// here, since a unit test cannot create the real tap.
    func testTheMissingPermissionForAllFourStates() {
        XCTAssertNil(HoldKeyMonitor.missingPermission(accessibility: true, inputMonitoring: true))
        XCTAssertEqual(HoldKeyMonitor.missingPermission(accessibility: false, inputMonitoring: true),
                       .accessibilityDenied)
        XCTAssertEqual(HoldKeyMonitor.missingPermission(accessibility: true, inputMonitoring: false),
                       .inputMonitoringDenied)
        XCTAssertEqual(HoldKeyMonitor.missingPermission(accessibility: false, inputMonitoring: false),
                       .bothDenied)
    }

    /// A local monitor stays local, and never asks for the permissions.
    func testLocalStaysLocal() {
        let monitor = HoldKeyMonitor(
            config: config(global: false),
            permissions: HoldKeyMonitor.PermissionCheck(
                accessibility: { XCTFail("local start read Accessibility"); return false },
                inputMonitoring: { XCTFail("local start read Input Monitoring"); return false }))
        XCTAssertNil(monitor.startFallingBackToLocal())
        XCTAssertEqual(monitor.scope, .local)
        monitor.stop()
        XCTAssertNil(monitor.scope)
    }
}
