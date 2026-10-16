import Foundation

/// Help > Export Log: what gets run and what the file is called.
///
/// Turns a camera wedge into a file someone can send: the last day of the
/// app's unified log, which already carries the quit sequence and every
/// camera error with timestamps.
public enum LogExportPlan {
    /// The subsystem every Film Tether logger writes under (CameraLog and the
    /// App target's loggers use the same string).
    public static let subsystem = "co.wonders.filmtether"

    public static let logTool = "/usr/bin/log"

    // Keeping info and debug lines, with no sudo. By default macOS holds a
    // subsystem's info lines in memory only and drops debug lines, so `log
    // show` reads back errors and defaults and little else, and the connect:
    // step lines, logged at info, would never reach an export. Two layers fix that:
    //
    //   1. Resources/Info.plist carries OSLogPreferences for this subsystem,
    //      Level Enable Debug and Persist Debug: Apple's documented per-app
    //      alternative to `sudo log config`, read from the app bundle, so the
    //      lines are written to the store and survive a relaunch. That is what
    //      a stall usually ends in before anyone exports.
    //   2. The export appends this process's own entries read with OSLogStore
    //      at `.currentProcessIdentifier`, which needs no entitlement and
    //      includes lines held only in memory. It covers this run even if a
    //      macOS release stops honoring the plist key.
    //
    // Check it on a Mac: `log config --status --subsystem co.wonders.filmtether`
    // with the app running shows the levels in effect.

    /// How far back an export reaches: a day, so an export the morning after
    /// a night of scanning still holds that night.
    public static let exportHours = 24

    /// Arguments for `/usr/bin/log`, passed as an array, never through a shell.
    public static func arguments(lastHours: Int = exportHours) -> [String] {
        ["show",
         "--predicate", "subsystem == \"\(subsystem)\"",
         "--last", "\(lastHours)h",
         "--info",
         "--debug",
         "--style", "compact"]
    }

    /// The heading between the store's hour and this run's in-memory lines.
    public static let inProcessHeading = "\n==== This run, read in-process (info and debug, including lines kept only in memory) ====\n"

    /// One in-process entry, in the same shape the compact style prints.
    public static func inProcessLine(date: Date, level: String, category: String, message: String,
                                     timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "\(f.string(from: date)) \(level) [\(subsystem):\(category)] \(message)"
    }

    /// A file's name for a log line, without the folders above it. Log lines
    /// that name a file on this Mac use this, so an exported log carries none
    /// of its folders.
    public static func name(of url: URL) -> String {
        url.lastPathComponent
    }

    /// `FilmTether-log-2026-09-27.txt`, in the local calendar.
    public static func defaultFileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return "FilmTether-log-\(f.string(from: date)).txt"
    }
}
