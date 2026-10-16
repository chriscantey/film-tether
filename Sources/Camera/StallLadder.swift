import Foundation

// A budget on the two camera calls that can hang with no timeout: the first
// gp_camera_get_config after gp_camera_init, and the live-view start.
//
// Without it, the app on a fresh 7D can sit in AppModel.refreshSnapshot for
// over three minutes, inside gp_camera_get_config, ptp_check_eos_events,
// ptp_canon_eos_getevent and libusb_bulk_transfer, with the UI at Ready and
// dashes. Nothing on that path has a timeout of its own, so the app looks
// connected and never is.
//
// The app's ladder (`StallLadder.app`), one run per call:
//   1. The call runs on the camera actor. A timer off the camera thread
//      watches it for `budget` seconds (45: slow first reads that did
//      answer were sampled past 30 s on the 7D, so 20 cut good starts short).
//   2. On an overrun, close the stuck session first, from off the camera
//      thread: libgphoto2 defers the exit behind the call in flight and runs
//      it when that call returns, so no half-closed transaction is left
//      behind. Then advice ("the camera is not answering, turn it off and
//      on"), never a silent Ready. The stuck call returns when the camera is
//      power cycled.
//
// The ladder never resets the USB. On a 7D the in-process re-enumeration
// returned -4 six times in six, and after the first of them every cold
// session stalled, across camera power cycles, until the Mac was restarted.
// The reset at open is refused the same way (CameraSession.initRecoveryPlan).
//
// The live-view ladder holds the presence poll for its whole run
// (CameraConnection.pollHold), so no poll connects or disconnects while it
// owns the session. The app keeps running and may need the ladder again, so
// the close is per session (`CameraSession.closeFromWatchdog`).
//
// Pure except for the injected I/O, so the order (close first, then advice)
// is tested with no body attached (StallLadderTests).

/// What a run does after each overrun. A value, so the tests read it directly.
public struct StallLadder: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Exit the stuck session from off the camera thread.
        case close
        /// Tell the user the camera is not answering.
        case advise
    }

    /// Slow but successful first reads ran past 30 s, so the budget is 45.
    /// Under `.app` the card lands at about 45 s.
    public static let defaultBudget: Double = 45
    /// The app's ladder: a stall is close, then advice (see the header).
    public static let app = StallLadder()

    /// Seconds the call gets, each attempt.
    public let budget: Double
    public private(set) var overruns = 0

    public init(budget: Double = StallLadder.defaultBudget) {
        self.budget = budget
    }

    /// The steps for the overrun that just happened. Close always comes
    /// first.
    public mutating func overran() -> [Step] {
        overruns += 1
        return [.close, .advise]
    }

}

/// Where a run has got to, for the status line's wait glyph (CameraWait).
public enum StallProgress: Equatable, Sendable {
    /// Attempt `n` has started under its budget.
    case attempt(Int)
    /// The run has ended, however it ended.
    case finished
}

/// The ladder's hands. Closures, so the connection, the app and the tests
/// each supply their own.
public struct StallIO: Sendable {
    /// The budgeted call, given its attempt number.
    public var attempt: @Sendable (_ n: Int) async throws -> Void
    /// Close the stuck session from off the camera thread. Never waits for
    /// the camera thread. Returns what it did, for the log.
    public var close: @Sendable () -> String
    /// Show "the camera is not answering". Called from off the camera
    /// thread, which may still be stuck.
    public var advise: @Sendable () -> Void
    /// One log line, without its prefix or timestamp.
    public var log: @Sendable (_ line: String) -> Void
    /// Where the run has got to. Called from off the camera thread, in order.
    public var progress: @Sendable (_ p: StallProgress) -> Void

    public init(attempt: @escaping @Sendable (_ n: Int) async throws -> Void,
                close: @escaping @Sendable () -> String,
                advise: @escaping @Sendable () -> Void,
                log: @escaping @Sendable (_ line: String) -> Void,
                progress: @escaping @Sendable (_ p: StallProgress) -> Void = { _ in }) {
        self.attempt = attempt; self.close = close
        self.advise = advise; self.log = log
        self.progress = progress
    }
}

/// How a run ended.
public enum StallOutcome: Sendable {
    /// The call returned inside its budget on attempt `attempt`.
    case answered(attempt: Int)
    /// The call returned an error inside its budget. Not a
    /// stall: the caller reports it the way it reports any camera error.
    case failed(Error, attempt: Int)
    /// The ladder ran out. Advice has already been shown.
    case notAnswering(attempts: Int)

    public var answered: Bool { if case .answered = self { return true }; return false }
}

public enum StallGuard {
    /// Run `io.attempt` under the ladder. Never throws and never waits on a
    /// stuck call: an overrun is decided by a timer off the camera thread,
    /// and a stuck call's late result, whenever it comes, is dropped.
    public static func run(stage: String, ladder: StallLadder = .app, io: StallIO) async -> StallOutcome {
        var ladder = ladder
        let t0 = Date()
        func ms() -> Int { Int((Date().timeIntervalSince(t0) * 1000).rounded()) }
        // Every return below, answered, failed or advised, clears the glyph.
        defer { io.progress(.finished) }
        io.progress(.attempt(1))
        io.log("\(stage) attempt 1 at \(ms()) ms, budget \(seconds(ladder.budget)) s")
        switch await timed(ladder.budget, { try await io.attempt(1) }) {
        case .returned(nil):
            io.log("\(stage) answered on attempt 1 at \(ms()) ms")
            return .answered(attempt: 1)
        case .returned(let error?):
            io.log("\(stage) failed on attempt 1 at \(ms()) ms: \(error)")
            return .failed(error, attempt: 1)
        case .overran:
            io.log("\(stage) attempt 1 overran its \(seconds(ladder.budget)) s budget at \(ms()) ms")
        }
        perform(ladder.overran(), stage: stage, io: io, ms: ms)
        return .notAnswering(attempts: 1)
    }

    /// Runs the steps in order: the close, then the advice.
    private static func perform(_ steps: [StallLadder.Step], stage: String, io: StallIO, ms: () -> Int) {
        for step in steps {
            switch step {
            case .close:
                let what = io.close()
                io.log("\(stage) close requested at \(ms()) ms: \(what)")
            case .advise:
                io.log("\(stage) not answering after \(ms()) ms, advising a power cycle")
                io.advise()
            }
        }
    }

    private static func seconds(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(s)
    }

    enum Timed: Sendable {
        /// The call came back inside the budget: nil for success.
        case returned(Error?)
        case overran
    }

    /// Race `work` against a timer on a dispatch queue, never against
    /// anything that needs the camera thread. The loser is dropped: a call
    /// that comes back after the budget finds the result already decided.
    static func timed(_ budget: Double, _ work: @escaping @Sendable () async throws -> Void) async -> Timed {
        let box = FirstResult()
        Task {
            do { try await work(); box.finish(.returned(nil)) }
            catch { box.finish(.returned(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, budget)) { box.finish(.overran) }
        return await box.value()
    }

    /// Resolved once, by whichever side gets there first.
    final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Timed?
        private var waiter: CheckedContinuation<Timed, Never>?

        func finish(_ r: Timed) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = r
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: r)
        }

        func value() async -> Timed {
            await withCheckedContinuation { (c: CheckedContinuation<Timed, Never>) in
                lock.lock()
                if let r = result { lock.unlock(); c.resume(returning: r); return }
                waiter = c
                lock.unlock()
            }
        }
    }
}
