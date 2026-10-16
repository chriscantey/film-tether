import Foundation
import CGPhoto2
import UsbReset

/// Owns the libgphoto2 `Camera*` and `GPContext*` for a single connected camera.
/// Instance methods run on `CameraActor`'s pinned thread, except
/// `closeFromWatchdog`, which the stall ladder calls from another thread.
@CameraActor
public final class CameraSession {
    private var camera: UnsafeMutablePointer<Camera>?
    private var context: OpaquePointer?
    public private(set) var isOpen: Bool = false

    /// Firmware version reported by the camera (e.g. "2.0.6"). Populated after `open()`.
    public private(set) var firmware: String?
    /// Model name from the summary ("Canon EOS 7D"). Populated after `open()`.
    public private(set) var model: String?

    public init() throws {
        // AppLaunch.bootstrap runs this setup at process start. It runs again
        // here, idempotently, for a test or a non-main entry point.
        CameraEnvironment.setup()

        var newCamera: UnsafeMutablePointer<Camera>? = nil
        try CameraError.check(gp_camera_new(&newCamera))
        self.camera = newCamera
        self.context = gp_context_new()
        if self.context == nil {
            if let c = newCamera { gp_camera_unref(c) }
            throw CameraError.libGPhoto(code: -1, message: "gp_context_new returned NULL")
        }
    }

    deinit {
        // deinit runs on whatever thread released the final reference, not the pinned
        // camera thread, so it must not start a USB transaction. gp_camera_unref frees
        // the camera through gp_camera_free, which calls gp_camera_exit itself when the
        // camera is still initialized (gphoto2-camera.c, 2.5.33). For a closed session
        // that leaves a ref-count drop and a memory free with no USB I/O, and
        // gp_context_unref is the same.
        //
        // If isOpen is true here, the caller failed to call close(), and that
        // gp_camera_exit runs inside gp_camera_unref on this thread, off the camera
        // thread, unless closeFromWatchdog already exited the handle (it leaves
        // isOpen set, and gp_camera_free skips the exit once it has run).
        Self.openHandles.remove(ObjectIdentifier(self))
        if let cam = camera { gp_camera_unref(cam) }
        if let ctx = context { gp_context_unref(ctx) }
    }

    /// Handles of every open session, readable off the camera thread. The
    /// stall ladder takes one (`closeFromWatchdog`, StallLadder.swift). A
    /// session whose handle has been taken refuses every later call
    /// (`gpCamera`).
    nonisolated static let openHandles = OpenHandleRegistry()

    /// What `open` does after a failed gp_camera_init. recover:false gets
    /// nothing. The app passes usbReset:false and gets the soft retry only:
    /// against Image Capture's claim this reset can fire 19 times in 3
    /// minutes, every one refused with -4, so the app never resets the USB,
    /// and its stall ladder (StallLadder.swift) never resets either.
    /// The debug CLI's own commands keep the full plan.
    public enum InitRecoveryStep: Equatable, Sendable { case softRetry, usbReset }
    public nonisolated static func initRecoveryPlan(recover: Bool, usbReset: Bool = true) -> [InitRecoveryStep] {
        guard recover else { return [] }
        return usbReset ? [.softRetry, .usbReset] : [.softRetry]
    }

    /// Initialize the camera connection. A caller that meets the macOS PTPCamera
    /// USB-claim race releases the claim first with `ICDeviceClaim.releaseCanonEos()`.
    /// The app's connect skips that on its first attempt and calls it from the
    /// third (`CameraConnection.connect`).
    ///
    /// - Parameter recover: run the steps of `initRecoveryPlan` when
    ///   `gp_camera_init` fails.
    /// - Parameter usbReset: follow a failed soft retry with the IOKit USB
    ///   re-enumeration. The app passes false (see `initRecoveryPlan`).
    public func open(recover: Bool = true, usbReset: Bool = true) async throws {
        guard !isOpen else { throw CameraError.sessionAlreadyOpen }
        guard let cam = camera, let ctx = context else {
            throw CameraError.sessionNotOpen
        }
        CameraLog.session.info("gp_camera_init …")
        var initResult = gp_camera_init(cam, ctx)
        let plan = Self.initRecoveryPlan(recover: recover, usbReset: usbReset)
        if plan.contains(.softRetry), initResult == GP_ERROR_TIMEOUT || initResult == GP_ERROR_IO || initResult == -53 {
            // First-line recovery: gp_camera_exit + brief wait + retry. Handles
            // the common case where libgphoto2's port state is stale but the
            // body's PTP daemon is healthy.
            CameraLog.session.info("gp_camera_init returned \(initResult), attempting soft retry")
            _ = gp_camera_exit(cam, ctx)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            CameraLog.session.info("gp_camera_init (soft retry) …")
            initResult = gp_camera_init(cam, ctx)
        }
        if plan.contains(.usbReset), initResult == GP_ERROR_TIMEOUT || initResult == GP_ERROR_IO || initResult == -53 {
            // Last-resort recovery, after the soft retry above failed: USB
            // re-enumeration via IOKit, which makes the device disappear
            // briefly when it goes through. The app never asks for it (see
            // `initRecoveryPlan`).
            CameraLog.session.info("soft retry failed, issuing IOKit USB ReEnumerate on Canon (0x04A9)")
            _ = gp_camera_exit(cam, ctx)
            let resetRc = filmtether_reset_usb_device(0x04A9)
            CameraLog.session.info("filmtether_reset_usb_device → \(resetRc) (0=ok, -1=not found, -2/-3=IOKit fail, -4=exclusive, -5=re-enumerate fail)")
            if resetRc == 0 {
                // 0 means the re-enumeration was requested, or it failed and the
                // bus-reset fallback went through (UsbReset.h). Both are handled
                // the same way. After a re-enumeration the old cam pointer
                // references a stale io_service_t, and any call on it returns
                // GP_ERROR_BAD_PARAMETERS (-2), so the camera object is
                // re-allocated to find the device again, after a wait that gives
                // the body time to come back online.
                CameraLog.session.info("waiting 6s for body PTP daemon to come back …")
                try? await Task.sleep(nanoseconds: 6_000_000_000)

                gp_camera_unref(cam)
                self.camera = nil
                var freshCam: UnsafeMutablePointer<Camera>? = nil
                try CameraError.check(gp_camera_new(&freshCam))
                guard freshCam != nil else {
                    throw CameraError.libGPhoto(code: -1, message: "gp_camera_new returned null after USB reset")
                }
                self.camera = freshCam
                CameraLog.session.info("gp_camera_init (after USB reset, fresh handle) …")
                initResult = gp_camera_init(freshCam, ctx)
            }
        }
        try CameraError.check(initResult)
        isOpen = true
        if let c = camera { Self.openHandles.put(ObjectIdentifier(self), camera: c, context: ctx) }
        CameraLog.session.info("gp_camera_init → GP_OK")

        // open() is read-only (just init + summary parse). The 7D has hit a
        // fatal "shooting is not possible" error on app restart, with no user
        // action, while open() wrote capturetarget and syncdatetimeutc, so
        // open() writes nothing and writes wait until the user needs them.
        // The exception is the app's clock sync, which runs after connect
        // from AppModel and is on by default (autoSyncClockOnConnect). It
        // writes datetimeutc, so it remains a known risk for that error.

        // Read firmware via summary, and refuse a version on the known-buggy list.
        if let detected = try readFirmwareVersion() {
            firmware = detected
            CameraLog.session.info("firmware: \(detected, privacy: .public)")
            if isFirmwareTooOld(detected) {
                CameraLog.session.error("firmware \(detected, privacy: .public) is on the known-buggy list, refusing to proceed")
                isOpen = false
                Self.openHandles.remove(ObjectIdentifier(self))
                _ = gp_camera_exit(cam, ctx)
                throw CameraError.firmwareTooOld(detected: detected)
            }
        } else {
            CameraLog.session.info("firmware: not parseable from summary (OK for many bodies)")
        }
    }


    public func close() {
        guard isOpen, let cam = camera, let ctx = context else { return }
        // A `closeFromWatchdog` that already took the handle has exited this
        // session. A second gp_camera_exit would only close a closed port.
        guard Self.openHandles.remove(ObjectIdentifier(self)) else { isOpen = false; return }
        _ = gp_camera_exit(cam, ctx)
        isOpen = false
    }

    /// The stall ladder's close (StallLadder.swift), from off the camera
    /// thread while this session's call is stuck. Takes only this session's
    /// handle, so a later session is never touched. Against a call in flight
    /// libgphoto2 sends nothing here: it defers the exit and runs it on the
    /// camera thread when that call returns (gphoto2-camera.c:261). The app's
    /// ladder never resets, so the call returns when the camera is power
    /// cycled. One race remains: if the call returned in the instant before
    /// this exit, the exit runs here, with the camera thread idle. Every call
    /// after this one refuses at `gpCamera`, because the handle is gone.
    public nonisolated func closeFromWatchdog() -> String {
        guard let h = Self.openHandles.take(ObjectIdentifier(self)) else { return "no session open" }
        let rc = gp_camera_exit(h.camera, h.context)
        return "gp_camera_exit requested, rc \(rc)"
    }

    /// The first `gp_camera_get_config` of a session, the call that can sit
    /// stuck in the 7D's first GetEvent for over three minutes. It also
    /// prepares the session (libgphoto2 runs camera_prepare_capture on the
    /// first config read). The tree is dropped: this read proves the body
    /// answers, and the app's snapshot reads after it. Returns its wall time
    /// in ms.
    public func firstConfig() throws -> Int {
        let cam = try gpCamera()
        let ctx = try gpContext()
        let t = Date()
        let root = try WidgetHelpers.fetchRoot(camera: cam, context: ctx)
        if let root { gp_widget_unref(root) }
        return Int((Date().timeIntervalSince(t) * 1000).rounded())
    }


    /// Internal accessors for peer classes in this module.
    internal func gpCamera() throws -> UnsafeMutablePointer<Camera> {
        guard isOpen, let c = camera else { throw CameraError.sessionNotOpen }
        // closeFromWatchdog took the handle and exited the session.
        guard Self.openHandles.contains(ObjectIdentifier(self)) else { throw CameraError.sessionNotOpen }
        return c
    }

    internal func gpContext() throws -> OpaquePointer {
        guard let c = context else { throw CameraError.sessionNotOpen }
        return c
    }

    // MARK: - Private

    private func readFirmwareVersion() throws -> String? {
        guard let cam = camera, let ctx = context else { return nil }
        var summary = CameraText()
        try CameraError.check(gp_camera_get_summary(cam, &summary, ctx))

        // CameraText.text is a 32 KB C array. Swift imports fixed-size arrays that large
        // as inaccessible fields, so read it via raw memory: the struct's address is the
        // address of its first (and only) field, so we rebind the struct pointer as `CChar*`.
        let text = withUnsafePointer(to: summary) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        model = Self.parseModel(from: text)
        return parseFirmware(from: text)
    }

    /// The "Model: Canon EOS 7D" line of the summary, trimmed. nil if absent.
    public nonisolated static func parseModel(from summary: String) -> String? {
        for line in summary.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Model:") {
                let v = t.dropFirst("Model:".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Parse "Firmware Version: X.Y.Z" out of `gp_camera_get_summary` output.
    /// Returns nil if not found.
    public nonisolated static func parseFirmware(from summary: String) -> String? {
        // Two patterns, because the summary format varies across camlibs.
        let patterns = [
            #"Firmware\s+Version[:\s]+([0-9]+(?:\.[0-9]+)+)"#,
            #"Firmware[:\s]+([0-9]+(?:\.[0-9]+)+)"#,
        ]
        for p in patterns {
            if let r = summary.range(of: p, options: .regularExpression) {
                let match = String(summary[r])
                if let v = match.range(of: #"[0-9]+(?:\.[0-9]+)+"#, options: .regularExpression) {
                    return String(match[v])
                }
            }
        }
        return nil
    }

    private func parseFirmware(from summary: String) -> String? {
        Self.parseFirmware(from: summary)
    }

    /// Returns true if `version` is on the known-buggy-firmware list. The list holds
    /// 2.0.3, the Canon EOS 7D firmware with a PTP I/O error on capture-image
    /// (gphoto2 issue #460). The check matches the version string alone, with no
    /// model test, so any body reporting 2.0.3 is refused. The 70D on its usual 1.x
    /// firmware passes.
    public nonisolated static func isFirmwareTooOld(_ version: String) -> Bool {
        knownBuggyFirmwares.contains(version)
    }

    private nonisolated static let knownBuggyFirmwares: Set<String> = [
        "2.0.3",
    ]

    private func isFirmwareTooOld(_ version: String) -> Bool {
        Self.isFirmwareTooOld(version)
    }
}

/// Lock-guarded map of open session handles (see `CameraSession.openHandles`).
final class OpenHandleRegistry: @unchecked Sendable {
    typealias CameraPtr = UnsafeMutablePointer<Camera>
    struct Handles { let camera: CameraPtr; let context: OpaquePointer }
    private let lock = NSLock()
    private var map: [ObjectIdentifier: Handles] = [:]

    func put(_ id: ObjectIdentifier, camera: UnsafeMutablePointer<Camera>, context: OpaquePointer) {
        lock.lock(); map[id] = Handles(camera: camera, context: context); lock.unlock()
    }
    /// True when the entry was there, so the caller owns its close.
    @discardableResult
    func remove(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: id) != nil
    }
    /// Remove and return one entry, so its close is owned by the caller alone.
    func take(_ id: ObjectIdentifier) -> Handles? {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: id)
    }
    func contains(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map[id] != nil
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
}
