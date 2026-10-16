import Foundation

/// The value Film Tether writes to the camera's `datetimeutc` so that EXIF
/// DateTimeOriginal comes out as this Mac's local wall time.
///
/// `datetimeutc` takes a raw epoch (libgphoto2 2.5.33 `_put_UINT32_as_time`,
/// no conversion). The body then shows and stamps `epoch + its own zone`. The
/// 7D has no daylight-saving setting and keeps its zone on standard time, so
/// writing the true UTC leaves it exactly an hour behind for all of daylight
/// saving time: EXIF 23:00:22 for a 00:00:24 PDT capture, with the manual
/// offset setting at its default of 0. So for a body that does not
/// observe DST, the write adds this Mac's current DST offset: in July it is an
/// hour ahead of UTC, in January nothing.
///
/// Bodies that apply DST themselves must not get it twice. The R5 is the one
/// verified (a DST-on zone, EXIF matched host wall time with no offset,
/// CameraProperties.syncDateTimeToHostLocal). Every other body is
/// treated as the 7D until measured.
///
/// The Settings offset (`cameraTZOffsetMinutes`) still adds on top, for a
/// camera whose zone is not this Mac's standard time.
public enum CameraClock {
    /// Bodies verified to apply daylight saving time themselves.
    public static let bodiesObservingDST: Set<String> = ["Canon EOS R5"]

    public static func observesDST(model: String?) -> Bool {
        guard let model else { return false }
        return bodiesObservingDST.contains(model.trimmingCharacters(in: .whitespaces))
    }

    /// The epoch to write for `now`.
    public static func datetimeUTCValue(now: Date, hostZone: TimeZone = .current,
                                        cameraObservesDST: Bool, extraOffsetMinutes: Int = 0) -> Int32 {
        let dst = cameraObservesDST ? 0 : Int(hostZone.daylightSavingTimeOffset(for: now))
        return Int32(now.timeIntervalSince1970) + Int32(dst) + Int32(extraOffsetMinutes * 60)
    }
}
