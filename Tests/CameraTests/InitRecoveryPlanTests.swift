import XCTest
@testable import Camera

/// What `CameraSession.open` does after a failed gp_camera_init.
final class InitRecoveryPlanTests: XCTestCase {

    func testOpenWithoutRecoveryRunsNoStep() {
        XCTAssertEqual(CameraSession.initRecoveryPlan(recover: false), [])
        XCTAssertEqual(CameraSession.initRecoveryPlan(recover: true), [.softRetry, .usbReset],
                       "the debug CLI's own commands keep the full plan")
    }

    /// A USB reset is refused while Image Capture holds its claim, so the
    /// app's connect keeps the soft retry and drops the reset.
    func testTheAppsConnectNeverResetsTheUSB() {
        XCTAssertFalse(CameraConnection.appUSBReset)
        let plan = CameraSession.initRecoveryPlan(recover: true, usbReset: CameraConnection.appUSBReset)
        XCTAssertEqual(plan, [.softRetry])
        XCTAssertFalse(plan.contains(.usbReset))
        XCTAssertEqual(CameraSession.initRecoveryPlan(recover: false, usbReset: true), [], "no recovery means none")
    }
}
