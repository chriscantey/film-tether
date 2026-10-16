import Foundation

// The autofocus sequence, the pure half. Everything here is free of
// libgphoto2 so the sequence state machine is testable without a body. The
// app's autofocus (AppAutofocus.swift) runs S2 from here.
//
// Widget semantics, re-derived from camlibs/ptp2/config.c at the 2.5.33 tag:
//   autofocusdrive=1          → DoAf (0x9154), then ptp_check_eos_events
//   cancelautofocus=1         → AfCancel (0x9160), then ptp_check_eos_events
//   autofocusdrive=0          → AfCancel as well
//   eosremoterelease=Press Half   → RemoteReleaseOn(1, 1): half press, AF disabled
//   eosremoterelease=Release Half → RemoteReleaseOff(1), the same as Release 1
// The second RemoteReleaseOn parameter is "1 -> disabled AF" (library.c:6059).
//
// Whether a 7D honors that AF-disabled flag when C.Fn IV-1 is at its default
// (where a half press of the shutter button starts AF) has not been measured.
// LiveView.start and CameraCapture.capture send Press Half and treat an AF
// drive as possible, because a 7D at that setting has wedged with the
// live-view meter kick in place.
//
// The event drain inside every put queues events in libgphoto2 rather than
// dropping them, so `gp_camera_wait_for_event` still returns them afterwards.

/// One widget write on the wire.
public enum AFWidgetWrite: Equatable, Sendable {
    case toggle(name: String, value: Int32)
    case text(name: String, value: String)

    public var widget: String {
        switch self {
        case .toggle(let n, _), .text(let n, _): return n
        }
    }

    public var valueString: String {
        switch self {
        case .toggle(_, let v): return String(v)
        case .text(_, let v): return v
        }
    }

    public static let doAf = AFWidgetWrite.toggle(name: "autofocusdrive", value: 1)
    public static let afCancel = AFWidgetWrite.toggle(name: "cancelautofocus", value: 1)
}

public enum AFStep: Equatable, Sendable {
    /// Send one widget write. A failure stops the main steps (cleanup still runs).
    case write(AFWidgetWrite)
    /// Send one widget write whose failure is recorded and does not stop the
    /// sequence: the leading "clear a stale latch" cancel, which a body with
    /// nothing latched may refuse.
    case bestEffort(AFWidgetWrite)
    /// Read events until the body says AF finished, or the timeout. The only
    /// step that reacts to what the body says. In focus and AfResult count at
    /// once. Failed counts only after a running record, so a failed record
    /// left over from before the DoAf cannot end the wait.
    case awaitCompletion(timeoutMs: Int)
    /// Read events for a fixed time without reacting to them. Still the one
    /// event consumer, so nothing arriving in the window is lost.
    case collect(ms: Int)
}

/// An autofocus sequence. `steps` and `cleanup` are the whole contract: a
/// sequence sends exactly those widget writes.
public enum AFSequence: String, CaseIterable, Sendable {
    case s2 = "S2"

    public static let completionTimeoutMs = 6000
    /// Read after cleanup when the main steps succeeded, for the post-cancel burst.
    public static let tailMs = 300
    /// Read between the leading cancel and DoAf, so what the cancel caused is
    /// consumed before the DoAf and cannot pass for its completion.
    public static let clearMs = 300

    public var steps: [AFStep] {
        switch self {
        case .s2:
            return [.bestEffort(.afCancel), .collect(ms: Self.clearMs), .write(.doAf),
                    .awaitCompletion(timeoutMs: Self.completionTimeoutMs)]
        }
    }

    /// Steps that run however the main steps end (a thrown write, a timeout),
    /// so the closing cancel is still sent. If that write fails, the trace
    /// records `cleanupError` and the latch may still be held. S2's closing
    /// AfCancel lives here, so a refused DoAf or a failed event read still
    /// sends it.
    public var cleanup: [AFStep] {
        switch self {
        case .s2: return [.write(.afCancel)]
        }
    }

}

/// What an EOS focus event says. libgphoto2 surfaces the OLC focus record as
/// `Focus Info <hex>` (library.c:6810), six bytes as twelve hex digits (the
/// R8 appends a seventh). ptp-pack.c:2446 documents the last two bytes: 00 01
/// AF running, 01 01 in focus, 02 xx failed, 00 00 or 01 00 idle.
/// libgphoto2's capture path tests the same "000000000101" marker
/// (library.c:6074). AfResult (0xc1a3) is not decoded by libgphoto2 and
/// arrives as "unhandled EOS event AfResult (size N)" (ptp-pack.c:2572).
public enum AFFocusSignal: String, Equatable, Sendable {
    case running, inFocus = "in-focus", failed, idle, afResult = "af-result"

    public var isCompletion: Bool {
        switch self {
        case .inFocus, .failed, .afResult: return true
        case .running, .idle: return false
        }
    }

    public static func classify(_ event: String) -> AFFocusSignal? {
        if event.contains("AfResult") { return .afResult }
        guard event.hasPrefix("Focus Info ") else { return nil }
        let hex = event.dropFirst("Focus Info ".count).filter { !$0.isWhitespace }
        guard hex.count >= 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(hex)
        let b5 = String(chars[8..<10]).lowercased()
        let b6 = String(chars[10..<12]).lowercased()
        switch (b5, b6) {
        case ("01", "01"): return .inFocus
        case ("02", _): return .failed
        case ("00", "01"): return .running
        default: return .idle
        }
    }
}

/// A property-change event as libgphoto2 2.5.33 prints it for an EOS body:
/// `PTP Property d1c0 changed, "flashcharged" to "0"` when the property has
/// a widget, the bare `PTP Property d1b7 changed` when it has none.
public enum AFPropertyEvent {
    /// The four hex digits of the property id, lowercased, or nil for any
    /// other event.
    public static func propID(_ text: String) -> String? {
        let prefix = "PTP Property "
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let id = rest.prefix(while: \.isHexDigit)
        guard id.count == 4, rest.dropFirst(4).hasPrefix(" changed") else { return nil }
        return id.lowercased()
    }
}

/// What ends S2's completion wait on a body that never
/// reports focus. The 7D answers OLC as unsupported and sends neither Focus
/// Info nor AfResult, so under `.timeout` S2 always runs to its 6 s cap. Its
/// timeline after DoAf, the same over 20 runs of S2: ExposureSimMode d1b7
/// plus OneShotRawOn d1c3 at about 0.65 s as AF starts, then
/// FlashChargingState d1c0 at about 2.5 s and a second d1b7 at about 2.8 s
/// as AF ends. Focus Info and AfResult still end the wait under every rule,
/// and the 6 s cap stays as the fallback.
public enum AFCompletionRule: String, CaseIterable, Sendable {
    /// Only a focus event or the cap. The runner's default.
    case timeout
    /// The first FlashChargingState (d1c0) change after DoAf.
    case d1c0
}

/// Feeds on the events read after DoAf, in order, and says which one
/// completes the wait under its rule.
public struct AFCompletionMatcher: Sendable {
    public let rule: AFCompletionRule

    public init(rule: AFCompletionRule) { self.rule = rule }

    /// True for an event that completes under the rule: any d1c0 under
    /// `.d1c0`. Never true under `.timeout`.
    public mutating func feed(_ text: String) -> Bool {
        guard let id = AFPropertyEvent.propID(text) else { return false }
        switch rule {
        case .timeout:
            return false
        case .d1c0:
            return id == "d1c0"
        }
    }
}

/// The I/O a trial needs.
public protocol AFProbeIO: AnyObject {
    func write(_ w: AFWidgetWrite) async throws
    /// One event, or nil when `timeoutMs` passed with none.
    func nextEvent(timeoutMs: Int) async throws -> String?
    /// Milliseconds since the trial started.
    func elapsedMs() -> Int
}

public struct AFEventRecord: Equatable, Sendable {
    /// When the runner read the event. libgphoto2 drains events inside every
    /// widget put, so an event can arrive during a write and be read just
    /// after it returns.
    public let ms: Int
    public let text: String
    public let signal: AFFocusSignal?

    public init(ms: Int, text: String, signal: AFFocusSignal?) {
        self.ms = ms; self.text = text; self.signal = signal
    }
}

public struct AFCommandRecord: Equatable, Sendable {
    /// The write started (ms) and returned (endMs). A put can take a few
    /// hundred ms, since each one resolves the widget through a config read.
    public let ms: Int
    public let endMs: Int
    public let widget: String
    public let value: String
    /// nil on success, the error text otherwise.
    public let error: String?
    public let cleanup: Bool

    public init(ms: Int, endMs: Int, widget: String, value: String, error: String?, cleanup: Bool) {
        self.ms = ms; self.endMs = endMs; self.widget = widget; self.value = value
        self.error = error; self.cleanup = cleanup
    }
}


public struct AFTrialTrace: Equatable, Sendable {
    public var commands: [AFCommandRecord] = []
    public var events: [AFEventRecord] = []
    /// "event" (Focus Info or AfResult), the name of the rule that fired
    /// ("d1c0"), or "timeout". nil when no completion wait ended.
    public var completion: String?
    public var completionSignal: AFFocusSignal?
    public var completionMs: Int?
    /// The raw text of the event that ended the wait.
    public var completionEvent: String?
    /// First failure in the main steps. The sequence stops there and runs its
    /// cleanup.
    public var error: String?
    public var cleanupError: String?
    public var elapsedMs = 0

    public init() {}
}

public enum AFTrialRunner {
    /// Run one sequence. Never throws, and the cleanup steps run whatever
    /// happened before them. Write failures and main-step failures land in
    /// the trace. An event-read failure in the tail read is dropped.
    /// - Parameter completion: the rule for an awaitCompletion step.
    public static func run(_ seq: AFSequence, io: AFProbeIO,
                           completion: AFCompletionRule = .timeout,
                           pollMs: Int = 50) async -> AFTrialTrace {
        var trace = AFTrialTrace()
        return await run(seq, io: io, trace: &trace, completion: completion, pollMs: pollMs)
    }


    private static func run(_ seq: AFSequence, io: AFProbeIO, trace: inout AFTrialTrace,
                            completion: AFCompletionRule, pollMs: Int) async -> AFTrialTrace {
        for step in seq.steps {
            do {
                try await perform(step, io: io, trace: &trace, cleanup: false,
                                  completion: completion, pollMs: pollMs)
            } catch {
                trace.error = String(describing: error)
                break
            }
        }
        for step in seq.cleanup {
            do {
                try await perform(step, io: io, trace: &trace, cleanup: true, pollMs: pollMs)
            } catch {
                if trace.cleanupError == nil { trace.cleanupError = String(describing: error) }
            }
        }
        if trace.error == nil {
            try? await collect(ms: AFSequence.tailMs, io: io, trace: &trace, pollMs: pollMs)
        }
        trace.elapsedMs = io.elapsedMs()
        return trace
    }

    static func perform(_ step: AFStep, io: AFProbeIO, trace: inout AFTrialTrace,
                        cleanup: Bool, completion: AFCompletionRule = .timeout,
                        pollMs: Int) async throws {
        switch step {
        case .write(let w):
            try await send(w, io: io, trace: &trace, cleanup: cleanup)
        case .bestEffort(let w):
            try? await send(w, io: io, trace: &trace, cleanup: cleanup)
        case .collect(let ms):
            try await collect(ms: ms, io: io, trace: &trace, pollMs: pollMs)
        case .awaitCompletion(let timeoutMs):
            let start = io.elapsedMs()
            var sawRunning = false
            var matcher = AFCompletionMatcher(rule: completion)
            while true {
                let remaining = timeoutMs - (io.elapsedMs() - start)
                if remaining <= 0 {
                    trace.completion = "timeout"
                    return
                }
                guard let text = try await io.nextEvent(timeoutMs: min(pollMs, remaining)) else { continue }
                let signal = AFFocusSignal.classify(text)
                trace.events.append(AFEventRecord(ms: io.elapsedMs(), text: text, signal: signal))
                if signal == .running { sawRunning = true }
                if let signal, signal.isCompletion, signal != .failed || sawRunning {
                    trace.completion = "event"
                    trace.completionSignal = signal
                    trace.completionMs = io.elapsedMs()
                    trace.completionEvent = text
                    return
                }
                if matcher.feed(text) {
                    trace.completion = completion.rawValue
                    trace.completionMs = io.elapsedMs()
                    trace.completionEvent = text
                    return
                }
            }
        }
    }

    static func send(_ w: AFWidgetWrite, io: AFProbeIO, trace: inout AFTrialTrace,
                     cleanup: Bool) async throws {
        let t = io.elapsedMs()
        do {
            try await io.write(w)
            trace.commands.append(AFCommandRecord(ms: t, endMs: io.elapsedMs(), widget: w.widget,
                                                  value: w.valueString, error: nil, cleanup: cleanup))
        } catch {
            trace.commands.append(AFCommandRecord(ms: t, endMs: io.elapsedMs(), widget: w.widget,
                                                  value: w.valueString, error: String(describing: error),
                                                  cleanup: cleanup))
            throw error
        }
    }

    static func collect(ms: Int, io: AFProbeIO, trace: inout AFTrialTrace, pollMs: Int) async throws {
        let start = io.elapsedMs()
        while true {
            let remaining = ms - (io.elapsedMs() - start)
            if remaining <= 0 { return }
            if let text = try await io.nextEvent(timeoutMs: min(pollMs, remaining)) {
                trace.events.append(AFEventRecord(ms: io.elapsedMs(), text: text,
                                                  signal: AFFocusSignal.classify(text)))
            }
        }
    }
}

