import AppKit

/// Checked only when a camera error is about to be shown, to pick the hint.
/// Nothing here quits or kills anything.
enum OtherCameraApps {
    /// Apps that can take the body through ptpcamerad.
    static let bundleIDs: Set<String> = ["com.apple.Preview", "com.apple.Image_Capture", "com.apple.Photos"]

    static func cameraAppsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(bundleIDs.contains) ?? false
        }
    }

    /// `pgrep -x ptpcamerad`, argument array, no shell. Exit 0 means found.
    static func ptpDaemonRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "ptpcamerad"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
