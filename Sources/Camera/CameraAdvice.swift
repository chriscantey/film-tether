import Foundation

/// What the app shows when the camera refuses something: a plain first line,
/// a hint saying what to try, and the raw libgphoto2 code and message kept
/// behind an info icon.
///
/// One mapping for connect, live view start, capture and the camera controls,
/// so no failure surfaces as a bare "libgphoto2 error N: message".
public struct CameraAdvice: Equatable, Sendable {
    public let message: String
    public let hint: String?
    /// What the info icon shows, for example the raw code and libgphoto2's
    /// own words.
    public let detail: String?

    public init(message: String, hint: String?, detail: String?) {
        self.message = message
        self.hint = hint
        self.detail = detail
    }

    /// What the app was doing when the error came back.
    public enum Operation: Sendable {
        case connect, liveView, capture, control
        /// The AF button.
        case autofocus
    }

    // The sentences, one place, so the tests and the app say the same thing.
    public static let otherAppMessage = "Another app is using the camera."
    public static let otherAppHint = "Quit Preview, Image Capture and Photos, then try again."
    public static let liveViewMessage = "The camera did not enter live view."
    public static let liveViewHint = "Turn it off, remove the battery for five seconds, put it back, then relaunch Film Tether."
    public static let stuckHint = "The camera may be stuck. Turn it off, wait three seconds, and turn it back on. Film Tether reconnects on its own."
    public static let firmwareHint = "Update the camera's firmware to the latest version."
    public static let ptpHint = "Set the camera's Communication menu to PTP."
    public static let autofocusMessage = "The camera did not autofocus."
    /// The main-screen card while the camera is connected and live view
    /// is off. Same imperative, no-period shape as "Connect a compatible
    /// camera", and it names the button it points at.
    public static let liveViewOffMessage = "Turn on Live View"
    /// The line under it, in the shape of NoCamera's: what is true now, then
    /// the two ways to start live view.
    public static let liveViewOffHint = "The camera is connected.\nClick Live View below, or press Cmd-L."
    public static let notAnsweringMessage = "The camera is not answering."
    public static let notAnsweringHint = "Turn it off, wait three seconds, and turn it back on. Film Tether reconnects on its own."
    /// Only on the measured signature (StallHistory): a stall, a camera power
    /// cycle, and a stall again right after it. Never on a first stall.
    public static let notAnsweringRestartHint = "Turn it off, wait three seconds, and turn it back on. If it stalls again right after a power cycle, restart the Mac: that clears a stuck USB state on the Mac side."
    public static let autofocusHint = "Check that the lens switch is on AF, the camera is not set to manual focus, and live view is on. Then move the focus a few steps and try again."
    public static let autofocusNotConfirmedMessage = "Autofocus finished, but the live view did not get measurably sharper."
    public static let autofocusNoDriveMessage = "The camera did not start focusing."
    public static let autofocusNoDriveHint = "Quit Film Tether and open it again. That reconnects the camera, which clears this."
    public static let autofocusNotConfirmedHint = "If it already looked sharp, that is expected. Otherwise check the punch-in, move the focus a few steps so the frame has some detail, and try again."

    /// The AF button's "not confirmed" glyph. Not an error: the run went
    /// through. `detail` is the sharpness numbers or the reason, for the
    /// popover only.
    public static func autofocusNotConfirmed(detail: String?) -> CameraAdvice {
        CameraAdvice(message: autofocusNotConfirmedMessage, hint: autofocusNotConfirmedHint, detail: detail)
    }

    /// Codes that mean something else holds the USB interface. -53 is
    /// GP_ERROR_IO_USB_CLAIM and -60 GP_ERROR_IO_LOCK: definite, whatever else
    /// is running.
    static let claimCodes: Set<Int32> = [-53, -60]

    /// GP_ERROR_MODEL_NOT_FOUND. `gp_camera_init` returns it when another
    /// process half-holds the body (CameraConnection retries on it for that
    /// reason), and also when the camera is off or not in PTP mode. So it
    /// reads as another app when one is running: Preview, Image Capture
    /// or Photos, or at connect ptpcamerad alone (`otherAppRunning` in
    /// `advice`).
    static let modelNotFound: Int32 = -105

    /// Transport failures: GP_ERROR_IO -7, GP_ERROR_TIMEOUT -10,
    /// GP_ERROR_IO_READ -34, GP_ERROR_IO_WRITE -35, GP_ERROR_CAMERA_BUSY -110.
    static let transportCodes: Set<Int32> = [-7, -10, -34, -35, -110]

    /// First line when another app is running but the code alone does not
    /// prove it holds the camera.
    public static let maybeOtherAppMessage = "Another app may be using the camera."

    /// The recovery step for an operation, used after "quit the other apps"
    /// when the evidence is ambiguous.
    static func recovery(for op: Operation) -> String {
        switch op {
        case .liveView:
            return "If live view still does not start, turn the camera off, remove the battery for five seconds, put it back, then relaunch Film Tether."
        default:
            return "If it still fails, turn the camera off, wait three seconds, and turn it back on."
        }
    }

    /// - Parameters:
    ///   - cameraAppsRunning: Preview, Image Capture or Photos is running at
    ///     the moment of the failure. Any of them can take the body through
    ///     ptpcamerad. Preview is also open for PDFs all day,
    ///     so on a transport code it only makes the advice say "may be" and
    ///     keeps the recovery step, rather than blaming Preview outright.
    ///   - ptpDaemonRunning: ptpcamerad itself is running. macOS starts it
    ///     whenever a PTP body is attached, so it is weak evidence and counts
    ///     only at connect. Once connected Film Tether holds the interface.
    ///     The app checks both. This mapping only decides.
    ///   - claimSeenInSeries: a claim code (-53 or -60) came back earlier in
    ///     the same connect series, even though the attempt that finally
    ///     failed returned something else. With Image Capture open, a series
    ///     can run -53 and then end on -4 "Error loading a library", which on
    ///     its own would read only "could not connect".
    public static func advice(for error: CameraError, during op: Operation,
                              cameraAppsRunning: Bool, ptpDaemonRunning: Bool,
                              claimSeenInSeries: Bool = false) -> CameraAdvice {
        let raw = error.errorDescription
        let otherAppRunning = cameraAppsRunning || (op == .connect && ptpDaemonRunning)
        // At connect, a claim seen anywhere in the series, or the PTP helper
        // with Preview, Image Capture or Photos also running, makes a connect
        // failure (`isConnectFailure`) read as another app. The helper alone
        // (macOS starts it whenever a PTP body attaches) does not pass this
        // check. It does count in `otherAppRunning` at connect, so with only
        // ptpcamerad running, -105 reads as another app and a transport code
        // reads as "may be".
        let helperWithApp = ptpDaemonRunning && cameraAppsRunning
        if op == .connect, claimSeenInSeries || helperWithApp, Self.isConnectFailure(error) {
            return CameraAdvice(message: otherAppMessage, hint: otherAppHint, detail: raw)
        }
        switch error {
        case .notAnswering:
            // Before the live-view default below: a stall is the same advice
            // whichever call it was, and the raw stage stays behind the icon.
            return CameraAdvice(message: notAnsweringMessage, hint: notAnsweringHint, detail: raw)
        case .notAnsweringAfterPowerCycle:
            return CameraAdvice(message: notAnsweringMessage, hint: notAnsweringRestartHint, detail: raw)
        case .usbClaimDenied:
            return CameraAdvice(message: otherAppMessage, hint: otherAppHint, detail: raw)
        case .firmwareTooOld(let detected):
            return CameraAdvice(message: "Camera firmware \(detected) has a known tethering bug.",
                                hint: firmwareHint, detail: nil)
        case .cameraNotFound:
            return CameraAdvice(message: "No camera found on USB.", hint: ptpHint, detail: raw)
        case .libGPhoto(let code, _):
            if claimCodes.contains(code) || (code == modelNotFound && otherAppRunning) {
                return CameraAdvice(message: otherAppMessage, hint: otherAppHint, detail: raw)
            }
            if code == modelNotFound {
                return CameraAdvice(message: "No camera found on USB.", hint: ptpHint, detail: raw)
            }
            if transportCodes.contains(code) && otherAppRunning {
                return CameraAdvice(message: maybeOtherAppMessage,
                                    hint: otherAppHint + " " + recovery(for: op), detail: raw)
            }
            if op == .liveView && transportCodes.contains(code) {
                return CameraAdvice(message: liveViewMessage, hint: liveViewHint, detail: raw)
            }
            if transportCodes.contains(code) {
                return CameraAdvice(message: plainLine(for: op), hint: stuckHint, detail: raw)
            }
            return CameraAdvice(message: plainLine(for: op),
                                hint: op == .autofocus ? autofocusHint : nil, detail: raw)
        case .unexpected:
            return CameraAdvice(message: plainLine(for: op), hint: defaultHint(for: op), detail: raw)
        default:
            // Any other failure to start live view is still a live view
            // refusal, and gets the same advice.
            if op == .liveView {
                return CameraAdvice(message: liveViewMessage, hint: liveViewHint, detail: raw)
            }
            return CameraAdvice(message: raw ?? plainLine(for: op), hint: defaultHint(for: op), detail: nil)
        }
    }

    /// The errors a connect ends on that another app holding the camera can
    /// cause: the claim error, and any libgphoto2 code except the transport
    /// ones.
    static func isConnectFailure(_ error: CameraError) -> Bool {
        switch error {
        case .usbClaimDenied: return true
        case .libGPhoto(let code, _): return !transportCodes.contains(code)
        default: return false
        }
    }

    /// Advice for an error that is not a `CameraError` at all.
    public static func advice(forOther error: Error, during op: Operation) -> CameraAdvice {
        CameraAdvice(message: plainLine(for: op), hint: defaultHint(for: op),
                     detail: String(describing: error))
    }

    /// The hint when nothing more specific applies: live view and autofocus
    /// always say what to try, the other operations only when the code does.
    static func defaultHint(for op: Operation) -> String? {
        switch op {
        case .liveView: return liveViewHint
        case .autofocus: return autofocusHint
        default: return nil
        }
    }

    /// The first line for an error with no better sentence.
    public static func plainLine(for op: Operation) -> String {
        switch op {
        case .connect: return "Film Tether could not connect to the camera."
        case .liveView: return liveViewMessage
        case .capture: return "The camera did not take the picture."
        case .control: return "The camera did not accept that change."
        case .autofocus: return autofocusMessage
        }
    }
}
