import Foundation
import CGPhoto2

/// USB enumeration + reconnection state machine. Polls libgphoto2's
/// `gp_camera_autodetect` (no hotplug API in libgphoto2 itself), releases
/// macOS's claim on the camera before a connect retry, publishes state via
/// `stateStream`. Matches any Canon EOS body, tested with 7D, 70D and R5.
@CameraActor
public final class CameraConnection {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case enumerating
        case ready
        /// The error itself, not its description, so the app can map the
        /// code to a sentence and a hint (CameraAdvice).
        case error(CameraError)
    }

    public nonisolated let stateStream: AsyncStream<ConnectionState>
    private nonisolated let continuation: AsyncStream<ConnectionState>.Continuation
    /// The status line's wait glyph for the first config read (CameraWait):
    /// a value while the ladder runs, nil when it ends. Fed from off the camera
    /// thread, which may be the one that is stuck.
    public nonisolated let waitStream: AsyncStream<CameraWait?>
    private nonisolated let waitContinuation: AsyncStream<CameraWait?>.Continuation

    private var session: CameraSession?
    /// Held by the live-view stall ladder for its whole run, set from off the
    /// camera thread, so no presence poll starts a connect or a disconnect
    /// while the ladder owns the session.
    public nonisolated let pollHold = StallFlag()
    /// Whether a stall matches the restart-the-Mac signature. One per
    /// process, shared with the live-view ladder (StallHistory).
    public nonisolated let stallHistory = StallHistory()
    /// A claim code (-53 or -60) came back somewhere in the current connect
    /// series. Cleared when a series starts, read by the app's advice.
    public nonisolated let claimSeenInSeries = StallFlag()
    private var monitorTask: Task<Void, Never>?
    private var lastState: ConnectionState = .disconnected
    private var consecutiveMisses: Int = 0
    private var connectInFlight: Bool = false
    private let missesBeforeDisconnect = 3
    // Poll the USB bus every 10 seconds, to keep pressure on the body low.
    // Do not shorten this: a 3 s cadence coincided with a 7D wedge so deep
    // only a full AC pull recovered it. Once connected, autodetect is only
    // useful for hot-plug detection, and after a wedge the body is fragile
    // enough that even autodetect's USB enumeration can stress it.
    private let pollIntervalNanoseconds: UInt64 = 10_000_000_000

    public init() {
        var localContinuation: AsyncStream<ConnectionState>.Continuation!
        self.stateStream = AsyncStream<ConnectionState> { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
        var localWait: AsyncStream<CameraWait?>.Continuation!
        self.waitStream = AsyncStream<CameraWait?>(bufferingPolicy: .bufferingNewest(4)) { cont in
            localWait = cont
        }
        self.waitContinuation = localWait
    }

    deinit {
        monitorTask?.cancel()
        continuation.finish()
        waitContinuation.finish()
    }

    public func startMonitoring() async {
        guard monitorTask == nil else { return }
        let interval = pollIntervalNanoseconds
        monitorTask = Task { @CameraActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Stop the presence poll without closing the session. Quit calls this
    /// before it drains the body's EVF-exit burst, so no USB enumeration runs
    /// meanwhile.
    public func stopPolling() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let s = session { s.close() }
        session = nil
        transition(.disconnected)
    }

    public func currentSession() -> CameraSession? {
        return session
    }

    // MARK: - Private

    private func tick() async {
        // Skip the tick while another task's connect() is suspended
        // mid-flight, so the poll never starts a second connect beside it.
        guard !connectInFlight else { return }
        guard !pollHold.isSet else { return }

        let present = await isCanonEosPresent()
        if present {
            consecutiveMisses = 0
            if session == nil {
                await connect()
            }
        } else {
            consecutiveMisses += 1
            // The camera left the bus: after a stall, that is the power cycle
            // half of the restart signature.
            stallHistory.cameraLeft()
            if consecutiveMisses >= missesBeforeDisconnect, session != nil {
                session?.close()
                session = nil
                transition(.disconnected)
            }
        }
    }

    /// Scan via `gp_camera_autodetect` for any Canon EOS body.
    /// Tested with the 7D, 70D and R5. Other EOS bodies libgphoto2 supports
    /// may work. We filter by name here rather than USB ID because the
    /// libgphoto2 enumeration doesn't easily expose USB IDs. The per-body
    /// USB-claim release uses Canon's vendor ID via ImageCaptureCore.
    private func isCanonEosPresent() async -> Bool {
        var list: OpaquePointer? = nil
        guard gp_list_new(&list) == GP_OK, let list else { return false }
        defer { gp_list_unref(list) }

        let ctx = gp_context_new()
        defer { if let ctx { gp_context_unref(ctx) } }
        guard let ctx else { return false }

        let count = gp_camera_autodetect(list, ctx)
        guard count > 0 else { return false }

        for i in 0..<Int32(count) {
            var name: UnsafePointer<CChar>? = nil
            if gp_list_get_name(list, i, &name) == GP_OK, let name {
                let s = String(cString: name)
                CameraLog.connection.debug("autodetect candidate: \(s, privacy: .public)")
                // Match any Canon EOS body. libgphoto2 names them like "Canon EOS 7D",
                // "Canon EOS 70D", "Canon EOS 5D Mark IV", etc.
                if s.localizedCaseInsensitiveContains("Canon EOS") {
                    CameraLog.connection.info("autodetect matched: \(s, privacy: .public)")
                    return true
                }
            }
        }
        return false
    }


    /// After the live-view ladder ran out: forget the stuck session so the
    /// presence poll opens a fresh one once the camera comes back from its
    /// power cycle, then let the poll run again. Runs when the camera thread
    /// comes free, which is that power cycle. Only the session the ladder was
    /// stuck on is dropped, never one that replaced it.
    public func dropStalledSession(_ stale: CameraSession?) {
        if let stale, session === stale {
            session?.close()
            session = nil
        }
        pollHold.clear()
    }

    /// The first config read of a new session, under the stall ladder.
    private func firstConfigUnderBudget(_ box: SessionBox,
                                        log: @escaping @Sendable (String) -> Void) async -> StallOutcome {
        let cont = continuation
        let waits = waitContinuation
        let history = stallHistory
        let stage = CameraConnection.firstConfigStage
        let io = StallIO(
            attempt: { _ in
                guard let s = box.get() else { throw CameraError.sessionNotOpen }
                let ms = try await s.firstConfig()
                log("first config read took \(ms) ms")
            },
            close: { box.get()?.closeFromWatchdog() ?? "no session" },
            // The camera thread may still be stuck, so this cannot wait for
            // the actor: the error goes straight onto the stream.
            advise: {
                cont.yield(.error(history.recordStall(stage: stage)))
            },
            log: log,
            progress: { p in
                switch p {
                case .attempt(1): waits.yield(CameraWait(activity: .connecting, since: Date()))
                case .attempt: break
                case .finished: waits.yield(nil)
                }
            })
        return await StallGuard.run(stage: stage, ladder: .app, io: io)
    }

    public nonisolated static let firstConfigStage = "first config read"

    /// The app never re-enumerates the USB, on a stall or on a failed init
    /// (CameraSession.initRecoveryPlan, StallLadder.swift header).
    public nonisolated static let appUSBReset = false

    /// -53 GP_ERROR_IO_USB_CLAIM (thrown as usbClaimDenied) or -60 GP_ERROR_IO_LOCK.
    public nonisolated static func isClaim(_ e: CameraError) -> Bool {
        if case .usbClaimDenied = e { return true }
        if case .libGPhoto(let code, _) = e { return code == -53 || code == -60 }
        return false
    }


    private func connect(resetAllowed: Bool = true) async {
        connectInFlight = true
        defer { connectInFlight = false }
        claimSeenInSeries.clear()
        transition(.enumerating)
        // connect: lines carry ms from here, so Help > Export Log shows where
        // a connect spent its time.
        let t0 = Date()
        let log: @Sendable (String) -> Void = { line in
            let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
            CameraLog.connection.info("connect: t+\(ms, privacy: .public) ms \(line, privacy: .public)")
        }

        // Attempt 1 is CameraSession.open alone, with no helper kill and no
        // eject. It usually wins, so a clean connect never disturbs the
        // camera. Attempt 2 first kills ptpcamerad, and attempt 3 also ejects
        // the body through ImageCaptureCore (ICDeviceClaim). A retry follows
        // only a code `isRecoverable` accepts: usbClaimDenied, -53, -105 or -52.
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                CameraLog.connection.info("retry attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public): killing ptpcamerad")
                ICDeviceClaim.killPTPCameraHelper()
                if attempt >= 3 {
                    CameraLog.connection.info("attempt \(attempt, privacy: .public): also ICDevice eject")
                    await ICDeviceClaim.releaseCanonEos()
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            do {
                log("attempt \(attempt): opening session")
                let s = try CameraSession()
                // The app never lets open reset the USB (`appUSBReset`), so
                // its recovery is the soft retry only.
                try await s.open(recover: resetAllowed, usbReset: CameraConnection.appUSBReset)
                log("attempt \(attempt): gp_camera_init returned, firmware \(s.firmware ?? "unread")")
                // Ready only once the body has answered a config read.
                // Otherwise a first GetEvent that never comes back would leave
                // the app at Ready with dashes for minutes.
                let box = SessionBox(s)
                switch await firstConfigUnderBudget(box, log: log) {
                case .answered:
                    self.session = box.get()
                    stallHistory.ready()
                    log("ready")
                    transition(.ready)
                case .failed(let err, _):
                    box.get()?.close()
                    log("first config read failed, not ready: \(err)")
                    transition(.error(err as? CameraError ?? .unexpected(String(describing: err))))
                case .notAnswering:
                    // Reached only once the camera thread comes free, which on a
                    // body that stopped answering is its power cycle. The advice
                    // went out when the ladder ran out. The next presence poll
                    // after the power cycle connects afresh.
                    box.get()?.close()
                    self.session = nil
                    log("camera thread free again after a stall")
                    // The same error the advice went out with.
                    transition(.error(stallHistory.lastStall ?? .notAnswering(stage: CameraConnection.firstConfigStage)))
                }
                return
            } catch let err as CameraError {
                lastError = err
                if CameraConnection.isClaim(err) { claimSeenInSeries.set() }
                let isRecoverable: Bool = {
                    if case .usbClaimDenied = err { return true }
                    if case .libGPhoto(let code, _) = err {
                        // -53 IO_USB_CLAIM, -105 MODEL_NOT_FOUND (half-claimed), -52 IO_USB_FIND
                        return code == -53 || code == -105 || code == -52
                    }
                    return false
                }()
                if isRecoverable && attempt < maxAttempts {
                    // Back-off grows 0.5 s per attempt: 0.5 s after attempt 1,
                    // 1 s after attempt 2. The last attempt does not wait.
                    let backoffMs = attempt * 500
                    CameraLog.connection.error("attempt \(attempt, privacy: .public): \(err.localizedDescription, privacy: .public), backing off \(backoffMs, privacy: .public)ms before retry")
                    try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                    continue
                }
                CameraLog.connection.error("connect failed (CameraError, final): \(err.localizedDescription, privacy: .public)")
                transition(.error(err))
                return
            } catch {
                lastError = error
                CameraLog.connection.error("connect failed (other, final): \(String(describing: error), privacy: .public)")
                transition(.error(.unexpected(String(describing: error))))
                return
            }
        }
        let final = (lastError as? CameraError)
            ?? .unexpected(lastError.map { String(describing: $0) } ?? "unknown")
        transition(.error(final))
    }

    private func transition(_ new: ConnectionState) {
        if new == self.lastState { return }
        let prev = self.lastState
        CameraLog.connection.info("state: \(String(describing: prev), privacy: .public) → \(String(describing: new), privacy: .public)")
        self.lastState = new
        self.continuation.yield(new)
    }
}

/// The session a connect is working on. The stall ladder's closures read it
/// from other tasks, so it is read under a lock.
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CameraSession?
    init(_ s: CameraSession?) { session = s }
    func get() -> CameraSession? { lock.lock(); defer { lock.unlock() }; return session }
}

/// A lock-guarded flag, set and read from any thread.
public final class StallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func set() { lock.lock(); value = true; lock.unlock() }
    public func clear() { lock.lock(); value = false; lock.unlock() }
}
