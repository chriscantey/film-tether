import Foundation
import CoreFoundation

/// A `SerialExecutor` that pins all work to a single dedicated `pthread` running a `CFRunLoop`.
///
/// Swift's custom global actor (`CameraActor`) guarantees serial execution but not thread
/// affinity: the default executor hops between OS threads at suspension points. This executor
/// keeps the actor's libgphoto2 calls on one thread, so they do not depend on libgphoto2 and
/// libusb tolerating a session that moves between threads.
public final class PinnedThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let thread: Thread
    private let label: String

    public init(label: String) {
        self.label = label
        let runLoopBox = RunLoopBox()
        let barrier = DispatchSemaphore(value: 0)

        let thread = Thread {
            runLoopBox.runLoop = CFRunLoopGetCurrent()
            Thread.current.name = label

            // CFRunLoop exits immediately if it has no sources. Add a no-op source so it stays alive.
            var ctx = CFRunLoopSourceContext()
            ctx.version = 0
            ctx.perform = { _ in /* no-op */ }
            let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

            barrier.signal()

            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1024 * 1024 // 1 MB, libgphoto2's deep call stacks need headroom
        thread.start()

        barrier.wait()
        self.thread = thread
        guard let captured = runLoopBox.runLoop else {
            fatalError("PinnedThreadExecutor: failed to capture run loop")
        }
        self.runLoop = captured
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = self.asUnownedSerialExecutor()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            unowned.runSynchronously(on: executor)
        }
        CFRunLoopWakeUp(runLoop)
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

private final class RunLoopBox: @unchecked Sendable {
    var runLoop: CFRunLoop?
}
