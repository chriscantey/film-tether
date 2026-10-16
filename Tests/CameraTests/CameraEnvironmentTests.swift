import XCTest
@testable import Camera

/// The PCHDDCapacity resend is on unless the environment says otherwise.
final class CameraEnvironmentTests: XCTestCase {
    typealias Env = CameraEnvironment

    func testTheResendIsOnByDefault() {
        XCTAssertEqual(Env.pchddResend(environment: [:]), "0x7fffffff")
        XCTAssertEqual(Env.pchddResend(environment: ["HOME": "/Users/x"]), Env.pchddResendDefault)
    }

    func testAnExplicitValueWins() {
        XCTAssertEqual(Env.pchddResend(environment: [Env.pchddResendKey: "0x1000"]), "0x1000")
    }

    func testAnEmptyValueFallsBackToTheDefault() {
        XCTAssertEqual(Env.pchddResend(environment: [Env.pchddResendKey: ""]), Env.pchddResendDefault)
    }

    /// Any value turns it off, even beside an explicit one.
    func testTheOffSwitchWins() {
        XCTAssertNil(Env.pchddResend(environment: [Env.pchddResendOffKey: "1"]))
        XCTAssertNil(Env.pchddResend(environment: [Env.pchddResendOffKey: "1", Env.pchddResendKey: "0x1000"]))
    }
}
