import Foundation

/// Why a control is off, for the one info icon beside it. Not every disabled
/// control gets one, only those where an explanation helps. The UI text stays
/// minimal: one small icon, tooltip on hover, popover on click, shown only
/// while the control is off.
///
/// Where an icon is and is not, and why:
///   • Focus steps and AF with live view off: an icon. Nothing on screen says
///     the lens only moves through live view, and the step buttons' own
///     tooltips describe the step, not why it is off.
///   • Focus steps and AF with the lens switch on MF: an icon. The
///     switch is on the lens, out of sight of the screen.
///   • Capture with live view off: no icon. The Live View lamp sits right
///     beside it, and Capture's tooltip already says to start live view.
///   • AF while a run is busy: no icon. The button shows a spinner.
///   • Exposure controls locked by the mode dial: no icon. Their tooltips say
///     so, disabled or not.
public enum DisabledReasons {
    public static let focusNeedsLiveView = "Start live view to focus (Cmd-L). Film Tether moves the lens through live view, so the focus steps and autofocus need it on."
    public static let lensSwitch = "Set the lens focus switch to AF, and make sure the camera is not set to manual focus. The focus steps and autofocus both drive the lens motor, and the camera only allows that in autofocus."

    /// The focus group's icon text, or nil when the steps and AF are on (or
    /// off only for a moment, during an AF run). Live view first: with it off
    /// the camera's focus mode may not even have been read.
    public static func focus(liveViewOn: Bool, focusMode: String?) -> String? {
        if !liveViewOn { return focusNeedsLiveView }
        if AppAutofocus.blockedByLensSwitch(focusMode: focusMode) { return lensSwitch }
        return nil
    }
}
