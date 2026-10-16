import Foundation

// The app's autofocus button. On a 7D this sequence (`AFSequence.s2`)
// focused 20 times in 20 with no wedge:
//
//   AfCancel (clears any half-press latch left from before)
//   DoAf
//   read events, one consumer, until the first FlashChargingState (d1c0)
//     change after DoAf, about 2.5 s in, or the 6 s cap
//   AfCancel (required: without it the body latches the half press and
//     ignores every later DoAf and every manual step)
//
// The closing cancel must come after the marker: on the 7D a cancel at
// 1.5 s, before the marker, aborted the drive, and 2 of 20 tries focused.
// The 7D never sends Focus Info or AfResult and refuses the OLC request, so
// d1c0 is the done marker. A Focus Info or AfResult still ends the wait.
//
// Apart from `CameraAFIO`, this file is free of libgphoto2, so the state
// machine is tested without a body. Each write goes out once, with no -110
// retry.

public enum AppAutofocus {
    public static let sequence: AFSequence = .s2
    public static let marker: AFCompletionRule = .d1c0
    /// The fallback cap on the completion wait.
    public static let capMs = AFSequence.completionTimeoutMs

    /// A sharpness rise must beat this fraction of the before score to count
    /// as confirmed. The measured noise floor at a parked focus (n=10) is a
    /// spread of 44.7 on a mean of 341.8, 13%. A change inside that is not
    /// evidence either way.
    public static let confirmRise = 0.15
    /// The rise must also clear this absolute amount, so two near-zero scores
    /// of a blank frame cannot confirm on a rounding difference.
    public static let confirmMinDelta = 1.0

    /// True when the body reports its focus mode as Manual, which on an EOS
    /// body is the lens switch set to MF. Autofocus and the six step buttons
    /// both need the switch on AF. Unknown (nil, or not yet read) is not
    /// blocked: the gate only closes on a reading that says Manual.
    public static func blockedByLensSwitch(focusMode: String?) -> Bool {
        guard let m = focusMode?.trimmingCharacters(in: .whitespaces) else { return false }
        return m.lowercased().hasPrefix("manual")
    }

    /// The AF key: slash, beside the comma and period focus keys. `chars` is
    /// `charactersIgnoringModifiers`, which still applies Shift, so while
    /// Shift holds the momentary punch-in the same key arrives as `?`.
    /// Command is left to the menus.
    public static func isAutofocusKey(_ chars: String, command: Bool) -> Bool {
        !command && (chars == "/" || chars == "?")
    }

    /// How the completion wait ended.
    public enum Completion: String, Equatable, Sendable {
        /// The d1c0 marker.
        case marker
        /// A Focus Info or AfResult event, which the 7D never sends.
        case focusEvent
        /// The 6 s cap. Not a failure: the closing cancel still goes out
        /// after it, and the sharpness check says whether the lens moved.
        case timeout
    }

    public struct Outcome: Equatable, Sendable {
        public let trace: AFTrialTrace

        /// nil when a write or an event read failed before the wait ended.
        public var completion: Completion? {
            guard let c = trace.completion else { return nil }
            if c == AppAutofocus.marker.rawValue { return .marker }
            if c == "event" { return .focusEvent }
            if c == "timeout" { return .timeout }
            return nil
        }

        /// The DoAf, an event read, or the closing cancel failed. A failed
        /// leading cancel is not one: a body with nothing latched may refuse it.
        public var failed: Bool { trace.error != nil || trace.cleanupError != nil }

        /// The body started driving the lens. The lock marker says so, and so
        /// does the drive property: on every app run measured that drove, the
        /// body reported d1b7 700 to 1150 ms after DoAf, and on every run that
        /// did not drive it reported nothing but d1c3.
        public var bodyDrove: Bool {
            if completion == .marker || completion == .focusEvent { return true }
            return trace.events.contains { AppAutofocus.isDriveEvent($0.text) }
        }
    }

    /// The property the 7D changes when its autofocus drive starts.
    public static let driveProperty = "d1b7"

    public static func isDriveEvent(_ text: String) -> Bool {
        text.contains("Property \(driveProperty)") || text.hasPrefix("Focus Points")
    }

    /// Run the sequence once. Never throws. A failed main step or cleanup
    /// write is in the trace.
    /// The caller pauses the live-view loop first, so this is the only reader
    /// of camera events while it runs.
    public static func run(io: AFProbeIO, pollMs: Int = 50) async -> Outcome {
        Outcome(trace: await AFTrialRunner.run(sequence, io: io, completion: marker, pollMs: pollMs))
    }

    /// One `af:` log line per write, event and ending, for Help > Export Log.
    /// Write and event lines carry their ms from the start of the run.
    public static func logLines(_ o: Outcome) -> [String] {
        var items: [(ms: Int, order: Int, line: String)] = []
        for (i, c) in o.trace.commands.enumerated() {
            let result = c.error.map { "FAILED: \($0)" } ?? "ok"
            items.append((c.ms, i, "af: \(c.widget)=\(c.value) at \(c.ms) ms, back at \(c.endMs) ms, \(result)"))
        }
        for (i, e) in o.trace.events.enumerated() {
            items.append((e.ms, 1000 + i, "af: event at \(e.ms) ms: \(e.text)"))
        }
        var lines = items.sorted { ($0.ms, $0.order) < ($1.ms, $1.order) }.map { $0.line }
        switch o.completion {
        case .marker?:
            lines.append("af: done by \(marker.rawValue) at \(o.trace.completionMs ?? -1) ms")
        case .focusEvent?:
            lines.append("af: done by focus event at \(o.trace.completionMs ?? -1) ms: \(o.trace.completionEvent ?? "")")
        case .timeout?:
            lines.append("af: no \(marker.rawValue) marker within \(capMs) ms, closing cancel sent at the cap")
        case nil:
            break
        }
        if let e = o.trace.error { lines.append("af: stopped: \(e)") }
        if let e = o.trace.cleanupError { lines.append("af: closing cancel FAILED: \(e)") }
        lines.append("af: finished in \(o.trace.elapsedMs) ms")
        return lines
    }

    /// The glyph on the AF button after a run. Both results that are not a
    /// confirmation carry CameraAdvice.
    public enum Result: Equatable, Sendable {
        /// Sharpness rose past the noise floor, or the body locked on a frame
        /// that was already sharp (`heldFocus`).
        case confirmed
        /// It did not, or the run could not be judged (see `NotConfirmedReason`).
        case notConfirmed(CameraAdvice)
        /// A write or event read failed, and the advice is what the icon says.
        case failed(CameraAdvice)

        public var isConfirmed: Bool { self == .confirmed }
        public var advice: CameraAdvice? {
            switch self {
            case .confirmed: return nil
            case .notConfirmed(let a), .failed(let a): return a
            }
        }
    }

    /// Why a run was not confirmed, for the detail behind the icon.
    public enum NotConfirmedReason: Equatable, Sendable {
        /// Both frames scored, and neither a rise past `confirmRise` nor
        /// `heldFocus` confirmed the run.
        case flat(before: Double, after: Double)
        /// A before or an after frame was missing or would not decode.
        case nothingToMeasure
        /// No live-view frame arrived to score after the run.
        case noFrame(waitSeconds: Int)
        /// The zoom changed during the run, so the two frames do not compare.
        case zoomChanged
        /// The body took DoAf and never started driving.
        case noDrive
    }

    public static func notConfirmed(_ reason: NotConfirmedReason) -> Result {
        let detail: String
        switch reason {
        case .flat(let b, let a):
            detail = String(format: "sharpness %.1f before, %.1f after, a rise under the %ld%% noise floor",
                            b, a, Int((confirmRise * 100).rounded()))
        case .nothingToMeasure:
            detail = "no before or after frame to score"
        case .noFrame(let s):
            detail = "no live view frame within \(s) s after the run"
        case .zoomChanged:
            detail = "the zoom changed during the run, so the frames do not compare"
        case .noDrive:
            return .notConfirmed(CameraAdvice(message: CameraAdvice.autofocusNoDriveMessage,
                                              hint: CameraAdvice.autofocusNoDriveHint,
                                              detail: "the camera accepted the autofocus command and did not start driving the lens (no drive event, no lock within \(capMs / 1000) s)"))
        }
        return .notConfirmed(CameraAdvice.autofocusNotConfirmed(detail: detail))
    }

    /// A before score at or above this means the frame was already in
    /// focus when AF was pressed. Every measured defocused live-view frame
    /// scored 2.5 to 4.7 (six and two far-large steps, fit zoom). A focused
    /// frame scored 342 to 737 at fit and 50.9 at the 5x punch-in, so 15 sits
    /// three times over the highest blank score and three times under the
    /// lowest sharp one.
    public static let alreadySharpScore = 15.0

    /// Confirmed when both scores exist and the after score beats the before
    /// one by more than the noise floor. Also confirmed, with no rise, when the
    /// body reported its lock (`markerArrived`), the before frame was already
    /// sharp, and the after frame did not fall past the noise floor: pressing
    /// AF on a focused frame locks again and changes nothing, and that is a
    /// confirmation, not a miss.
    public static func verdict(before: Double?, after: Double?, markerArrived: Bool = false) -> Result {
        guard let before, let after else { return notConfirmed(.nothingToMeasure) }
        let delta = after - before
        if delta > Swift.max(before * confirmRise, confirmMinDelta) { return .confirmed }
        if heldFocus(before: before, after: after, markerArrived: markerArrived) { return .confirmed }
        return notConfirmed(.flat(before: before, after: after))
    }

    /// The verdict, then the no-drive case: a run where the body never drove,
    /// and whose frames do not confirm either, says so rather than giving the
    /// verdict's reason.
    public static func conclusion(before: Double?, after: Double?, markerArrived: Bool,
                                  bodyDrove: Bool) -> Result {
        let v = verdict(before: before, after: after, markerArrived: markerArrived)
        if !v.isConfirmed && !bodyDrove { return notConfirmed(.noDrive) }
        return v
    }

    /// The already-sharp case on its own, for the log line: the body locked on
    /// a frame that was already sharp and it stayed sharp.
    public static func heldFocus(before: Double, after: Double, markerArrived: Bool) -> Bool {
        markerArrived && before >= alreadySharpScore && after >= before * (1 - confirmRise)
    }
}

/// libgphoto2 through the Camera module, for the app's autofocus. Toggles
/// go out through `writeToggle` (no -110 retry), events come one at a time
/// from `CameraEvents.waitOne`.
@CameraActor
public final class CameraAFIO: AFProbeIO {
    let props: CameraProperties
    let events: CameraEvents
    let start = Date()
    private var doAfSent = false

    /// The first write or event-read error, kept as the real error so the
    /// app can map it through `CameraAdvice` (the trace keeps only text).
    /// The leading cancel's refusal is not kept: the sequence treats it as
    /// best effort.
    public private(set) var firstError: Error?
    /// Every event this run read, in order. The run is the only reader while
    /// it lasts, so the app replays these into its snapshot afterwards.
    public private(set) var seen: [CameraEvents.Event] = []

    public init(props: CameraProperties, events: CameraEvents) {
        self.props = props
        self.events = events
    }

    public func write(_ w: AFWidgetWrite) async throws {
        let isLeadingCancel = w == .afCancel && !doAfSent
        if w == .doAf { doAfSent = true }
        do {
            switch w {
            case .toggle(let name, let value):
                try await props.writeToggle(name, value: value)
            case .text(let name, let value):
                try await props.setString(name, value: value, retryInProgress: false)
            }
        } catch {
            if !isLeadingCancel { record(error) }
            throw error
        }
    }

    public func nextEvent(timeoutMs: Int) async throws -> String? {
        do {
            let e = try await events.waitOne(timeoutMs: Int32(Swift.max(1, timeoutMs)))
            if e != .timeout { seen.append(e) }
            return CameraAFIO.text(e)
        } catch {
            record(error)
            throw error
        }
    }

    public nonisolated func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private func record(_ error: Error) {
        if firstError == nil { firstError = error }
    }

    /// An event as the text the trace records, or nil for a timeout.
    public nonisolated static func text(_ e: CameraEvents.Event) -> String? {
        switch e {
        case .timeout: return nil
        case .propertyChanged(_, _, let raw): return raw
        case .unknown(let raw): return raw
        case .fileAdded(let folder, let name): return "FILE_ADDED \(folder)/\(name)"
        case .captureComplete: return "CAPTURE_COMPLETE"
        }
    }
}
