import Foundation
import CGPhoto2

/// Fires the shutter via `gp_camera_capture(GP_CAPTURE_IMAGE)` and downloads
/// the resulting file(s) to a destination folder, byte-for-byte as the camera
/// produced them. When the camera's filename has an extension (.CR2 on a 7D,
/// .CR3 on an R5, .JPG for JPEG quality settings), the saved name ends in it
/// whatever extension the user's filename pattern gives, so a pattern ending
/// in .CR2 cannot mislabel CR3 or JPEG bytes and make macOS misreport the format.
/// When the body is set to RAW+JPEG it creates two files per shot but
/// gp_camera_capture returns only the first. The companion arrives on the
/// event queue, so capture drains FILE_ADDED events before downloading and
/// saves every file of the capture (same base name, each with its own true
/// extension).
///
/// Why gp_camera_capture and not eosremoterelease=Immediate: writing
/// `eosremoterelease=Immediate` (PTP value 5) did not fire the shutter on
/// the 7D in testing: `gphoto2 --set-config eosremoterelease=5
/// --wait-event-and-download` produced zero files in three attempts, while
/// `gphoto2 --capture-image-and-download` (which is exactly
/// `gp_camera_capture(GP_CAPTURE_IMAGE)` underneath) fires reliably. A file
/// that does turn up after an Immediate write is most likely a stale CR2 left
/// in libgphoto2's queue by a previous session, not a fresh exposure.
///
/// Known body-firmware behaviors with this path:
///   - The body re-AFs on capture unless the lens is in MF mode. A
///     focusmode widget write does nothing to suppress AF: the 7D firmware
///     ignores it and drives a fresh AF pass through its internal Press-Full
///     lifecycle, so this path writes no focusmode. The lens switch is the
///     reliable answer for film scanning (focus is locked by the carrier
///     anyway).
///   - The body re-meters in Av/P modes at shutter trigger. There is no
///     widget for AE-lock on this body (verified via `gphoto2 --get-config
///     aelock` → empty).
///   - `gp_camera_capture` has hung on the 7D with EVF (viewfinder=1)
///     active. The app (AppModel.captureNow) keeps live view up through
///     the capture, so the body's live-view meter sets the exposure, and
///     only pauses the frame fetch (`withLVPriority`).
@CameraActor
public final class CameraCapture {
    public struct CaptureResult: Sendable {
        /// Primary saved file. When the capture produced multiple files
        /// (RAW+JPEG), this is the RAW, otherwise the first file saved.
        public let path: URL
        /// Every file this capture saved, primary included. One entry for
        /// RAW-only or JPEG-only quality settings, two for RAW+JPEG.
        public let allPaths: [URL]
        public let timestamp: Date
        public let iso: String?
        public let shutter: String?
        public let aperture: String?
        /// Where the metadata went: the .xmp sidecar, or the RAW itself when
        /// the embedded backend wrote into it. nil when nothing was written.
        public let sidecarPath: URL?
    }

    private let session: CameraSession
    private let properties: CameraProperties
    private let events: CameraEvents
    private var sessionSeq: Int = 0

    public init(session: CameraSession, properties: CameraProperties) {
        self.session = session
        self.properties = properties
        self.events = CameraEvents(session: session)
    }

    public func capture(
        to destinationDir: URL,
        filenamePattern: String = "IMG_{ymd}_{hms}_{seq}.{ext}",
        metadata: CaptureMetadata = CaptureMetadata(camera: "", film: "")
    ) async throws -> CaptureResult {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()

        // Snapshot exposure values at capture time for the CaptureResult.
        async let isoTask: String? = try? properties.iso()
        async let shutterTask: String? = try? properties.shutter()
        async let apertureTask: String? = try? properties.aperture()

        // AE lock around capture: with C.Fn IV-1 = "AE lock / AF" set on the
        // body, eosremoterelease=Press Half locks the body's auto-exposure.
        // gp_camera_capture then uses the locked AE instead of re-metering at
        // shutter trigger, which addresses the "captured image is brighter than
        // LV" symptom. Release Half clears the lock afterward. Both writes are
        // best-effort. If the body rejects them the capture still runs.
        //
        // If C.Fn IV-1 is not set to option 1, the capture falls back to
        // re-metering at shutter trigger, and Press Half may drive AF (see
        // AFProbe.swift). That is not proven harmless: an AF during live-view
        // startup correlates with a firmware-deep wedge (see LiveView.start).
        //
        // gp_camera_capture half-presses with AF enabled before it fires
        // (libgphoto2 2.5.34 library.c, RemoteReleaseOn(1, 0)). On the 7D in
        // live view that does not move the lens: three captures from a
        // defocused lens left the frame's sharpness unchanged, with no drive
        // event, while DoAf from the same states focused.
        try? await properties.setString("eosremoterelease", value: "Press Half")
        // 50ms dwell. The body needs one meter pass before capture, and
        // 50ms is empirically enough on the 7D's PTP daemon. The three
        // exposure reads above can run on the camera thread during this
        // sleep, so the gap before the capture may be longer.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // gp_camera_capture(GP_CAPTURE_IMAGE), the standard Canon capture
        // lifecycle. Returns a CameraFilePath pointing at the file the
        // body just wrote. First call after a fresh session sometimes
        // returns -1 ("Could not capture") while the body initializes.
        // Any failure gets one retry after 500 ms, which covers that case.
        CameraLog.capture.info("gp_camera_capture(GP_CAPTURE_IMAGE) after Press Half …")
        var filePath = CameraFilePath()
        var rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &filePath, ctx)
        if rc != GP_OK {
            CameraLog.capture.info("gp_camera_capture first attempt: rc=\(rc), retrying after 500ms")
            try? await Task.sleep(nanoseconds: 500_000_000)
            rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &filePath, ctx)
        }
        // Always release the AE lock, even if capture errored, so the
        // body doesn't stay locked through the next LV preview.
        try? await properties.setString("eosremoterelease", value: "Release Half")
        try CameraError.check(rc)

        let folderString = withUnsafePointer(to: filePath.folder) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        let nameString = withUnsafePointer(to: filePath.name) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        CameraLog.capture.info("camera file: \(folderString, privacy: .public)/\(nameString, privacy: .public)")

        // RAW+JPEG: the body created a second file for this shot. Only the
        // first came back in filePath. The companion is announced via a queued
        // FILE_ADDED event, so drain the queue briefly before naming/saving.
        // Two 200 ms timeouts in a row end the wait. Any other event resets
        // that count, so the wait can run to about 2 s.
        var cameraFiles: [(folder: String, name: String)] = [(folderString, nameString)]
        var consecutiveTimeouts = 0
        let drainDeadline = Date().addingTimeInterval(2.0)
        while Date() < drainDeadline && consecutiveTimeouts < 2 {
            guard let event = try? await events.waitOne(timeoutMs: 200) else { break }
            switch event {
            case .fileAdded(let folder, let name):
                consecutiveTimeouts = 0
                if !cameraFiles.contains(where: { $0.folder == folder && $0.name == name }) {
                    CameraLog.capture.info("companion file: \(folder, privacy: .public)/\(name, privacy: .public)")
                    cameraFiles.append((folder, name))
                }
            case .timeout:
                consecutiveTimeouts += 1
            case .captureComplete, .propertyChanged, .unknown:
                consecutiveTimeouts = 0
            }
        }

        sessionSeq += 1
        let timestamp = Date()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Name every file of this capture from the same resolved base, chosen
        // so that no file or sidecar already in the folder is replaced. Each
        // file gets its own true extension straight from the camera's filename.
        let resolved = Self.captureNames(
            pattern: filenamePattern, timestamp: timestamp, startingSequence: sessionSeq,
            cameraExtensions: cameraFiles.map { file in
                let ext = (file.name as NSString).pathExtension
                return ext.isEmpty ? nil : ext
            },
            exists: { name in
                FileManager.default.fileExists(atPath: destinationDir.appendingPathComponent(name).path)
            }
        )
        if resolved.sequence != sessionSeq {
            CameraLog.capture.info("shot number \(self.sessionSeq, privacy: .public) is taken in the folder, using \(resolved.sequence, privacy: .public)")
        }
        sessionSeq = resolved.sequence
        var savedURLs: [URL] = []
        for ((folder, name), resolvedName) in zip(cameraFiles, resolved.names) {
            let outURL = destinationDir.appendingPathComponent(resolvedName)
            let data = try downloadFile(camera: cam, context: ctx, folder: folder, name: name)
            try data.write(to: outURL, options: .atomic)
            CameraLog.capture.info("wrote \(data.count, privacy: .public) bytes → \(LogExportPlan.name(of: outURL), privacy: .public)")
            savedURLs.append(outURL)

            // Delete the on-camera copy so the next capture has a clean slate.
            folder.withCString { folderC in
                name.withCString { nameC in
                    _ = gp_camera_file_delete(cam, folderC, nameC, ctx)
                }
            }
        }
        guard !savedURLs.isEmpty else {
            throw CameraError.captureFailed(reason: "no files downloaded")
        }

        let iso = await isoTask
        let shutter = await shutterTask
        let aperture = await apertureTask

        let rawExtensions: Set<String> = ["cr2", "cr3", "crw"]
        let primary = savedURLs.first(where: { rawExtensions.contains($0.pathExtension.lowercased()) })
            ?? savedURLs[0]

        // Write the camera/film provenance for the primary file.
        // Best-effort: a metadata failure must never lose the scan, which is
        // already on disk.
        var sidecarPath: URL? = nil
        if !metadata.isEmpty {
            do {
                sidecarPath = try MetadataWriter.write(metadata, forRAW: primary)
                if let sidecarPath {
                    CameraLog.capture.info("wrote metadata → \(LogExportPlan.name(of: sidecarPath), privacy: .public)")
                }
            } catch {
                CameraLog.capture.error("metadata write failed (scan is fine): \(String(describing: error), privacy: .public)")
            }
        }

        return CaptureResult(
            path: primary,
            allPaths: savedURLs,
            timestamp: timestamp,
            iso: iso,
            shutter: shutter,
            aperture: aperture,
            sidecarPath: sidecarPath
        )
    }

    /// Download one on-camera file's bytes via gp_camera_file_get. No
    /// re-encoding anywhere: the returned Data is exactly what the body wrote.
    private func downloadFile(
        camera cam: UnsafeMutablePointer<Camera>,
        context ctx: OpaquePointer,
        folder: String,
        name: String
    ) throws -> Data {
        var file: OpaquePointer? = nil
        try CameraError.check(gp_file_new(&file))
        guard let file else { throw CameraError.captureFailed(reason: "gp_file_new returned NULL") }
        defer { gp_file_unref(file) }

        try folder.withCString { folderC in
            try name.withCString { nameC in
                try CameraError.check(
                    gp_camera_file_get(cam, folderC, nameC, GP_FILE_TYPE_NORMAL, file, ctx)
                )
            }
        }

        var dataPtr: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        try withUnsafeMutablePointer(to: &dataPtr) { dPtr in
            try withUnsafeMutablePointer(to: &size) { sPtr in
                try CameraError.check(gp_file_get_data_and_size(file, dPtr, sPtr))
            }
        }
        guard let dataPtr, size > 0 else {
            throw CameraError.captureFailed(reason: "empty file data")
        }
        return Data(bytes: dataPtr, count: Int(size))
    }

    /// Resolve `{ymd}`/`{hms}`/`{seq}`/`{ext}` tokens in a filename pattern.
    /// `nonisolated` so the Settings preview can call it directly (it's a pure
    /// function).
    ///
    /// `cameraExtension` is the extension of the file the camera produced
    /// (e.g. "CR2", "CR3", "JPG"). When provided, it fills `{ext}` and
    /// overrides any literal extension in the pattern. The saved name must
    /// never lie about the bytes inside (a pattern hardcoding ".CR2" would
    /// otherwise mislabel CR3 or JPEG files). That extension is uppercased,
    /// whatever case the camera or the pattern used. When nil, tokens resolve
    /// but `{ext}` and the pattern's literal extension are left alone.
    public nonisolated static func resolveFilename(
        pattern: String, timestamp: Date, sequence: Int, cameraExtension: String? = nil
    ) -> String {
        let cameraExtension = cameraExtension?.uppercased()
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        let ymd = String(format: "%04d%02d%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let hms = String(format: "%02d%02d%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let seq = String(format: "%04d", sequence)
        var resolved = pattern
            .replacingOccurrences(of: "{ymd}", with: ymd)
            .replacingOccurrences(of: "{hms}", with: hms)
            .replacingOccurrences(of: "{seq}", with: seq)
        if let ext = cameraExtension, !ext.isEmpty {
            resolved = resolved.replacingOccurrences(of: "{ext}", with: ext)
        }
        var name = sanitizeFilename(resolved)
        // Force the true extension when it is known. A pattern can end in a
        // literal ".CR2", so swap it rather than trusting it.
        // Exact comparison (not case-insensitive) so a lowercase ".cr3" in a
        // pattern is also normalized to the uppercase form.
        if let ext = cameraExtension, !ext.isEmpty {
            let ns = name as NSString
            if ns.pathExtension != ext {
                name = ns.deletingPathExtension + ".\(ext)"
            }
        }
        return name
    }

    /// The names one capture's files are saved under, and the shot number they
    /// carry.
    public struct CaptureNames: Equatable, Sendable {
        /// One name per file, in the order of the extensions passed in.
        public let names: [String]
        /// The shot number the names were resolved with. The next capture
        /// counts on from here.
        public let sequence: Int
    }

    /// Name every file of one capture so that none of them replaces a file
    /// already in the capture folder. Pure, so the tests drive it with a set of
    /// names instead of a folder.
    ///
    /// A capture's files are judged together: a name is taken when any file of
    /// the capture would land on an existing file, or when the `<basename>.xmp`
    /// sidecar for any of them already exists, so a new RAW never adopts an old
    /// frame's sidecar. When the pattern numbers its names with `{seq}`, the
    /// shot number counts up from `startingSequence` to the first one that is
    /// free for every file. Without `{seq}`, every file of the capture gets the
    /// same `_2`, `_3` and so on after its base name.
    ///
    /// - Parameters:
    ///   - cameraExtensions: one entry per file of the capture, the extension
    ///     of the camera's own filename, or nil when it had none.
    ///   - exists: whether a file of that name is already in the folder.
    public nonisolated static func captureNames(
        pattern: String, timestamp: Date, startingSequence: Int,
        cameraExtensions: [String?], exists: (String) -> Bool
    ) -> CaptureNames {
        func names(sequence: Int, suffix: Int) -> [String] {
            var out: [String] = []
            for ext in cameraExtensions {
                var name = resolveFilename(pattern: pattern, timestamp: timestamp,
                                           sequence: sequence, cameraExtension: ext)
                if suffix > 1 { name = suffixed(name, suffix) }
                // Two files of one capture with the same extension (a body
                // could emit two JPEGs) must not replace each other either.
                let first = name
                var n = 2
                while out.contains(name) {
                    name = suffixed(first, n)
                    n += 1
                }
                out.append(name)
            }
            return out
        }
        func taken(_ names: [String]) -> Bool {
            names.contains { name in
                exists(name) || exists(MetadataWriter.sidecarURL(forRAW: URL(fileURLWithPath: name)).lastPathComponent)
            }
        }

        // `{seq}` numbers the names only if it survives into the final name. A
        // `{seq}` in a directory part is dropped by `sanitizeFilename`, and
        // counting up would then never reach a free name.
        let numbered = resolveFilename(pattern: pattern, timestamp: timestamp, sequence: 1)
            != resolveFilename(pattern: pattern, timestamp: timestamp, sequence: 2)
        if numbered {
            var sequence = startingSequence
            while taken(names(sequence: sequence, suffix: 1)) { sequence += 1 }
            return CaptureNames(names: names(sequence: sequence, suffix: 1), sequence: sequence)
        }
        var suffix = 1
        while taken(names(sequence: startingSequence, suffix: suffix)) { suffix += 1 }
        return CaptureNames(names: names(sequence: startingSequence, suffix: suffix),
                            sequence: startingSequence)
    }

    /// `name` with `_<n>` after its base name, before the extension.
    nonisolated static func suffixed(_ name: String, _ n: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        return ns.deletingPathExtension + "_\(n)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Reduce a resolved name to a single safe path component so a user-set
    /// pattern can never write outside the chosen capture folder. Strips any
    /// directory parts (keeps the final segment), neutralizes path separators
    /// and parent-dir traversal, and never yields a hidden/empty name.
    nonisolated static func sanitizeFilename(_ name: String) -> String {
        var s = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "IMG" }
        return s
    }
}
