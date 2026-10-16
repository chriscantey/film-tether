import XCTest
@testable import Camera

/// The stall ladder on the first config read and the live-view start. The app
/// runs `StallLadder.app`, so a stall is close, then advice. Budgets here are
/// 200 ms so the suite stays fast.
final class StallLadderTests: XCTestCase {


    // MARK: - The app's ladder: no reset, ever

    func testTheAppLadderClosesThenAdvisesOnTheFirstOverrun() {
        var l = StallLadder.app
        XCTAssertEqual(l.budget, 45)
        XCTAssertEqual(l.overran(), [.close, .advise])
        XCTAssertEqual(l.overran(), [.close, .advise])
    }

    /// On the 7D the reset is refused (six of six measured), and the Mac stack
    /// stays stuck until a reboot after it: under the app's ladder a hang never
    /// reaches a reset.
    func testTheAppNeverResetsOnAStall() async {
        let body = FakeStallBody(ladder: .app)
        body.hang[1] = true
        let out = await StallGuard.run(stage: "first config read", ladder: body.ladder, io: body.io)
        guard case .notAnswering(let n) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(body.steps, ["attempt 1", "close", "advise"])
        XCTAssertEqual(body.count("reset"), 0)
        XCTAssertEqual(body.count("reopen"), 0)
        body.powerCycle()
    }

    func testTheAppNeverShowsRetrying() async {
        let body = FakeStallBody(ladder: .app)
        body.hang[1] = true
        _ = await StallGuard.run(stage: "live view start", ladder: body.ladder, io: body.io)
        XCTAssertEqual(body.progress, [.attempt(1), .finished])
        body.powerCycle()
    }


    // MARK: - The runner

    func testACallInsideItsBudgetTouchesNothing() async {
        let body = FakeStallBody()
        let out = await StallGuard.run(stage: "first config read", ladder: body.ladder, io: body.io)
        guard case .answered(let n) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(body.steps, ["attempt 1", "answered 1"])
    }

    func testAnErrorInsideTheBudgetIsReportedNotLaddered() async {
        let body = FakeStallBody()
        body.fail[1] = CameraError.libGPhoto(code: -7, message: "I/O problem")
        let out = await StallGuard.run(stage: "first config read", ladder: body.ladder, io: body.io)
        guard case .failed(let e, let n) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(e as? CameraError, .libGPhoto(code: -7, message: "I/O problem"))
        XCTAssertEqual(body.count("close"), 0)
        XCTAssertEqual(body.count("reset"), 0)
    }


    // MARK: - Progress, for the status line's wait glyph

    func testProgressMarksTheAttemptAndTheEnd() async {
        let body = FakeStallBody()
        _ = await StallGuard.run(stage: "first config read", ladder: body.ladder, io: body.io)
        XCTAssertEqual(body.progress, [.attempt(1), .finished])
    }


    func testEveryWayARunEndsClearsTheGlyph() async {
        let failed = FakeStallBody()
        failed.fail[1] = CameraError.sessionNotOpen
        _ = await StallGuard.run(stage: "s", ladder: failed.ladder, io: failed.io)
        XCTAssertEqual(failed.progress.last, .finished)

        let advised = FakeStallBody()
        advised.hang[1] = true
        advised.resetRC = -4
        _ = await StallGuard.run(stage: "s", ladder: advised.ladder, io: advised.io)
        XCTAssertEqual(advised.progress.last, .finished)
        XCTAssertEqual(advised.progress.filter { $0 == .finished }.count, 1)
        advised.powerCycle()
    }

    // MARK: - Advice

    func testNotAnsweringSaysPowerCycleOnBothPaths() {
        for (op, stage) in [(CameraAdvice.Operation.connect, "first config read"),
                            (CameraAdvice.Operation.liveView, "live view start")] {
            let a = CameraAdvice.advice(for: .notAnswering(stage: stage), during: op,
                                        cameraAppsRunning: true, ptpDaemonRunning: true)
            XCTAssertEqual(a.message, CameraAdvice.notAnsweringMessage)
            XCTAssertEqual(a.hint, CameraAdvice.notAnsweringHint)
            XCTAssertTrue(a.hint!.contains("turn it back on"))
            XCTAssertTrue(a.detail!.contains(stage), "the stage stays behind the icon")
        }
    }

    func testTheNotAnsweringCopyNamesNoBrand() {
        for brand in ["Canon", "EOS", "7D", "libgphoto2"] {
            XCTAssertFalse(CameraAdvice.notAnsweringMessage.contains(brand), brand)
            XCTAssertFalse(CameraAdvice.notAnsweringHint.contains(brand), brand)
        }
    }

    // MARK: - The flags that stop queued work outliving the ladder

    func testAStallFlagSetsAndClearsFromAnyThread() async {
        let f = StallFlag()
        XCTAssertFalse(f.isSet)
        await Task.detached { f.set() }.value
        XCTAssertTrue(f.isSet)
        f.clear()
        XCTAssertFalse(f.isSet)
    }


    // MARK: - The per-session close

    func testTakingOneHandleLeavesTheOthers() {
        let reg = OpenHandleRegistry()
        let a = NSObject(), b = NSObject()
        let cam = OpenHandleRegistry.CameraPtr.allocate(capacity: 1)
        defer { cam.deallocate() }
        let ctx = OpaquePointer(bitPattern: 0x1)!
        reg.put(ObjectIdentifier(a), camera: cam, context: ctx)
        reg.put(ObjectIdentifier(b), camera: cam, context: ctx)
        XCTAssertNotNil(reg.take(ObjectIdentifier(a)))
        XCTAssertNil(reg.take(ObjectIdentifier(a)), "a handle is taken once")
        XCTAssertFalse(reg.contains(ObjectIdentifier(a)))
        XCTAssertTrue(reg.contains(ObjectIdentifier(b)))
        XCTAssertEqual(reg.count, 1)
    }
}

/// A fake body whose calls can hang. A power cycle fails every stuck call.
private final class FakeStallBody: @unchecked Sendable {
    let ladder: StallLadder
    private let lock = NSLock()
    private let t0 = Date()
    private var log: [(String, Double)] = []
    private var logLines: [String] = []
    private var progressLog: [StallProgress] = []
    var progress: [StallProgress] { lock.lock(); defer { lock.unlock() }; return progressLog }
    private var stuck: [CheckedContinuation<Void, Error>] = []
    private var stuckReopen: [CheckedContinuation<Void, Error>] = []

    var hang: [Int: Bool] = [:]
    var fail: [Int: Error] = [:]
    var resetFrees = true
    var reopenHangs = false
    var reopenError: Error?
    /// What the USB reset returns. Nonzero never frees a stuck call.
    var resetRC: Int32 = 0
    private(set) var advised = false

    struct Freed: Error {}

    /// The app's ladder with a 200 ms budget, which leaves a loaded machine
    /// room to start and park each fake call well inside it.
    init(ladder template: StallLadder = .app) {
        ladder = StallLadder(budget: 0.2)
    }

    var steps: [String] { lock.lock(); defer { lock.unlock() }; return log.map { $0.0 } }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return logLines }
    func count(_ s: String) -> Int { steps.filter { $0 == s }.count }
    func at(_ s: String) -> Double? { lock.lock(); defer { lock.unlock() }; return log.first { $0.0 == s }?.1 }

    private func note(_ s: String) {
        lock.lock(); log.append((s, Date().timeIntervalSince(t0))); lock.unlock()
    }

    /// Fails every call still stuck, as turning the camera off does.
    func powerCycle() {
        lock.lock()
        let c = stuck + stuckReopen
        stuck = []; stuckReopen = []
        lock.unlock()
        c.forEach { $0.resume(throwing: Freed()) }
    }

    private func freeStuckCalls() {
        lock.lock()
        let c = stuck
        stuck = []
        lock.unlock()
        c.forEach { $0.resume(throwing: Freed()) }
    }

    var io: StallIO {
        let io = StallIO(
            attempt: { n in
                self.note("attempt \(n)")
                if let e = self.fail[n] { throw e }
                if self.hang[n] == true {
                    do {
                        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                            self.lock.lock(); self.stuck.append(c); self.lock.unlock()
                        }
                    } catch {
                        self.note("late \(n)")
                        throw error
                    }
                }
                self.note("answered \(n)")
            },
            close: { self.note("close"); return "closed" },
            advise: { self.lock.lock(); self.advised = true; self.lock.unlock(); self.note("advise") },
            log: { line in self.lock.lock(); self.logLines.append(line); self.lock.unlock() },
            progress: { p in self.lock.lock(); self.progressLog.append(p); self.lock.unlock() })
        return io
    }
}
