import Foundation

/// What the status line shows while a budgeted camera call (StallLadder.swift)
/// is still inside its budget.
///
/// One small spinner beside the connection badge, with no sentence on the
/// surface: its tooltip says what it is, and its popover says what is going
/// on. Nothing shows for the first 5 s, since a normal connect or live-view
/// start is over well before that. It goes away when the ladder ends.
public struct CameraWait: Equatable, Sendable {
    /// What the app is waiting on, in the user's terms rather than the
    /// ladder's stage names.
    public enum Activity: Equatable, Sendable {
        case connecting
        case startingLiveView
    }


    public let activity: Activity
    /// When the wait began.
    public let since: Date

    public static let showAfter: TimeInterval = 5

    public init(activity: Activity, since: Date) {
        self.activity = activity
        self.since = since
    }

    /// Whether the glyph shows at `now`.
    public func isVisible(at now: Date) -> Bool {
        return now.timeIntervalSince(since) >= Self.showAfter
    }

    public var tooltip: String {
        return Self.waitingTooltip
    }

    public var popover: String {
        switch activity {
        case .connecting:
            return "Film Tether is connecting to the camera, and the camera is slow to answer. A slow start can take up to a minute, so there is nothing to do yet."
        case .startingLiveView:
            return "Film Tether is starting live view, and the camera is slow to answer. A slow start can take up to a minute, so there is nothing to do yet."
        }
    }

    public static let waitingTooltip = "Waiting for the camera"
}
