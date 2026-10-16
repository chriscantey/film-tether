import XCTest
@testable import Camera

/// A settings write fails while live view runs, the error card shows, and the next
/// successful write clears it. The state it clears to must follow the stream.
final class ClearedErrorStateTests: XCTestCase {

    /// The write fails mid-stream and the stream keeps running. Clearing to Ready here would
    /// put the "Turn on Live View" card over a live picture.
    func testAnErrorWhileStreamingClearsBackToStreaming() {
        XCTAssertEqual(ClearedErrorState.after(streamActive: true), .streaming)
    }

    /// Connected with live view off, a write fails and then succeeds: back to Ready, where the
    /// card belongs.
    func testAnErrorWithLiveViewOffClearsToReady() {
        XCTAssertEqual(ClearedErrorState.after(streamActive: false), .ready)
    }
}
