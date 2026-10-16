import XCTest
@testable import Camera

/// Help > Export Log runs `log show` for the app's subsystem over the
/// last 24 hours and names the file after the day.
final class LogExportPlanTests: XCTestCase {
    func testArgumentsAreTheLastDayOfTheSubsystemAtInfoAndDebugLevel() {
        XCTAssertEqual(LogExportPlan.arguments(), [
            "show", "--predicate", "subsystem == \"co.wonders.filmtether\"",
            "--last", "24h", "--info", "--debug", "--style", "compact",
        ])
    }

    /// The app bundle asks macOS to keep and persist info and debug lines for
    /// the subsystem, with no sudo (LogExportPlan, layer 1). Read from the
    /// source Info.plist that scripts/bundle.sh copies into the bundle.
    func testInfoPlistPersistsInfoAndDebugForTheSubsystem() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let prefs = try XCTUnwrap(root["OSLogPreferences"] as? [String: Any])
        let sub = try XCTUnwrap(prefs[LogExportPlan.subsystem] as? [String: Any])
        let opts = try XCTUnwrap(sub["DEFAULT-OPTIONS"] as? [String: Any])
        let level = try XCTUnwrap(opts["Level"] as? [String: String])
        XCTAssertEqual(level["Enable"], "Debug")
        XCTAssertEqual(level["Persist"], "Debug")
    }

    func testAnInProcessLineCarriesTimeLevelCategoryAndMessage() {
        let utc = TimeZone(identifier: "UTC")!
        let line = LogExportPlan.inProcessLine(date: Date(timeIntervalSince1970: 1_790_566_200.25), level: "Debug",
                                               category: "Connection", message: "connect: t+12 ms ready", timeZone: utc)
        XCTAssertEqual(line, "2026-09-28 03:30:00.250 Debug [co.wonders.filmtether:Connection] connect: t+12 ms ready")
    }

    func testDefaultNameIsTheLocalDate() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        // 03:30 UTC on the 28th is still the 27th in Los Angeles.
        let d = Date(timeIntervalSince1970: 1_790_566_200)
        XCTAssertEqual(LogExportPlan.defaultFileName(for: d, timeZone: la), "FilmTether-log-2026-09-27.txt")
    }

    // MARK: - File names in log lines

    func testANestedPathLogsOnlyTheFileName() {
        let url = URL(fileURLWithPath: "/Users/you/Pictures/Scans/roll 12/IMG_0001.CR2")
        XCTAssertEqual(LogExportPlan.name(of: url), "IMG_0001.CR2")
    }

    func testABareNameLogsAsItIs() {
        XCTAssertEqual(LogExportPlan.name(of: URL(fileURLWithPath: "IMG_0001.xmp")), "IMG_0001.xmp")
    }

    func testATrailingSlashLogsTheLastNameOnly() throws {
        let url = try XCTUnwrap(URL(string: "file:///Users/you/Pictures/Scans/"))
        XCTAssertEqual(LogExportPlan.name(of: url), "Scans")
    }
}
