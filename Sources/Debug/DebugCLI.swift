import Foundation
import Camera
import CGPhoto2
import CoreGraphics
import ImageIO
import Scan

/// FilmTetherDebug is a headless CLI for exercising the Camera module without
/// the SwiftUI app. Useful for testing over SSH: the GUI app needs a window
/// server and this doesn't. Builds via `swift build --product FilmTetherDebug`.
///
/// Only one process can hold the USB at a time. Quit the SwiftUI app
/// before running CLI commands and vice versa. If a command hangs or returns
/// -10/-53, run `killall ptpcamerad PTPCamera` and retry.
@main
struct DebugCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(2)
        }
        CameraEnvironment.setup()
        installStderrGphotoLog()  // no-op unless EOS_DEBUG=1
        let cmd = args[1]
        let rest = Array(args.dropFirst(2))
        do {
            try await dispatch(cmd: cmd, rest: rest)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    @CameraActor
    static func dispatch(cmd: String, rest: [String]) async throws {
        switch cmd {
        case "connect":       try await runConnect()
        case "snapshot":      try await runSnapshot()
        case "widget":
            guard let name = rest.first else { fail("widget needs NAME") }
            try await runWidget(name)
        case "set-widget":
            guard rest.count >= 2 else { fail("set-widget needs NAME VALUE") }
            try await runSetWidget(rest[0], rest[1])
        case "choices":
            guard let name = rest.first else { fail("choices needs NAME") }
            try await runChoices(name)
        case "capture":
            let dir = rest.first ?? defaultCaptureDir()
            let camera = rest.count > 1 ? rest[1] : ""
            let film = rest.count > 2 ? rest[2] : ""
            try await runCapture(toDir: dir, camera: camera, film: film)
        case "tag":
            var tagArgs = rest
            let embed = tagArgs.contains("--embed")
            tagArgs.removeAll { $0 == "--embed" }
            // --crop x,y,w,h[,straightenDeg[,filmSizeID]] and --sample r,g,b put a
            // crop and an eyedropper sample into the tagged fixture's treatment
            // record.
            var crop: TreatmentRecord.Crop? = nil
            var sample: TreatmentRecord.RGB? = nil
            if let i = tagArgs.firstIndex(of: "--crop"), i + 1 < tagArgs.count {
                let v = tagArgs[i + 1].split(separator: ",").compactMap { Double($0) }
                guard v.count >= 4 else { fail("--crop needs x,y,w,h[,deg[,id]]") }
                crop = TreatmentRecord.Crop(x: v[0], y: v[1], width: v[2], height: v[3],
                                            straightenDegrees: v.count > 4 ? v[4] : 0,
                                            filmSizeID: v.count > 5 ? Int(v[5]) : nil)
                tagArgs.removeSubrange(i...(i + 1))
            }
            if let i = tagArgs.firstIndex(of: "--sample"), i + 1 < tagArgs.count {
                let v = tagArgs[i + 1].split(separator: ",").compactMap { Double($0) }
                guard v.count == 3 else { fail("--sample needs r,g,b") }
                sample = TreatmentRecord.RGB(r: v[0], g: v[1], b: v[2])
                tagArgs.removeSubrange(i...(i + 1))
            }
            // The shared geometry and the eyedropper point, which Film Positive
            // reads from a Tether-written file.
            var rotate = 0
            if let i = tagArgs.firstIndex(of: "--rotate"), i + 1 < tagArgs.count {
                guard let r = Int(tagArgs[i + 1]), [0, 90, 180, 270].contains(r) else { fail("--rotate needs 0, 90, 180 or 270") }
                rotate = r
                tagArgs.removeSubrange(i...(i + 1))
            }
            let flip = tagArgs.contains("--flip")
            tagArgs.removeAll { $0 == "--flip" }
            var straighten = 0.0
            if let i = tagArgs.firstIndex(of: "--straighten"), i + 1 < tagArgs.count {
                guard let d = Double(tagArgs[i + 1]) else { fail("--straighten needs degrees") }
                straighten = d
                tagArgs.removeSubrange(i...(i + 1))
            }
            var point: TreatmentRecord.Point? = nil
            if let i = tagArgs.firstIndex(of: "--point"), i + 1 < tagArgs.count {
                let v = tagArgs[i + 1].split(separator: ",").compactMap { Double($0) }
                guard v.count == 2 else { fail("--point needs x,y") }
                point = TreatmentRecord.Point(x: v[0], y: v[1])
                tagArgs.removeSubrange(i...(i + 1))
            }
            guard let path = tagArgs.first else { fail("tag needs FILE [CAMERA] [FILM] [--embed] [--crop x,y,w,h[,deg[,id]]] [--sample r,g,b] [--rotate 0|90|180|270] [--flip] [--point x,y] [--straighten deg]") }
            let camera = tagArgs.count > 1 ? tagArgs[1] : ""
            let film = tagArgs.count > 2 ? tagArgs[2] : ""
            if embed { MetadataWriter.backend = .embedded }
            let record = TreatmentRecord(baseSample: sample, crop: crop, rotate: rotate,
                                         flip: flip, samplePoint: point, straightenDegrees: straighten)
            let treatment = record.isEmpty ? nil : record
            runTag(file: path, camera: camera, film: film, treatment: treatment)
        case "lv-start":      try await runLVStart()
        case "lv-stop":       try await runLVStop()
        case "preview":
            let dir = rest.first ?? "/tmp"
            try await runPreview(toDir: dir)
        case "mf":
            guard let step = rest.first else { fail("mf needs STEP") }
            try await runManualFocus(step)
        case "meter":
            let secs = Int(rest.first ?? "8") ?? 8
            try await runMeter(seconds: secs)
        case "events":
            let secs = Int(rest.first ?? "5") ?? 5
            try await runEvents(seconds: secs)
        case "clock":         try await runClock()
        case "sync-clock":    try await runSyncClock(local: true)
        case "sync-clock-utc": try await runSyncClock(local: false)
        case "test":          try await runTestSuite()
        case "help", "-h", "--help": printUsage()
        default:
            fail("unknown command: \(cmd)")
        }
    }

    // MARK: - Subcommands

    @CameraActor
    static func runConnect() async throws {
        let sess = try await openSession()
        let fw = sess.firmware ?? "(not reported)"
        print("OK firmware=\(fw)")
        sess.close()
    }

    @CameraActor
    static func runSnapshot() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let snap = try await CameraProperties(session: sess).snapshot()
        print("iso=\(snap.iso ?? "?")")
        print("shutter=\(snap.shutter ?? "?")")
        print("aperture=\(snap.aperture ?? "?")")
        print("whitebalance=\(snap.whiteBalance ?? "?")")
        print("kelvin=\(snap.kelvin.map(String.init) ?? "?")")
        print("mode=\(snap.mode ?? "?")")
        print("imageformat=\(snap.imageFormat ?? "?")")
        print("battery=\(snap.battery ?? "?")")
        print("focusmode=\(snap.focusMode ?? "?")")
        if let dt = snap.cameraDateTime {
            print("clock=\(dt) (drift_host=\(Int(dt.timeIntervalSinceNow))s)")
        } else {
            print("clock=?")
        }
    }

    @CameraActor
    static func runWidget(_ name: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let v = try await CameraProperties(session: sess).getString(name)
        print("\(name)=\(v)")
    }

    @CameraActor
    static func runSetWidget(_ name: String, _ value: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        try await CameraProperties(session: sess).setString(name, value: value)
        print("set \(name)=\(value)")
    }

    /// Dump a RADIO/MENU widget's full choice list plus its current value.
    /// Diagnostic for "why is X missing from a picker": these are the raw
    /// strings libgphoto2 and the body report, before the app relabels them.
    @CameraActor
    static func runChoices(_ name: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let current = (try? await props.getString(name)) ?? "?"
        let list = try await props.choices(for: name)
        print("\(name) current=\(current) (\(list.count) choices)")
        for (i, c) in list.enumerated() {
            print(String(format: "  [%2d] %@", i, c))
        }
    }

    @CameraActor
    static func runCapture(toDir dirString: String, camera: String = "", film: String = "") async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let cap = CameraCapture(session: sess, properties: props)
        let meta = CaptureMetadata(camera: camera, film: film, capturedAt: Date())
        let before = Date()
        let result = try await cap.capture(to: dir, metadata: meta)
        let dt = Date().timeIntervalSince(before)
        let sidecar = result.sidecarPath.map { " sidecar=\($0.path)" } ?? ""
        print("OK capture=\(result.path.path) iso=\(result.iso ?? "?") Tv=\(result.shutter ?? "?") Av=\(result.aperture ?? "?") elapsed=\(String(format: "%.1f", dt))s\(sidecar)")
    }

    /// Write metadata for an existing raw, no camera needed: a sidecar by
    /// default, or embedded in the file with `--embed`. Use this
    /// to generate a tagged `.xmp` next to a test CR2, convert it with metadata
    /// included, then `exiftool` the export to confirm the camera/film survived.
    nonisolated static func runTag(file path: String, camera: String, film: String,
                                   treatment: TreatmentRecord? = nil) {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let meta = CaptureMetadata(camera: camera, film: film, treatment: treatment)
        guard !meta.isEmpty else { fail("tag has nothing to write. Give a CAMERA or FILM value, or a flag such as --crop or --rotate") }
        do {
            if let out = try MetadataWriter.write(meta, forRAW: url) {
                print("OK wrote \(out.path)")
                if out.pathExtension.lowercased() == "xmp" {
                    // Read back what is on disk: after a merge into an existing
                    // sidecar that is the only packet that reflects the file.
                    print("--- XMP ---")
                    print(try String(contentsOf: out, encoding: .utf8))
                } else {
                    print("(embedded into \(out.lastPathComponent))")
                }
            } else {
                print("no-op (nothing to write)")
            }
        } catch {
            fail("tag failed: \(error)")
        }
    }

    @CameraActor
    static func runLVStart() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        try await lv.start()
        print("OK live view started (mirror up).")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try? await lv.stop()
    }

    @CameraActor
    static func runLVStop() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        try? await props.setString("viewfinder", value: "0")
        try? await props.setString("output", value: "TFT")
        print("OK sent viewfinder=0 and output=TFT, write errors ignored (mirror should be down)")
    }

    /// Save one live-view JPEG to disk and print its dimensions, which are the
    /// resolution the body streams.
    @CameraActor
    static func runPreview(toDir dirString: String) async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        try await lv.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let data = try await lv.fetchOnePreview()
        try? await lv.stop()
        let url = dir.appendingPathComponent("fs-preview.jpg")
        try data.write(to: url)
        let (w, h) = LiveView.parseJPEGDimensions(data)
        print("OK preview \(w ?? 0)x\(h ?? 0) \(data.count) bytes → \(url.path)")
    }

    @CameraActor
    static func runManualFocus(_ stepString: String) async throws {
        let step: CameraProperties.ManualFocusStep
        switch stepString.lowercased() {
        case "near-tiny": step = .nearTiny
        case "near-small": step = .nearSmall
        case "near-large": step = .nearLarge
        case "far-tiny": step = .farTiny
        case "far-small": step = .farSmall
        case "far-large": step = .farLarge
        default: fail("mf STEP must be near-tiny|near-small|near-large|far-tiny|far-small|far-large")
        }
        let sess = try await openSession(); defer { sess.close() }
        try await CameraProperties(session: sess).driveManualFocus(step)
        print("OK driveManualFocus(\(step.rawValue))")
    }

    @CameraActor
    static func runMeter(seconds: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let evts = CameraEvents(session: sess)
        try await lv.start()
        print("LV up, draining shutterspeed events for \(seconds)s …")
        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(seconds))
        var tvCount = 0
        while Date() < deadline {
            let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
            for e in drained {
                if case .propertyChanged(let name, let value, _) = e,
                   name == "shutterspeed", let value {
                    let elapsed = Date().timeIntervalSince(start)
                    print(String(format: "  +%.2fs Tv=%@", elapsed, value))
                    tvCount += 1
                }
            }
        }
        try? await lv.stop()
        print("OK metered \(tvCount) shutterspeed updates over \(seconds)s")
    }

    @CameraActor
    static func runEvents(seconds: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let evts = CameraEvents(session: sess)
        try await lv.start()
        print("LV up, dumping ALL events for \(seconds)s …")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var count = 0
        while Date() < deadline {
            let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
            for e in drained {
                count += 1
                print("  \(formatEvent(e))")
            }
        }
        try? await lv.stop()
        print("OK \(count) events drained")
    }

    @CameraActor
    static func runClock() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let snap = try await CameraProperties(session: sess).snapshot()
        guard let dt = snap.cameraDateTime else {
            print("camera clock not readable"); return
        }
        let drift = dt.timeIntervalSinceNow
        print("camera=\(dt)")
        print("host=\(Date())")
        print("drift=\(Int(drift))s")
    }

    @CameraActor
    static func runSyncClock(local: Bool) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        if local {
            try await props.syncDateTimeToHostLocal()
            print("OK synced camera to host LOCAL wall clock (\(Date()))")
        } else {
            try await props.syncDateTimeToHost()
            print("OK synced camera to host UTC (\(Date()))")
        }
    }

    // MARK: - Test suite

    @CameraActor
    static func runTestSuite() async throws {
        print("===Film Tether debug test suite===")
        print("start=\(Date())")
        var results: [(String, Bool, String)] = []

        results.append(await runStep("connect") {
            let sess = try await openSession()
            let fw = sess.firmware ?? "?"
            sess.close()
            return "firmware=\(fw)"
        })

        results.append(await runStep("snapshot") {
            let sess = try await openSession(); defer { sess.close() }
            let snap = try await CameraProperties(session: sess).snapshot()
            return "iso=\(snap.iso ?? "?") Tv=\(snap.shutter ?? "?") mode=\(snap.mode ?? "?")"
        })

        results.append(await runStep("clock-sync-local") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            try await props.syncDateTimeToHostLocal()
            let snap = try await props.snapshot()
            guard let dt = snap.cameraDateTime else {
                throw DebugError("no clock readback after sync")
            }
            let drift = abs(dt.timeIntervalSinceNow)
            guard drift < 5 else {
                throw DebugError("drift \(Int(drift))s > 5s after sync")
            }
            return "drift_after=\(Int(drift))s"
        })

        results.append(await runStep("lv-frame") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let frame = try await lv.fetchOnePreview()
            try? await lv.stop()
            guard frame.count > 1000 else {
                throw DebugError("tiny frame \(frame.count) bytes")
            }
            return "bytes=\(frame.count)"
        })

        results.append(await runStep("metering-events") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            let evts = CameraEvents(session: sess)
            try await lv.start()
            let deadline = Date().addingTimeInterval(4)
            var tvCount = 0
            var lastTv: String? = nil
            while Date() < deadline {
                let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
                for e in drained {
                    if case .propertyChanged(let name, let value, _) = e,
                       name == "shutterspeed", let value {
                        tvCount += 1
                        lastTv = value
                    }
                }
            }
            try? await lv.stop()
            guard tvCount > 0 else {
                throw DebugError("no Tv events seen in 4s")
            }
            return "tv_updates=\(tvCount) last=\(lastTv ?? "?")"
        })

        let captureDir = URL(fileURLWithPath: NSString(string: defaultCaptureDir()).expandingTildeInPath)
        results.append(await runStep("capture-immediate") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let cap = CameraCapture(session: sess, properties: props)
            let result = try await cap.capture(to: captureDir, filenamePattern: "DEBUG_{ymd}_{hms}_{seq}.{ext}")
            let attrs = try FileManager.default.attributesOfItem(atPath: result.path.path)
            let size = (attrs[.size] as? Int) ?? 0
            guard size > 1_000_000 else {
                throw DebugError("RAW too small (\(size) bytes)")
            }
            return "path=\(result.path.lastPathComponent) bytes=\(size) iso=\(result.iso ?? "?") Tv=\(result.shutter ?? "?")"
        })

        results.append(await runStep("manual-focus") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await props.driveManualFocus(.nearTiny)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try await props.driveManualFocus(.farTiny)
            try? await lv.stop()
            return "near-tiny + far-tiny written without error"
        })

        results.append(await runStep("teardown") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            try? await props.setString("viewfinder", value: "0")
            try? await props.setString("output", value: "TFT")
            return "viewfinder=0 + output=TFT sent, write errors ignored (mirror should be down)"
        })

        printResults(results)
    }

    // MARK: - Helpers

    @CameraActor
    static func runStep(_ name: String, _ body: () async throws -> String) async -> (String, Bool, String) {
        do {
            let evidence = try await body()
            return (name, true, evidence)
        } catch {
            return (name, false, "\(error)")
        }
    }

    static func printResults(_ results: [(String, Bool, String)]) {
        print("\n===RESULTS===")
        var pass = 0, fail = 0
        for (name, ok, evidence) in results {
            let tag = ok ? "PASS" : "FAIL"
            print("\(tag) \(name): \(evidence)")
            if ok { pass += 1 } else { fail += 1 }
        }
        print("\nsummary: \(pass) passed, \(fail) failed, total \(results.count)")
        print("end=\(Date())")
    }

    /// With EOS_DEBUG=1, forward libgphoto2's log callback to stderr. Nothing
    /// arrives with Homebrew's libgphoto2, which compiles the callback out (see
    /// CameraLog). The GUI app sends libgphoto2's log to unified logging instead.
    static func installStderrGphotoLog() {
        guard ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" else { return }
        gp_log_add_func(GP_LOG_DEBUG, { _, domain, message, _ in
            let d = domain.map { String(cString: $0) } ?? "?"
            let m = message.map { String(cString: $0) } ?? "?"
            FileHandle.standardError.write(Data("gp[\(d)] \(m)\n".utf8))
        }, nil)
    }

    @CameraActor
    static func openSession() async throws -> CameraSession {
        let sess = try CameraSession()
        try await sess.open()
        return sess
    }

    static func formatEvent(_ e: CameraEvents.Event) -> String {
        switch e {
        case .timeout: return "timeout"
        case .fileAdded(let folder, let name): return "FILE_ADDED \(folder)/\(name)"
        case .captureComplete: return "CAPTURE_COMPLETE"
        case .propertyChanged(let n, let v, let raw):
            if let n, let v { return "PROP \(n) = \(v)" }
            return "PROP_RAW \(raw)"
        case .unknown(let raw): return "UNKNOWN \(raw)"
        }
    }

    static func defaultCaptureDir() -> String {
        return NSString(string: "~/Pictures/Film Tether").expandingTildeInPath
    }

    static func printUsage() {
        print("""
        FilmTetherDebug is a headless CLI for the Camera module.

        Usage: FilmTetherDebug <command> [args]

        Commands:
          connect                 Open + close session, print firmware
          snapshot                Dump current property snapshot
          widget NAME             Read a raw widget value
          set-widget NAME VALUE   Write a raw widget value
          choices NAME            List a RADIO/MENU widget's choices + current value
          capture [DIR] [CAMERA] [FILM]
                                  Fire release + download the RAW under its true extension
                                  (and the JPEG too, if quality is RAW+JPEG) + write metadata
                                  when CAMERA or FILM is given
          tag FILE [CAMERA] [FILM] [--crop x,y,w,h[,deg[,id]]] [--straighten deg] [--rotate 0|90|180|270] [--flip]
                                  [--point x,y] [--sample r,g,b] [--embed]
                                  Write metadata for an EXISTING raw (no camera)
          lv-start                Engage live view briefly (sanity check)
          lv-stop                 Disengage live view (mirror down)
          preview [DIR]           Save one LV JPEG (default /tmp) + print its dimensions
          mf STEP                 Manual focus: near-tiny|near-small|near-large|far-tiny|far-small|far-large
          meter [SECONDS]         LV + drain shutterspeed events (default 8s)
          events [SECONDS]        LV + dump ALL events (default 5s)
          clock                   Read camera clock + host drift
          sync-clock              Sync camera to host LOCAL wall clock
          sync-clock-utc          Sync camera to host UTC (syncdatetimeutc, no local-time correction)
          test                    Hardware checks: sets the camera clock, captures one RAW, moves focus

        """)
        print("""
        Reminder: only one process can hold the USB at a time. Quit the
        SwiftUI Film Tether app before running CLI commands. If a command
        hangs or returns -10/-53, run: killall ptpcamerad PTPCamera
        """)
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
        exit(2)
    }

    struct DebugError: LocalizedError {
        let message: String
        init(_ m: String) { self.message = m }
        var errorDescription: String? { message }
    }
}
