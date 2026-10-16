import Foundation

/// Whether a stall matches the one signature that justifies telling someone
/// to restart their Mac. No other stall gets that advice.
///
/// The signature: a stall, then a camera power cycle (the app saw the camera
/// leave the bus and come back), then a stall again in the first session
/// after it. When that was measured, only a restart of the Mac cleared it, so
/// only that sequence earns the restart line. A first stall, or a second one
/// with no power cycle between, keeps the plain power-cycle hint.
///
/// Per process, and a clean ready clears it. Lock-guarded, because a stall is
/// recorded off the camera thread while that thread may still be stuck, and
/// the presence poll reports the camera leaving from the camera actor.
public final class StallHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var stalled = false
    private var cameraLeftSinceStall = false
    private var last: CameraError?

    public init() {}

    /// A stall has just run out its ladder. Returns the error the card shows:
    /// `.notAnsweringAfterPowerCycle` only on the signature.
    @discardableResult
    public func recordStall(stage: String) -> CameraError {
        lock.lock(); defer { lock.unlock() }
        let signature = stalled && cameraLeftSinceStall
        stalled = true
        cameraLeftSinceStall = false
        let e: CameraError = signature ? .notAnsweringAfterPowerCycle(stage: stage) : .notAnswering(stage: stage)
        last = e
        return e
    }

    /// The presence poll found no camera on the bus. Counts only after a stall.
    public func cameraLeft() {
        lock.lock(); defer { lock.unlock() }
        if stalled { cameraLeftSinceStall = true }
    }

    /// A session reached ready: the history starts over.
    public func ready() {
        lock.lock(); defer { lock.unlock() }
        stalled = false
        cameraLeftSinceStall = false
        last = nil
    }

    /// The error the last stall was shown with, so a later report of the same
    /// stall says the same thing.
    public var lastStall: CameraError? { lock.lock(); defer { lock.unlock() }; return last }
}
