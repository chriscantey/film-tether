import Foundation
import CGPhoto2

/// Drains libgphoto2's per-camera event queue and parses the text libgphoto2
/// prints for Canon EOS property changes. This is how we learn the body's live
/// metered exposure (Tv) during EVF streaming without polling. The body sends
/// a property change every time the meter recomputes, which libgphoto2 reports
/// as a `PTP Property d102 changed, "shutterspeed" to "1/200"` line.
@CameraActor
public final class CameraEvents {
    /// One libgphoto2 event reduced to the parts we use. The C payloads stay
    /// inside this file, and callers see typed values.
    public enum Event: Sendable, Equatable {
        /// No event during the timeout window, or a FOLDER_ADDED or
        /// FILE_CHANGED event, or a FILE_ADDED with no path, all of which
        /// `waitOne` folds into this case.
        case timeout
        /// New file landed on the camera (Internal RAM or card). Folder + name
        /// are the on-camera path. CameraCapture downloads via gp_camera_file_get.
        case fileAdded(folder: String, name: String)
        /// A Canon property changed. `name` is libgphoto2's widget name (e.g.
        /// "shutterspeed", "iso", "aperture") and `value` is the new value as a
        /// string, nil when the line carries no quoted value. The parser never
        /// produces a nil `name`: a property libgphoto2 has no name for arrives
        /// as a bare `PTP Property d1b7 changed` line and comes out as
        /// `.unknown(raw:)`.
        case propertyChanged(name: String?, value: String?, raw: String)
        /// libgphoto2 fired GP_EVENT_CAPTURE_COMPLETE. The capture drain
        /// treats it as activity, not as the end of the shot.
        case captureComplete
        /// Anything we couldn't parse, kept so debug logs are honest.
        case unknown(raw: String)
    }

    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    /// Block on `gp_camera_wait_for_event` for up to `timeoutMs` milliseconds,
    /// return the first event that arrives (or `.timeout`). Safe to call in a
    /// tight loop, because libgphoto2 paces the underlying USB poll.
    ///
    /// This is intentionally a *single* event per call. The body emits dozens
    /// of property events per second during EVF, and keeping the loop in
    /// Swift land lets the actor yield between events.
    public func waitOne(timeoutMs: Int32) async throws -> Event {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()

        var eventType = CameraEventType(rawValue: 0)
        var eventData: UnsafeMutableRawPointer? = nil
        let rc = gp_camera_wait_for_event(cam, timeoutMs, &eventType, &eventData, ctx)
        if rc != GP_OK {
            // Bubble the error so the caller can decide whether to back off or
            // tear down. Most non-OK returns on this call mean the session
            // died (e.g. body powered off mid-stream), and the caller stops.
            throw CameraError.libGPhoto(
                code: rc,
                message: "gp_camera_wait_for_event failed (rc \(rc))"
            )
        }

        switch eventType {
        case GP_EVENT_TIMEOUT:
            return .timeout

        case GP_EVENT_FILE_ADDED:
            guard let raw = eventData else { return .timeout }
            // libgphoto2 hands us an allocated CameraFilePath* whose memory we
            // own. Copy folder + name into Swift, free the struct, return.
            let path = raw.assumingMemoryBound(to: CameraFilePath.self).pointee
            let folder = Self.cArrayToString(path.folder)
            let name = Self.cArrayToString(path.name)
            free(raw)
            return .fileAdded(folder: folder, name: name)

        case GP_EVENT_CAPTURE_COMPLETE:
            if eventData != nil { free(eventData) }
            return .captureComplete

        case GP_EVENT_UNKNOWN:
            guard let raw = eventData else { return .unknown(raw: "") }
            let s = String(cString: raw.assumingMemoryBound(to: CChar.self))
            free(raw)
            if let (name, value) = Self.parseUnknownPropertyChange(s) {
                return .propertyChanged(name: name, value: value, raw: s)
            }
            return .unknown(raw: s)

        case GP_EVENT_FOLDER_ADDED, GP_EVENT_FILE_CHANGED:
            // No flow uses either. Folder-added is the camera creating a new
            // DCIM subdir, and file-changed is metadata-only. Both come back
            // as .timeout, so drain() stops on them and the capture's
            // companion-file wait counts them as an empty poll.
            if eventData != nil { free(eventData) }
            return .timeout

        default:
            if eventData != nil { free(eventData) }
            return .unknown(raw: "type=\(eventType.rawValue)")
        }
    }

    /// Read queued events with a per-call timeout, up to `budgetMs`
    /// wall-clock milliseconds total, stopping at the first `.timeout`.
    /// Returns the events in arrival order, empty if none were queued.
    public func drain(budgetMs: Int, perCallMs: Int32 = 50) async -> [Event] {
        let deadline = Date().addingTimeInterval(TimeInterval(budgetMs) / 1000.0)
        var out: [Event] = []
        while Date() < deadline {
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000.0))
            let thisCall = min(perCallMs, remaining > 0 ? remaining : 1)
            do {
                let e = try await waitOne(timeoutMs: thisCall)
                if case .timeout = e { break }
                out.append(e)
            } catch {
                // A session error inside drain: stop here.
                break
            }
        }
        return out
    }

    // MARK: - Parsing

    /// libgphoto2 reports EOS property changes as unknown-event text like:
    ///   `PTP Property d102 changed, "shutterspeed" to "1/200"`
    ///   `PTP Property d101 changed`
    /// Return (name, value) when both are present, (name, nil) when libgphoto2
    /// resolved the property name but the value didn't quote, and nil when the
    /// whole line is something else (Focus Points, CTGInfoCheckComplete, …).
    static func parseUnknownPropertyChange(_ s: String) -> (String, String?)? {
        guard s.contains("PTP Property") else { return nil }
        // The name is the text between the first quote and `" to "`.
        if let quoteRange = s.range(of: "\""),
           let afterFirst = s.range(of: "\" to \"") {
            let nameStart = quoteRange.upperBound
            let nameEnd = afterFirst.lowerBound
            guard nameStart < nameEnd else { return nil }
            let name = String(s[nameStart..<nameEnd])
            let valueStart = afterFirst.upperBound
            guard let closing = s.range(of: "\"", range: valueStart..<s.endIndex) else {
                return (name, nil)
            }
            let value = String(s[valueStart..<closing.lowerBound])
            return (name, value)
        }
        // Otherwise `"name" changed`, name only, no value.
        if let first = s.range(of: "\""),
           let second = s.range(of: "\"", range: first.upperBound..<s.endIndex) {
            let name = String(s[first.upperBound..<second.lowerBound])
            return (name, nil)
        }
        return nil
    }

    /// libgphoto2 fixed-size char arrays surface in Swift as tuples of
    /// (CChar, CChar, …). Decode via raw memory, same trick CameraCapture
    /// uses for filePath.folder / filePath.name.
    private static func cArrayToString<T>(_ tuple: T) -> String {
        return withUnsafePointer(to: tuple) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
    }
}
