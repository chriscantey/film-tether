import Foundation
import os
import CGPhoto2

/// Central logging surface for the Camera module.
///
/// All logs go to macOS unified logging under subsystem `co.wonders.filmtether`,
/// streamable via:
///
///     log stream --predicate 'subsystem == "co.wonders.filmtether"' --info --debug
///
/// `.debug` messages from our own code are kept whatever the environment, because
/// the app's Info.plist sets OSLogPreferences to enable and persist Debug for this
/// subsystem.
///
/// `EOS_DEBUG=1` before launch (or `make run-debug`) installs a libgphoto2 log
/// callback that forwards its messages into the `gphoto2` category. With Homebrew's
/// libgphoto2 that callback receives nothing: Homebrew configures it with
/// `--disable-debug`, so libgphoto2_port compiles `gp_log_add_func` and `gp_log` as
/// stubs. Only a libgphoto2 built with debugging delivers lines to it.
public enum CameraLog {
    private static let subsystem = LogExportPlan.subsystem

    public static let connection = Logger(subsystem: subsystem, category: "Connection")
    public static let session = Logger(subsystem: subsystem, category: "Session")
    public static let properties = Logger(subsystem: subsystem, category: "Properties")
    public static let capture = Logger(subsystem: subsystem, category: "Capture")
    public static let liveView = Logger(subsystem: subsystem, category: "LiveView")
    public static let liveZoom = Logger(subsystem: subsystem, category: "LiveZoom")
    public static let icDevice = Logger(subsystem: subsystem, category: "ICDevice")
    public static let gphoto = Logger(subsystem: subsystem, category: "gphoto2")

    public static var isDebug: Bool {
        ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1"
    }

    /// One-time install of a libgphoto2 log callback that pipes its internal logging
    /// into our unified-log stream, when `EOS_DEBUG=1` (see the type doc for when it
    /// receives anything). Called from `AppLaunch.bootstrap`.
    public static func installGphotoLogBridge() {
        guard isDebug else { return }
        // Registered at GP_LOG_DEBUG, so GP_LOG_DATA lines are never delivered.
        gp_log_add_func(GP_LOG_DEBUG, { level, domain, message, _ in
            let d = domain.map { String(cString: $0) } ?? "?"
            let m = message.map { String(cString: $0) } ?? "?"
            switch level {
            case GP_LOG_ERROR:
                CameraLog.gphoto.error("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_VERBOSE:
                CameraLog.gphoto.info("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_DEBUG:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_DATA:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            default:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            }
        }, nil)
        CameraLog.gphoto.info("EOS_DEBUG=1, libgphoto2 log bridge installed (level=DEBUG)")
    }
}
