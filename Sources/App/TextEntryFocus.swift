import AppKit

/// Is the user typing into a text field in one of the app's windows? While
/// they are, every bare-key shortcut (the capture key, hold-to-zoom, arrow
/// nudge, focus stepping) stands down so the keys reach the field. Without
/// it, Space in the Camera and Film fields fires a capture and Shift punches
/// in.
///
/// AppKit and SwiftUI text fields edit through the window's field editor,
/// which is an NSText and is the key window's first responder exactly while
/// a field holds the caret, so that is what `isActive` checks.
enum TextEntryFocus {

    /// Live answer. Main thread only.
    @MainActor static var isActive: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    /// Safe from any thread. On the main thread it is the live answer. Off it
    /// (the global event tap runs on its own thread) it is the copy refreshed
    /// by `startTracking()`.
    static func isActiveFromAnyThread() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { isActive }
        }
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Keeps the cross-thread copy current by refreshing it just after every
    /// in-app mouse-down and key press, and when the app activates
    /// or resigns or a window becomes or resigns key. Also ends editing when a
    /// click lands outside any text view. Idempotent.
    @MainActor static func startTracking() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { event in
            // Decided before dispatch, while the view under the pointer is
            // still the one the click was aimed at.
            let clickedAway = event.type != .keyDown
                && MainActor.assumeIsolated { isActive && !hitsTextView(event) }
            // After AppKit has dispatched the event, not before: a click
            // changes the first responder while it is handled.
            DispatchQueue.main.async {
                // AppKit moves the caret only when the clicked view accepts
                // first responder, and a click on the preview, a label or the
                // bar's background does not. Left alone, the field keeps the
                // caret and the shortcuts stay off, so a click away ends editing.
                if clickedAway && isActive {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                refresh()
            }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            })
        }
        refresh()
    }

    /// Hands the keys back to the app. Ends editing in whichever field holds
    /// the caret, then refreshes the cross-thread copy in the same step, so
    /// the shortcuts return on the next key rather than on the next click.
    /// Return and Escape in the row-3 text fields call this. Deferred one
    /// turn of the run loop so the field editor is not torn down inside its
    /// own action, and so this refresh lands after the one the key monitor
    /// queued before the key dispatched.
    @MainActor static func endEditing() {
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
            refresh()
        }
    }

    /// Whether a click lands in a text field or text view, including the
    /// field editor itself. Those keep their own AppKit behavior: clicking
    /// from Camera into Film moves the caret, and a click inside a field
    /// places it. A SwiftUI surface hit-tests to the hosting view, not to a
    /// text view, so it counts as away.
    @MainActor private static func hitsTextView(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        // hitTest takes a point in the receiver's superview's coordinates.
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        var view = content.hitTest(point)
        while let v = view {
            if v is NSText || v is NSTextField || v is NSTextView { return true }
            view = v.superview
        }
        return false
    }

    @MainActor private static func refresh() {
        let now = isActive
        lock.lock(); cached = now; lock.unlock()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached = false
    nonisolated(unsafe) private static var monitor: Any?
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
}
