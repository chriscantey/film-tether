import SwiftUI
import AppKit
import Camera

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $settings.settingsTab) {
            captureTab()
                .tabItem { Label("Capture", systemImage: "camera.shutter.button") }
                .tag(AppSettings.SettingsTab.capture)

            liveViewTab()
                .tabItem { Label("Live View", systemImage: "viewfinder") }
                .tag(AppSettings.SettingsTab.liveView)

            cameraTab()
                .tabItem { Label("Camera", systemImage: "camera") }
                .tag(AppSettings.SettingsTab.camera)

            hotkeyTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(AppSettings.SettingsTab.hotkeys)

            // Only a build with a feed has an updater to switch.
            if let updater = AppUpdates.updater {
                UpdatesSettingsTab(updater: updater)
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                    .tag(AppSettings.SettingsTab.updates)
            }
        }
        .padding()
    }

    // MARK: - Live View

    @ViewBuilder
    private func liveViewTab() -> some View {
        Form {
            Section("Focus peaking") {
                HStack {
                    Picker("Mode", selection: $settings.focusPeakingMode) {
                        ForEach(FocusPeaking.Mode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("""
                            Edges: highlights sharp outlines, like the edge of a building or a face. Works on any subject.

                            Grain, the default: picks up very fine texture, a few pixels across. Smooth areas stay dark, and strong edges still show. Made for scanning film, where the grain is the finest detail there is to focus on.

                            If the two look the same on what's under the lens, try Grain on a grainier stock or raise Sensitivity.
                            """)
                }

                HStack {
                    Text("Sensitivity")
                    Slider(value: $settings.focusPeakingIntensity, in: 1.0...10.0, step: 0.5)
                    Text(String(format: "%.1f", settings.focusPeakingIntensity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Section("Peaking color") {
                colorSwatchGrid()
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }

    @ViewBuilder
    private func colorSwatchGrid() -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FocusPeaking.PeakColor.allCases, id: \.self) { color in
                colorSwatch(color)
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(_ color: FocusPeaking.PeakColor) -> some View {
        let rgb = color.swatchRGB
        let isSelected = settings.focusPeakingColor == color
        Button {
            settings.focusPeakingColor = color
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                    .frame(height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                                    lineWidth: isSelected ? 3 : 1)
                    )
                Text(color.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Show focus peaking in \(color.displayName.lowercased())")
    }

    // MARK: - Camera

    @ViewBuilder
    private func cameraTab() -> some View {
        Form {
            Section("Camera clock") {
                if let cameraTime = model.snapshot.cameraDateTime {
                    HStack {
                        Text("Camera time, cached reading")
                        Spacer()
                        Text(Self.fullClockFormatter.string(from: cameraTime))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    let drift = cameraTime.timeIntervalSinceNow
                    let absDrift = abs(drift)
                    HStack {
                        Text("That reading against this Mac's clock now")
                        Spacer()
                        Text(driftString(drift))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(absDrift > 60 ? .red : .secondary)
                    }
                } else {
                    Text("Connect a camera to read its clock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Set camera clock to this Mac's time") {
                    Task { await model.syncCameraClockLocal() }
                }
                .disabled(model.snapshot.cameraDateTime == nil)
                Toggle("Set the camera clock every time a camera connects", isOn: $settings.autoSyncClockOnConnect)
            }

            Section("Status bar") {
                Toggle("Show camera battery", isOn: $settings.showBatteryIndicator)
                Toggle("Show the last metered shutter speed", isOn: $settings.showMeteredShutter)
                Toggle("Keep the camera clock showing", isOn: $settings.showCameraClock)
                Toggle("Show white balance gains", isOn: $settings.showWhiteBalanceGains)
                Toggle("Show crop corners", isOn: $settings.showCropDetail)
                Text("Some cameras only update the metered reading after a capture or a settings change, so it can lag behind live view. The clock always shows once the camera is more than five minutes off. Right-click the status bar for the same switches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Camera clock offset") {
                HStack {
                    Text("Offset")
                    Spacer()
                    Picker("", selection: $settings.cameraTZOffsetMinutes) {
                        Text("0").tag(0)
                        Text("+60 min").tag(60)
                        Text("+120 min").tag(120)
                        Text("-60 min").tag(-60)
                        Text("-120 min").tag(-120)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("""
                            Added to this Mac's time when Film Tether sets the camera clock.

                            Film Tether already adds the daylight saving hour for a camera that keeps standard time, so with the camera set to this Mac's time zone, leave this at 0.

                            Use it only when capture times still come out a whole number of hours off, for example with the camera set to another time zone: one zone east of this Mac needs -60, one zone west needs +60.
                            """)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }

    static let fullClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f
    }()

    private func driftString(_ drift: TimeInterval) -> String {
        let abs = Swift.abs(drift)
        let sign = drift >= 0 ? "+" : "-"
        if abs < 60 { return "\(sign)\(Int(abs))s" }
        if abs < 3600 { return "\(sign)\(Int(abs / 60))m \(Int(abs.truncatingRemainder(dividingBy: 60)))s" }
        let h = Int(abs / 3600)
        let m = Int((abs.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(sign)\(h)h \(m)m"
    }

    // MARK: - Capture

    @ViewBuilder
    private func captureTab() -> some View {
        Form {
            Section("Capture folder") {
                HStack {
                    Text(settings.captureFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseCaptureFolder() }
                }
                Text("Each capture is saved here with the camera's own extension (.CR2, .CR3, .JPG). Set the camera to RAW to keep the full sensor data, or to RAW+JPEG to get both files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Metadata") {
                Toggle("Write metadata into the RAW file", isOn: $settings.embedMetadata)
                Text(settings.embedMetadata
                     ? "Camera and film details are written inside the RAW file. The image data is never touched, and the file is only replaced once the write checks out. The details go wherever the file goes."
                     : "Camera and film details are written to a .xmp sidecar file next to the RAW, and the RAW itself is never written to. Keep the two files together when you move them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Filename pattern") {
                TextField("", text: $settings.filenamePattern)
                    .font(.system(.body, design: .monospaced))
                Text("Tokens: {ymd} is the date (20260919), {hms} the time (143005), {seq} this session's shot count with leading zeros, skipping numbers already used in the folder, and {ext} the camera's own extension (CR2, CR3, JPG). An extension typed into the pattern is swapped for the real one when the file is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Example: \(previewFilename())")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsPane()
    }

    /// Uses the capture's own resolver (including its path-safety
    /// sanitization), with sequence 1 and no camera extension.
    private func previewFilename() -> String {
        CameraCapture.resolveFilename(pattern: settings.filenamePattern, timestamp: Date(), sequence: 1)
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.captureFolder
        panel.prompt = "Choose"
        panel.message = "Choose a folder for captures"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setCaptureFolder(url)
        }
    }

    // MARK: - Hotkeys

    @ViewBuilder
    private func hotkeyTab() -> some View {
        Form {
            Section("Capture") {
                Picker("Capture key", selection: $settings.captureKeyCode) {
                    ForEach(KeyCodeLabel.common, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
                Text("Space by default. Press once to capture. Cmd-Return captures too. The capture key does nothing while you're typing in a text field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hold to zoom") {
                Toggle("Hold Shift to zoom", isOn: $settings.zoomUsesShift)
                if !settings.zoomUsesShift {
                    Picker("Hold key", selection: $settings.zoomKeyCode) {
                        ForEach(KeyCodeLabel.common, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                }
                Text(settings.zoomUsesShift
                     ? "Hold Shift over live view to see the camera's own 5× magnified view, and let go to see the whole frame again. Drag the zoom box first to choose where it looks. The arrow keys move it while you hold. Works only while Film Tether's window is in front."
                     : "Hold the chosen key to see the 5× view, and let go to see the whole frame again. The arrow keys move the zoom box while you hold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hold key in other apps") {
                Toggle("Use the hold key while another app is in front", isOn: $settings.enableGlobalHotkey)
                Text("Applies to the hold-to-zoom key when Hold Shift to zoom is off. Needs the Accessibility and Input Monitoring permissions. Without both, the hold key still works while Film Tether is in front. The capture, focus and autofocus keys only work while Film Tether's window is in front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.enableGlobalHotkey {
                    HStack {
                        permissionRow("Accessibility", granted: model.permissionsState.accessibility) {
                            model.requestAccessibility()
                        }
                        permissionRow("Input Monitoring", granted: model.permissionsState.inputMonitoring) {
                            model.requestInputMonitoring()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The hold-key monitor reads these when it starts, so restart it on a
        // change rather than leaving the change to the next connect.
        .onChange(of: settings.zoomUsesShift) { model.applyHoldKeySettings() }
        .onChange(of: settings.zoomKeyCode) { model.applyHoldKeySettings() }
        .onChange(of: settings.enableGlobalHotkey) { model.applyHoldKeySettings() }
        .settingsPane()
    }

    @ViewBuilder
    private func permissionRow(_ label: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(label).font(.caption)
            if !granted {
                Button("Request") { request() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    /// Each tab is exactly as tall as its own content, so no tab scrolls. The
    /// Metadata caption and the Hotkeys permission rows change height with
    /// their settings, so no single fixed height fits. The grouped Form stops
    /// scrolling and reports its content height, and the Settings window
    /// resizes to it on each tab.
    func settingsPane() -> some View {
        scrollDisabled(true)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}
