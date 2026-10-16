import AppKit
import Camera
import os
import OSLog

private let exportLog = Logger(subsystem: LogExportPlan.subsystem, category: "LogExport")

/// Help > Export Log…. Writes the last day of the app's unified log to a
/// file the user picks, defaulting to the capture folder, then shows it in
/// Finder, ready to attach to a problem report.
@MainActor
enum LogExport {
    /// `log show` over an hour can take a while with no feedback, so a second
    /// menu press while one runs does nothing.
    private static var isRunning = false

    static func run() {
        guard !isRunning else { return }
        let panel = NSSavePanel()
        panel.title = "Export Log"
        panel.message = "Saves the last 24 hours of Film Tether's log, to send with a problem report."
        panel.nameFieldStringValue = LogExportPlan.defaultFileName(for: Date())
        panel.directoryURL = AppSettings.shared.captureFolder
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportLog.info("export log → \(LogExportPlan.name(of: url), privacy: .public)")
        isRunning = true
        Task.detached {
            let result = write(to: url)
            await MainActor.run { finish(url: url, error: result) }
        }
    }

    /// Runs `/usr/bin/log show` with stdout straight into the file. Returns
    /// nil on success, or what went wrong.
    nonisolated private static func write(to url: URL) -> String? {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else {
            return "Could not create \(url.lastPathComponent)."
        }
        defer { try? out.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: LogExportPlan.logTool)
        p.arguments = LogExportPlan.arguments()
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "Could not run log: \(error.localizedDescription)" }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "log exited with status \(p.terminationStatus). \(text)"
        }
        appendThisRun(to: out)
        return nil
    }

    /// This process's own entries for the same span, info and debug included,
    /// read in-process with OSLogStore (LogExportPlan, layer 2). Best effort:
    /// a store that will not open leaves the export as `log show` wrote it.
    nonisolated private static func appendThisRun(to out: FileHandle) {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let start = store.position(date: Date().addingTimeInterval(-Double(LogExportPlan.exportHours) * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", LogExportPlan.subsystem)
        guard let entries = try? store.getEntries(at: start, matching: predicate) else { return }
        var text = LogExportPlan.inProcessHeading
        for case let e as OSLogEntryLog in entries {
            let level: String
            switch e.level {
            case .debug: level = "Debug"
            case .info: level = "Info"
            case .notice: level = "Default"
            case .error: level = "Error"
            case .fault: level = "Fault"
            default: level = "Other"
            }
            text += LogExportPlan.inProcessLine(date: e.date, level: level, category: e.category,
                                                message: e.composedMessage) + "\n"
        }
        _ = out.seekToEndOfFile()
        out.write(Data(text.utf8))
    }

    private static func finish(url: URL, error: String?) {
        isRunning = false
        if let error {
            // No empty or partial file left behind to be mistaken for a log.
            try? FileManager.default.removeItem(at: url)
            exportLog.error("export log failed: \(error, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "The log could not be exported."
            alert.informativeText = error
            alert.runModal()
            return
        }
        exportLog.info("export log done: \(LogExportPlan.name(of: url), privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
