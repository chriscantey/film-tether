import Foundation
import CGPhoto2

/// Polls `gp_camera_capture_preview` continuously to deliver live-view JPEG frames.
@CameraActor
public final class LiveView {
    public struct Frame: Sendable {
        public let jpegData: Data
        public let timestamp: Date
        public let width: Int?
        public let height: Int?
    }

    public nonisolated let frameStream: AsyncStream<Frame>
    private nonisolated let continuation: AsyncStream<Frame>.Continuation

    /// Internal, not private: the quit settle (QuitSettle.swift) drains and
    /// reads back on the same session.
    let session: CameraSession
    private let properties: CameraProperties
    private var loopTask: Task<Void, Never>?
    public private(set) var isActive: Bool = false
    /// Pause counter for the frame loop. When > 0, runLoop yields the actor
    /// and waits instead of fetching a frame. User actions (AF, focus drive,
    /// property writes) increment this before doing their USB work and
    /// decrement after, so the LV stream doesn't compete for the
    /// USB pipe while the body is processing a user request. Without this,
    /// pressing AF / focus / ISO either does nothing or returns -110 errors
    /// because the 30 FPS LV traffic leaves no breathing room.
    private var pauseCount: Int = 0

    public init(session: CameraSession, properties: CameraProperties) {
        self.session = session
        self.properties = properties
        var localContinuation: AsyncStream<Frame>.Continuation!
        self.frameStream = AsyncStream<Frame>(bufferingPolicy: .bufferingNewest(2)) { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    public func start() async throws {
        guard !isActive else { return }
        try await requestFeed()
        await kickMeter()
        beginLoop()
    }


    private func requestFeed() async throws {
        CameraLog.liveView.info("start: requesting PC live view")
        // First: route frames to the host (not HDMI). 'output' is on the 7D + similar bodies,
        // newer EOS may not expose it.
        try? await setOutputToPC()
        // Then: toggle the viewfinder leaf.
        try await setViewfinder(enabled: true)
        // Enable exposure simulation so the LV preview brightness matches what
        // the captured image will look like. Without this, the 7D shows an
        // auto-gain'd preview regardless of exposure settings, causing the
        // "captured image is much brighter than the live view" symptom.
        // Best-effort: skips silently if the widget isn't exposed on this body.
        try? await properties.setExposureSimulation(true)
    }

    private func kickMeter() async {
        // Kick the body's auto-meter loop. Without this the 7D firmware
        // doesn't emit shutterspeed change events during LV until something
        // wakes the metering state machine, which is why the footer stays
        // blank until first capture.
        //
        // Known risk: a 7D with C.Fn IV-1 at its default ("Shutter / AE
        // lock") has wedged with this kick in place. On that setting Press
        // Half may drive AF (see AFProbe.swift), and AF during live-view
        // startup correlates with the firmware-deep wedge. With C.Fn IV-1 =
        // "AE lock / AF", Press Half locks AE only and drives no AF. The app
        // does not read C.Fn IV-1, so `start()` sends this kick whatever
        // C.Fn IV-1 is set to.
        //
        // Body behavior after this kick: Press Half locks AE for ~120ms,
        // Release Half returns the body to "LV with auto-meter active"
        // state. Subsequent shutterspeed change events flow as the scene
        // changes brightness.
        try? await properties.setString("eosremoterelease", value: "Press Half")
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await properties.setString("eosremoterelease", value: "Release Half")
    }

    private func beginLoop() {
        isActive = true
        loopTask = Task { @CameraActor [weak self] in
            await self?.runLoop()
        }
        CameraLog.liveView.info("start: loop task spawned")
    }

    public func stop() async throws {
        guard isActive else { return }
        CameraLog.liveView.info("stop: cancelling loop")
        isActive = false
        loopTask?.cancel()
        loopTask = nil
        // Full EVF teardown for the 7D: write both viewfinder=0 and
        // output=TFT (EVFOutputDevice) so the mirror drops. A gp_camera_exit
        // sent before the mirror drops wedges the body until a power-cycle, so
        // the writes are awaited: the caller (quit's gp_camera_exit, or a
        // re-start) runs only after both writes have returned.
        do {
            try await setViewfinder(enabled: false)
            CameraLog.liveView.info("stop: setViewfinder(false) wrote")
        } catch {
            CameraLog.liveView.error("stop: setViewfinder(false) failed: \(String(describing: error), privacy: .public)")
        }
        do {
            try await setOutputToTFT()
            CameraLog.liveView.info("stop: setOutputToTFT wrote (mirror should drop)")
        } catch {
            CameraLog.liveView.info("stop: setOutputToTFT skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// True while the pause counter is above zero (`withPriority` or a direct
    /// `pauseFrameLoop`). Exposed so other background loops (e.g. AppModel's
    /// event-drain task) can pause themselves on the same signal. Capture
    /// can't have a second `gp_camera_wait_for_event` consumer running
    /// while it waits for FILE_ADDED, or that other consumer eats the
    /// event the capture needs.
    public var isPaused: Bool { pauseCount > 0 }

    /// Increment the pause counter. The runLoop will yield instead of
    /// fetching until a matching `resumeFrameLoop()` decrements back to 0.
    /// Nests: each pause needs a matching resume.
    public func pauseFrameLoop() async {
        pauseCount += 1
    }

    /// Decrement the pause counter. Once it returns to 0 the runLoop's
    /// next iteration resumes fetching.
    public func resumeFrameLoop() async {
        pauseCount = Swift.max(0, pauseCount - 1)
    }

    /// Run a closure with the frame loop paused. The pause is incremented
    /// before the closure runs and decremented after, even on throw.
    public func withPriority<T>(_ work: () async throws -> T) async rethrows -> T {
        await pauseFrameLoop()
        defer { Task { await self.resumeFrameLoop() } }
        CameraLog.liveView.info("withPriority: paused (count=\(self.pauseCount, privacy: .public))")
        // 100ms after raising the pause is empirically enough for the user
        // op to go through.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let result = try await work()
        CameraLog.liveView.info("withPriority: work completed")
        return result
    }

    /// One-shot fetch of a single preview frame. Callers see CameraError on
    /// any libgphoto2 error and on host-side timeout. `gp_camera_capture_preview`
    /// has been observed hanging 20+ seconds before returning -7 when the body
    /// is in certain wedged states. The host-side timeout does not return
    /// early from such a hang (see `fetchOnePreviewWithTimeout`), so the
    /// caller waits until the C call returns either way.
    public func fetchOnePreview() async throws -> Data {
        return try await fetchOnePreviewWithTimeout(seconds: 5)
    }

    private func fetchOnePreviewWithTimeout(seconds: Double) async throws -> Data {
        // Race the fetch against a deadline timer. The first child to finish
        // supplies the result or the error, and the other is canceled. The C
        // call inside fetchRaw can't be canceled from Swift, and the task
        // group waits for every child before it returns or rethrows, so a
        // timer that wins still leaves the caller blocked until
        // gp_camera_capture_preview returns. The timeout error then replaces
        // whatever the fetch returned.
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @CameraActor in
                try await self.fetchOnePreviewRaw()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CameraError.libGPhoto(
                    code: -10,
                    message: "fetchOnePreview timed out after \(seconds)s, body may be wedged"
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func fetchOnePreviewRaw() async throws -> Data {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var file: OpaquePointer? = nil
        try CameraError.check(gp_file_new(&file))
        guard let file else { throw CameraError.captureFailed(reason: "gp_file_new failed") }
        defer { gp_file_unref(file) }
        try CameraError.check(gp_camera_capture_preview(cam, file, ctx))
        var dataPtr: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        try withUnsafeMutablePointer(to: &dataPtr) { dPtr in
            try withUnsafeMutablePointer(to: &size) { sPtr in
                try CameraError.check(gp_file_get_data_and_size(file, dPtr, sPtr))
            }
        }
        guard let dataPtr, size > 0 else {
            throw CameraError.captureFailed(reason: "empty preview data")
        }
        return Data(bytes: dataPtr, count: Int(size))
    }

    // MARK: - Private

    /// Toggle the live-view feed on or off. Tries `viewfinder` (the leaf on the
    /// 7D, 70D, and most EOS bodies) first, then `eosviewfinder`.
    private func setViewfinder(enabled: Bool) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        for name in ["viewfinder", "eosviewfinder"] {
            do {
                let (root, leaf) = try WidgetHelpers.resolveLeaf(
                    camera: cam, context: ctx, name: name
                )
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeToggle(leaf, value: enabled ? 1 : 0)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.liveView.info("setViewfinder(\(enabled, privacy: .public)): wrote leaf '\(name, privacy: .public)'")
                return
            } catch CameraError.propertyNotFound {
                continue
            }
        }
        CameraLog.liveView.error("setViewfinder: neither 'viewfinder' nor 'eosviewfinder' exists on this body")
        throw CameraError.propertyNotFound(name: "viewfinder/eosviewfinder")
    }

    /// Route live-view frames over USB to the host (vs HDMI to a TV). The 7D and similar
    /// bodies expose this under `/main/settings/output`. Throws when the leaf isn't
    /// present, and `requestFeed` ignores that (newer bodies use viewfinder alone).
    private func setOutputToPC() async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "output"
        )
        defer { gp_widget_unref(root) }
        // libgphoto2 labels the 'output' values "Off", "TFT", "PC", "MOBILE",
        // "MOBILE2" and their "+" combinations. Setting "PC" routes USB-bound frames.
        try WidgetHelpers.writeString(leaf, value: "PC")
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "output", leaf: leaf)
        CameraLog.liveView.info("setOutputToPC: output=PC")
    }

    /// Restore `output` to the camera's default (TFT = on-camera LCD), writing
    /// EVFOutputDevice back so the body drops the mirror and exits the
    /// live-view state machine. Without this the 7D leaves the mirror up.
    private func setOutputToTFT() async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "output"
        )
        defer { gp_widget_unref(root) }
        // "TFT" is the 7D's standard label. libgphoto2's set_value does not
        // check the choice list, so a value the body lacks fails at the
        // commit, and the caller treats that as non-fatal. The "OFF" write
        // runs only if the "TFT" write throws.
        do {
            try WidgetHelpers.writeString(leaf, value: "TFT")
        } catch {
            try WidgetHelpers.writeString(leaf, value: "OFF")
        }
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "output", leaf: leaf)
    }

    private func runLoop() async {
        var consecutiveErrors = 0
        var frameCount = 0
        // EVF needs time to settle after viewfinder=1. The first few
        // gp_camera_capture_preview calls often return -110 I/O in progress
        // (or -1 General Error if body hasn't engaged EVF yet) while the
        // mirror flips and the JPEG pipeline initializes. The 7D from a
        // cold start needs ~1s.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        CameraLog.liveView.info("runLoop: starting fetch loop (target ~30 FPS)")
        // Frame-rate cap. The 7D + libgphoto2 deliver ~30-40 FPS uncapped,
        // which matches the body's internal EVF refresh. Capping at
        // ~30 FPS (33ms) reduces USB chatter and host CPU without losing
        // visible smoothness.
        let targetFrameInterval: UInt64 = 33_000_000
        while !Task.isCancelled && isActive {
            // Yield to user-priority ops. While the pause counter is non-zero,
            // skip fetching and sleep: the body's USB pipe belongs to whatever
            // user action (AF, focus drive, ISO change) incremented the
            // counter. The loop re-checks every 50ms. User ops typically take
            // 100-300ms so this loop won't burn the actor.
            if pauseCount > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            let frameStart = DispatchTime.now()
            do {
                let bytes = try await fetchOnePreview()
                let (w, h) = Self.parseJPEGDimensions(bytes)
                let frame = Frame(jpegData: bytes, timestamp: Date(), width: w, height: h)
                continuation.yield(frame)
                if frameCount == 0 {
                    CameraLog.liveView.info("runLoop: first frame yielded (\(bytes.count) bytes, \(w ?? 0)x\(h ?? 0))")
                }
                frameCount += 1
                if frameCount % 30 == 0 {
                    CameraLog.liveView.debug("runLoop: \(frameCount) frames yielded")
                }
                consecutiveErrors = 0
                // Yield the CameraActor between frames so property writes, capture,
                // and zoom calls don't have to wait for the next preview tick. Also
                // pace to ~30 FPS by sleeping the remainder of the target interval. If
                // the fetch already took longer than the interval we proceed
                // immediately (no negative sleep).
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds
                if elapsed < targetFrameInterval {
                    try? await Task.sleep(nanoseconds: targetFrameInterval - elapsed)
                } else {
                    await Task.yield()
                }
            } catch {
                consecutiveErrors += 1
                // privacy: .public so the error shows in an exported log. os_log
                // redacts String(describing:) by default.
                CameraLog.liveView.error("runLoop: fetch error #\(consecutiveErrors, privacy: .public), \(String(describing: error), privacy: .public)")
                // 25 tries, because -110 I/O in progress is normal during
                // mirror flip and camera-side state transitions. The backoff
                // grows 200 ms per error up to 2 s so we don't hammer
                // libgphoto2's port.
                if consecutiveErrors >= 25 {
                    CameraLog.liveView.error("runLoop: 25 consecutive errors, giving up")
                    continuation.finish()
                    isActive = false
                    return
                }
                let backoff: UInt64 = min(2_000_000_000, UInt64(consecutiveErrors) * 200_000_000)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
        CameraLog.liveView.info("runLoop: exited (cancelled=\(Task.isCancelled), isActive=\(self.isActive), frames=\(frameCount))")
    }

    /// Read a JPEG's dimensions from its first SOF (Start of Frame) marker, SOF0 to
    /// SOF15. Returns (nil, nil) if not found.
    public nonisolated static func parseJPEGDimensions(_ data: Data) -> (Int?, Int?) {
        guard data.count >= 4 else { return (nil, nil) }
        guard data[0] == 0xFF, data[1] == 0xD8 else { return (nil, nil) }
        var i = 2
        while i < data.count - 8 {
            // Markers start with 0xFF. Skip any other byte.
            guard data[i] == 0xFF else { i += 1; continue }
            // There is no stop at SOS (0xDA) and no skip for a stuffed 0xFF 0x00:
            // both are read as length-prefixed segments below, so a JPEG whose
            // SOF comes after its scan data is not parsed correctly.
            let marker = data[i + 1]
            if marker == 0xD8 || marker == 0xD9 { i += 2; continue }
            // SOF0 = 0xC0 .. SOF15 = 0xCF except DHT (0xC4), JPG (0xC8), DAC (0xCC).
            if (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard i + 9 < data.count else { return (nil, nil) }
                let h = (Int(data[i + 5]) << 8) | Int(data[i + 6])
                let w = (Int(data[i + 7]) << 8) | Int(data[i + 8])
                return (w, h)
            }
            // Standard segment: 2-byte length follows the marker.
            guard i + 3 < data.count else { return (nil, nil) }
            let segmentLen = (Int(data[i + 2]) << 8) | Int(data[i + 3])
            if segmentLen < 2 { return (nil, nil) }
            i += 2 + segmentLen
        }
        return (nil, nil)
    }
}
