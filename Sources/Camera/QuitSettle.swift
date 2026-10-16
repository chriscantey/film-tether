import Foundation
import CGPhoto2

/// When to stop draining the body's event queue after the quit-path EVF
/// teardown.
///
/// Quitting with live view on and no drain runs `gp_camera_exit`
/// milliseconds after the `output=TFT` write, while the body is still
/// leaving EVF and emitting its property-change burst. Over 16 rolls of use
/// that quit dropped the mirror, and on relaunch live view would not start
/// until the battery came out. The UI Stop path, which sends the same
/// teardown writes and keeps the session open, never wedged over the same
/// use. So quit drains until the burst goes quiet, capped, before it closes
/// the session.
public struct QuietWindow: Sendable {
    public enum Verdict: Equatable, Sendable {
        case keepDraining
        /// No event for `quietMs`, measured from the later of the start and
        /// the last event, so a burst that begins late is still waited for.
        case quiet
        /// `capMs` elapsed before the window went quiet.
        case capped
        /// `gp_camera_wait_for_event` itself failed. The readback is skipped
        /// then, since a body that fails a 50 ms event poll will not answer a
        /// config read quickly either, and quit must reach `gp_camera_exit`.
        case failed
    }

    public let start: Date
    public let quietMs: Int
    public let capMs: Int
    public private(set) var lastEvent: Date?
    public private(set) var events = 0

    public init(start: Date, quietMs: Int = 300, capMs: Int = 1500) {
        self.start = start
        self.quietMs = quietMs
        self.capMs = capMs
    }

    public mutating func noteEvent(at t: Date) {
        lastEvent = t
        events += 1
    }

    public func verdict(at now: Date) -> Verdict {
        if ms(from: start, to: now) >= capMs { return .capped }
        if ms(from: lastEvent ?? start, to: now) >= quietMs { return .quiet }
        return .keepDraining
    }

    public func elapsedMs(at now: Date) -> Int { ms(from: start, to: now) }

    private func ms(from a: Date, to b: Date) -> Int {
        Int((b.timeIntervalSince(a) * 1000).rounded())
    }
}

/// What the body said between the quit-path EVF writes and `gp_camera_exit`.
public struct QuitSettleReport: Sendable {
    public let events: Int
    public let verdict: QuietWindow.Verdict
    public let drainMs: Int
    /// Read back after the drain. nil when the read failed or was skipped.
    public let viewfinder: String?
    public let output: String?
}

extension LiveView {
    /// Drain the EOS event queue until it goes quiet (or the cap), then read
    /// back `viewfinder` and `output`, logging every step. Call after `stop()`
    /// and before the session closes. The app's UI Stop path keeps the
    /// session open and never wedged, so it does not drain.
    public func settleBeforeExit(quietMs: Int = 300, capMs: Int = 1500,
                                 readBack: Bool = true) async -> QuitSettleReport {
        let events = CameraEvents(session: session)
        var window = QuietWindow(start: Date(), quietMs: quietMs, capMs: capMs)
        CameraLog.liveView.info("quit settle: draining events, quiet \(quietMs, privacy: .public) ms, cap \(capMs, privacy: .public) ms")
        var verdict = QuietWindow.Verdict.keepDraining
        while true {
            verdict = window.verdict(at: Date())
            if verdict != .keepDraining { break }
            do {
                let e = try await events.waitOne(timeoutMs: 50)
                if case .timeout = e { continue }
                window.noteEvent(at: Date())
                CameraLog.liveView.info("quit settle: t+\(window.elapsedMs(at: Date()), privacy: .public) ms event \(String(describing: e), privacy: .public)")
            } catch {
                CameraLog.liveView.error("quit settle: t+\(window.elapsedMs(at: Date()), privacy: .public) ms wait failed, stopping the drain: \(String(describing: error), privacy: .public)")
                verdict = .failed
                break
            }
        }
        let drainMs = window.elapsedMs(at: Date())
        CameraLog.liveView.info("quit settle: drain ended \(String(describing: verdict), privacy: .public) after \(drainMs, privacy: .public) ms, \(window.events, privacy: .public) events")
        guard verdict != .failed, readBack else {
            CameraLog.liveView.info("quit settle: readback skipped (\(verdict == .failed ? "drain failed" : "quit deadline", privacy: .public))")
            return QuitSettleReport(events: window.events, verdict: verdict, drainMs: drainMs,
                                    viewfinder: nil, output: nil)
        }
        let (vf, out) = readViewfinderAndOutput()
        CameraLog.liveView.info("quit settle: read back viewfinder=\(vf ?? "unreadable", privacy: .public) output=\(out ?? "unreadable", privacy: .public) at t+\(window.elapsedMs(at: Date()), privacy: .public) ms")
        return QuitSettleReport(events: window.events, verdict: verdict, drainMs: drainMs,
                                viewfinder: vf, output: out)
    }

    /// One `gp_camera_get_config` for both values. On a 7D that call builds
    /// the whole tree, so a lookup per leaf (with the eosviewfinder fallback)
    /// would cost up to three of them at the moment the body is slowest.
    private func readViewfinderAndOutput() -> (String?, String?) {
        guard let cam = try? session.gpCamera(), let ctx = try? session.gpContext() else { return (nil, nil) }
        var root: OpaquePointer? = nil
        guard gp_camera_get_config(cam, &root, ctx) == GP_OK, let root else { return (nil, nil) }
        defer { gp_widget_unref(root) }
        func child(_ name: String) -> OpaquePointer? {
            var leaf: OpaquePointer? = nil
            let rc = name.withCString { gp_widget_get_child_by_name(root, $0, &leaf) }
            return rc == GP_OK ? leaf : nil
        }
        let vf = (child("viewfinder") ?? child("eosviewfinder"))
            .flatMap { try? WidgetHelpers.readToggle($0) }.map { String($0) }
        let out = child("output").flatMap { try? WidgetHelpers.readString($0) }
        return (vf, out)
    }
}
