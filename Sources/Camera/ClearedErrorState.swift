import Foundation

/// Where the main screen's state goes when a transient camera error clears.
/// It follows the stream, never an assumption. A settings write that fails
/// while live view runs leaves the stream running, so a plain fallback to
/// Ready would put the "Turn on Live View" card over a live picture with the
/// Live View lamp off while frames keep arriving.
public enum ClearedErrorState: Equatable, Sendable {
    case ready
    case streaming

    /// `streamActive` is `LiveView.isActive` read at the moment the error
    /// clears: true from a successful `start()` until `stop()` or the frame
    /// loop giving up.
    public static func after(streamActive: Bool) -> ClearedErrorState {
        streamActive ? .streaming : .ready
    }
}
