import Foundation
import ImageCaptureCore

/// Releases macOS's PTP claim on a Canon EOS body so libgphoto2 can take over.
///
/// macOS launches its PTP camera helper on hotplug, and the helper claims the body.
/// Symptom if not released: `gp_camera_init` returns `GP_ERROR_IO_USB_CLAIM (-53)` or live view
/// stalls after 1-2 frames.
public final class ICDeviceClaim: NSObject, @unchecked Sendable, ICDeviceBrowserDelegate {
    /// Canon's USB vendor ID. Matches all Canon EOS bodies.
    private static let canonVendorID: Int = 0x04a9

    private let browser = ICDeviceBrowser()
    private var matchedDevices: [ICCameraDevice] = []

    override private init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    /// Release any macOS-side claim on an attached Canon camera. Takes about
    /// 2 s: 1.5 s for the browser to enumerate, requestEject on any matches,
    /// then 0.5 s to settle.
    public static func releaseCanonEos() async {
        let claim = ICDeviceClaim()
        await claim.releaseInternal()
    }

    private func releaseInternal() async {
        browser.start()
        // Give the browser ~1.5s to enumerate. Longer waits don't help on cold plug.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for device in matchedDevices {
            // requestEject() replaces requestEjectOrDisconnect() (deprecated
            // macOS 10.15). Best-effort.
            try? await device.requestEject()
        }
        // Allow eject to propagate.
        try? await Task.sleep(nanoseconds: 500_000_000)
        browser.stop()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser,
                              didAdd device: ICDevice,
                              moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        // Match any Canon body (vendor ID), or fall back to name match for legacy enumerations
        // that report vendor/product as 0.
        if camera.usbVendorID == Self.canonVendorID {
            matchedDevices.append(camera)
            return
        }
        let name = camera.name ?? ""
        if name.localizedCaseInsensitiveContains("Canon EOS") {
            matchedDevices.append(camera)
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser,
                              didRemove device: ICDevice,
                              moreGoing: Bool) {
        if let camera = device as? ICCameraDevice,
           let idx = matchedDevices.firstIndex(of: camera) {
            matchedDevices.remove(at: idx)
        }
    }

    /// Fallback: terminate macOS's PTP camera helper processes.
    /// Safe to call even when no helper is running, and absorbs all errors.
    ///
    /// Older macOS releases run `PTPCamera`, and current ones run
    /// `/usr/libexec/ptpcamerad` (macOS 13 already does). We try both names.
    /// Each `killall` is a no-op if the process isn't running.
    public static func killPTPCameraHelper() {
        let candidates = ["ptpcamerad", "PTPCamera"]
        for name in candidates {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [name]
            task.standardError = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }
}

