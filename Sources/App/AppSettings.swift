import Foundation
import SwiftUI
import Camera
import Scan

/// Persisted app settings, backed by UserDefaults.
///
/// Folder picks are stored as security-scoped bookmarks, so they survive relaunches and
/// keep working if the app is sandboxed.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Key {
        static let captureFolderBookmark = "captureFolderBookmark"
        static let filenamePattern = "filenamePattern"
        static let captureKeyCode = "captureKeyCode"
        static let zoomKeyCode = "zoomKeyCode"
        static let zoomUsesShift = "zoomUsesShift"
        static let embedMetadata = "embedMetadata"
        static let metadataEnabled = "metadataEnabled"
        static let histogramEnabled = "histogramEnabled"
        static let histogramCorner = "histogramCorner"
        static let enableGlobalHotkey = "enableGlobalHotkey"
        static let hotkeyMappingVersion = "hotkeyMappingVersion"
        static let focusPeakingColor = "focusPeakingColor"
        static let focusPeakingMode = "focusPeakingMode"
        static let focusPeakingIntensity = "focusPeakingIntensity"
        static let autoSyncClockOnConnect = "autoSyncClockOnConnect"
        static let cameraTZOffsetMinutes = "cameraTZOffsetMinutes"
        static let focusPeakingEnabled = "focusPeakingEnabled"
        static let showMeteringOverlay = "showMeteringOverlay"
        static let showBatteryIndicator = "showBatteryIndicator"
        static let showMeteredShutter = "showMeteredShutter"
        static let showCameraClock = "showCameraClock"
        static let showWhiteBalanceGains = "showWhiteBalanceGains"
        static let showCropDetail = "showCropDetail"
        static let shotCamera = "shotCamera"
        static let shotFilm = "shotFilm"
        static let cameraHistory = "cameraHistory"
        static let filmHistory = "filmHistory"
        static let shotTakenOn = "shotTakenOn"
        static let takenOnHistory = "takenOnHistory"
        static let previewRotation = "previewRotation"
        static let previewMirrored = "previewMirrored"
        static let previewMonochrome = "previewMonochrome"
        static let previewInvert = "previewInvert"
        static let previewWhiteBalance = "previewWhiteBalance"
        static let previewStraightenDegrees = "previewStraightenDegrees"
        static let expectedFilmSizeID = "expectedFilmSizeID"
        static let filmSizeOther = "filmSizeOther"
        static let cropSensorRect = "cropSensorRect"
    }

    // MARK: - Defaults

    /// Default capture destination: `~/Pictures/Film Tether/`.
    static var defaultCaptureFolder: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return pics.appendingPathComponent("Film Tether")
    }

    /// `{ext}` resolves to the extension of the file the camera produced (CR2
    /// on a 7D, CR3 on an R5, JPG for JPEG quality). Patterns with a hardcoded
    /// literal extension get the extension corrected at save time too, when
    /// the camera's filename has one.
    static let defaultFilenamePattern = "IMG_{ymd}_{hms}_{seq}.{ext}"

    /// Default capture key: Space (US keycode 0x31).
    static let defaultCaptureKeyCode: UInt16 = 0x31

    /// Fallback zoom key when `zoomUsesShift` is off: Space (US keycode 0x31).
    /// Default trigger is the Shift modifier (see `zoomUsesShift`).
    static let defaultZoomKeyCode: UInt16 = 0x31

    /// Current hotkey-mapping migration version. Bump to force a one-time
    /// re-default of the hotkey keys for existing installs whose stored prefs
    /// predate a mapping change. v2 = Shift-zoom / Space-capture.
    static let currentHotkeyMappingVersion = 2

    // MARK: - Settings window tab

    /// The Settings window's tabs. The selection lives here, not in the view,
    /// so the footer's folder control can land the window on Capture.
    enum SettingsTab: Hashable { case capture, liveView, camera, hotkeys, updates }

    /// Which Settings tab shows. Not persisted: each launch starts on Capture.
    @Published var settingsTab: SettingsTab = .capture

    // MARK: - Capture folder (security-scoped bookmark)

    /// Resolved capture folder. Falls back to a stored plain path, then to
    /// `defaultCaptureFolder`, if no bookmark is set or the bookmark is
    /// unresolvable.
    @Published private(set) var captureFolder: URL = AppSettings.defaultCaptureFolder

    /// Set a new capture folder, persisted as a security-scoped bookmark, or
    /// as a plain path when the bookmark cannot be made.
    func setCaptureFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Key.captureFolderBookmark)
            captureFolder = url
        } catch {
            // Bookmark creation can fail for non-existent or inaccessible paths.
            // Fall back to plain URL persistence as a last resort.
            defaults.set(url.path, forKey: Key.captureFolderBookmark + ".path")
            captureFolder = url
        }
    }

    private func loadCaptureFolder() {
        if let bookmark = defaults.data(forKey: Key.captureFolderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                captureFolder = url
                if isStale {
                    setCaptureFolder(url)
                }
                return
            }
        }
        if let path = defaults.string(forKey: Key.captureFolderBookmark + ".path") {
            captureFolder = URL(fileURLWithPath: path)
            return
        }
        captureFolder = Self.defaultCaptureFolder
    }

    // MARK: - Filename pattern

    @Published var filenamePattern: String {
        didSet { defaults.set(filenamePattern, forKey: Key.filenamePattern) }
    }

    // MARK: - Hotkeys

    @Published var captureKeyCode: UInt16 {
        didSet { defaults.set(Int(captureKeyCode), forKey: Key.captureKeyCode) }
    }

    @Published var zoomKeyCode: UInt16 {
        didSet { defaults.set(Int(zoomKeyCode), forKey: Key.zoomKeyCode) }
    }

    /// When on (the default), hold-to-zoom is triggered by the Shift modifier
    /// instead of `zoomKeyCode`. Shift-zoom is always window-local, because a
    /// bare global modifier would zoom while any app is focused.
    @Published var zoomUsesShift: Bool {
        didSet { defaults.set(zoomUsesShift, forKey: Key.zoomUsesShift) }
    }

    @Published var enableGlobalHotkey: Bool {
        didSet { defaults.set(enableGlobalHotkey, forKey: Key.enableGlobalHotkey) }
    }

    /// Master metadata switch (the Meta switch, row 2). When off the
    /// fields gray out and captures write nothing: no sidecar, no embed.
    @Published var metadataEnabled: Bool {
        didSet { defaults.set(metadataEnabled, forKey: Key.metadataEnabled) }
    }

    /// Live RGB histogram overlay (Hist toggle, row 2). Corner persists.
    @Published var histogramEnabled: Bool {
        didSet { defaults.set(histogramEnabled, forKey: Key.histogramEnabled) }
    }
    @Published var histogramCorner: HistogramCorner {
        didSet { defaults.set(histogramCorner.rawValue, forKey: Key.histogramCorner) }
    }

    /// Metadata backend choice. Off (the default) writes an XMP sidecar next
    /// to the RAW and never writes to the RAW. On splices the packet into the RAW
    /// (append-only, sensor bytes untouched, atomic swap, falling back to
    /// sidecar on unrecognized containers). Mirrored into
    /// `MetadataWriter.backend` so the capture path needs no settings import.
    @Published var embedMetadata: Bool {
        didSet {
            defaults.set(embedMetadata, forKey: Key.embedMetadata)
            MetadataWriter.backend = embedMetadata ? .embedded : .sidecar
        }
    }

    // MARK: - Focus peaking

    @Published var focusPeakingColor: FocusPeaking.PeakColor {
        didSet { defaults.set(focusPeakingColor.rawValue, forKey: Key.focusPeakingColor) }
    }

    @Published var focusPeakingMode: FocusPeaking.Mode {
        didSet { defaults.set(focusPeakingMode.rawValue, forKey: Key.focusPeakingMode) }
    }

    @Published var focusPeakingIntensity: Double {
        didSet { defaults.set(focusPeakingIntensity, forKey: Key.focusPeakingIntensity) }
    }

    // MARK: - Camera clock

    /// Set the camera clock from this Mac the moment the connection becomes
    /// ready. On by default. It can be turned off in Settings.
    @Published var autoSyncClockOnConnect: Bool {
        didSet { defaults.set(autoSyncClockOnConnect, forKey: Key.autoSyncClockOnConnect) }
    }

    /// Manual correction added on top of the clock sync. The body stamps EXIF
    /// DateTimeOriginal as `datetimeutc + its own zone`, and the sync already
    /// adds this Mac's DST offset for bodies that keep their zone on standard
    /// time (CameraClock), so a camera on PST with this Mac on PDT needs no
    /// offset here. This offset is for a camera whose zone is not this Mac's
    /// standard time. libgphoto2 exposes no widget for the camera's TZ menu,
    /// so it can't be read.
    ///
    /// Units: minutes. +60 = sync 1 hour ahead, -60 = 1 hour behind.
    @Published var cameraTZOffsetMinutes: Int {
        didSet { defaults.set(cameraTZOffsetMinutes, forKey: Key.cameraTZOffsetMinutes) }
    }

    /// Whether focus peaking is enabled. Off on first launch, then remembered
    /// across launches.
    @Published var focusPeakingEnabled: Bool {
        didSet { defaults.set(focusPeakingEnabled, forKey: Key.focusPeakingEnabled) }
    }

    /// Whether the zoom box is shown. On by default and remembered across
    /// launches.
    @Published var showMeteringOverlay: Bool {
        didSet { defaults.set(showMeteringOverlay, forKey: Key.showMeteringOverlay) }
    }

    /// Show the battery percentage in the footer. Off by default for the common
    /// case of a body that stays plugged in.
    @Published var showBatteryIndicator: Bool {
        didSet { defaults.set(showBatteryIndicator, forKey: Key.showBatteryIndicator) }
    }

    /// Show the most-recent metered shutter speed in the footer when one is
    /// available. Off by default because the value only updates sporadically
    /// (the live-view meter rarely emits shutterspeed events).
    @Published var showMeteredShutter: Bool {
        didSet { defaults.set(showMeteredShutter, forKey: Key.showMeteredShutter) }
    }

    /// Keep the ticking camera clock in the footer. Off by default: it then shows
    /// only while the camera has drifted more than five minutes, when it turns
    /// red and a click sets it.
    @Published var showCameraClock: Bool {
        didSet { defaults.set(showCameraClock, forKey: Key.showCameraClock) }
    }

    /// Show the eyedropper's R/G/B gains in the footer. Off by default, since
    /// it is an engineering readout.
    @Published var showWhiteBalanceGains: Bool {
        didSet { defaults.set(showWhiteBalanceGains, forKey: Key.showWhiteBalanceGains) }
    }

    /// Show the crop's pixel corners and size beside the crop state. Off by default: the
    /// short state stays, and the corners are in its tooltip.
    @Published var showCropDetail: Bool {
        didSet { defaults.set(showCropDetail, forKey: Key.showCropDetail) }
    }

    // MARK: - Capture metadata (camera + film)

    /// The original film camera the negative was shot on (e.g. "Leica M6").
    /// Written to the capture's XMP as tiff:Make/Model, in the .xmp sidecar or
    /// inside the RAW when `embedMetadata` is on. The RAW's own EXIF still
    /// names the scanning camera. Persisted so the last-used value is
    /// restored on the next launch.
    @Published var shotCamera: String {
        didSet { defaults.set(shotCamera, forKey: Key.shotCamera) }
    }

    /// The film stock the negative was shot on (e.g. "Kodak Portra 400").
    /// Written into AnalogExif XMP, a searchable keyword and the caption on
    /// capture. Persisted so the last-used value is restored on launch.
    @Published var shotFilm: String {
        didSet { defaults.set(shotFilm, forKey: Key.shotFilm) }
    }

    /// Previously-used camera strings, most-recent-first. A plain list of
    /// strings, no IDs, no records, that backs the field's dropdown. Entries
    /// are individually removable. Capped at `maxHistory`.
    @Published private(set) var cameraHistory: [String] {
        didSet { defaults.set(cameraHistory, forKey: Key.cameraHistory) }
    }

    /// Previously-used film strings, most-recent-first. Same plain-list model
    /// as `cameraHistory`.
    @Published private(set) var filmHistory: [String] {
        didSet { defaults.set(filmHistory, forKey: Key.filmHistory) }
    }

    /// The day the roll was shot, typed "YYYY-MM-DD" (for example
    /// "2026-09-14"). Per roll like the film, so it persists until changed.
    /// Written as `Film:TakenOn`, which Film Positive reads as the photo's
    /// date. A value that is not a real day is not written.
    @Published var shotTakenOn: String {
        didSet { defaults.set(shotTakenOn, forKey: Key.shotTakenOn) }
    }

    /// Previously-used Taken dates, most-recent-first, valid days only.
    @Published private(set) var takenOnHistory: [String] {
        didSet { defaults.set(takenOnHistory, forKey: Key.takenOnHistory) }
    }

    /// Cap on stored history so the dropdown and UserDefaults never grow
    /// unbounded. Old entries fall off the end. Users can also remove any
    /// entry by hand.
    static let maxHistory = 50

    /// Record `value` as the current camera and fold it into history
    /// (case-insensitive dedup, moved to front). Trims whitespace. An empty
    /// value clears the current selection without touching history.
    func commitCamera(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        shotCamera = trimmed
        guard !trimmed.isEmpty else { return }
        cameraHistory = Self.fold(trimmed, into: cameraHistory)
    }

    /// Record `value` as the current film and fold it into history.
    func commitFilm(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        shotFilm = trimmed
        guard !trimmed.isEmpty else { return }
        filmHistory = Self.fold(trimmed, into: filmHistory)
    }

    /// Record `value` as the Taken date. Only a real calendar day joins the
    /// history, so the dropdown never offers a typo.
    func commitTakenOn(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        shotTakenOn = trimmed
        guard let day = CaptureMetadata.validTakenOn(trimmed) else { return }
        takenOnHistory = Self.fold(day, into: takenOnHistory)
    }

    func removeTakenOnHistory(_ value: String) {
        takenOnHistory.removeAll { $0 == value }
    }

    /// Remove a single entry from camera history (the little "x" in the
    /// dropdown). Case-insensitive so the visible row always disappears.
    func removeCameraHistory(_ value: String) {
        cameraHistory.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Remove a single entry from film history.
    func removeFilmHistory(_ value: String) {
        filmHistory.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Case-insensitive dedup, move to front, and cap.
    private static func fold(_ value: String, into list: [String]) -> [String] {
        var out = list.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        out.insert(value, at: 0)
        if out.count > maxHistory { out = Array(out.prefix(maxHistory)) }
        return out
    }

    // MARK: - Preview rotation

    /// Quarter-turn rotation of the live preview. Persisted because a scanning
    /// rig's camera-to-film orientation is fixed for a whole session (and
    /// usually for good). It does not reset when the film format changes.
    @Published var previewRotation: PreviewRotation {
        didSet { defaults.set(previewRotation.rawValue, forKey: Key.previewRotation) }
    }

    /// Horizontal mirror on the preview, for film loaded emulsion-side-up.
    /// Persists for the same reason rotation does: it is a property of how the
    /// film is sitting in the holder, which outlives any one session.
    @Published var previewMirrored: Bool {
        didSet { defaults.set(previewMirrored, forKey: Key.previewMirrored) }
    }

    // MARK: - Preview adjustments (monochrome + white balance)

    /// Host-side preview corrections. Persisted because they belong to the
    /// film you're working through, not to the app session.
    ///
    /// Stored as three defaults keys (monochrome, invert, and the white
    /// balance gains as JSON) rather than one encoded blob, so `defaults read`
    /// stays legible when diagnosing a scanning session. The measured base
    /// sample (`baseSample`) is not persisted.
    @Published var previewAdjustments: PreviewAdjustments {
        didSet {
            defaults.set(previewAdjustments.monochrome, forKey: Key.previewMonochrome)
            defaults.set(previewAdjustments.invert, forKey: Key.previewInvert)
            if let wb = previewAdjustments.whiteBalance,
               let data = try? JSONEncoder().encode(wb) {
                defaults.set(data, forKey: Key.previewWhiteBalance)
            } else {
                defaults.removeObject(forKey: Key.previewWhiteBalance)
            }
        }
    }

    // MARK: - Crop and straightening

    /// Straightening applied on top of the quarter turn, in degrees clockwise.
    ///
    /// Separate from `previewRotation` rather than folded into one angle,
    /// because a quarter turn can be done exactly (the pixels are moved, not
    /// resampled), and only the straightening on top of it needs
    /// interpolating. Keeping them apart means an unstraightened preview stays
    /// pixel-exact, which is the state it is in almost all of the time.
    @Published var previewStraightenDegrees: Double {
        didSet { defaults.set(previewStraightenDegrees, forKey: Key.previewStraightenDegrees) }
    }

    /// Format the operator is currently working through.
    ///
    /// Stored as the catalog's own numeric id, which travels unchanged into
    /// the sidecar. Storing the name instead would break the moment a row is
    /// renamed.
    @Published var expectedFilmSize: FilmSize? {
        didSet {
            if let id = expectedFilmSize?.id, id != FilmSize.unknown.id {
                defaults.set(id, forKey: Key.expectedFilmSizeID)
            } else {
                defaults.removeObject(forKey: Key.expectedFilmSizeID)
            }
        }
    }

    /// The Size picker's Other. Non-nil while Other is chosen (empty
    /// until something is typed), and then `expectedFilmSize` is nil: the text
    /// is written as `Film:FilmSizeName` with no id, and Auto-Crop uses no film
    /// format.
    @Published var filmSizeOther: String? {
        didSet {
            if let t = filmSizeOther { defaults.set(t, forKey: Key.filmSizeOther) }
            else { defaults.removeObject(forKey: Key.filmSizeOther) }
        }
    }

    /// The format in words for the sidecar: the typed text under Other, or
    /// the chosen row's plain name. Nil when nothing is set.
    var filmSizeName: String? {
        if let t = filmSizeOther { return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t }
        return expectedFilmSize.flatMap { $0.isUnknown ? nil : $0.displayName }
    }

    /// The crop box, normalized [0,1]² and y-down in sensor space.
    ///
    /// Persisted because a copy stand does not move between sessions, so the
    /// negative is in the same place in the frame when the app is reopened.
    /// Sensor space rather than display space so that a rotation changed
    /// between sessions cannot leave the restored box pointing at different
    /// film.
    ///
    /// Four doubles under one key rather than four keys, so the box is saved
    /// whole or not at all.
    @Published var cropSensorRect: CGRect? {
        didSet {
            if let r = cropSensorRect, r.width > 0, r.height > 0 {
                defaults.set([r.minX, r.minY, r.width, r.height].map(Double.init),
                             forKey: Key.cropSensorRect)
            } else {
                defaults.removeObject(forKey: Key.cropSensorRect)
            }
        }
    }

    /// Read the stored crop back, rejecting anything that isn't four finite
    /// numbers describing a box with area. A defaults value can be edited by
    /// hand or left behind by an older build, and a NaN here would propagate
    /// into every overlay coordinate silently.
    private static func storedCrop(_ defaults: UserDefaults) -> CGRect? {
        guard let v = defaults.array(forKey: Key.cropSensorRect) as? [Double],
              v.count == 4, v.allSatisfy({ $0.isFinite }),
              v[2] > 0, v[3] > 0
        else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    // MARK: - Init

    private init() {
        self.histogramEnabled = defaults.bool(forKey: Key.histogramEnabled)
        self.histogramCorner = HistogramCorner(rawValue: defaults.string(forKey: Key.histogramCorner) ?? "") ?? .topRight
        self.metadataEnabled = defaults.object(forKey: Key.metadataEnabled) as? Bool ?? true
        self.embedMetadata = defaults.bool(forKey: Key.embedMetadata)
        MetadataWriter.backend = defaults.bool(forKey: Key.embedMetadata) ? .embedded : .sidecar
        self.shotCamera = defaults.string(forKey: Key.shotCamera) ?? ""
        self.shotFilm = defaults.string(forKey: Key.shotFilm) ?? ""
        self.cameraHistory = defaults.stringArray(forKey: Key.cameraHistory) ?? []
        self.filmHistory = defaults.stringArray(forKey: Key.filmHistory) ?? []
        self.shotTakenOn = defaults.string(forKey: Key.shotTakenOn) ?? ""
        self.takenOnHistory = defaults.stringArray(forKey: Key.takenOnHistory) ?? []
        var storedPattern = defaults.string(forKey: Key.filenamePattern) ?? Self.defaultFilenamePattern
        // One-time migration: installs that saved the pre-{ext} default keep
        // its hardcoded ".CR2" in UserDefaults. Save-time extension correction
        // makes it harmless, but move them to the new default so the Settings
        // preview reflects reality. Custom patterns are left untouched.
        if storedPattern == "IMG_{ymd}_{hms}_{seq}.CR2" {
            storedPattern = Self.defaultFilenamePattern
            defaults.set(storedPattern, forKey: Key.filenamePattern)
        }
        self.filenamePattern = storedPattern
        // Hotkey-mapping migration. An install whose stored mapping version
        // is below currentHotkeyMappingVersion gets the current default
        // mapping (Shift-zoom, Space capture) once, since changing the static
        // defaults alone does not reach stored prefs. The user can change it
        // afterward and the change sticks, because the migration does not
        // run again.
        let storedMappingVersion = defaults.integer(forKey: Key.hotkeyMappingVersion)
        let needsHotkeyMigration = storedMappingVersion < Self.currentHotkeyMappingVersion
        if needsHotkeyMigration {
            defaults.set(Int(Self.defaultCaptureKeyCode), forKey: Key.captureKeyCode)
            defaults.set(true, forKey: Key.zoomUsesShift)
            defaults.set(false, forKey: Key.enableGlobalHotkey) // Shift-zoom is local-only
            defaults.set(Self.currentHotkeyMappingVersion, forKey: Key.hotkeyMappingVersion)
        }
        let storedCapture = defaults.object(forKey: Key.captureKeyCode) as? Int
        self.captureKeyCode = UInt16(storedCapture ?? Int(Self.defaultCaptureKeyCode))
        let storedZoom = defaults.object(forKey: Key.zoomKeyCode) as? Int
        self.zoomKeyCode = UInt16(storedZoom ?? Int(Self.defaultZoomKeyCode))
        // zoomUsesShift defaults true when unset (migration also sets it).
        self.zoomUsesShift = (defaults.object(forKey: Key.zoomUsesShift) as? Bool) ?? true
        self.enableGlobalHotkey = defaults.bool(forKey: Key.enableGlobalHotkey)
        let storedColor = defaults.string(forKey: Key.focusPeakingColor) ?? ""
        self.focusPeakingColor = FocusPeaking.PeakColor(rawValue: storedColor) ?? .cyan
        let storedMode = defaults.string(forKey: Key.focusPeakingMode) ?? ""
        // Default .grain: the primary use case is film scanning, where grain
        // detection is the right signal.
        self.focusPeakingMode = FocusPeaking.Mode(rawValue: storedMode) ?? .grain
        let storedIntensity = defaults.object(forKey: Key.focusPeakingIntensity) as? Double
        self.focusPeakingIntensity = storedIntensity ?? 3.0
        // Defaults to true. On first launch there is no key, and
        // UserDefaults.bool would return false and silently disable a wanted
        // feature, so a missing key reads as on.
        if defaults.object(forKey: Key.autoSyncClockOnConnect) == nil {
            self.autoSyncClockOnConnect = true
            defaults.set(true, forKey: Key.autoSyncClockOnConnect)
        } else {
            self.autoSyncClockOnConnect = defaults.bool(forKey: Key.autoSyncClockOnConnect)
        }
        self.cameraTZOffsetMinutes = (defaults.object(forKey: Key.cameraTZOffsetMinutes) as? Int) ?? 0
        if defaults.object(forKey: Key.focusPeakingEnabled) == nil {
            self.focusPeakingEnabled = false
            defaults.set(false, forKey: Key.focusPeakingEnabled)
        } else {
            self.focusPeakingEnabled = defaults.bool(forKey: Key.focusPeakingEnabled)
        }
        if defaults.object(forKey: Key.showMeteringOverlay) == nil {
            self.showMeteringOverlay = true
            defaults.set(true, forKey: Key.showMeteringOverlay)
        } else {
            self.showMeteringOverlay = defaults.bool(forKey: Key.showMeteringOverlay)
        }
        self.showBatteryIndicator = defaults.bool(forKey: Key.showBatteryIndicator)
        self.showMeteredShutter = defaults.bool(forKey: Key.showMeteredShutter)
        // Footer extras, all off by default (a missing key reads false).
        self.showCameraClock = defaults.bool(forKey: Key.showCameraClock)
        self.showWhiteBalanceGains = defaults.bool(forKey: Key.showWhiteBalanceGains)
        self.showCropDetail = defaults.bool(forKey: Key.showCropDetail)
        // Missing key reads as 0, which is exactly `.none`, the right default.
        self.previewRotation = PreviewRotation(rawValue: defaults.integer(forKey: Key.previewRotation)) ?? .none
        self.previewMirrored = defaults.bool(forKey: Key.previewMirrored)
        let storedWB = defaults.data(forKey: Key.previewWhiteBalance)
            .flatMap { try? JSONDecoder().decode(ChannelGains.self, from: $0) }
        self.previewAdjustments = PreviewAdjustments(
            monochrome: defaults.bool(forKey: Key.previewMonochrome),
            invert: defaults.bool(forKey: Key.previewInvert),
            whiteBalance: storedWB
        )
        self.previewStraightenDegrees = defaults.double(forKey: Key.previewStraightenDegrees)
        let storedSizeID = defaults.object(forKey: Key.expectedFilmSizeID) as? Int
        self.expectedFilmSize = storedSizeID.flatMap(FilmSize.resolve(id:))
        self.filmSizeOther = defaults.string(forKey: Key.filmSizeOther)
        self.cropSensorRect = Self.storedCrop(defaults)
        loadCaptureFolder()
    }
}

/// Friendly labels for common US-layout keycodes shown in the Settings UI.
enum KeyCodeLabel {
    static let common: [(code: UInt16, label: String)] = [
        (0x24, "Return"),
        (0x31, "Space"),
        (0x30, "Tab"),
        (0x33, "Delete"),
        (0x35, "Escape"),
        (0x03, "F"),
        (0x06, "Z"),
        (0x0C, "Q"),
        (0x0D, "W"),
        (0x0E, "E"),
    ]
}
