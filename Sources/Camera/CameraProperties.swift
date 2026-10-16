import Foundation
import CGPhoto2

/// Read/write exposure properties via the libgphoto2 widget tree.
/// Instance methods run on `CameraActor`'s pinned thread.
///
/// The price of a read, in `gp_camera_get_config` calls: each one
/// rebuilds the camera's whole config tree, whichever leaf is wanted, and all
/// per-name reads funnel through `WidgetHelpers.fetchRoot` (via
/// `resolveLeaf`):
///
///   getString(name)      1
///   choices(for: name)   1
///   setString / writeToggle   1 get_config + 1 set_single_config per attempt,
///                        setString makes up to 3 attempts on -110
///   setExposureSimulation     up to 2 get_config (one per leaf name tried) + 1 set
///   snapshot(), choicesSnapshot()   1 each, however many leaves
@CameraActor
public final class CameraProperties {
    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    // MARK: - Generic accessors


    /// Costs one `gp_camera_get_config` (resolveLeaf → fetchRoot).
    public func getString(_ name: String) async throws -> String {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        do {
            let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
            defer { gp_widget_unref(root) }
            let value = try WidgetHelpers.readString(leaf)
            CameraLog.properties.debug("get \(name, privacy: .public) = \(value, privacy: .public)")
            return value
        } catch {
            CameraLog.properties.error("get \(name, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Raw widget write access. The convenience methods (setIso etc) wrap
    /// this. The -110 retry lives here only.
    ///
    /// - Parameter retryInProgress: retry on -110 as described below. The
    ///   app's autofocus passes false so every write it sends happens
    ///   exactly once on the wire.
    public func setString(_ name: String, value: String, retryInProgress: Bool = true) async throws {
        // Retry on GP_ERROR_CAMERA_BUSY (-110, libgphoto2's "I/O in
        // progress"), at most three attempts in all. That error means
        // libgphoto2's port has another transaction in flight (usually a
        // manual-focus drive that hasn't drained yet). With `retryInProgress`,
        // a 250 ms sleep before each retry lets the in-flight op complete.
        // Without this, a user changing ISO right after pressing focus buttons
        // sees a permanent error in the UI even though the body itself is fine.
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeString(leaf, value: value)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.properties.info("set \(name, privacy: .public) ← \(value, privacy: .public)\(attempt > 1 ? " (attempt \(attempt))" : "")")
                return
            } catch CameraError.libGPhoto(let code, _) where code == -110 && attempt < 3 && retryInProgress {
                CameraLog.properties.debug("set \(name, privacy: .public): -110 in_progress on attempt \(attempt, privacy: .public), retrying after 250ms")
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            } catch {
                lastError = error
                break
            }
        }
        CameraLog.properties.error("set \(name, privacy: .public) ← \(value, privacy: .public) FAILED: \(String(describing: lastError ?? CameraError.libGPhoto(code: -1, message: "?")), privacy: .public)")
        throw lastError ?? CameraError.libGPhoto(code: -1, message: "set \(name) failed")
    }

    /// Costs one `gp_camera_get_config` (resolveLeaf → fetchRoot).
    public func choices(for name: String) async throws -> [String] {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
        defer { gp_widget_unref(root) }
        return try WidgetHelpers.choices(leaf)
    }

    // MARK: - Bulk snapshot read

    /// One result of a bulk-snapshot call. Optional fields are missing when the leaf
    /// either doesn't exist on this body or doesn't return readable data.
    public struct Snapshot: Sendable, Equatable {
        public var iso: String?
        public var shutter: String?
        public var aperture: String?
        public var whiteBalance: String?
        public var kelvin: Int?
        public var mode: String?
        public var imageFormat: String?
        public var battery: String?
        public var focusMode: String?
        public var meteringMode: String?
        /// The time the camera's clock reads, from a `datetime` DATE leaf. The
        /// 7D exposes only `datetimeutc` (see `syncDateTimeToHostLocal`), so on
        /// a 7D this stays nil. Settings shows it, and enables "Set camera
        /// clock to this Mac's time" only when it is present.
        public var cameraDateTime: Date?
    }

    /// Read all common properties in one `gp_camera_get_config` traversal
    /// instead of one per property (see the cost table above). A per-property
    /// read is ~100ms per call. The 7D in particular gets confused by tight loops
    /// of independent get_config calls (it sometimes returns stale data from libgphoto2's
    /// internal cache or partially-updates the tree mid-read).
    public func snapshot() async throws -> Snapshot {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var root: OpaquePointer? = nil
        try CameraError.check(gp_camera_get_config(cam, &root, ctx))
        guard let root else { throw CameraError.propertyNotFound(name: "<root>") }
        defer { gp_widget_unref(root) }

        func leafByName(_ name: String) -> OpaquePointer? {
            var leaf: OpaquePointer? = nil
            let rc = name.withCString { cName in
                gp_widget_get_child_by_name(root, cName, &leaf)
            }
            return (rc == GP_OK) ? leaf : nil
        }

        func readStringLeaf(_ name: String) -> String? {
            guard let leaf = leafByName(name) else { return nil }
            return try? WidgetHelpers.readString(leaf)
        }

        var snap = Snapshot()
        snap.iso = readStringLeaf("iso")
        snap.shutter = readStringLeaf("shutterspeed")
        snap.aperture = readStringLeaf("aperture")
        snap.whiteBalance = readStringLeaf("whitebalance")
        if let kStr = readStringLeaf("colortemperature"), let k = Int(kStr) {
            snap.kelvin = k
        }
        // The 7D libgphoto2 driver normally uses "autoexposuremode". Fall back to
        // "expprogram" for newer builds. The fallback costs no extra get_config,
        // because both leaves live under the same root we already have.
        snap.mode = readStringLeaf("autoexposuremode") ?? readStringLeaf("expprogram")
        snap.imageFormat = readStringLeaf("imageformat")
        snap.battery = readStringLeaf("batterylevel")
        snap.focusMode = readStringLeaf("focusmode")
        snap.meteringMode = readStringLeaf("meteringmode")
        // Bodies that expose a `datetime` leaf get it here (libgphoto2 2.5.33
        // builds it as a DATE widget holding Unix seconds). The 7D has none, so
        // this stays nil there. A leaf of any other type also leaves it nil.
        if let leaf = leafByName("datetime"), let ts = try? WidgetHelpers.readDate(leaf), ts > 0 {
            snap.cameraDateTime = Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return snap
    }

    // MARK: - Choices bulk read (same single-get_config trick)

    public struct ChoiceSet: Sendable, Equatable {
        public var iso: [String]
        public var shutter: [String]
        public var aperture: [String]
        public var whiteBalance: [String]
        public var imageFormat: [String]
        public var meteringMode: [String]

        public init(iso: [String] = [], shutter: [String] = [], aperture: [String] = [],
                    whiteBalance: [String] = [], imageFormat: [String] = [],
                    meteringMode: [String] = []) {
            self.iso = iso
            self.shutter = shutter
            self.aperture = aperture
            self.whiteBalance = whiteBalance
            self.imageFormat = imageFormat
            self.meteringMode = meteringMode
        }
    }

    /// Read all picker choices in one config traversal. Same rationale as `snapshot()`.
    public func choicesSnapshot() async throws -> ChoiceSet {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var root: OpaquePointer? = nil
        try CameraError.check(gp_camera_get_config(cam, &root, ctx))
        guard let root else { throw CameraError.propertyNotFound(name: "<root>") }
        defer { gp_widget_unref(root) }

        func choicesByName(_ name: String) -> [String] {
            var leaf: OpaquePointer? = nil
            let rc = name.withCString { cName in
                gp_widget_get_child_by_name(root, cName, &leaf)
            }
            guard rc == GP_OK, let leaf else { return [] }
            return (try? WidgetHelpers.choices(leaf)) ?? []
        }

        return ChoiceSet(
            iso: choicesByName("iso"),
            shutter: choicesByName("shutterspeed"),
            aperture: choicesByName("aperture"),
            whiteBalance: choicesByName("whitebalance"),
            imageFormat: choicesByName("imageformat"),
            meteringMode: choicesByName("meteringmode")
        )
    }

    // MARK: - Typed convenience accessors

    public func iso() async throws -> String {
        try await getString("iso")
    }

    public func setIso(_ value: String) async throws {
        try await assertWritableForExposureProp("iso")
        try await setString("iso", value: value)
    }

    public func shutter() async throws -> String {
        try await getString("shutterspeed")
    }

    public func setShutter(_ value: String) async throws {
        try await assertWritableForExposureProp("shutterspeed")
        try await setString("shutterspeed", value: value)
    }

    public func aperture() async throws -> String {
        try await getString("aperture")
    }

    public func setAperture(_ value: String) async throws {
        try await assertWritableForExposureProp("aperture")
        try await setString("aperture", value: value)
    }

    public func setWhiteBalance(_ value: String) async throws {
        try await setString("whitebalance", value: value)
    }

    /// The white-balance mode in which `colortemperature` is the value the body
    /// uses. Any other mode ignores it.
    ///
    /// `nonisolated` so the UI can compare against it without hopping to the
    /// camera actor. It is a constant string, not camera state.
    public nonisolated static let colorTemperatureMode = "Color Temperature"

    /// Set the body's color temperature, putting it into Color Temperature
    /// mode first so the value is the one applied.
    ///
    /// Writing `colortemperature` alone has no effect unless the body is in
    /// Color Temperature mode: the body keeps whatever white-balance mode it
    /// was in and derives its own temperature, so the number the app shows
    /// bears no relation to the exposure. Measured on the R5: a capture whose EXIF
    /// recorded `Color Temperature: 5200` while `Color Temp As Shot` was
    /// 2639, mode left on `Custom Whitebalance: PC-1`. Roughly a 2600K error
    /// against a daylight light table.
    ///
    /// Best-effort on the mode: bodies that don't expose the choice still get
    /// the temperature written, which is no worse than writing it alone.
    public func setWhiteBalanceKelvin(_ k: Int) async throws {
        try? await ensureColorTemperatureMode()
        try await setString("colortemperature", value: "\(k)")
    }

    /// Switch to Color Temperature white balance if the body offers it and
    /// isn't already there. Skipped silently when the choice doesn't exist.
    ///
    /// The current mode is read first. `getString` and `choices(for:)` each
    /// cost one full `gp_camera_get_config` (the cost table above), and this
    /// runs on every Kelvin write, which the UI drives from a Stepper. After
    /// the first write the mode already matches and this returns after the
    /// one `getString`, without the `choices(for:)` read.
    private func ensureColorTemperatureMode() async throws {
        let current = try? await getString("whitebalance")
        if let current,
           current.caseInsensitiveCompare(Self.colorTemperatureMode) == .orderedSame {
            return
        }
        let available = (try? await choices(for: "whitebalance")) ?? []
        guard let target = available.first(where: {
            $0.caseInsensitiveCompare(Self.colorTemperatureMode) == .orderedSame
        }) else { return }
        try await setString("whitebalance", value: target)
        CameraLog.properties.info(
            "whitebalance → \(target, privacy: .public) (was \(current ?? "?", privacy: .public)) so colortemperature applies"
        )
    }

    /// Values on the 7D: "Evaluative", "Partial", "Spot" and "Center-weighted
    /// average". The spot meter sits at the frame center, and libgphoto2
    /// cannot move it.
    public func setMeteringMode(_ value: String) async throws {
        try await setString("meteringmode", value: value)
    }

    /// The exposure mode. The 7D sets it on its physical mode dial, so there is
    /// no setter.
    public func exposureMode() async throws -> String {
        // Some libgphoto2 builds expose this as `autoexposuremode`, others as `expprogram`.
        do { return try await getString("autoexposuremode") } catch {}
        do { return try await getString("expprogram") } catch {}
        throw CameraError.propertyNotFound(name: "autoexposuremode/expprogram")
    }

    // MARK: - Manual focus drive

    /// Direction + magnitude for a one-shot manual focus step. The 7D's
    /// libgphoto2 driver exposes `manualfocusdrive` as a RADIO with values
    /// "Near 1", "Near 2", "Near 3", "Far 1", "Far 2", "Far 3", "None".
    /// Each step moves the lens motor a fine/medium/coarse amount toward the
    /// near / far end. Multiple writes compound.
    public enum ManualFocusStep: String, Sendable, CaseIterable {
        case nearTiny = "Near 1"
        case nearSmall = "Near 2"
        case nearLarge = "Near 3"
        case farTiny = "Far 1"
        case farSmall = "Far 2"
        case farLarge = "Far 3"

        /// The step a focus key asks for, or nil when the key is not one.
        ///
        /// Comma is far, period is near. Bare is medium, Option fine, Control
        /// coarse (medium is the step used most, so it gets the bare key, and
        /// the on-screen buttons keep their order). `chars` is
        /// `charactersIgnoringModifiers`, which despite the name still applies
        /// Shift, so a comma pressed while Shift holds the momentary punch-in
        /// arrives as `<` (and period as `>`). Both forms are accepted so focus
        /// can be stepped while zoomed in.
        public static func forFocusKey(_ chars: String, option: Bool, control: Bool) -> ManualFocusStep? {
            let near: Bool
            switch chars {
            case ",", "<": near = false
            case ".", ">": near = true
            default: return nil
            }
            if control { return near ? .nearLarge : .farLarge }
            if option  { return near ? .nearTiny : .farTiny }
            return near ? .nearSmall : .farSmall
        }
    }

    /// Drive the lens focus motor one step in the requested direction.
    ///
    /// Preconditions for the motor to move (the libgphoto2 write returns OK
    /// regardless, so silent no-ops are common if these aren't met):
    ///   • Lens switch must be set to AF. The EF lens motor is mechanically
    ///     disconnected in MF: the body sends the drive command and the lens
    ///     accepts it, but nothing physical happens.
    ///   • Body focusmode should be a non-Manual mode (One Shot / AI Servo /
    ///     AI Focus).
    ///   • Live view should be active. Some Canon bodies only accept
    ///     manualfocusdrive while EVF is up (mirror raised). The 7D in
    ///     particular ignores the command when the mirror is down.
    ///
    /// A Manual focusmode may be a body setting that blocks the drive, which
    /// forcing One Shot fixes, or the lens switch on MF, which is how
    /// AppAutofocus.blockedByLensSwitch reads it and where forcing One Shot
    /// cannot help. Which reading holds on the 7D is not settled.
    public func driveManualFocus(_ step: ManualFocusStep) async throws {
        do {
            let current = try await getString("focusmode")
            if current.lowercased() == "manual" || current.isEmpty {
                CameraLog.properties.info("driveManualFocus: focusmode=\(current, privacy: .public), forcing One Shot first")
                try? await setString("focusmode", value: "One Shot")
            }
        } catch {
        }
        try await setString("manualfocusdrive", value: step.rawValue)
    }

    // MARK: - Exposure simulation

    /// Turn exposure simulation in EVF on or off. On, the LV preview matches
    /// what the body would capture. The 7D defaults to off (LV always shows an
    /// auto-gain'd image regardless of exposure settings).
    /// Returns silently if the widget isn't exposed by this libgphoto2 build.
    public func setExposureSimulation(_ enabled: Bool) async throws {
        // The 7D's libgphoto2 widget for this is typically `eosexposuresimulation`
        // (TOGGLE 0/1). Some bodies/builds expose it as `exposuresimulation` or
        // not at all. Try both leaf names.
        for name in ["eosexposuresimulation", "exposuresimulation"] {
            do {
                let cam = try session.gpCamera()
                let ctx = try session.gpContext()
                let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeToggle(leaf, value: enabled ? 1 : 0)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.properties.info("set \(name, privacy: .public) ← \(enabled, privacy: .public)")
                return
            } catch CameraError.propertyNotFound {
                continue
            }
        }
        // Both leaf names missing: log and return. The caller treats this as
        // best-effort.
        CameraLog.properties.info("exposure simulation widget not exposed, skipping")
    }

    // MARK: - Image format (RAW / RAW+JPEG / JPEG / etc.)

    public func setImageFormat(_ value: String) async throws {
        try await setString("imageformat", value: value)
    }

    /// Sync the camera's clock with optional TZ-offset correction so saved
    /// CR2 files get EXIF DateTimeOriginal that matches host wall clock.
    ///
    /// The 7D's `datetimeutc` widget writes the camera's internal UTC. The body
    /// then derives EXIF DateTimeOriginal as `internal_utc + camera_tz_menu`.
    /// If the camera's TZ menu setting doesn't match the host's TZ, EXIF drifts
    /// by the delta. An exact 1-hour gap was observed with the camera on PST
    /// (no DST) while the host was on PDT. libgphoto2 exposes no widget for the
    /// camera TZ menu, so we can't read or fix it from software.
    ///
    /// The 7D does not expose a plain `datetime` widget (only `datetimeutc`),
    /// so local wall time cannot be written through `datetime` on it. That is
    /// why the write below targets `datetimeutc` with a corrected epoch.
    ///
    /// Verified on the R5: that body exposes all four leaves,
    /// `settings/datetime`, `settings/datetimeutc`, `actions/syncdatetime`,
    /// `actions/syncdatetimeutc`, and this function works there:
    /// a clock skewed by an hour was corrected to within a second, and EXIF
    /// DateTimeOriginal on the resulting CR3 matched host wall clock with a
    /// correct -07:00 DST-on zone. `tzOffsetMinutes` is not needed on the
    /// R5. Leave it at 0.
    ///
    /// On the R5, `settings/datetime` reports `Readonly: 0` but ignores
    /// writes: no error, and the value is unchanged. `settings/datetimeutc`
    /// takes the write, which is why this writes it and not `datetime`.
    ///
    /// The DST term is `CameraClock.datetimeUTCValue`. A body that keeps
    /// its zone on standard time (the 7D) gets this Mac's DST offset added, so
    /// the clock is right in summer as well as winter without the setting.
    /// A camera on PST while this Mac is on PDT needs no offset: the DST term
    /// already adds that hour, and passing +60 as well would add it twice.
    ///
    /// `tzOffsetMinutes` adds on top of that, for a camera whose zone is not
    /// this Mac's standard time: pass this Mac's standard-time offset minus
    /// the camera's zone offset, in minutes (a camera zone one hour east of
    /// this Mac's standard time → -60). tzOffsetMinutes=0 means the camera's
    /// zone already matches this Mac's standard time, which is the proper
    /// long-term setting.
    public func syncDateTimeToHostLocal(tzOffsetMinutes: Int = 0) async throws {
        let now = Date()
        let observesDST = CameraClock.observesDST(model: session.model)
        let correctedEpoch = CameraClock.datetimeUTCValue(now: now, cameraObservesDST: observesDST,
                                                          extraOffsetMinutes: tzOffsetMinutes)
        CameraLog.properties.info("syncDateTimeToHostLocal: model \(self.session.model ?? "unread", privacy: .public), camera observes DST \(observesDST, privacy: .public), DST add \(observesDST ? 0 : Int(TimeZone.current.daylightSavingTimeOffset(for: now)), privacy: .public) s")
        // Write `datetimeutc` directly (the 7D's leaf, a DATE widget on this
        // driver). The syncdatetimeutc action below runs when the leaf is
        // missing or is not a DATE widget.
        do {
            try await writeInt32Leaf("datetimeutc", value: correctedEpoch)
            CameraLog.properties.info("syncDateTimeToHostLocal: wrote datetimeutc=\(correctedEpoch, privacy: .public) (host_utc + DST term + \(tzOffsetMinutes, privacy: .public)min)")
            return
        } catch CameraError.widgetTypeMismatch, CameraError.propertyNotFound {
        }
        try await writeToggleAction("syncdatetimeutc", value: 1)
        CameraLog.properties.info("syncDateTimeToHostLocal: no DATE datetimeutc leaf, fired syncdatetimeutc action instead (TZ offset not applied)")
    }

    /// Fires the syncdatetimeutc action (true UTC, no DST term). The debug
    /// CLI's UTC clock sync uses it. The app uses `syncDateTimeToHostLocal()`
    /// because EXIF timestamps want wall-clock parity, not zone-correct UTC.
    public func syncDateTimeToHost() async throws {
        try await writeToggleAction("syncdatetimeutc", value: 1)
    }

    /// Write an Int32 to a DATE leaf, which libgphoto2 stores as Unix seconds
    /// (used for `datetimeutc`). Throws `widgetTypeMismatch` for a leaf that
    /// is not a DATE widget, before anything is written.
    private func writeInt32Leaf(_ name: String, value: Int32) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
        defer { gp_widget_unref(root) }
        try WidgetHelpers.writeDate(leaf, value: value)
        try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
    }

    /// Public face of `writeToggleAction`, with no -110 retry.
    public func writeToggle(_ name: String, value: Int32) async throws {
        try await writeToggleAction(name, value: value)
    }


    /// Write a TOGGLE-typed action leaf, the libgphoto2 convention for fire-once
    /// actions such as autofocusdrive, cancelautofocus and syncdatetimeutc.
    private func writeToggleAction(_ name: String, value: Int32) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        do {
            let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
            defer { gp_widget_unref(root) }
            try WidgetHelpers.writeToggle(leaf, value: value)
            try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
            CameraLog.properties.info("action \(name, privacy: .public) ← \(value, privacy: .public)")
        } catch {
            CameraLog.properties.error("action \(name, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Mode-aware write guards

    /// Returns true if a property is writable in the current exposure mode.
    /// The table is the 7D's mode-dial behavior. This function matches mode
    /// names by substring and enforces only the Tv, Av and P rows: it returns
    /// true for all three properties in any mode whose name contains none of
    /// AV, APERTURE, TV, SHUTTER or P (B and Manual included).
    ///   M  → ISO, Tv, Av all writable
    ///   Tv → ISO, Tv writable, Av is auto/read-only
    ///   Av → ISO, Av writable, Tv is auto/read-only
    ///   P  → ISO writable, Tv and Av auto/read-only
    ///   B  → ISO writable, Tv = bulb (read-only), Av writable
    ///   C1/C2/C3 → depends on stored custom mode, treat permissively
    public nonisolated static func isWritable(prop: String, inMode mode: String) -> Bool {
        let normalized = mode.uppercased()
        let isAvMode = normalized.contains("AV") || normalized.contains("APERTURE")
        let isTvMode = normalized.contains("TV") || normalized.contains("SHUTTER")
        let isPMode = normalized.contains("P") && !isAvMode && !isTvMode

        switch prop {
        case "iso":
            return true
        case "shutterspeed":
            if isAvMode || isPMode { return false }
            return true
        case "aperture":
            if isTvMode || isPMode { return false }
            return true
        default:
            return true
        }
    }

    /// Whether a body event for `prop` carrying `value` moves that property's
    /// picker in `mode`. An auto value always does. Any other value does only
    /// where the property is writable in that mode (`isWritable`): elsewhere a
    /// numeric shutter speed is the body's metered choice, not a setting.
    public nonisolated static func pickerFollowsEvent(prop: String, mode: String, value: String) -> Bool {
        if value.isEmpty || value.lowercased() == "auto" { return true }
        return isWritable(prop: prop, inMode: mode)
    }

    private func assertWritableForExposureProp(_ prop: String) async throws {
        let mode = (try? await exposureMode()) ?? "M"
        if !Self.isWritable(prop: prop, inMode: mode) {
            throw CameraError.propertyReadOnly(name: prop)
        }
    }
}
