import Foundation

/// One-time process setup for libgphoto2's `dlopen` search paths.
///
/// libgphoto2 dynamically loads camlibs (e.g. `ptp2.so`) and iolibs (e.g.
/// `usb1.so`) at `gp_camera_init` time. The default search path is the
/// compile-time prefix of whatever libgphoto2 binary we linked, for a Homebrew install
/// that's `/opt/homebrew/Cellar/libgphoto2/.../lib/libgphoto2/...`. That path embeds a
/// brew version number that drifts on `brew upgrade`, so the bundled app would break
/// silently after an unrelated brew operation.
///
/// To keep the .app self-contained, the bundle script copies the camlibs and iolibs into
/// `Contents/Resources/camlibs/` and `Contents/Resources/iolibs/` and we override the
/// search via the `CAMLIBS` / `IOLIBS` env vars before any libgphoto2 call.
public enum CameraEnvironment {
    private static let setupOnce: Void = {
        guard let resources = Bundle.main.resourcePath else { return }
        let camlibs = "\(resources)/camlibs"
        let iolibs = "\(resources)/iolibs"
        // Only override if the directory exists in the bundle. Under `swift run`
        // (no app bundle) libgphoto2 keeps its compile-time default (brew prefix).
        if FileManager.default.fileExists(atPath: camlibs) {
            setenv("CAMLIBS", camlibs, 1)
        }
        if FileManager.default.fileExists(atPath: iolibs) {
            setenv("IOLIBS", iolibs, 1)
        }
        if let v = pchddResend(environment: ProcessInfo.processInfo.environment) {
            setenv(pchddResendKey, v, 1)
        } else {
            unsetenv(pchddResendKey)
        }
    }()

    /// The PCHDDCapacity resend for the stuck connect. With it set, the camlib
    /// resends PCHDDCapacity at 500 ms, and on a 7D a stuck connect then
    /// answered at 561 ms and autofocus drove the sharpness score from 4.5 to
    /// 665.6. The stuck connect: on some connects the 7D never answers the
    /// AvailableShots read after the capture target switches to the PC, the
    /// wait our patched ptp2 bounds at 1 s
    /// (`patches/eos-capture-target-bounded-wait.diff`). A body that misses that
    /// answer accepts every autofocus command for the rest of the session and
    /// never drives. Over 18 measured launches, every slow connect (first
    /// config read 1136 to 1148 ms) had no drive and every fast one (143 to
    /// 161 ms) drove. 0x7fffffff is the value that was measured.
    public static let pchddResendKey = "FT_RESEND_PCHDD"
    /// On by default. On the 7D measured, the body went many sessions without
    /// entering the capture-target wait after a few resends, then entered it
    /// again as before, so the resend is not known to change the body for good.
    /// With no USB cable attached, that body still saves pictures to its card.
    /// `pchddResendOffKey` turns the resend off.
    public static let pchddResendDefault = "0x7fffffff"
    /// Set to any value to turn the resend off.
    public static let pchddResendOffKey = "FT_NO_RESEND_PCHDD"

    /// The resend value to export, or nil to leave it unset. An explicit value in the
    /// environment wins over the default.
    public static func pchddResend(environment env: [String: String]) -> String? {
        if env[pchddResendOffKey] != nil { return nil }
        if let v = env[pchddResendKey], !v.isEmpty { return v }
        return pchddResendDefault
    }

    /// Idempotent and thread-safe (backed by Swift's static-let-once init).
    public static func setup() {
        _ = setupOnce
    }
}
