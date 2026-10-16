import Foundation

/// The white-balance eyedropper's armed state, and what the preview shows
/// while it is armed.
///
/// With the preview inverted, the film base is the darkest thing on screen
/// rather than the brightest, which invites clicking the wrong spot. So while
/// the eyedropper is armed the preview shows the negative, and it goes back
/// to the positive the moment the pick ends, however it ends.
///
/// The negative is *derived* from `isArmed`, never written into the user's
/// adjustments. Those are persisted the moment they change and recorded with
/// captures, so a temporary `invert = false` stored there would survive a quit
/// mid-pick and could ride into a capture. Because it is derived, every path
/// that disarms shows the positive again with no bookkeeping.
public struct WhiteBalancePick: Equatable, Sendable {
    public private(set) var isArmed = false

    public init() {}

    public mutating func arm() { isArmed = true }
    public mutating func disarm() { isArmed = false }

    /// Arm, or cancel a pick already armed.
    public mutating func toggle() { isArmed.toggle() }

    /// True when the pick is showing the negative in place of the user's
    /// positive.
    public func showsNegativeForPick(_ user: PreviewAdjustments) -> Bool {
        isArmed && user.invert
    }

    /// What the preview draws: the user's adjustments, with the negative
    /// shown while armed. Every other field is the user's.
    public func displayed(_ user: PreviewAdjustments) -> PreviewAdjustments {
        var shown = user
        shown.invert = user.invert && !isArmed
        return shown
    }

    /// What a capture records and what is saved: the user's own adjustments,
    /// armed or not.
    public func recorded(_ user: PreviewAdjustments) -> PreviewAdjustments { user }

    /// The invert toggle. It reads what is on screen: pressed while a pick
    /// shows the negative, it means "show me the positive". So it cancels the
    /// pick and sets invert to the opposite of what was displayed, which
    /// leaves the preview wherever the user just put it. Unarmed it is a
    /// plain flip. Returns true when a pick was canceled.
    @discardableResult
    public mutating func toggleInvert(_ user: inout PreviewAdjustments) -> Bool {
        let target = !displayed(user).invert
        let canceled = isArmed
        isArmed = false
        user.invert = target
        return canceled
    }
}
