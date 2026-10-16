import Foundation
import SwiftUI
import AppKit
import os
import Camera
import Hotkey
import Scan
import ImageIO

private let appLog = Logger(subsystem: LogExportPlan.subsystem, category: "AppModel")
private let hotkeyLog = Logger(subsystem: LogExportPlan.subsystem, category: "Hotkey")

/// Build identity, injected into Info.plist by scripts/bundle.sh (git short hash
/// + build time). Surfaced in the About panel so the running build can always
/// be confirmed exactly.
enum AppInfo {
    static var buildStamp: String {
        (Bundle.main.infoDictionary?["BuildStamp"] as? String) ?? "dev"
    }

    /// Where the in-app "supported cameras" links point. The app UI stays
    /// camera-agnostic ("compatible camera"). The authoritative tested/supported
    /// list lives in the repo README.
    static let supportedCamerasURL = URL(string: "https://github.com/chriscantey/film-tether#supported-cameras")!
    /// Help > Film Tether Help: the README is the app's write-up.
    static let helpURL = URL(string: "https://github.com/chriscantey/film-tether#readme")!
}

@MainActor
final class AppModel: ObservableObject {
    enum UIState: Equatable {
        case disconnected
        case enumerating
        case ready
        case streaming
        /// `detail` is the raw code and message, shown behind an info icon.
        case error(message: String, hint: String?, detail: String? = nil)
    }

    struct PropertySnapshot: Equatable {
        // Raw values straight from libgphoto2 (terse strings like "160", "2.8",
        // "0.005", "AV"). Kept around so picker writes round-trip exactly the
        // value libgphoto2 expects.
        var iso: String = "—"
        var shutter: String = "—"
        /// Last non-"Auto" shutter value observed during this session. In Av
        /// mode the body returns "Auto" most of the time and a numeric value
        /// briefly after a metering pass. This field keeps that brief numeric
        /// value.
        var meteredShutter: String? = nil
        var aperture: String = "—"
        var whiteBalance: String = "—"
        var whiteBalanceKelvin: Int? = nil
        var mode: String = "—"
        var imageFormat: String = "—"
        var battery: String = "—"
        /// The body's focus mode as libgphoto2 names it. "Manual" is the lens
        /// switch on MF, which closes the focus group. nil until read.
        var focusMode: String? = nil
        var cameraDateTime: Date? = nil
        /// Camera clock minus host clock, from the last fresh read, or 0 after
        /// a successful sync. Stored as an offset rather than a timestamp
        /// because both clocks tick in real time, and the footer reconstructs
        /// `now + offset` every second. Nil until the camera's clock has been
        /// read once.
        var cameraClockOffset: TimeInterval? = nil

        // Display strings, computed from the raw values via PropertyLabels.
        // The UI shows these.
        var isoLabel: String { PropertyLabels.iso(iso) }
        var shutterLabel: String { PropertyLabels.shutter(shutter) }
        var apertureLabel: String { PropertyLabels.aperture(aperture) }
        var whiteBalanceLabel: String { PropertyLabels.whiteBalance(whiteBalance) }
        var kelvinLabel: String { PropertyLabels.kelvin(whiteBalanceKelvin) }
        var modeLabel: String { PropertyLabels.exposureMode(mode) }
        var imageFormatLabel: String { PropertyLabels.imageFormat(imageFormat) }
        var batteryLabel: String { PropertyLabels.battery(battery) }
    }

    @Published private(set) var ui: UIState = .disconnected
    @Published private(set) var snapshot = PropertySnapshot()
    @Published private(set) var latestFrame: NSImage? = nil
    @Published private(set) var lastCapture: String? = nil
    @Published private(set) var zoomMode: LiveZoom.Mode = .fit
    @Published private(set) var zoomFallbackActive: Bool = false
    /// The AF button is running its sequence.
    @Published private(set) var autofocusBusy = false
    /// The glyph on the AF button after a run, nil before the first one and
    /// while the sharpness check waits for its frame.
    @Published private(set) var autofocusResult: AppAutofocus.Result? = nil

    /// The exposure advisor's glyph beside the shutter control, nil when
    /// nothing clips. Checked in manual mode with the camera punch-in off,
    /// about once a second.
    @Published private(set) var exposureAdvice: ExposureAdvisor.Advice? = nil
    private var exposureGate = ExposureAdvisor.Gate()
    private var exposureCheckAt = Date.distantPast
    private var exposureCheckBusy = false

    /// The status line's wait glyph (CameraWait): the first config read's
    /// ladder and the live-view start's. The live-view wait wins while it
    /// lasts.
    @Published private(set) var connectWait: CameraWait? = nil
    @Published private(set) var liveViewWait: CameraWait? = nil
    var cameraWait: CameraWait? { liveViewWait ?? connectWait }
    /// Bumped per live-view ladder, so a late progress hop from an earlier
    /// one cannot put a glyph back.
    private var liveViewLadderGen = 0
    @Published private(set) var isoChoices: [String] = []
    @Published private(set) var shutterChoices: [String] = []
    @Published private(set) var apertureChoices: [String] = []
    @Published private(set) var imageFormatChoices: [String] = []
    @Published private(set) var whiteBalanceChoices: [String] = []
    @Published private(set) var permissionsState: PermissionsState = .init()
    private var snapshotTick: Int = 0
    /// Toggle for the zoom box in the LV pane. On by default and persisted
    /// via AppSettings.
    var showMeteringOverlay: Bool {
        get { AppSettings.shared.showMeteringOverlay }
        set {
            AppSettings.shared.showMeteringOverlay = newValue
            objectWillChange.send()
        }
    }
    /// Normalized [0,1] x [0,1] center point of the zoom box, in sensor
    /// space. Starts at the center.
    @Published var meteringCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Focus peaking overlay toggle. Persisted via AppSettings so the
    /// last on/off state is remembered across launches.
    var focusPeakingEnabled: Bool {
        get { AppSettings.shared.focusPeakingEnabled }
        set {
            AppSettings.shared.focusPeakingEnabled = newValue
            objectWillChange.send()
        }
    }

    /// Color of the peaking overlay, proxied to AppSettings so the choice
    /// persists across launches and the Settings UI's swatch grid stays in
    /// sync with the Cmd-Shift-P cycle.
    var focusPeakingColor: FocusPeaking.PeakColor {
        get { AppSettings.shared.focusPeakingColor }
        set {
            AppSettings.shared.focusPeakingColor = newValue
            objectWillChange.send()
        }
    }

    /// Detection mode (edges vs grain). Same persistence story as color.
    var focusPeakingMode: FocusPeaking.Mode {
        get { AppSettings.shared.focusPeakingMode }
        set {
            AppSettings.shared.focusPeakingMode = newValue
            objectWillChange.send()
        }
    }

    /// Quarter-turn rotation of the live preview, proxied to AppSettings so it
    /// survives relaunches. Display-only: the camera is never told about it and
    /// captured files keep the body's native orientation. See `PreviewRotation`
    /// for why every other coordinate in this class stays in sensor space.
    var previewRotation: PreviewRotation {
        get { AppSettings.shared.previewRotation }
        set {
            AppSettings.shared.previewRotation = newValue
            objectWillChange.send()
        }
    }

    /// Horizontal mirror on the preview, proxied like rotation. Display-only.
    /// Rotate-then-mirror by convention (see PreviewMirror). With the four
    /// rotations this reaches all eight orientations, so a vertical flip is
    /// Mirror plus 180° and needs no control of its own.
    var previewMirrored: Bool {
        get { AppSettings.shared.previewMirrored }
        set {
            AppSettings.shared.previewMirrored = newValue
            objectWillChange.send()
        }
    }

    /// Direction twin of `sensorPoint(fromDisplay:)`, for arrow keys: undo the
    /// mirror (display space), then un-rotate. Straightening is not applied
    /// to directions, unlike `sensorPoint(fromDisplay:)`.
    func sensorDelta(fromDisplay d: CGVector) -> CGVector {
        previewRotation.sensorDelta(fromDisplay: PreviewMirror.unmirror(d, mirrored: previewMirrored))
    }

    /// Aspect ratio the preview pane should letterbox to. The body streams 3:2
    /// at every zoom level, so only rotation can change this.
    var previewAspectRatio: CGFloat {
        previewRotation.displayAspect(sensorAspect: sensorAspectRatio)
    }

    /// How the preview is scaled on screen. Session state, not persisted, so
    /// every launch starts at Fit.
    @Published private(set) var previewZoom: PreviewZoom = .fit
    /// Size of the preview pane in points, reported by the view layer. Feeds the
    /// live "Fit (N%)" readout, so it has to come from real laid-out geometry
    /// rather than an assumption about window size.
    @Published var previewPaneSize: CGSize = .zero
    /// Base zoom to restore when a momentary Shift-hold punch-in ends. Without
    /// this, releasing Shift would always drop to Fit even from 100%.
    private var zoomBeforeHold: PreviewZoom = .fit

    // MARK: - Preview adjustments (monochrome + click white balance)

    /// Host-side preview corrections, proxied to AppSettings, which persists
    /// all of them except the base sample. Display-only: the camera keeps its
    /// own settings and captured files are never re-encoded. Recorded with
    /// each capture while metadata is on, so the same treatment can be
    /// replayed onto the RAW later.
    var previewAdjustments: PreviewAdjustments {
        get { AppSettings.shared.previewAdjustments }
        set {
            AppSettings.shared.previewAdjustments = newValue
            objectWillChange.send()
        }
    }

    /// The eyedropper's armed state. While armed over an inverted preview it
    /// shows the negative, derived rather than stored (see `WhiteBalancePick`),
    /// so every path that disarms also restores the positive.
    @Published private(set) var wbPick = WhiteBalancePick()

    /// True while the eyedropper is armed and the next click on the preview
    /// will sample white balance instead of moving the zoom box.
    var isPickingWhiteBalance: Bool { wbPick.isArmed }

    /// What the preview draws with: the user's adjustments, with the negative
    /// shown while a pick is armed. The preview renderer reads this. A
    /// capture's metadata and the saved settings read `previewAdjustments`,
    /// which the armed negative never changes.
    var displayedAdjustments: PreviewAdjustments { wbPick.displayed(previewAdjustments) }

    /// Short-lived status line for the footer, such as the reason an
    /// eyedropper sample was refused.
    @Published private(set) var notice: String? = nil
    private var noticeTask: Task<Void, Never>?

    /// Most recent frame before any adjustment (under the zoom fallback,
    /// after the host crop). The eyedropper samples this rather than what's on
    /// screen: sampling the corrected preview would compound corrections, so
    /// clicking the same spot twice would drift instead of being a no-op.
    private var lastUnadjustedFrame: Data?

    func toggleMonochrome() {
        previewAdjustments.monochrome.toggle()
        appLog.info("preview monochrome → \(self.previewAdjustments.monochrome, privacy: .public)")
    }

    /// Flip the preview between the raw negative and the positive it will
    /// become. The captured RAW is still the negative. The flag is recorded
    /// in the capture's metadata so the developing app knows which way we
    /// were looking.
    ///
    /// Mid-pick it reads what is on screen: pressed while the pick shows the
    /// negative it means "show the positive", so it cancels the pick and
    /// leaves the preview where the user just put it.
    func toggleInvert() {
        var user = previewAdjustments
        let canceled = wbPick.toggleInvert(&user)
        if user != previewAdjustments { previewAdjustments = user }
        appLog.info("preview invert → \(self.previewAdjustments.invert, privacy: .public)")
        if canceled { showNotice("White balance pick canceled") }
    }

    /// White balance can be picked with live view on, inverted or not.
    ///
    /// With the preview inverted the film base is the *darkest* part of the
    /// picture rather than the brightest, which invites clicking the wrong
    /// spot, so an armed pick shows the negative (`displayedAdjustments`) and
    /// the positive comes back when it ends.
    ///
    /// Blocked at 100% (.actual): the pane draws a center crop there, so the
    /// click coordinate cannot be mapped to the pixel under it. At 5x the
    /// sampled frame is the magnified one, so the click maps there too.
    var canPickWhiteBalance: Bool {
        isLiveViewOn && previewZoom != .actual
    }

    /// Arm or disarm the white-balance eyedropper.
    func toggleWhiteBalancePicker() {
        wbPick.toggle()
        if wbPick.showsNegativeForPick(previewAdjustments) {
            showNotice("Click the film base to set white balance. Showing the negative while you pick.")
        } else if wbPick.isArmed {
            showNotice("Click the film base to set white balance")
        }
    }

    func resetWhiteBalance() {
        previewAdjustments.whiteBalance = nil
        previewAdjustments.baseSample = nil
        wbPick.disarm()
        showNotice("White balance reset to as-shot")
        appLog.info("white balance reset")
    }

    /// Sample the frame at `point` (normalized, y-down, unrotated sensor space)
    /// and set the white balance that renders it neutral.
    func sampleWhiteBalance(atSensor point: CGPoint) {
        wbPick.disarm()
        guard let jpeg = lastUnadjustedFrame else {
            showNotice("No frame to sample. Start live view first.")
            return
        }
        guard let s = PreviewPipeline.sampleColor(jpeg: jpeg, atNormalized: point) else {
            showNotice("Couldn't read that pixel")
            return
        }
        guard let gains = ChannelGains.neutralizing(red: s.red, green: s.green, blue: s.blue) else {
            // Refusing beats applying a wild correction from a near-black
            // sample, but the user needs to know why nothing happened.
            showNotice("That spot is too dark to balance from. Pick a brighter one.")
            return
        }
        previewAdjustments.whiteBalance = gains
        // Keep the raw measurement too, because the gains are clamped (lossy)
        // and Film Positive reads the measured base itself. The point is
        // recorded in crop space (the straightened frame, before the quarter
        // turn) so it can find the same patch of base.
        // `point` itself is in raw-frame space because that is what was sampled.
        let recorded = FineRotation.straightened(
            point, byDegrees: previewStraightenDegrees, aspect: sensorAspectRatio)
        previewAdjustments.baseSample = BaseSample(
            red: s.red, green: s.green, blue: s.blue,
            point: .init(x: Double(recorded.x), y: Double(recorded.y)))
        appLog.info("white balance set: r=\(gains.red, privacy: .public) g=\(gains.green, privacy: .public) b=\(gains.blue, privacy: .public)")
        // The notice leaves out the gains. They are in the log line above, the
        // WB button's tooltip, and the footer when that readout is on.
        showNotice("White balance set")
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Percentage at which the current frame fits the pane, or nil when there's
    /// nothing to measure (live view off, or pane not laid out yet).
    var previewFitPercent: Int? {
        guard let frame = latestFrame else { return nil }
        return PreviewZoom.fitPercent(frame: frame.size, pane: previewPaneSize)
    }

    /// Label for the zoom button, e.g. "Fit (85%)", "100%", "500%".
    var previewZoomLabel: String { previewZoom.label(fitPercent: previewFitPercent) }

    /// Advance the zoom button: Fit → 100% → 500% → Fit.
    func cyclePreviewZoom() async {
        await setPreviewZoom(previewZoom.next)
    }

    /// Set the display zoom and bring the camera's punch-in in line with it.
    /// Only 500% needs the body involved. Fit and 100% are host-side scaling of
    /// the same full-frame stream, so switching between those two costs no USB
    /// traffic at all.
    func setPreviewZoom(_ z: PreviewZoom) async {
        let wasPunchedIn = previewZoom.engagesCameraPunchIn
        self.previewZoom = z
        appLog.info("preview zoom → \(z.rawValue, privacy: .public)")
        // Disarm rather than leaving the eyedropper armed behind a pane that
        // no longer takes its click.
        if z == .actual, isPickingWhiteBalance {
            wbPick.disarm()
            showNotice("White balance pick canceled. Clicks can't be placed at 100%, so use Fit or 500%.")
        }
        guard z.engagesCameraPunchIn != wasPunchedIn else { return }
        await applyZoom(z.engagesCameraPunchIn ? .fivex : .fit)
    }

    func rotatePreviewRight() {
        previewRotation = previewRotation.rotatedRight
        appLog.info("preview rotation → \(self.previewRotation.rawValue, privacy: .public)°")
    }

    func rotatePreviewLeft() {
        previewRotation = previewRotation.rotatedLeft
        appLog.info("preview rotation → \(self.previewRotation.rawValue, privacy: .public)°")
    }

    func toggleMirror() {
        previewMirrored.toggle()
        appLog.info("preview mirror → \(self.previewMirrored, privacy: .public)")
    }

    // MARK: - Straightening

    /// Rotation of the preview beyond the quarter turn, in degrees clockwise.
    /// The band just outside the crop box's grips drives it.
    ///
    /// It turns the *picture* under a crop box that stays square to the screen,
    /// so the operator can see whether a film edge has been brought level
    /// against the box. Display-only, like every other preview treatment: the
    /// camera is never told and the captured RAW is never re-encoded. The angle
    /// is recorded in the capture's metadata instead, so the crop it produced
    /// can be reproduced later.
    var previewStraightenDegrees: Double {
        get { AppSettings.shared.previewStraightenDegrees }
        set {
            AppSettings.shared.previewStraightenDegrees = FineRotation.clamped(newValue)
            objectWillChange.send()
        }
    }

    var isStraightened: Bool { !FineRotation.isNegligible(previewStraightenDegrees) }

    /// Signed, one decimal: a tenth of a degree is a visible amount of
    /// straightening across a 5000-pixel negative, and the sign is the thing
    /// the operator is reading, so it is quoted in display
    /// handedness. With the mirror on, sensor +1.4° looks like −1.4° on
    /// screen, and a readout disagreeing with the picture reads as broken.
    /// The metadata records the sensor-space value instead.
    var straightenLabel: String { String(format: "%+.1f°", displayStraightenDegrees) }

    /// The straightening as the overlay's rotate band reads and writes it: in
    /// the chirality of what is on screen. A horizontal mirror reverses
    /// handedness, so with the mirror on, a drag the operator sees as
    /// clockwise is counter-clockwise in sensor space. Negating here lets the
    /// drag follow the screen while the stored angle stays in sensor space.
    var displayStraightenDegrees: Double {
        get { previewMirrored ? -previewStraightenDegrees : previewStraightenDegrees }
        set { previewStraightenDegrees = previewMirrored ? -newValue : newValue }
    }

    func resetStraightening() {
        guard isStraightened else { return }
        previewStraightenDegrees = 0
        showNotice("Straightening cleared")
    }

    /// Aspect ratio of the frame as the camera sends it. Every body we speak to
    /// streams 3:2 at every zoom level, so only the display rotation can change
    /// what is on screen (see `previewAspectRatio`).
    var sensorAspectRatio: CGFloat { 3.0 / 2.0 }

    /// Take a point the operator indicated on screen back to the pixel of the
    /// frame the camera sent, undoing the mirror, the quarter turn and the
    /// straightening in that order.
    ///
    /// Both the eyedropper and the zoom box are defined against the raw
    /// frame (one samples it, the other names a sensor region the body will
    /// punch into), so both come back through here. The component transforms
    /// are tested in ScanTests.
    func sensorPoint(fromDisplay p: CGPoint) -> CGPoint {
        FineRotation.unstraightened(
            previewRotation.sensorPoint(
                fromDisplay: PreviewMirror.unmirror(p, mirrored: previewMirrored)),
            byDegrees: previewStraightenDegrees,
            aspect: sensorAspectRatio)
    }

    // MARK: - Crop

    /// The crop, in sensor space: normalized [0,1]², y-down, against the
    /// straightened frame as the camera sends it, before the quarter turn.
    ///
    /// Sensor space because that is this codebase's structural rule (see
    /// `PreviewRotation`) and because it makes the quarter-turn button free:
    /// turning the view cannot move a box that was never expressed in the
    /// view's coordinates.
    ///
    /// Editing still happens in display space (`cropDisplayRect` is what the
    /// overlay binds to), because a quarter turn is the only rotation that
    /// carries an axis-aligned rectangle to another one, so the two
    /// representations are exactly interconvertible and the editor never has to
    /// reason about rotation.
    ///
    /// Persistence hangs off the property itself rather than off each place
    /// that changes it. A drag writes UserDefaults on every event, which is an
    /// in-memory dictionary write coalesced to disk.
    @Published private(set) var cropSensorRect: CGRect? = AppSettings.shared.cropSensorRect {
        didSet { AppSettings.shared.cropSensorRect = cropSensorRect }
    }

    /// The crop as the overlay sees it: the same rectangle, turned into the
    /// orientation on screen.
    var cropDisplayRect: CGRect? {
        get {
            cropSensorRect.map {
                PreviewMirror.mirrorRect(previewRotation.displayRect(fromSensor: $0),
                                         mirrored: previewMirrored)
            }
        }
        set {
            cropSensorRect = newValue.map {
                previewRotation.sensorRect(
                    fromDisplay: PreviewMirror.mirrorRect($0, mirrored: previewMirrored))
            }
        }
    }

    var isCropActive: Bool { cropSensorRect != nil }

    /// True while the box is being adjusted. The overlay takes the pointer
    /// while this is true and the eyedropper is not armed.
    ///
    /// The overlay covers the whole pane (it has to, because a crop taken to
    /// the negative's edge puts its rotate band out in the letterbox), so
    /// leaving it interactive after the box is settled would put it between
    /// the operator and click-to-move-the-zoom-box and everything else
    /// underneath. See `CropInteraction` for why fixed mode removes the
    /// gesture.
    ///
    /// Restored as `false` on launch for the same reason.
    @Published private(set) var isCropEditing = false

    /// Format the session expects, carried from one negative to the next.
    ///
    /// An operator works through a stack of one format, so the last confirmed
    /// one is a strong prior for the next, strong enough to reject a detection
    /// whose shape no such frame could have. Persisted, because a session
    /// usually resumes where it left off.
    var expectedFilmSize: FilmSize? {
        get { AppSettings.shared.expectedFilmSize }
        set {
            AppSettings.shared.expectedFilmSize = newValue
            objectWillChange.send()
        }
    }

    /// Pixel size of the most recent capture, so the crop can be reported in
    /// the coordinates of the file it will be applied to rather than the
    /// preview's.
    @Published private(set) var lastCaptureSize: CGSize?

    /// Pixel size of the image the crop is quoted against, in sensor
    /// orientation: the captured file when one has arrived, the live frame
    /// until then.
    ///
    /// The two arrive in different orientations. `lastCaptureSize` is read
    /// from the RAW, which the body never rotates, so it is already
    /// sensor-oriented. `latestFrame` is the composed preview, which has been
    /// through the quarter turn, so at 90° and 270° its width and height are
    /// the other way round, and this swaps them back.
    var cropReferenceSensorSize: CGSize? {
        if let captured = lastCaptureSize { return captured }
        guard let frame = latestFrame?.size else { return nil }
        return previewRotation.swapsAxes
            ? CGSize(width: frame.height, height: frame.width) : frame
    }

    /// The same image's size as it appears on screen, for anything quoted
    /// against `cropDisplayRect`.
    var cropReferenceDisplaySize: CGSize? {
        cropReferenceSensorSize.map {
            previewRotation.swapsAxes ? CGSize(width: $0.height, height: $0.width) : $0
        }
    }

    /// The crop in the reference image's pixels, for the footer readout and
    /// the auto-crop notice.
    ///
    /// Quoted against the *display* rectangle and the display frame's size,
    /// because that is the picture the operator is looking at while reading the
    /// number. The metadata records the sensor-space rectangle instead, which
    /// is the one a downstream tool can apply without knowing how the preview
    /// happened to be turned.
    var cropPixelRect: CGRect? {
        guard let r = cropDisplayRect, let size = cropReferenceDisplaySize,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: r.minX * size.width, y: r.minY * size.height,
                      width: r.width * size.width, height: r.height * size.height)
    }

    /// What this live-view session has learned about the size of its own frames.
    ///
    /// The planner-anchored route builds its box from the expected format's
    /// nominal dimensions and lands consistently large. `FrameScale` remembers
    /// the size of every box a measured route produced and, once it holds
    /// three, resizes a planner-anchored box to their median, holding
    /// whichever edge the planner pinned. An operator works a stack of the
    /// same film on the same stand, so one negative's size predicts the next.
    ///
    /// Session-scoped, and reset in `startLiveView()`: a new session is
    /// usually a new stand height or a new format, and the old median would
    /// pull its boxes toward the wrong size.
    private var frameScale = FrameScale()

    /// Slack added to a detected crop, as a fraction of its own size.
    ///
    /// Detection stops on the boundary it found, so a crop taken exactly there
    /// can shave the outermost row of picture. On a 5300-pixel-wide 120 frame
    /// this works out at about 13 px overall, under 7 px a side, enough to
    /// stop the crop biting into the image, small enough that it doesn't
    /// visibly admit rebate.
    static let autoCropSlack = 0.0025

    /// Find the negative and put a crop box on it. Button-triggered, never
    /// automatic: detection firing on its own while film is still being
    /// positioned is worse than none.
    func runAutoCrop() {
        guard let jpeg = lastUnadjustedFrame else {
            showNotice("No frame to crop. Start live view first.")
            return
        }
        // Runs against the frame as the camera sent it, straightened but
        // otherwise untouched. Inversion, monochrome and white-balance gains
        // are the operator's view of the film rather than the film, and
        // detection should see the film.
        guard let cg = PreviewPipeline.straightenedBitmap(
            jpeg: jpeg, straightenDegrees: previewStraightenDegrees) else {
            showNotice("Couldn't read the frame")
            appLog.error("auto-crop: frame would not decode")
            return
        }
        // Same image as both arms: the live-view frame is a negative, and the
        // sprocket holes read brighter than the rebate on every stock, which is
        // the polarity `PerforationFrame`'s negative arm reads.
        guard let result = AutoCrop.detect(in: cg, expecting: expectedFilmSize, negative: cg) else {
            showNotice("No negative found. Set the crop by hand, or check the framing.")
            appLog.info("auto-crop: no plan")
            return
        }
        let final = frameScale.refined(result)
        cropSensorRect = CropBox.sanitized(
            CropBox.expanded(final.rect, byFraction: Self.autoCropSlack))
        isCropEditing = true
        if result.route.isMeasured { frameScale.learn(from: result) }

        // Learn from a detection we believed, so the next negative has a prior.
        // Only from the two rungs that measured the frame's own width:
        // `.perforationAnchored` takes its width from the expected format's
        // ratio, so learning the format back off it would be circular, the same
        // reason `.plannerAnchored` is excluded.
        // Sensor-oriented on purpose: `result.rect` came out of the detector in
        // sensor space, so pairing it with the display's dimensions would hand
        // the matcher a transposed frame on a rotated preview and make it pick
        // the portrait format for a landscape negative.
        if result.route == .plannerDetected || result.route == .frameFinderBounded,
           let size = cropReferenceSensorSize {
            let px = CGSize(width: result.rect.width * size.width,
                            height: result.rect.height * size.height)
            let match = FilmSizeMatcher.bestMatch(forCropSize: px, in: FilmSize.seedCatalog)
            if FilmSize.detectionMayReplace(expectedFilmSize, other: AppSettings.shared.filmSizeOther != nil, with: match) {
                expectedFilmSize = match
            }
        }

        showNotice(AutoCrop.notice(for: result.route, pixelSize: cropPixelRect?.size))
        appLog.info("auto-crop \(result.route.rawValue, privacy: .public) rect=\(String(describing: final.rect), privacy: .public) angle=\(String(format: "%.2f", result.angle), privacy: .public) scaleSamples=\(self.frameScale.sampleCount, privacy: .public) calibrated=\(self.frameScale.isCalibrated ? "Y" : "N", privacy: .public)")
    }

    /// Fix the box in place and hand the pointer back.
    func fixCrop() {
        guard isCropActive, isCropEditing else { return }
        isCropEditing = false
        showNotice("Crop fixed. Click-to-move works again.")
    }

    /// Go back to adjusting a fixed crop.
    func adjustCrop() {
        guard isCropActive, !isCropEditing else { return }
        isCropEditing = true
    }

    func toggleCropEditing() {
        if isCropEditing { fixCrop() } else { adjustCrop() }
    }

    /// Slide the crop box to the middle of the frame, size unchanged.
    func centerCrop() {
        guard let r = cropSensorRect else { return }
        cropSensorRect = CropBox.centered(r)
        showNotice("Crop centered")
    }

    func clearCrop() {
        guard isCropActive else { return }
        cropSensorRect = nil
        isCropEditing = false
        showNotice("Crop cleared")
    }

    /// The crop and straightening as they go into a capture's metadata, or nil
    /// when there is no crop to record.
    var cropRecord: TreatmentRecord.Crop? {
        guard let r = cropSensorRect else { return nil }
        return TreatmentRecord.Crop(
            x: Double(r.minX), y: Double(r.minY),
            width: Double(r.width), height: Double(r.height),
            straightenDegrees: isStraightened ? previewStraightenDegrees : 0,
            filmSizeID: expectedFilmSize.flatMap { $0.isUnknown ? nil : $0.id })
    }

    /// Pixel dimensions of an image file, from its header alone.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` never decodes, which is what makes
    /// this affordable: it runs on every capture, against files that are 5000
    /// pixels wide and RAW.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Cycle to the next peaking color. Wraps around after the last.
    func cycleFocusPeakingColor() {
        let all = FocusPeaking.PeakColor.allCases
        guard let idx = all.firstIndex(of: focusPeakingColor) else {
            focusPeakingColor = all.first ?? .cyan
            return
        }
        focusPeakingColor = all[(idx + 1) % all.count]
        appLog.info("focus peaking color → \(self.focusPeakingColor.rawValue, privacy: .public)")
    }

    var isLiveViewOn: Bool { ui == .streaming }

    struct PermissionsState: Equatable {
        var accessibility: Bool = false
        var inputMonitoring: Bool = false
    }

    private var connection: CameraConnection?
    private var session: CameraSession?
    private var properties: CameraProperties?
    private var capture: CameraCapture?
    private var liveView: LiveView?
    private var liveZoom: LiveZoom?
    private var hotkey: HoldKeyMonitor?
    private var connectionTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var hotkeyTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?

    /// Previous raw camera-clock reading, used to tell a live value from the
    /// ptp2 driver's per-session cache (the driver reports the clock once per
    /// session, so identical consecutive reads mean we are looking at the cache).
    private var lastRawCameraClock: Date?
    /// Background drain of libgphoto2's event queue. Runs while live view
    /// streams (started in startLiveView, canceled in stopLiveView and stop)
    /// to pick up property-change events the body emits during EVF, such as
    /// shutterspeed changes from the auto-meter and focusmode toggles.
    /// Without this loop the body's current state would come only from
    /// gp_camera_get_config, which fights the EVF stream for the USB pipe.
    /// The body emits the events whether they are drained or not. Source:
    /// gphoto2 --wait-event probe on the 7D.
    private var eventDrainTask: Task<Void, Never>?
    private var cameraEvents: CameraEvents?
    /// A drain call is (or may be about to be) reading camera events. See
    /// runEventDrain and waitForEventDrainIdle.
    private var eventDrainActive = false
    /// Camera ops inside withLVPriority, plus a capture in flight. Autofocus
    /// waits for this to reach 0 before its first write, and every such op
    /// waits for autofocus before counting itself in, so an AF run does not
    /// overlap another camera op unless that wait times out
    /// (afIdleWaitSeconds).
    private var cameraOpsInFlight = 0
    /// Set once autofocus has the camera (no op in flight), cleared when its
    /// closing cancel is back. Ops wait on this, not on autofocusBusy, so an
    /// op nested inside another op cannot deadlock against an AF press that
    /// is still waiting for the outer op to finish.
    private var autofocusRunning = false
    private var captureKeyMonitor: Any?
    /// Where the camera's 5x punch-in can land and the `eoszoomposition`
    /// value for each landing, measured on the body (see `PunchInGrid`). The
    /// box is drawn at the reachable center nearest the point the user chose,
    /// so it shows where the punch-in goes.
    static let punchIn = PunchInGrid.eos7D
    /// The 5x zoom region as a fraction of the frame. The box is drawn this
    /// size, and the clamp and nudge use it too.
    static let zoomBoxFraction: CGFloat = punchIn.boxFraction.width

    // MARK: - Lifecycle

    func start() async {
        refreshPermissions()
        TextEntryFocus.startTracking()
        startCaptureKeyMonitor()
        let conn = await CameraConnection()
        self.connection = conn
        connectionTask = Task { [weak self] in
            await conn.startMonitoring()
            for await state in conn.stateStream {
                await self?.handleConnectionState(state)
            }
        }
        waitTask = Task { [weak self] in
            for await w in conn.waitStream {
                self?.connectWait = w
            }
        }
    }

    func stop() async {
        connectionTask?.cancel()
        waitTask?.cancel()
        liveViewTask?.cancel()
        hotkeyTask?.cancel()
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        eventDrainTask?.cancel()
        eventDrainTask = nil
        cameraEvents = nil
        hotkey?.stop()
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        // Quit only: the UI Stop path is stopLiveView(), which keeps the
        // session open. The steps log their offset from here, so an Export
        // Log from Help shows the sequence.
        let t0 = Date()
        func at() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        let wasStreaming = await liveView?.isActive ?? false
        appLog.info("quit: begin, live view \(wasStreaming ? "on" : "off", privacy: .public)")
        // No presence poll during the teardown: it would put USB traffic
        // between the EVF-off writes and the drain.
        if let conn = connection { await conn.stopPolling() }
        if let lv = liveView {
            try? await lv.stop()   // cancels the LV loop, then viewfinder=0 and output=TFT, both awaited
            appLog.info("quit: t+\(at(), privacy: .public) ms EVF-off writes returned")
            // Closing the session straight after output=TFT can leave the body
            // wedged until a battery pull. Let the EVF-exit burst finish and
            // read back that EVF is off before gp_camera_exit. The drain is
            // capped at 1.5 s, inside the 8 s force-quit timer in
            // applicationShouldTerminate.
            if wasStreaming {
                // A slow body can spend the budget in the EVF writes. Past 4 s
                // the readback (one full config fetch) is skipped, so quit
                // still reaches gp_camera_exit before the 8 s timer.
                let r = await lv.settleBeforeExit(readBack: at() < 4000)
                appLog.info("quit: t+\(at(), privacy: .public) ms settled (\(String(describing: r.verdict), privacy: .public), \(r.events, privacy: .public) events), viewfinder=\(r.viewfinder ?? "unreadable", privacy: .public) output=\(r.output ?? "unreadable", privacy: .public)")
            }
        }
        // Close the libgphoto2 session so the USB/PTP claim is released.
        // stopMonitoring() already calls session.close() (gp_camera_exit), and
        // the explicit close is a no-op second guard.
        if let conn = connection { await conn.stopMonitoring() }
        await session?.close()
        appLog.info("quit: t+\(at(), privacy: .public) ms gp_camera_exit returned, session closed")
        connection = nil
        session = nil
        properties = nil
        capture = nil
        liveView = nil
        liveZoom = nil
    }

    // MARK: - Connection-state handling

    private func handleConnectionState(_ state: CameraConnection.ConnectionState) async {
        switch state {
        case .disconnected:
            self.session = nil
            self.properties = nil
            self.capture = nil
            self.liveView = nil
            self.liveZoom = nil
            self.ui = .disconnected
            self.latestFrame = nil
            // New session means a new driver cache, so the next clock reading
            // is fresh and must be allowed to set the offset.
            self.lastRawCameraClock = nil
            liveViewTask?.cancel()
            liveViewTask = nil
        case .enumerating:
            self.ui = .enumerating
        case .ready:
            guard let conn = connection else {
                self.ui = .error(message: "Connection ready but no connection object.", hint: nil)
                return
            }
            guard let sess = await conn.currentSession() else {
                self.ui = .error(message: "Connection ready but no session.", hint: nil)
                return
            }
            self.session = sess
            let props = await CameraProperties(session: sess)
            self.properties = props
            self.capture = await CameraCapture(session: sess, properties: props)
            let lv = await LiveView(session: sess, properties: props)
            self.liveView = lv
            self.liveZoom = await LiveZoom(session: sess)
            let evts = await CameraEvents(session: sess)
            self.cameraEvents = evts
            self.ui = .ready
            // Start the frame consumer once per connection. AsyncStream is not a
            // multicast subject: iterating it again across stop/start cycles
            // leaves the second iterator seeing an empty stream while runLoop is
            // still yielding frames. runLoop's start()/stop() controls whether
            // frames flow, and this loop drains whatever arrives.
            liveViewTask?.cancel()
            liveViewTask = Task { [weak self] in
                for await frame in lv.frameStream {
                    await self?.handleFrame(frame)
                }
            }
            await refreshSnapshot()
            await loadChoices()
            startHotkey()
            startSnapshotRefresh()
            // eventDrainTask is not started here. Started at connect-ready, the
            // drain holds the actor continuously while idle, which keeps the
            // body's PTP daemon busy enough that later setViewfinder(0/1) writes
            // fail to move the mirror: it fails to close or open on Stop/Start.
            // The drain only matters during live view (metered Tv is a
            // live-view-only signal), so startLiveView() starts it and
            // stopLiveView() stops it.

            // Sync the camera clock to host local wall time (on by default in
            // AppSettings). Local rather than UTC keeps EXIF DateTimeOriginal
            // right on bodies whose internal time zone setting doesn't match
            // the host (see CameraProperties.syncDateTimeToHostLocal).
            //
            // The 7D can go into its fatal "shooting is not possible, remove the
            // battery" error after a libgphoto2 widget write its firmware can't
            // handle in some state. The clock write is the only write the app
            // makes on the connect path, so it is the first suspect, though not
            // a proven cause. The clock sync has its own setting so it can be
            // turned off.
            if AppSettings.shared.autoSyncClockOnConnect {
                Task { [weak self] in await self?.syncCameraClockLocal() }
            }
        case .error(let err):
            showCameraError(err, during: .connect)
        }
    }

    /// Shows a camera error through `cameraAdvice`: a plain first line, a hint
    /// saying what to try, and the raw code behind the error card's info icon.
    /// The two internal-state errors in `handleConnectionState` set `ui`
    /// directly and have no hint.
    private func showCameraError(_ error: Error, during op: CameraAdvice.Operation) {
        let advice = cameraAdvice(for: error, during: op)
        appLog.error("camera error shown (\(String(describing: op), privacy: .public)): \(advice.message, privacy: .public) | \(advice.detail ?? "", privacy: .public)")
        self.ui = .error(message: advice.message, hint: advice.hint, detail: advice.detail)
    }

    /// Maps an error to the message, hint and detail the user reads.
    private func cameraAdvice(for error: Error, during op: CameraAdvice.Operation) -> CameraAdvice {
        if let e = error as? CameraError {
            return CameraAdvice.advice(for: e, during: op,
                                       cameraAppsRunning: OtherCameraApps.cameraAppsRunning(),
                                       // The PTP daemon check runs pgrep, so only on connect.
                                       ptpDaemonRunning: op == .connect && OtherCameraApps.ptpDaemonRunning(),
                                       claimSeenInSeries: op == .connect && (connection?.claimSeenInSeries.isSet ?? false))
        }
        return CameraAdvice.advice(forOther: error, during: op)
    }

    // MARK: - Live view

    func startLiveView() async {
        appLog.info("startLiveView() called")
        guard let lv = liveView, liveZoom != nil else {
            appLog.error("startLiveView: liveView or liveZoom nil")
            return
        }
        // A second press while the start, or its stall ladder, is still
        // running would start a second ladder against the same body.
        guard !liveViewStarting else {
            appLog.info("startLiveView: a start is already running, ignored")
            return
        }
        liveViewStarting = true
        defer { liveViewStarting = false }
        self.meteringCenter = CGPoint(x: 0.5, y: 0.5)
        // A new session is usually a new stand height or a new format, so the previous
        // session's median frame size is not evidence about this one.
        self.frameScale = FrameScale()
        do {
            try await startLiveViewUnderBudget(lv)
            self.ui = .streaming
            appLog.info("startLiveView: ui → .streaming")
            // The event drain runs only during live view, see the note in
            // handleConnectionState(.ready).
            startEventDrain()
            // No periodic meter kick here: Press Half writes every 2 s wedge
            // the body's firmware until a power cycle. The 7D can't tolerate
            // sustained Press Half cycling even with C.Fn IV-1 = AE lock. So
            // the footer's metered shutter does not update in real time. It
            // reflects what the live-view meter emits (rare in Av and P modes)
            // plus what arrives through the Press Half each capture sends. A
            // kick would make the body emit the capture-meter value, which on
            // the 7D differs from the live-view meter (the footer can read
            // 1/100 while capture fires 1/150). No safe way to get real-time
            // capture-meter parity on the 7D through libgphoto2 is known.

            // Camera-side eoszoom is assumed to work (on the 7D a probe found
            // it supported every time), so nothing probes it here. A probe
            // shows a visible "flash of zoom" on LV start, because it sets
            // setZoom(.fivex) and then back to .fit while the preview pane is
            // showing. zoomFallbackActive stays false until applyZoom finds
            // no LiveZoom or a zoom write throws.
            zoomFallbackActive = false
        } catch let err as CameraError {
            appLog.error("startLiveView CameraError: \(err.localizedDescription, privacy: .public)")
            showCameraError(err, during: .liveView)
        } catch {
            appLog.error("startLiveView error: \(String(describing: error), privacy: .public)")
            showCameraError(error, during: .liveView)
        }
    }

    /// True from a live-view start's first write until its ladder ends.
    private var liveViewStarting = false

    static let liveViewStartStage = "live view start"

    /// The live-view start under the stall ladder (StallLadder.swift): 45 s,
    /// then close the stuck session from off the camera thread and throw the
    /// error `StallHistory.recordStall` returns, or `.notAnswering`. No USB
    /// reset and no retry in the app. Throws the start's own error
    /// when it fails in time.
    private func startLiveViewUnderBudget(_ lv: LiveView) async throws {
        let box = LiveViewStallBox(lv: lv, session: session)
        liveViewLadderGen &+= 1
        let gen = liveViewLadderGen
        // The ladder owns the connection until it ends: no presence poll may
        // connect or disconnect under it (CameraConnection.pollHold).
        let conn = connection
        conn?.pollHold.set()
        let t0 = Date()
        let log: @Sendable (String) -> Void = { line in
            let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
            appLog.info("liveview: t+\(ms, privacy: .public) ms \(line, privacy: .public)")
        }
        // No reset in the app, so no reconnect and no retry: a stall is close,
        // then the card (StallLadder.swift header).
        let ladder = StallLadder.app
        let io = StallIO(
            attempt: { _ in
                guard let lv = box.liveView else { throw CameraError.liveViewNotActive }
                try await lv.start()
            },
            close: { box.session?.closeFromWatchdog() ?? "no session" },
            // The caller below is not stuck (only the camera thread is) and
            // throws the advice itself.
            advise: {},
            log: log,
            progress: { [weak self] p in
                Task { @MainActor in self?.noteLiveViewProgress(p, gen: gen) }
            })
        defer { liveViewWait = nil }
        switch await StallGuard.run(stage: AppModel.liveViewStartStage, ladder: ladder, io: io) {
        case .answered:
            conn?.pollHold.clear()
        case .failed(let error, _):
            conn?.pollHold.clear()
            throw error
        case .notAnswering:
            // Queued on the camera actor, so it runs when the thread comes
            // free, which is the power cycle: it drops the stuck session, only
            // that one, and hands the connection back to the presence poll,
            // which then opens a fresh session.
            let stuck = box.session
            if let conn { Task { await conn.dropStalledSession(stuck) } }
            // recordStall returns the restart-the-Mac error only for a stall,
            // power cycle, stall sequence (StallHistory), and the plain
            // not-answering error otherwise.
            throw conn?.stallHistory.recordStall(stage: AppModel.liveViewStartStage)
                ?? CameraError.notAnswering(stage: AppModel.liveViewStartStage)
        }
    }

    /// A live-view ladder's progress, hopped onto the main actor. Only the
    /// current ladder while it runs may set the glyph.
    private func noteLiveViewProgress(_ p: StallProgress, gen: Int) {
        guard gen == liveViewLadderGen, liveViewStarting else { return }
        switch p {
        case .attempt(1): liveViewWait = CameraWait(activity: .startingLiveView, since: Date())
        case .attempt: break
        case .finished: liveViewWait = nil
        }
    }

    func stopLiveView() async {
        appLog.info("stopLiveView() called (ui=\(String(describing: self.ui), privacy: .public))")
        // A stop between DoAf and the closing cancel would leave the half
        // press latched, so it waits for the run to end.
        await waitForAutofocusIdle()
        // Stop the event drain before writing viewfinder=0, so the body's PTP
        // daemon has a quiet channel to drop the mirror.
        eventDrainTask?.cancel()
        eventDrainTask = nil
        if let lv = liveView {
            do { try await lv.stop(); appLog.info("LiveView.stop() OK") }
            catch { appLog.error("LiveView.stop() failed: \(String(describing: error), privacy: .public)") }
        }
        if case .streaming = ui { self.ui = .ready; appLog.info("stopLiveView: ui → .ready") }
        latestFrame = nil
        exposureAdvice = nil
        exposureGate.reset()
        // Nothing left to sample, so an armed eyedropper would just fail on the
        // next click. The white balance itself is kept, it belongs to the film,
        // not to the live-view session.
        lastUnadjustedFrame = nil
        wbPick.disarm()
        // The next live view session starts at Fit.
        zoomMode = .fit
        previewZoom = .fit
        zoomBeforeHold = .fit
    }

    private func handleFrame(_ frame: LiveView.Frame) async {
        // Gate on streaming state. The long-lived liveViewTask keeps draining
        // lv.frameStream after the user hits Stop. A frame runLoop had
        // buffered at cancel can still arrive here and put the old image
        // back in latestFrame, so frames after a stop are dropped.
        guard ui == .streaming else { return }
        // Live histogram: ~5 Hz is plenty for an exposure aid. Skip while
        // zoomed (the card hides then anyway) and while disabled. Computed
        // inside the PreviewPipeline pass below so histogram ticks share the
        // display render's single decode instead of decoding the JPEG twice.
        histFrameTick &+= 1
        let wantHistogram = AppSettings.shared.histogramEnabled
            && zoomMode == .fit && histFrameTick % 6 == 0
        let now = Date()
        lastFrameJPEG = frame.jpegData
        lastFrameZoom = afZoomKey
        if afCheck != nil { noteFrameForAutofocus(frame.jpegData) }
        noteFrameForExposureAdvice(frame.jpegData, at: now)

        var jpeg = frame.jpegData
        // Client-side JPEG crop is a fallback only. When camera-side sensor
        // zoom is engaged (zoomFallbackActive == false), the body already
        // streams the sharp magnified frame, so it passes straight through.
        // The crop here runs when the body refused the eoszoom write or there
        // is no LiveZoom.
        if zoomMode != .fit, zoomFallbackActive,
           let cropped = JPEGCrop.cropAt(jpeg, divisor: zoomMode.rawValue, center: meteringCenter) {
            jpeg = cropped
        }
        // Keep the frame for the eyedropper to sample. Everything below is
        // correction the sample must not see.
        lastUnadjustedFrame = jpeg
        let peaking = focusPeakingEnabled
            ? PreviewPipeline.Peaking(
                mode: focusPeakingMode,
                intensity: Float(AppSettings.shared.focusPeakingIntensity),
                color: focusPeakingColor
              )
            : nil
        // One decode, one Core Image graph, one bitmap out, plus the
        // histogram tap on its ticks, sharing that same decode. Returns a nil
        // image when there's nothing to apply, which is the common case, then
        // the JPEG goes straight to NSImage.
        let (rendered, hist) = PreviewPipeline.renderTapped(
            jpeg: jpeg, adjustments: displayedAdjustments, peaking: peaking,
            computeHistogram: wantHistogram,
            straightenDegrees: previewStraightenDegrees
        )
        if let hist { histogramData = hist }
        let base = rendered ?? NSImage(data: jpeg)
        // Draw the zoom box into the frame itself (image-pixel space), not as
        // a separate SwiftUI overlay, so it cannot drift from the image
        // content. Drawn only at fit, and only while the zoom box is switched
        // on.
        var composed = base
        if let base, showMeteringOverlay, zoomMode == .fit {
            // `meteringCenter` is a sensor coordinate and the frame it is being
            // drawn onto has been straightened, so the box has to be turned
            // with it or it slides off the film it marks. Only the center is
            // mapped: the box itself stays square to the screen.
            let center = FineRotation.straightened(
                AppModel.punchIn.snapped(meteringCenter), byDegrees: previewStraightenDegrees,
                aspect: sensorAspectRatio)
            composed = Self.drawZoomBox(on: base, center: center,
                                        fraction: AppModel.zoomBoxFraction)
        }
        // The quarter turn and the mirror apply to the finished frame, so
        // the box drawn above turns with the image content.
        self.latestFrame = composed.map { PreviewMirror.apply(previewRotation.rotate($0), mirrored: previewMirrored) }
    }

    /// Composite the zoom-target rectangle onto a copy of the frame in image
    /// pixel coordinates. `center` is normalized [0,1] top-down. NSImage's
    /// origin is bottom-left, so Y is flipped.
    private static func drawZoomBox(on image: NSImage, center: CGPoint, fraction f: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))
        let bw = size.width * f, bh = size.height * f
        // The box is drawn at `center` with no offset. The caller passes the
        // metering center snapped to the punch-in grid and then straightened,
        // so the box sits where the camera zooms.
        let cx = center.x * size.width
        let cy = (1 - center.y) * size.height
        let rect = CGRect(x: cx - bw/2, y: cy - bh/2, width: bw, height: bh)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = max(1.5, size.width / 480)  // ~2px at 1056-wide
        path.stroke()
        let ch = NSBezierPath()
        ch.move(to: CGPoint(x: cx - 8, y: cy)); ch.line(to: CGPoint(x: cx + 8, y: cy))
        ch.move(to: CGPoint(x: cx, y: cy - 8)); ch.line(to: CGPoint(x: cx, y: cy + 8))
        ch.lineWidth = path.lineWidth; ch.stroke()
        out.unlockFocus()
        return out
    }

    // MARK: - Capture

    func captureNow() async {
        appLog.info("captureNow() called")
        // A capture asked for mid-autofocus waits for the closing cancel, and
        // counts itself so no autofocus starts while it runs (it reads camera
        // events for FILE_ADDED).
        await enterCameraOp()
        defer { cameraOpsInFlight -= 1 }
        guard let cap = capture else {
            appLog.error("captureNow: capture nil, connection not ready?")
            return
        }
        let folder = AppSettings.shared.captureFolder
        let pattern = AppSettings.shared.filenamePattern
        appLog.info("captureNow → \(pattern, privacy: .public)")

        // With Meta on, fold the live camera and film values into history, so
        // a value typed but not committed with Return is remembered the moment
        // it's used on a capture.
        let metaOn = AppSettings.shared.metadataEnabled
        if metaOn {
            AppSettings.shared.commitCamera(AppSettings.shared.shotCamera)
            AppSettings.shared.commitFilm(AppSettings.shared.shotFilm)
            AppSettings.shared.commitTakenOn(AppSettings.shared.shotTakenOn)
        }
        // With Meta off the metadata is empty and MetadataWriter.write is a
        // no-op: no sidecar, no embed, field values untouched for later. The
        // active preview treatment rides along under the same gate, recorded
        // per capture only when Meta is on and only when it carries data. It
        // records the user's own adjustments, never the negative an armed
        // pick shows.
        let adj = wbPick.recorded(previewAdjustments)
        let treatment = TreatmentRecord(
            baseSample: adj.baseSample.map { .init(r: $0.red, g: $0.green, b: $0.blue) },
            previewGains: adj.whiteBalance.flatMap {
                $0.isIdentity ? nil : .init(r: $0.red, g: $0.green, b: $0.blue)
            },
            inverted: adj.invert,
            monochrome: adj.monochrome,
            crop: cropRecord,
            // The shared geometry Film Positive applies after the crop: the
            // quarter turn and the mirror exactly as the operator had them.
            rotate: previewRotation.rawValue,
            flip: previewMirrored,
            samplePoint: adj.baseSample?.point.map { .init(x: $0.x, y: $0.y) },
            // Clear Crop leaves the angle in place, so record it on its own
            // too: what is on screen is what Film Positive gets.
            straightenDegrees: isStraightened ? previewStraightenDegrees : 0
        )
        let metadata = metaOn
            ? CaptureMetadata(camera: AppSettings.shared.shotCamera,
                              film: AppSettings.shared.shotFilm,
                              treatment: treatment.isEmpty ? nil : treatment,
                              capturedAt: Date(),
                              takenOn: AppSettings.shared.shotTakenOn,
                              filmSizeID: expectedFilmSize.flatMap { $0.isUnknown ? nil : $0.id },
                              filmSizeName: AppSettings.shared.filmSizeName)
            : CaptureMetadata(camera: "", film: "")

        // CameraCapture fires gp_camera_capture(GP_CAPTURE_IMAGE) after a
        // Press Half (what that does to AE depends on C.Fn IV-1, see
        // AFProbe.swift). Live view stays up through the capture. Tearing
        // EVF down makes the body's reflex meter (mirror down) set the
        // capture exposure, which differs from the LV meter that drove the
        // preview. With LV up the same sensor-based meter drives both preview
        // and captured exposure, so they match.
        //
        // On the 7D, gp_camera_capture has hung with viewfinder=1, so a hang
        // here may come from keeping live view up.
        //
        // The live-view frame fetch still pauses through withLVPriority so
        // the USB pipe isn't fighting capture's writes.
        var captureResult: CameraCapture.CaptureResult?
        var captureError: Error?
        await withLVPriority {
            do {
                captureResult = try await cap.capture(to: folder, filenamePattern: pattern, metadata: metadata)
            } catch {
                captureError = error
            }
        }

        if let result = captureResult {
            self.lastCapture = result.path.lastPathComponent
            // Dimensions only, read from the file's header without decoding
            // it. The crop is defined on the preview and applied to this, so
            // its corners should be quoted in this file's pixels rather than
            // the live view's much smaller ones.
            self.lastCaptureSize = Self.pixelSize(of: result.path) ?? self.lastCaptureSize
            self.snapshot.iso = result.iso ?? self.snapshot.iso
            self.snapshot.shutter = result.shutter ?? self.snapshot.shutter
            self.snapshot.aperture = result.aperture ?? self.snapshot.aperture
            appLog.info("captureNow OK: \(result.path.lastPathComponent, privacy: .public)")
            // Pick up any side-effect property changes the camera made during
            // capture (focusmode auto-restored, AE state, etc).
            await refreshSnapshot()
        } else if let err = captureError as? CameraError {
            appLog.error("captureNow CameraError: \(err.localizedDescription, privacy: .public)")
            showCameraError(err, during: .capture)
        } else if let err = captureError {
            appLog.error("captureNow error: \(String(describing: err), privacy: .public)")
            showCameraError(err, during: .capture)
        }
    }

    /// Push host *local* wall time to the camera (time zone aware). Local rather
    /// than UTC because the 7D's EXIF DateTimeOriginal is a wall-clock value.
    /// A UTC sync leaves a drift equal to the gap between the camera's time
    /// zone and the host's (one hour with the camera on PST and the host on
    /// PDT). CameraProperties has the details.
    func syncCameraClockLocal() async {
        appLog.info("syncCameraClockLocal() called")
        guard let p = properties else {
            showNotice("No camera connected, so the clock can't be set.")
            return
        }
        let tzOffset = AppSettings.shared.cameraTZOffsetMinutes
        // Runs under withLVPriority. Without it the write competes with the
        // 30 FPS preview stream for the USB pipe and can fail with -110 (I/O in
        // progress) during live view.
        var failure: Error?
        await withLVPriority {
            do {
                try await p.syncDateTimeToHostLocal(tzOffsetMinutes: tzOffset)
                appLog.info("camera datetime synced (tzOffset=\(tzOffset, privacy: .public)min)")
            } catch {
                failure = error
            }
        }
        if let failure {
            let advice = cameraAdvice(for: failure, during: .control)
            appLog.error("syncCameraClockLocal failed: \(advice.detail ?? String(describing: failure), privacy: .public)")
            // Surface it, or a failed write looks like a dead button. The raw
            // libgphoto2 text goes to the log, not the status line.
            showNotice(["Couldn't set the camera clock.", advice.hint].compactMap { $0 }.joined(separator: " "))
            return
        }
        await refreshSnapshot()
        // A successful sync sets the camera's clock to the host's, so the offset
        // is zero by definition. Assert that rather than reading it back: the
        // driver caches this property per session, and there's no guarantee the
        // cache reflects a write we just made.
        var s = snapshot
        s.cameraClockOffset = 0
        snapshot = s
        lastRawCameraClock = s.cameraDateTime
        showNotice("Camera clock set to this Mac's time")
    }

    /// Background event drain. While live view streams it keeps one in-flight
    /// call against gp_camera_wait_for_event with a short timeout. Property
    /// events for shutterspeed, iso, aperture, autoexposuremode and focusmode
    /// update the snapshot (applyEvent). This is what carries metered Tv in
    /// Av mode, where the shutterspeed widget reads "auto" but the value
    /// arrives on the event stream.
    private func startEventDrain() {
        eventDrainTask?.cancel()
        eventDrainTask = Task { [weak self] in
            await self?.runEventDrain()
        }
    }

    private func runEventDrain() async {
        guard let evts = cameraEvents else { return }
        appLog.info("event drain: starting")
        while !Task.isCancelled {
            // Raised before the pause check and lowered once the drain call
            // returns, so autofocus can wait for it to fall and know no drain
            // call is still reading events (`waitForEventDrainIdle`). Lowered
            // before every sleep, never left up across one.
            eventDrainActive = true
            // Yield to user-priority ops. When `withLVPriority` pauses the
            // live-view runLoop, the same signal pauses the drain. Otherwise
            // it would read camera events in parallel with capture's own
            // FILE_ADDED drain, and one consumer would eat the other's events.
            // A 50 ms re-check feels instant when the user op finishes.
            if let lv = liveView, await lv.isPaused {
                eventDrainActive = false
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            // drain() swallows errors internally. Loop only exits on
            // Task.isCancelled.
            let events = await evts.drain(budgetMs: 200, perCallMs: 100)
            eventDrainActive = false
            if events.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            for evt in events {
                await applyEvent(evt)
            }
        }
        eventDrainActive = false
        appLog.info("event drain: exited")
    }

    /// Project one camera event onto the UI snapshot.
    private func applyEvent(_ evt: CameraEvents.Event) async {
        switch evt {
        case .propertyChanged(let name, let value, _):
            guard let name, let value else { return }
            switch name {
            case "shutterspeed":
                let isAutoish = value.lowercased() == "auto" || value.isEmpty
                var s = self.snapshot
                if !isAutoish { s.meteredShutter = value }
                // The picker takes the event's value where shutter speed is
                // writable in the current mode (M and Tv among them), or when
                // the value is auto. In Av and P a numeric value goes into
                // meteredShutter only.
                if CameraProperties.pickerFollowsEvent(prop: "shutterspeed", mode: s.mode, value: value) {
                    s.shutter = value
                }
                self.snapshot = s
                self.snapshotTick &+= 1
            case "iso":
                var s = self.snapshot
                s.iso = value
                self.snapshot = s
            case "aperture":
                var s = self.snapshot
                s.aperture = value
                self.snapshot = s
            case "autoexposuremode":
                // Mode-dial turn. This event is the only prompt sign of the
                // dial during live view (the snapshot poller idles then), so
                // the snapshot's mode updates at once, which alone locks or
                // unlocks the exposure pickers, and the choices reload after
                // the dial settles.
                var s = self.snapshot
                guard s.mode != value else { break }
                appLog.notice("mode dial: \(s.mode, privacy: .public) → \(value, privacy: .public) (event), scheduling choices reload")
                s.mode = value
                self.snapshot = s
                self.snapshotTick &+= 1
                scheduleModeChangeRefresh()
            case "focusmode":
                // Reads "Manual" with the lens switch on MF. The snapshot
                // poller idles during live view, so this event is what closes
                // or opens the focus group while streaming.
                var s = self.snapshot
                guard s.focusMode != value else { break }
                appLog.notice("focusmode: \(s.focusMode ?? "unread", privacy: .public) → \(value, privacy: .public) (event)")
                s.focusMode = value
                self.snapshot = s
            default:
                break
            }
        case .fileAdded, .captureComplete, .timeout, .unknown:
            // The capture path drains its own FILE_ADDED inside CameraCapture.
            // Anything that arrives here was emitted outside a capture and is
            // safe to ignore.
            break
        }
    }

    /// A mode-dial sweep emits one autoexposuremode event per detent it
    /// passes through. Debounce so snapshot + choices reload once, after the
    /// dial settles, instead of once per intermediate position.
    private var modeChangeRefreshTask: Task<Void, Never>?
    private func scheduleModeChangeRefresh() {
        modeChangeRefreshTask?.cancel()
        modeChangeRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshSnapshot()
            await self.loadChoices()
        }
    }

    /// Latest live-histogram sample (nil until first compute). Written inline
    /// from handleFrame's PreviewPipeline tap, read by LiveViewPane.
    @Published var histogramData: HistogramData?
    private var histFrameTick: Int = 0

    /// Set while a manual-focus drive is in flight, so rapid button mashing
    /// doesn't queue dozens of USB writes. Without it, mashing can fire ~40
    /// writes in 11 seconds and block a later ISO change with -110
    /// IO_IN_PROGRESS. While one drive is in flight, further presses are
    /// ignored. The motor on the body has a physical settle time anyway.
    private var manualFocusInFlight: Bool = false

    /// Drive manual focus by one step in the requested direction. The motor
    /// moves only with the lens switch on AF and the body's focusmode set to a
    /// value other than Manual. Most USM lenses comply when both are set.
    /// Watch the live view to confirm the lens moved.
    func driveManualFocus(_ step: CameraProperties.ManualFocusStep) async {
        if manualFocusInFlight {
            appLog.debug("driveManualFocus(\(step.rawValue, privacy: .public)) dropped, prior write still in flight")
            return
        }
        // No step during an autofocus run, and none with the lens switch on
        // MF, where the body ignores the drive.
        if autofocusBusy || focusBlockedByLensSwitch {
            appLog.debug("driveManualFocus(\(step.rawValue, privacy: .public)) dropped, autofocus running or lens switch on MF")
            return
        }
        manualFocusInFlight = true
        defer { manualFocusInFlight = false }
        appLog.info("driveManualFocus(\(step.rawValue, privacy: .public))")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.driveManualFocus(step)
            }
            catch let err as CameraError { appLog.error("driveManualFocus: \(err.localizedDescription, privacy: .public)") }
            catch { appLog.error("driveManualFocus: \(String(describing: error), privacy: .public)") }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Autofocus

    /// The lens switch is on MF: the AF button and the six step buttons are
    /// off, and one info icon says why.
    var focusBlockedByLensSwitch: Bool {
        AppAutofocus.blockedByLensSwitch(focusMode: snapshot.focusMode)
    }

    /// The raw body JPEG of the last live-view frame, the before score's source.
    private var lastFrameJPEG: Data?
    /// The zoom state that frame was streamed under, recorded with it: a
    /// Shift punch-in can change the zoom before any zoomed frame arrives.
    private var lastFrameZoom: AFZoomKey?
    private var afRunCounter = 0

    /// What the frame the sharpness is scored on must match: a punch-in and
    /// a fit frame are different images and their scores do not compare.
    private struct AFZoomKey: Equatable {
        let mode: LiveZoom.Mode
        let fallback: Bool
    }
    private var afZoomKey: AFZoomKey { AFZoomKey(mode: zoomMode, fallback: zoomFallbackActive) }

    /// A pending result glyph: waiting for the frame after the run.
    private struct AFSharpnessCheck {
        let run: Int
        let before: Data?
        let zoom: AFZoomKey
        /// The body reported its lock (d1c0 or a focus event) inside the cap.
        let markerArrived: Bool
        /// The body started driving the lens at all.
        let bodyDrove: Bool
        var framesSeen = 0
    }
    private var afCheck: AFSharpnessCheck?
    /// How long the result waits for a frame before it settles on not confirmed.
    private static let afFrameWaitSeconds: UInt64 = 3

    /// One press of the AF button or key. The sequence is AppAutofocus's, with
    /// the d1c0 marker, inside a paused live-view loop so this run is the only
    /// reader of camera events. Busy clears when that sequence returns, and a
    /// successful run's glyph waits for a later frame. One press is one run:
    /// the app never moves the lens or runs AF again on its own.
    func autofocus() async {
        guard !autofocusBusy else { appLog.debug("autofocus: dropped, a run is in flight"); return }
        guard isLiveViewOn, !focusBlockedByLensSwitch, !manualFocusInFlight else {
            appLog.debug("autofocus: dropped (live view \(self.isLiveViewOn, privacy: .public), focusmode \(self.snapshot.focusMode ?? "unread", privacy: .public), step in flight \(self.manualFocusInFlight, privacy: .public))")
            return
        }
        guard let p = properties, let evts = cameraEvents, let lv = liveView else { return }
        autofocusBusy = true
        autofocusResult = nil
        afRunCounter &+= 1
        let run = afRunCounter
        afCheck = nil
        // Wait out any camera op already running (a zoom write, a step, a
        // capture) before the first write, and give up rather than overlap
        // one.
        guard await waitForCameraOpsIdle() else {
            appLog.error("af: run \(run, privacy: .public) dropped, another camera op did not finish in \(Int(AppModel.afOpsWaitSeconds), privacy: .public) s")
            autofocusBusy = false
            return
        }
        // Read after the wait: a zoom write that was in flight has landed and
        // its first frame may have too. The before frame's own zoom is
        // what the after frame must match.
        let before = lastFrameJPEG
        let zoom = lastFrameZoom ?? afZoomKey
        appLog.notice("af: start run \(run, privacy: .public), zoom \(String(describing: zoom.mode), privacy: .public), focusmode \(self.snapshot.focusMode ?? "unread", privacy: .public)")
        let result: (outcome: AppAutofocus.Outcome, error: Error?, seen: [CameraEvents.Event]) = await lv.withPriority {
            await self.waitForEventDrainIdle()
            let io = await CameraAFIO(props: p, events: evts)
            let outcome = await AppAutofocus.run(io: io)
            let error = await io.firstError
            let seen = await io.seen
            return (outcome: outcome, error: error, seen: seen)
        }
        for line in AppAutofocus.logLines(result.outcome) {
            appLog.notice("\(line, privacy: .public)")
        }
        autofocusRunning = false
        autofocusBusy = false
        // The run was the only event reader for up to 7 s. Hand what it read
        // to the snapshot, so a lens switch flipped mid-run still lands.
        for evt in result.seen { await applyEvent(evt) }
        if result.outcome.failed {
            let advice = result.error.map { cameraAdvice(for: $0, during: .autofocus) }
                ?? CameraAdvice.advice(forOther: AFFailure(text: result.outcome.trace.error
                                                           ?? result.outcome.trace.cleanupError ?? "unknown"),
                                       during: .autofocus)
            appLog.error("af: failed: \(advice.message, privacy: .public) | \(advice.detail ?? "", privacy: .public)")
            autofocusResult = .failed(advice)
            return
        }
        let markerArrived = result.outcome.completion == .marker || result.outcome.completion == .focusEvent
        let bodyDrove = result.outcome.bodyDrove
        if !bodyDrove {
            appLog.notice("af: run \(run, privacy: .public): the camera took the command and never started driving (no \(AppAutofocus.driveProperty, privacy: .public), no marker)")
        }
        afCheck = AFSharpnessCheck(run: run, before: before, zoom: zoom,
                                   markerArrived: markerArrived, bodyDrove: bodyDrove)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.afFrameWaitSeconds * 1_000_000_000)
            guard let self, let c = self.afCheck, c.run == run else { return }
            self.afCheck = nil
            appLog.notice("af: no frame within \(AppModel.afFrameWaitSeconds, privacy: .public) s to score, not confirmed")
            self.concludeAF(run: run,
                            result: AppAutofocus.notConfirmed(.noFrame(waitSeconds: Int(AppModel.afFrameWaitSeconds))))
        }
    }

    /// Shows an AF run's result, unless a newer run has started.
    private func concludeAF(run: Int, result: AppAutofocus.Result) {
        guard afRunCounter == run else { return }
        autofocusResult = result
    }

    /// The trace's text for a failure that kept no error object.
    private struct AFFailure: Error, CustomStringConvertible { let text: String; var description: String { text } }

    /// Called from handleFrame while a result is pending. The first frame
    /// after a pause can be the stale buffered one, so the score comes from
    /// the second.
    private func noteFrameForAutofocus(_ jpeg: Data) {
        guard var c = afCheck else { return }
        c.framesSeen += 1
        afCheck = c
        guard c.framesSeen >= 2 else { return }
        afCheck = nil
        guard c.zoom == afZoomKey else {
            // The operator changed the zoom mid-run. That is not a focus
            // failure, so the result is shown as is.
            appLog.notice("af: zoom changed during the run, nothing comparable to score, not confirmed")
            autofocusResult = AppAutofocus.notConfirmed(.zoomChanged)
            return
        }
        let run = c.run, before = c.before, marker = c.markerArrived, drove = c.bodyDrove
        Task.detached(priority: .utility) { [weak self] in
            let b = before.flatMap { Sharpness.score(jpeg: $0) }
            let a = Sharpness.score(jpeg: jpeg)
            await self?.finishAFCheck(run: run, before: b, after: a,
                                      markerArrived: marker, bodyDrove: drove)
        }
    }

    /// The body is in manual exposure, where the shutter is ours to suggest.
    var isManualExposureMode: Bool {
        let m = snapshot.mode.uppercased()
        return m.contains("MANUAL") || m == "M"
    }

    /// About once a second, measure how much of the frame's center
    /// clips, off the main actor, and let the gate decide the glyph. Only at
    /// fit zoom, since a punch-in frame is a different region of the film.
    private func noteFrameForExposureAdvice(_ jpeg: Data, at now: Date) {
        guard isManualExposureMode, zoomMode == .fit else {
            if exposureAdvice != nil || exposureGate.showing { exposureAdvice = nil; exposureGate.reset() }
            return
        }
        guard !exposureCheckBusy, now.timeIntervalSince(exposureCheckAt) >= 1 else { return }
        exposureCheckBusy = true
        exposureCheckAt = now
        Task.detached(priority: .utility) { [weak self] in
            let share = ExposureAdvisor.clippedShare(jpeg: jpeg)
            await self?.finishExposureAdvice(share: share)
        }
    }

    private func finishExposureAdvice(share: Double?) {
        exposureCheckBusy = false
        guard isLiveViewOn, isManualExposureMode, let share else { return }
        let show = exposureGate.update(share: share)
        exposureAdvice = show
            ? ExposureAdvisor.advice(clippedShare: share, current: snapshot.shutter, choices: shutterChoices)
            : nil
    }

    /// The scores are in: hand the verdict to concludeAF, unless a newer run
    /// has started.
    private func finishAFCheck(run: Int, before b: Double?, after a: Double?,
                               markerArrived: Bool, bodyDrove: Bool) {
        guard afRunCounter == run else { return }
        let verdict = AppAutofocus.conclusion(before: b, after: a, markerArrived: markerArrived, bodyDrove: bodyDrove)
        let held = b.flatMap { b in a.map { AppAutofocus.heldFocus(before: b, after: $0, markerArrived: markerArrived) } } ?? false
        let word = verdict.isConfirmed ? (held ? "confirmed (locked on a frame already in focus)" : "confirmed") : "not confirmed"
        appLog.notice("af: run \(run, privacy: .public) sharpness \(b.map { String(format: "%.1f", $0) } ?? "none", privacy: .public) → \(a.map { String(format: "%.1f", $0) } ?? "none", privacy: .public), marker \(markerArrived ? "yes" : "no", privacy: .public), drive \(bodyDrove ? "yes" : "no", privacy: .public), \(word, privacy: .public)")
        concludeAF(run: run, result: verdict)
    }

    /// Wait until no event-drain call is reading, so the autofocus run is the
    /// one consumer (its events must not be eaten). The live-view pause is
    /// already up, so no new drain call starts. This waits out one in flight,
    /// at most about 300 ms (200 ms budget, 100 ms per call).
    private func waitForEventDrainIdle() async {
        let deadline = Date().addingTimeInterval(1)
        while eventDrainActive && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if eventDrainActive { appLog.error("af: event drain still reading after 1 s, going ahead") }
    }

    /// A capture can take several seconds. Past this, autofocus gives up.
    private static let afOpsWaitSeconds: TimeInterval = 15

    /// Wait for camera ops already running to finish. False when one is still
    /// going at the bound, and the run must not start.
    private func waitForCameraOpsIdle() async -> Bool {
        let deadline = Date().addingTimeInterval(AppModel.afOpsWaitSeconds)
        while cameraOpsInFlight > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Checked and claimed with no suspension between, the mirror of
        // withLVPriority's wait-then-count.
        guard cameraOpsInFlight == 0 else { return false }
        autofocusRunning = true
        return true
    }

    /// Wait for any autofocus run to end, then count this op in, with no
    /// suspension between the check and the count so autofocus cannot claim
    /// the camera in the gap. The caller decrements `cameraOpsInFlight`.
    private func enterCameraOp() async {
        let deadline = Date().addingTimeInterval(AppModel.afIdleWaitSeconds)
        while autofocusRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if autofocusRunning { appLog.error("camera op going ahead with autofocus still running after \(Int(AppModel.afIdleWaitSeconds), privacy: .public) s") }
        cameraOpsInFlight += 1
    }

    /// A run is about 7 s (6 s wait plus writes and the tail read), plus up
    /// to 1 s for an in-flight drain and the 100 ms settle, so only a hung
    /// camera call reaches this.
    private static let afIdleWaitSeconds: TimeInterval = 15

    /// Hold stopLiveView until the autofocus run ends (see afIdleWaitSeconds).
    private func waitForAutofocusIdle() async {
        guard autofocusRunning else { return }
        appLog.info("camera op waiting for autofocus to finish")
        let deadline = Date().addingTimeInterval(AppModel.afIdleWaitSeconds)
        while autofocusRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Pause runLoop's frame fetching (via pauseCount), do the work, resume.
    /// The body stays in live view: no mirror cycle, no focus loss.
    private func withLVPriority<T>(_ work: () async -> T) async -> T {
        // A camera op asked for during an autofocus run waits for it to end
        // rather than landing between its DoAf and its closing cancel.
        await enterCameraOp()
        defer { cameraOpsInFlight -= 1 }
        guard let lv = liveView, isLiveViewOn else { return await work() }
        return await lv.withPriority { await work() }
    }

    func setImageFormat(_ value: String) async {
        appLog.info("setImageFormat(\(value, privacy: .public)) called")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setImageFormat(value)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
    }

    // MARK: - Property setters

    /// True when the body's white balance is the mode that uses the Kelvin
    /// value. The stepper dims when it is false.
    var kelvinIsActive: Bool {
        snapshot.whiteBalance.caseInsensitiveCompare(
            CameraProperties.colorTemperatureMode
        ) == .orderedSame
    }

    func setWhiteBalanceMode(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setWhiteBalance(value)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
        appLog.info("white balance mode → \(value, privacy: .public)")
    }

    func setISO(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setIso(value)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
        // No meter kick on the settings-change path: Press Half writes
        // (even occasional) correlate with body wedges that need power-cycle.
    }

    func setShutter(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setShutter(value)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
    }

    func setAperture(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setAperture(value)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
    }

    func setWhiteBalanceKelvin(_ k: Int) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setWhiteBalanceKelvin(k)
                await self.clearTransientErrorIfStreamingReady()
            }
            catch { self.showCameraError(error, during: .control) }
        }
        await refreshSnapshot()
    }

    /// Called after a successful write: if an error is showing, clear it so
    /// it doesn't leave a stale message in the UI. Only ever leaves .error,
    /// and it returns to .streaming or .ready by whether the stream is active.
    private func clearTransientErrorIfStreamingReady() async {
        guard case .error = ui else { return }
        let streamActive = await liveView?.isActive ?? false
        guard case .error = ui else { return }
        switch ClearedErrorState.after(streamActive: streamActive) {
        case .streaming: ui = .streaming
        case .ready: ui = .ready
        }
        appLog.info("transient error cleared: ui → \(String(describing: self.ui), privacy: .public) (stream active \(streamActive, privacy: .public))")
    }

    private func refreshSnapshot() async {
        guard let p = properties else { appLog.error("refreshSnapshot: properties nil"); return }
        // Single gp_camera_get_config call covers every leaf we display, much
        // gentler on the body than 6+ independent get_config calls per refresh.
        // Wrap in LV priority so this read doesn't compete with preview frames
        // when LV is active.
        let snap: CameraProperties.Snapshot? = await withLVPriority {
            do { return try await p.snapshot() }
            catch {
                appLog.error("snapshot read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let snap else { return }
        var s = self.snapshot
        if let v = snap.iso          { s.iso = v }
        if let v = snap.shutter {
            s.shutter = v
            let isAutoish = v.lowercased() == "auto" || v.isEmpty || v == "—"
            if !isAutoish {
                s.meteredShutter = v
            }
        }
        if let v = snap.aperture     { s.aperture = v }
        if let v = snap.whiteBalance { s.whiteBalance = v }
        s.whiteBalanceKelvin = snap.kelvin ?? s.whiteBalanceKelvin
        if let v = snap.mode         { s.mode = v }
        if let v = snap.imageFormat  { s.imageFormat = v }
        if let v = snap.battery      { s.battery = v }
        if let v = snap.focusMode    { s.focusMode = v }
        if let camTime = snap.cameraDateTime {
            s.cameraDateTime = camTime
            // Also store the camera-vs-host offset: both clocks tick in real
            // time, so the offset is the stable quantity and the footer
            // reconstructs `now + offset`.
            //
            // Only recompute it from a reading known to be fresh. The ptp2
            // driver caches this property for the life of the session (zero
            // advance measured over 12s of wall time), so in the app's one
            // long-lived session every read after the first returns the
            // connect-time value. Recomputing from that would make the offset a
            // second more negative per second: the readout would tick forward,
            // snap back, and turn red on a correctly synced camera.
            //
            // A changed reading proves the value is live. An identical one
            // means the cache, and the existing offset is the better estimate.
            // The camera's own clock is accurate to ~1s per day, so an offset
            // taken once at connect stays trustworthy.
            let isFresh = camTime != lastRawCameraClock
            if isFresh {
                lastRawCameraClock = camTime
                s.cameraClockOffset = camTime.timeIntervalSince(Date())
            }
        }
        self.snapshot = s
        self.snapshotTick &+= 1
        appLog.info("snapshot[\(self.snapshotTick, privacy: .public)]: iso=\(s.iso, privacy: .public) Tv=\(s.shutter, privacy: .public) Av=\(s.aperture, privacy: .public) K=\(s.whiteBalanceKelvin ?? -1, privacy: .public) mode=\(s.mode, privacy: .public) fmt=\(s.imageFormat, privacy: .public) batt=\(s.battery, privacy: .public)")
    }

    private func loadChoices() async {
        guard let p = properties else { return }
        let cs: CameraProperties.ChoiceSet? = await withLVPriority {
            do { return try await p.choicesSnapshot() }
            catch {
                appLog.error("choices read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let cs else { return }
        self.isoChoices = cs.iso
        self.shutterChoices = cs.shutter
        self.apertureChoices = cs.aperture
        self.imageFormatChoices = cs.imageFormat
        self.whiteBalanceChoices = cs.whiteBalance
        appLog.info("choices: iso=\(cs.iso.count, privacy: .public) shutter=\(cs.shutter.count, privacy: .public) aperture=\(cs.aperture.count, privacy: .public) imageFormat=\(cs.imageFormat.count, privacy: .public) meteringMode=\(cs.meteringMode.count, privacy: .public)")
    }

    /// Periodic background refresh that picks up settings the user changes on
    /// the camera body. The cadence is slow to keep PTP pressure on the body
    /// low. A tick that starts with live view streaming skips the refresh: the
    /// stream shows what the body is doing, setting changes trigger their own
    /// refresh, and captureNow refreshes after each successful capture. When
    /// idle it ticks every 10 s.
    /// Faster idle polling (1 s, 3 s) is suspected of wedging the body badly
    /// enough to need a power pull.
    private func startSnapshotRefresh() {
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = Task { [weak self] in
            var idleTick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let isStreaming = await MainActor.run { self.ui == .streaming }
                if isStreaming {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let intervalNs: UInt64 = 10_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                let stillConnected = await MainActor.run {
                    if case .ready = self.ui { return true }
                    if case .streaming = self.ui { return true }
                    return false
                }
                guard stillConnected else { continue }
                let modeBefore = await MainActor.run { self.snapshot.mode }
                await self.refreshSnapshot()
                let modeAfter = await MainActor.run { self.snapshot.mode }
                idleTick &+= 1
                // Choices rarely change except on a mode change, where they
                // almost always do (Av's shutter list is "auto", M's is the
                // real ladder). Reload on a mode change, otherwise every third
                // tick.
                if modeAfter != modeBefore || idleTick % 3 == 0 {
                    await self.loadChoices()
                }
            }
        }
    }

    // MARK: - Hotkey

    /// Restart the hold-key monitor after a hold-key setting changes (Hold
    /// Shift to zoom, the hold key, the other-apps switch), so the change
    /// applies at once. With no session it does nothing, and the next connect
    /// starts the monitor from the current settings.
    func applyHoldKeySettings() {
        guard session != nil else { return }
        startHotkey()
    }

    private func startHotkey() {
        hotkey?.stop()
        hotkeyTask?.cancel()
        var config = HoldKeyMonitor.Config()
        if AppSettings.shared.zoomUsesShift {
            // Shift-hold = zoom. Bare modifier → always local, since
            // a global Shift trigger would zoom while any app is focused.
            config.triggerModifier = .shift
            config.keyCode = 0x31
            config.globalScope = false
        } else {
            config.keyCode = AppSettings.shared.zoomKeyCode
            config.globalScope = AppSettings.shared.enableGlobalHotkey
        }
        config.isSuspended = { TextEntryFocus.isActiveFromAnyThread() }
        hotkeyLog.info("starting HoldKeyMonitor (trigger=\(AppSettings.shared.zoomUsesShift ? "Shift" : "key0x\(String(config.keyCode, radix: 16))", privacy: .public), global=\(config.globalScope, privacy: .public))")
        let hk = HoldKeyMonitor(config: config)
        // A global start that fails, usually a permission not granted, falls back
        // to the in-window monitor with the same key, so the key never goes dead.
        if let reason = hk.startFallingBackToLocal() {
            hotkeyLog.error("HoldKeyMonitor global start failed, using the in-window monitor instead: \(String(describing: reason), privacy: .public)")
        } else {
            hotkeyLog.info("HoldKeyMonitor.start() OK")
        }
        self.hotkey = hk
        hotkeyTask = Task { [weak self] in
            for await event in hk.events {
                await self?.handleHotkey(event)
            }
        }
    }

    /// Local NSEvent monitor that fires capture on the configured capture key
    /// (default: Space). Only active while a Film Tether window is focused.
    private func startCaptureKeyMonitor() {
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        let configured = AppSettings.shared.captureKeyCode
        hotkeyLog.info("installing capture-key monitor (keyCode=0x\(String(configured, radix: 16), privacy: .public))")
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Typing in a text field (Camera, Film, Settings) owns every key:
            // no capture on Space or Return, no focus steps on , and .
            if TextEntryFocus.isActive { return event }
            // Manual-focus stepping via keyboard: "," = far, "." = near.
            // Bare = medium (2), ⌥ = fine (1), ⌃ = coarse (3). ⌘ is left alone
            // so ⌘, still opens Settings. Only act over live view. Shift is
            // not excluded: it holds the momentary punch-in, and stepping
            // focus while zoomed in is what the zoom is for. The mapping
            // accepts the shifted < and > forms for that.
            let mods = event.modifierFlags
            // Autofocus on "/" (arrives as "?" while Shift holds the punch-in).
            // One press is one run. Autorepeat is swallowed like the focus keys.
            if let chars = event.charactersIgnoringModifiers,
               AppAutofocus.isAutofocusKey(chars, command: mods.contains(.command)) {
                if event.isARepeat { return nil }
                guard self.isLiveViewOn else { return event }
                hotkeyLog.info("autofocus key matched")
                Task { await self.autofocus() }
                return nil
            }
            if !mods.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               let step = CameraProperties.ManualFocusStep.forFocusKey(
                   chars, option: mods.contains(.option), control: mods.contains(.control)) {
                // Autorepeat is swallowed, not driven: one press is one pulse
                // (the motor has a settle time), and letting the repeat fall
                // through to AppKit would beep for as long as the key is held.
                if event.isARepeat { return nil }
                guard self.isLiveViewOn else { return event }
                hotkeyLog.info("focus key matched, driving \(step.rawValue, privacy: .public)")
                Task { await self.driveManualFocus(step) }
                return nil
            }
            // Escape puts an armed white-balance eyedropper away. Checked
            // before the capture key, which can itself be set to Escape.
            if event.keyCode == 0x35, self.isPickingWhiteBalance {
                if !event.isARepeat { self.toggleWhiteBalancePicker() }
                return nil
            }
            if event.isARepeat { return event }
            if event.keyCode == AppSettings.shared.captureKeyCode {
                hotkeyLog.info("capture key matched, firing captureNow")
                Task { await self.captureNow() }
                return nil
            }
            return event
        }
    }

    private func handleHotkey(_ event: HoldKeyMonitor.Event) async {
        hotkeyLog.info("HoldKeyMonitor event: \(String(describing: event), privacy: .public)")
        switch event {
        case .pressed:
            // Trigger held (Shift by default) → punch in to 5× sensor zoom.
            // No 10× step: it silently no-ops on the 7D's firmware.
            // Remember where we were so the release restores it, or holding
            // Shift from 100% would drop you back at Fit.
            if !previewZoom.engagesCameraPunchIn { zoomBeforeHold = previewZoom }
            await setPreviewZoom(.fiveX)
        case .released:
            await setPreviewZoom(zoomBeforeHold)
        case .arrow(let direction):
            // An arrow nudge moves the zoom rect by one full rect width per
            // press (zoomBoxFraction, about 1/5 of the image dimension),
            // clamped so the rect never crosses the edge. When sensor zoom
            // is engaged the punch-in follows the box.
            await nudgeMeteringCenter(direction)
        }
    }

    private func nudgeMeteringCenter(_ direction: HoldKeyMonitor.ArrowKey) async {
        let f = AppModel.zoomBoxFraction
        let step = f                 // one box-width per press
        let lo = f / 2, hi = 1 - f / 2   // keep the box fully inside the frame
        // The arrow the user pressed is a direction on screen. meteringCenter
        // lives in sensor space. Map through the mirror and the quarter turn so
        // pressing Up moves the box up in the preview. Straightening is not
        // mapped (see sensorDelta).
        let screenDelta: CGVector
        switch direction {
        case .up:    screenDelta = CGVector(dx: 0, dy: -step)
        case .down:  screenDelta = CGVector(dx: 0, dy: step)
        case .left:  screenDelta = CGVector(dx: -step, dy: 0)
        case .right: screenDelta = CGVector(dx: step, dy: 0)
        }
        let d = sensorDelta(fromDisplay: screenDelta)
        // Step from where the box is drawn, which is the snapped center.
        var c = AppModel.punchIn.snapped(meteringCenter)
        c.x = min(max(c.x + d.dx, lo), hi)
        c.y = min(max(c.y + d.dy, lo), hi)
        await applyMeteringCenter(c)
    }

    /// Put the zoom box back in the middle of the frame. The same thing a
    /// power cycle does to the body's own window, available on demand.
    func centerMeteringBox() async {
        await applyMeteringCenter(CGPoint(x: 0.5, y: 0.5))
    }

    /// Move the box, and if the real sensor zoom is engaged, move the punch-in
    /// to the new spot too (the box aims the live magnified region). The
    /// position is recomputed from the box (bodyZoomPosition).
    private func applyMeteringCenter(_ c: CGPoint) async {
        meteringCenter = c
        if zoomMode != .fit, !zoomFallbackActive, let lz = liveZoom {
            let (x, y) = bodyZoomPosition()
            await withLVPriority { try? await lz.setZoomPosition(x: x, y: y) }
        }
    }

    private func applyZoom(_ mode: LiveZoom.Mode) async {
        self.zoomMode = mode
        // The goal is a zoom that yields more real pixels from the camera.
        // The primary path is the body's sensor-crop punch-in (eoszoom), which
        // streams a sharp 1024×680 JPEG of a small sensor region. The
        // client-side JPEG crop is an automatic fallback for when the body
        // refuses the write or there is no LiveZoom. The box aims the
        // punch-in via eoszoomposition.
        guard let lz = liveZoom else {
            self.zoomFallbackActive = true   // no camera-side path → client crop
            return
        }
        if mode == .fit {
            await withLVPriority { try? await lz.setZoom(.fit) }
            self.zoomFallbackActive = false
            return
        }
        // .fivex: punch in, then move the window to the box. Order matters:
        // About 290 ms after zoom engages, the 7D moves the window back to
        // its last punch-in spot, so a position written before eoszoom=5 is
        // lost. Enter magnified mode first, write eoszoomposition at 180 ms,
        // and write it again at 300 ms, after that move has landed. On the
        // 7D this lands 10 times out of 10.
        let (x, y) = bodyZoomPosition()
        let cameraSideOK: Bool = await withLVPriority {
            do {
                try await lz.setZoom(.fivex)
                try? await Task.sleep(nanoseconds: 180_000_000)
                try await lz.setZoomPosition(x: x, y: y)
                try? await Task.sleep(nanoseconds: 120_000_000)
                try? await lz.setZoomPosition(x: x, y: y)
                return true
            } catch {
                appLog.error("camera-side zoom failed (\(String(describing: error), privacy: .public)), falling back to client crop")
                return false
            }
        }
        // On success the body streams the magnified frame and handleFrame
        // skips its crop. On failure handleFrame crops on the host.
        self.zoomFallbackActive = !cameraSideOK
    }

    /// The eoszoomposition value for the current box: the measured value that
    /// lands the punch-in on the reachable center nearest the box, which is
    /// where the box is drawn.
    private func bodyZoomPosition() -> (x: Int, y: Int) {
        AppModel.punchIn.position(for: meteringCenter)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        self.permissionsState = .init(
            accessibility: Permissions.hasAccessibility,
            inputMonitoring: Permissions.hasInputMonitoring
        )
    }

    func requestAccessibility() { Permissions.requestAccessibility(); refreshPermissions() }
    func requestInputMonitoring() { Permissions.requestInputMonitoring(); refreshPermissions() }
}

/// The LiveView and session a live-view ladder is working on. Its close
/// reads the session from off the main actor.
private final class LiveViewStallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lv: LiveView?
    private var sess: CameraSession?
    init(lv: LiveView?, session: CameraSession?) { self.lv = lv; self.sess = session }
    var liveView: LiveView? { lock.lock(); defer { lock.unlock() }; return lv }
    var session: CameraSession? { lock.lock(); defer { lock.unlock() }; return sess }
}
