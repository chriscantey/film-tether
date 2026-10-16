import SwiftUI
import AppKit
import os

@main
struct FilmTetherApp: App {
    @StateObject private var model: AppModel = {
        _ = AppLaunch.bootstrap
        return AppModel()
    }()

    // NSApplicationDelegateAdaptor hooks the AppKit lifecycle from SwiftUI.
    // An observer added in App.init() would hit a known @StateObject
    // double-instantiation issue: init-time access of self.model creates one
    // AppModel and view mount creates another, so the hook and the views
    // would hold different models.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Film Tether") {
            MainView()
                .environmentObject(model)
                .onAppear { AppUpdates.start() }
                .task {
                    // Hand the model to the delegate so its applicationShouldTerminate
                    // hook can run a clean stop() before the process dies.
                    AppDelegate.activeModel = model
                    await model.start()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Film Tether") { FilmTetherApp.showAboutPanel() }
                // Check for Updates… sits under About. A build with no feed
                // (a dev build) has no updater and no item.
                if let updater = AppUpdates.updater {
                    Divider()
                    CheckForUpdatesButton(updater: updater)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Capture") { Task { await model.captureNow() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button(model.isLiveViewOn ? "Stop Live View" : "Start Live View") {
                    Task {
                        if model.isLiveViewOn {
                            await model.stopLiveView()
                        } else {
                            await model.startLiveView()
                        }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Set Camera Clock to This Mac") {
                    Task { await model.syncCameraClockLocal() }
                }
                .help("Set the camera clock to this Mac's local time, so the capture time in each RAW matches the time Finder shows.")
            }
            // Everything that changes how the preview *looks* belongs in View,
            // not File. `.toolbar` is the placement that lands there. The View
            // menu is otherwise empty, and an empty menu on macOS opens and
            // instantly closes again, which looks broken.
            CommandGroup(replacing: .toolbar) {
                Button(model.showMeteringOverlay ? "Hide Zoom Box" : "Show Zoom Box") {
                    model.showMeteringOverlay.toggle()
                }
                .help("Show or hide the box that marks where the Shift zoom looks.")
                Button("Rotate Preview Right (now \(model.previewRotation.displayName))") {
                    model.rotatePreviewRight()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Turn the live preview 90° clockwise. Cmd-R. Remembered across launches. The camera and the RAW are never rotated. The rotation is saved in the capture's metadata, so an app that reads it can turn the picture the same way.")
                Button("Rotate Preview Left") {
                    model.rotatePreviewLeft()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Turn the live preview 90° counter-clockwise. Cmd-Shift-R.")
                Button(model.previewMirrored
                       ? "Un-Mirror Preview" : "Mirror Preview (Flip Horizontally)") {
                    model.toggleMirror()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help("Flip the preview left to right, for film sitting emulsion side up in the holder. Cmd-Shift-M. Remembered across launches. A vertical flip is this plus two Rotate Rights. The RAW's image data is untouched. The flip is saved in the capture's metadata.")
                Divider()
                Button(model.displayedAdjustments.invert
                       ? "Show Preview as Negative" : "Show Preview as Positive") {
                    model.toggleInvert()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .help("Invert the preview so a negative shows as the positive image. Cmd-I. The captured RAW is still the negative. The setting is saved in the capture's metadata.")
                Button(model.previewAdjustments.monochrome
                       ? "Show Preview in Color" : "Show Preview in Black & White") {
                    model.toggleMonochrome()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .help("Switch the preview between black and white and color. Raw pixels off a black and white negative carry no useful color. Cmd-B. The camera and the RAW's image data are untouched. The setting is saved in the capture's metadata.")
                Button(model.isPickingWhiteBalance
                       ? "Cancel White Balance Pick" : "Pick White Balance from Preview…") {
                    model.toggleWhiteBalancePicker()
                }
                .disabled(!model.canPickWhiteBalance)
                .help("Choose this, then click the unexposed film base in the preview to neutralize its color cast. If the preview is showing the positive, it shows the negative while you pick and switches back after.")
                Button("Reset White Balance") {
                    model.resetWhiteBalance()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.previewAdjustments.whiteBalance == nil)
                .help("Go back to the camera's as-shot color. Cmd-Shift-W.")
                Divider()
                Button("Auto-Crop") { model.runAutoCrop() }
                    .disabled(!model.isLiveViewOn || model.previewZoom != .fit)
                    .help("Find the negative under the lens and put an adjustable crop box on it. It runs only when you ask, so it never jumps around while you're still positioning the film.")
                // Cmd-K, not a bare Return. A menu item's key equivalent is
                // dispatched before the responder chain, so a bare Return here
                // would be swallowed from the Camera and Film fields on row 3,
                // where Return commits a value into its history, for as long
                // as a crop exists. Cmd-Return is already Capture, and
                // colliding with it would make fixing a crop fire the shutter
                // or vice versa.
                Button(model.isCropEditing ? "Fix Crop in Place" : "Adjust Crop") {
                    model.toggleCropEditing()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!model.isCropActive)
                .help("Fixing the crop leaves a hairline outline and stops the overlay taking the pointer, so click-to-move and the eyedropper underneath it work again. Cmd-K.")
                Button("Center Crop") { model.centerCrop() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!model.isCropActive)
                    .help("Slide the crop box to the middle of the frame, same size. Cmd-Shift-K.")
                Button("Center Zoom Box") { Task { await model.centerMeteringBox() } }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                    .disabled(!model.isLiveViewOn)
                    .help("Put the zoom box back in the middle of the frame. If the 500% view is on, it follows. Cmd-Shift-0.")
                Button("Clear Crop") { model.clearCrop() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(!model.isCropActive)
                    .help("Remove the crop entirely. Cmd-Delete.")
                Button("Clear Straightening") { model.resetStraightening() }
                    .disabled(!model.isStraightened)
                    .help("Undo the straightening the crop box's rotate band applied, leaving the quarter-turn rotation alone. An unstraightened preview is pixel exact. A straightened one is resampled.")
                Divider()
                Button(model.focusPeakingEnabled ? "Disable Focus Peaking" : "Enable Focus Peaking") {
                    model.focusPeakingEnabled.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .help("Highlight the parts of the preview that are in focus. Cmd-P.")
                Button("Cycle Peaking Color (currently \(model.focusPeakingColor.displayName))") {
                    model.cycleFocusPeakingColor()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Step through the eight peaking colors. Cmd-Shift-P. Handy when the current one blends into the picture.")
            }
            // There is no sidebar. Left alone, SwiftUI's "Toggle Sidebar" lands
            // in the Help menu of all places, where it does nothing.
            CommandGroup(replacing: .sidebar) { }
            // Help > Film Tether Help opens the write-up on GitHub. Left alone,
            // macOS shows "Help isn't available for Film Tether".
            CommandGroup(replacing: .help) {
                Button("Film Tether Help") { NSWorkspace.shared.open(AppInfo.helpURL) }
            }
            // Help > Export Log…, so a problem report can carry the log as a file.
            CommandGroup(after: .help) {
                Button("Export Log…") { LogExport.run() }
                    .help("Save the last 24 hours of Film Tether's log to a file, to send with a problem report.")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    /// Standard macOS About panel, populated with the marketing version
    /// (Info.plist CFBundleShortVersionString) and the injected build stamp
    /// (git short hash and bundle time).
    static func showAboutPanel() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        // Contributors are linked rather than listed, because a name list
        // compiled into the binary goes stale when someone new lands work.
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Other people have put work into this app. They're listed under ",
            attributes: body))
        credits.append(NSAttributedString(
            string: "Contributors",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://github.com/chriscantey/film-tether#contributors")!,
            ]))
        credits.append(NSAttributedString(
            string: ", and huge thanks to them. The cameras it works with are listed under ",
            attributes: body))
        credits.append(NSAttributedString(
            string: "Supported cameras",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: AppInfo.supportedCamerasURL,
            ]))
        credits.append(NSAttributedString(
            string: ".\n\n"
                  + "Built on libgphoto2, part of the gPhoto project, and on libusb, "
                  + "libexif, libintl from GNU gettext and libltdl from GNU Libtool, all "
                  + "under the GNU LGPL, and on libjpeg-turbo. This software is based in "
                  + "part on the work of the Independent JPEG Group. The license texts "
                  + "and notices are inside the app in Contents/Resources/Licenses, and "
                  + "RELINKING.md in the repository explains how to replace these "
                  + "libraries with your own builds. Thanks to their maintainers.\n\n"
                  + AppUpdates.aboutSentence,
            attributes: body))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Film Tether",
            .applicationVersion: version,
            .version: AppInfo.buildStamp,
            .credits: credits,
        ])
    }
}

/// AppKit delegate that hooks the standard `applicationShouldTerminate` path
/// for a clean libgphoto2 shutdown. Without it, Cmd-Q exits the process
/// without ever running model.stop(), so gp_camera_exit is never called and
/// the body's PTP session stays wedged for the next launch (-10 timeout
/// chains until the body is power-cycled).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from FilmTetherApp.body.task once SwiftUI has finished mounting the
    /// @StateObject AppModel. Until then it is nil, and
    /// applicationShouldTerminate quits without stopping the camera.
    static var activeModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarTidy.install()
    }

    /// Async-clean shutdown. applicationWillTerminate with DispatchGroup.wait
    /// cannot work: it blocks the main thread, and model.stop() is @MainActor
    /// and needs that thread. The self-deadlock leaves the camera in live view
    /// (mirror up, wedged) and makes quit hang the full timeout.
    /// applicationShouldTerminate with .terminateLater lets the run loop keep
    /// turning while stop() runs (dropping EVF, then gp_camera_exit), and the
    /// reply then lets the app exit. A safety timer force-quits if stop()
    /// hangs on a sluggish body.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.activeModel else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NSApp.reply(toApplicationShouldTerminate: true)   // idempotent safety net
        }
        return .terminateLater
    }
}
