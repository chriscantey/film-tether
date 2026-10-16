import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox   // kVK_* constants

/// Hold-to-zoom hotkey monitor for the focus-check feature. It emits `.pressed`
/// and `.released` around a hold of the trigger. The app punches in to 5x on
/// press and restores the zoom from before the hold on release. The trigger is
/// either a keyCode or a bare modifier via `Config.triggerModifier` (Shift when
/// the app's Shift-to-zoom setting is on). Arrow keys while the trigger is
/// held nudge the zoom rect.
///
/// Two scopes:
///   - Local (`config.globalScope == false`): an NSEvent local monitor. It fires
///     only when our window is frontmost and needs no special permissions.
///   - Global (`config.globalScope == true`): a CGEventTap on the session event
///     tap. It fires regardless of focus, and `start()` requires both
///     Accessibility and Input Monitoring before it creates the tap.
///     `startFallingBackToLocal()` starts the local monitor instead when the
///     tap cannot start.
///
/// Emits one `.pressed` on the first non-autorepeat keyDown of the configured
/// key, one `.released` on the matching keyUp, and `.arrow(direction)` on each
/// arrow keyDown that occurs *while* the configured key is held. Arrows when
/// the key isn't held are ignored. Autorepeat keyDowns of the configured key
/// are dropped.
public final class HoldKeyMonitor: @unchecked Sendable {

    // MARK: - Public types

    public enum Event: Sendable {
        case pressed(modifiers: ModifierSet)
        case released
        case arrow(ArrowKey)
    }

    public enum ArrowKey: Sendable {
        case up, down, left, right
    }

    /// A bare modifier used as the hold-to-zoom trigger (Shift = zoom by
    /// default). When `Config.triggerModifier` is set, press/release are detected
    /// from `flagsChanged` transitions of this modifier instead of a keyCode,
    /// because modifiers don't emit keyDown/keyUp with a keycode. The configured
    /// `keyCode` is then ignored.
    public enum TriggerModifier: Sendable { case shift, command, option, control }

    public struct ModifierSet: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let none    = ModifierSet([])
        public static let shift   = ModifierSet(rawValue: 1 << 0)
        public static let command = ModifierSet(rawValue: 1 << 1)
        public static let option  = ModifierSet(rawValue: 1 << 2)
    }

    public struct Config: Sendable {
        /// Virtual key code of the trigger key. 0x31 is Space (kVK_Space).
        /// In `triggerModifier` mode this is ignored.
        public var keyCode: CGKeyCode = 0x31
        /// When set, the hold trigger is this bare modifier (via flagsChanged)
        /// rather than `keyCode`. nil → classic keycode trigger.
        public var triggerModifier: TriggerModifier? = nil
        /// `true` → CGEventTap (requires permissions). `false` → NSEvent local monitor.
        public var globalScope: Bool = false
        /// While this returns true (the app passes "a text field has the
        /// caret"), the monitor stands down: no `.pressed`, no `.arrow`, and
        /// no key is consumed, so Shift capitalizes and Space types a space.
        /// `.released` still goes out, so a punch-in that began before the
        /// caret landed in a field always ends. Called on the main thread in
        /// local scope and on the tap thread in global scope.
        public var isSuspended: (@Sendable () -> Bool)? = nil
        public init() {}
    }

    /// Where a running monitor listens.
    public enum Scope: Sendable { case local, global }

    /// The two permission checks the global scope needs, injectable so the
    /// start decision can be tested without the real privacy settings.
    public struct PermissionCheck: Sendable {
        public var accessibility: @Sendable () -> Bool
        public var inputMonitoring: @Sendable () -> Bool

        public init(accessibility: @escaping @Sendable () -> Bool,
                    inputMonitoring: @escaping @Sendable () -> Bool) {
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
        }

        /// The process's real Accessibility and Input Monitoring state.
        public static let system = PermissionCheck(
            accessibility: { Permissions.hasAccessibility },
            inputMonitoring: { Permissions.hasInputMonitoring })
    }

    public enum PermissionError: Error, LocalizedError {
        case accessibilityDenied
        case inputMonitoringDenied
        case bothDenied

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Global hotkey requires Accessibility permission. Enable it in System Settings → Privacy & Security → Accessibility."
            case .inputMonitoringDenied:
                return "Global hotkey requires Input Monitoring permission. Enable it in System Settings → Privacy & Security → Input Monitoring."
            case .bothDenied:
                return "Global hotkey requires Accessibility and Input Monitoring permissions. Enable both in System Settings → Privacy & Security."
            }
        }
    }

    /// The permission the global scope is missing, or nil when both are granted.
    public static func missingPermission(accessibility: Bool, inputMonitoring: Bool) -> PermissionError? {
        switch (accessibility, inputMonitoring) {
        case (false, false): return .bothDenied
        case (false, true):  return .accessibilityDenied
        case (true, false):  return .inputMonitoringDenied
        case (true, true):   return nil
        }
    }

    // MARK: - Stored config + state

    private let config: Config
    private let permissions: PermissionCheck

    /// Currently-running scope (nil when stopped). Tracked so `stop()` knows
    /// which teardown path to take and so we don't double-`start()`.
    private var runMode: Scope?

    /// Where the monitor is listening, or nil when it is stopped.
    public var scope: Scope? { runMode }

    /// Logical "is our configured hotkey currently held down?", set on the
    /// trigger's press and cleared on its release or by `stop()`. Used to (a) suppress duplicate `.pressed` from
    /// autorepeat, (b) gate `.arrow(...)` emission to only-while-held.
    /// Accessed from the CGEventTap callback thread and the NSEvent main-thread
    /// monitor, so we serialize through `stateLock`.
    private var keyHeld: Bool = false
    private let stateLock = NSLock()

    // MARK: - Local-scope state

    private var localMonitor: Any?

    // MARK: - Global-scope state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    /// Signaled by the tap thread once its CFRunLoop is registered and ready
    /// to run. `start()` waits on this for up to 2 s.
    private let tapReadySemaphore = DispatchSemaphore(value: 0)

    // MARK: - AsyncStream plumbing

    private var continuation: AsyncStream<Event>.Continuation?
    private var lazyStream: AsyncStream<Event>?
    private let streamLock = NSLock()

    // MARK: - Init / public surface

    public init(config: Config = Config(), permissions: PermissionCheck = .system) {
        self.config = config
        self.permissions = permissions
    }

    deinit {
        // Best-effort teardown. Callers should call stop() explicitly.
        stopUnsafe()
    }

    /// Lazy single-consumer event stream. The continuation is captured on first
    /// access and reused. Later subscribers get the same stream (Swift's
    /// AsyncStream is single-consumer by design, and the App layer subscribes
    /// only once).
    public var events: AsyncStream<Event> {
        streamLock.lock()
        defer { streamLock.unlock() }
        if let existing = lazyStream { return existing }
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(64)) { cont in
            self.continuation = cont
        }
        lazyStream = stream
        return stream
    }

    /// Start monitoring. In `globalScope`, throws if either permission is
    /// missing. It does not prompt the user (call Permissions.request* first).
    public func start() throws {
        guard runMode == nil else { return }

        if config.globalScope {
            if let missing = Self.missingPermission(accessibility: permissions.accessibility(),
                                                    inputMonitoring: permissions.inputMonitoring()) {
                throw missing
            }
            try startGlobal()
            runMode = .global
        } else {
            startLocal()
            runMode = .local
        }
    }

    /// Start in the configured scope. When the global scope cannot start, a
    /// permission missing or the event tap refused, start the local monitor
    /// with the same key instead, so the key still works while the app's
    /// window is in front. Returns why the global scope did not start, or nil
    /// when the monitor started in the scope it was configured for.
    @discardableResult
    public func startFallingBackToLocal() -> Error? {
        do {
            try start()
            return nil
        } catch {
            guard runMode == nil else { return error }
            startLocal()
            runMode = .local
            return error
        }
    }

    /// Stop monitoring. Idempotent.
    public func stop() {
        stopUnsafe()
    }

    private func stopUnsafe() {
        switch runMode {
        case .local:
            if let token = localMonitor {
                NSEvent.removeMonitor(token)
            }
            localMonitor = nil
        case .global:
            // Disable + invalidate tap. CFRunLoopStop kicks the runloop thread
            // out of CFRunLoopRun() so the tap thread exits.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let src = runLoopSource, let rl = tapRunLoop {
                CFRunLoopRemoveSource(rl, src, .commonModes)
            }
            if let rl = tapRunLoop {
                CFRunLoopStop(rl)
            }
            eventTap = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
        case nil:
            break
        }
        runMode = nil

        // Reset held-state in case stop() lands between pressed/released.
        stateLock.lock(); keyHeld = false; stateLock.unlock()
    }

    // MARK: - Local-scope implementation

    private func startLocal() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            // Modifier-trigger mode (Shift=zoom): press/release ride on
            // flagsChanged. Never consume the modifier: Shift must keep
            // working normally for everything else while the app is focused.
            if self.config.triggerModifier != nil, nsEvent.type == .flagsChanged {
                self.handleModifierTransition(down: self.flagsContainTrigger(nsEvent.modifierFlags))
                return nsEvent
            }
            // Swallow the event only if we recognized it as our configured
            // hotkey or as an arrow key delivered while the hotkey is held.
            // Returning nsEvent for an unrecognized keypress to a window with
            // no first-responder for that key triggers AppKit's system beep,
            // which would beep the whole time the key is held. Consume when
            // handled, pass through otherwise.
            let keyCode = CGKeyCode(nsEvent.keyCode)
            // In modifier mode the configured keyCode is not ours (Shift is the
            // trigger), so only arrows-while-held are consumed.
            let triggerByKey = (self.config.triggerModifier == nil) && (keyCode == self.config.keyCode)
            let handled = !self.suspended() && (triggerByKey ||
                          (self.arrowKey(for: keyCode) != nil && self.isKeyHeld()))
            self.handleNSEvent(nsEvent)
            return handled ? nil : nsEvent
        }
    }

    private func handleNSEvent(_ ev: NSEvent) {
        let keyCode = CGKeyCode(ev.keyCode)
        switch ev.type {
        case .keyDown:
            // NSEvent surfaces autorepeat via `.isARepeat`. In modifier-trigger
            // mode the keyCode is never the trigger, so the press path is skipped.
            if config.triggerModifier == nil, keyCode == config.keyCode {
                if ev.isARepeat { return }
                deliverPressed(modifiers: translate(nsModifiers: ev.modifierFlags))
            } else if let arrow = arrowKey(for: keyCode) {
                // Arrow keys only fire while the configured hotkey is held,
                // and never while a text field has the caret.
                if isKeyHeld(), !suspended() {
                    deliver(.arrow(arrow))
                }
            }
        case .keyUp:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                deliverReleased()
            }
        default:
            break
        }
    }

    /// Modifier-trigger press/release. `deliverPressed`/`deliverReleased`
    /// self-dedup via `keyHeld`, so repeated flagsChanged (e.g. a second
    /// modifier added) won't double-fire.
    private func handleModifierTransition(down: Bool) {
        if down {
            deliverPressed(modifiers: config.triggerModifier == .shift ? [.shift] : [])
        } else {
            deliverReleased()
        }
    }

    private func flagsContainTrigger(_ ns: NSEvent.ModifierFlags) -> Bool {
        switch config.triggerModifier {
        case .shift:   return ns.contains(.shift)
        case .command: return ns.contains(.command)
        case .option:  return ns.contains(.option)
        case .control: return ns.contains(.control)
        case nil:      return false
        }
    }

    private func flagsContainTrigger(_ cg: CGEventFlags) -> Bool {
        switch config.triggerModifier {
        case .shift:   return cg.contains(.maskShift)
        case .command: return cg.contains(.maskCommand)
        case .option:  return cg.contains(.maskAlternate)
        case .control: return cg.contains(.maskControl)
        case nil:      return false
        }
    }

    // MARK: - Global-scope implementation (CGEventTap + dedicated runloop)

    private func startGlobal() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.flagsChanged.rawValue)

        // refcon holds an unretained pointer to self. We control the lifetime
        // by calling stop() before self is deallocated. passUnretained avoids
        // a retain cycle (CGEventTap → self → tap).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HoldKeyMonitor.tapCallback,
            userInfo: selfPtr
        ) else {
            // tapCreate returns nil if perms were revoked between our check
            // and the call, or if the process can't tap the session.
            throw PermissionError.bothDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.eventTap = tap
        self.runLoopSource = source

        // Spin a dedicated NSThread carrying its own CFRunLoop. Apple's docs
        // for CGEventTap state the tap must be driven by a runloop that's
        // alive for the tap's lifetime. Running it on the main loop would
        // couple hotkey latency to SwiftUI redraw cadence.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tapReadySemaphore.signal()
            CFRunLoopRun()  // blocks until CFRunLoopStop()
        }
        thread.name = "FilmTether.HoldKeyMonitor.tapRunLoop"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()

        // Wait up to 2 s for the tap to be wired up and listening, so an
        // immediate keypress does not race the runloop registration.
        _ = tapReadySemaphore.wait(timeout: .now() + .seconds(2))
    }

    /// The tap callback is a C function pointer, so this closure can capture
    /// nothing. `self` comes in through `refcon`.
    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, refcon in
        guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
        let monitor = Unmanaged<HoldKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleCGEvent(type: type, event: cgEvent)
        // Return the event unchanged and never consume keys. The tap is
        // created active (`.defaultTap`), but this callback only listens.
        // The callback does not own `cgEvent`, so returning it unretained
        // passes the same event through unchanged.
        return Unmanaged.passUnretained(cgEvent)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        // The system can disable the tap (timeout, user-initiated). We then
        // get a tapDisabledByTimeout/tapDisabledByUserInput event and must
        // re-enable. Without this, a slow callback or a sleep can wedge the
        // tap silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                if autorepeat != 0 { return }
                deliverPressed(modifiers: translate(cgFlags: event.flags))
            } else if let arrow = arrowKey(for: keyCode) {
                if isKeyHeld(), !suspended() {
                    deliver(.arrow(arrow))
                }
            }
        case .keyUp:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                deliverReleased()
            }
        case .flagsChanged:
            // Modifier-trigger mode (Shift=zoom): press/release ride here.
            // In keycode mode we stay quiet (modifiers are read off keyDown).
            if config.triggerModifier != nil {
                handleModifierTransition(down: flagsContainTrigger(event.flags))
            }
        default:
            break
        }
    }

    // MARK: - Delivery helpers

    private func suspended() -> Bool {
        config.isSuspended?() ?? false
    }

    private func deliverPressed(modifiers: ModifierSet) {
        // Typing in a field: not a zoom. keyHeld stays false, so the matching
        // release is dropped too and arrows are not taken as nudges.
        if suspended() { return }
        stateLock.lock()
        let wasHeld = keyHeld
        keyHeld = true
        stateLock.unlock()
        // Second guard: if some upstream layer ever bypasses the
        // autorepeat-drop, don't emit a duplicate `.pressed`.
        guard !wasHeld else { return }
        deliver(.pressed(modifiers: modifiers))
    }

    private func deliverReleased() {
        stateLock.lock()
        let wasHeld = keyHeld
        keyHeld = false
        stateLock.unlock()
        guard wasHeld else { return }   // only emit if matched a prior press
        deliver(.released)
    }

    private func deliver(_ event: Event) {
        continuation?.yield(event)
    }

    private func isKeyHeld() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return keyHeld
    }

    // MARK: - Translation helpers

    private func translate(nsModifiers flags: NSEvent.ModifierFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.shift)   { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option)  { result.insert(.option) }
        return result
    }

    private func translate(cgFlags flags: CGEventFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.maskShift)     { result.insert(.shift) }
        if flags.contains(.maskCommand)   { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        return result
    }

    /// Map the arrow keycodes to `ArrowKey`. Keycodes are layout-independent on
    /// macOS for the arrow cluster (they live in the dedicated arrow block), so
    /// this is safe across QWERTY/Dvorak/Colemak.
    private func arrowKey(for keyCode: CGKeyCode) -> ArrowKey? {
        switch Int(keyCode) {
        case kVK_UpArrow:    return .up
        case kVK_DownArrow:  return .down
        case kVK_LeftArrow:  return .left
        case kVK_RightArrow: return .right
        default:             return nil
        }
    }
}
