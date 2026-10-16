import SwiftUI
import FilmStyle
import Camera

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    static let cameraClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            connectionBadge()
            Text(model.snapshot.modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Camera mode (set by the body's mode dial)")
            // Optional metered shutter display, opt-in via Settings > Camera >
            // Status bar. Shows only when the body has emitted a value (after
            // capture or a settings change). Blank when not available.
            // Off by default because the value is sporadic on the 7D.
            if settings.showMeteredShutter, let metered = model.snapshot.meteredShutter {
                Label(PropertyLabels.shutter(metered), systemImage: "camera.metering.center.weighted")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("The last metered shutter speed the camera reported. Some cameras update it only after a capture or a settings change.")
            }
            if settings.showBatteryIndicator, model.snapshot.battery != "—" {
                Label(model.snapshot.batteryLabel, systemImage: "minus.plus.batteryblock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Camera battery")
            }
            // Reconstructed from the stored offset and re-rendered each second,
            // so it ticks along with the system clock. Showing the raw stored
            // timestamp instead would freeze at the last read (the ptp2 driver
            // caches the camera clock per session), drift visibly, and turn
            // red on a correctly synced camera.
            // Shown only when the camera has drifted more than 300 s, unless
            // switched on from the footer's right-click menu or Settings.
            if let offset = model.snapshot.cameraClockOffset,
               settings.showCameraClock || abs(offset) > 300 {
                let drift = abs(offset)
                let isStale = drift > 300  // 5 min off = needs sync
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button {
                        Task { await model.syncCameraClockLocal() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundStyle(isStale ? .red : .secondary)
                            Text(Self.cameraClockFormatter.string(
                                from: context.date.addingTimeInterval(offset)
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isStale ? .red : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .help(isStale
                      ? "The camera clock was \(Int(drift)) s off this Mac's clock when last read. Click to set it."
                      : "The camera clock was within \(Int(drift)) s of this Mac's clock when last read. Click to set it again.")
            }
            if settings.showWhiteBalanceGains, let wb = model.previewAdjustments.whiteBalance {
                Text(String(format: "WB %.2f/%.2f/%.2f", wb.red, wb.green, wb.blue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("White balance gains (R, G, B) from the eyedropper, applied to the preview. The RAW is unaffected.")
            }
            // The crop's corners, in the pixels of the file it will be applied
            // to once a capture has told us how big that is. The live preview's
            // own pixels are not the ones the operator cares about, and the tick
            // says whether the box is settled or still taking the pointer.
            // The short state always, the corners only when switched on. They
            // are in the tooltip either way.
            if let px = model.cropPixelRect {
                let state = model.isCropEditing ? "Crop…" : "Crop ✓"
                let corners = String(format: "%.0f,%.0f → %.0f,%.0f  (%.0f×%.0f)",
                                     px.minX, px.minY, px.maxX, px.maxY, px.width, px.height)
                Text(settings.showCropDetail ? "\(state) \(corners)" : state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(corners + ". " + (model.lastCaptureSize == nil
                          ? "Crop corners in live-preview pixels. They'll be restated in the captured file's pixels once a frame has been taken. Written into the capture's metadata in normalized sensor coordinates, so a downstream tool needs neither number."
                          : "Crop corners in the captured file's pixels. Written into the capture's metadata in normalized sensor coordinates."))
            }
            // Straightening is applied only through the crop box's rotate band,
            // and it is the one preview treatment with no button of its own,
            // which makes this readout the only place it is visible. Without it the operator
            // could be looking at a resampled preview and not know why.
            if model.isStraightened {
                Text(model.straightenLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Straightening applied to the preview by the crop box's rotate band, on top of the quarter-turn rotation. The RAW keeps the whole frame, and the angle is recorded in the sidecar with the crop so it can be reproduced. View > Clear Straightening removes it.")
            }
            Spacer()
            // Transient feedback, so a refused eyedropper sample does not look
            // like a click that did nothing.
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            folderReadout()
            if let last = model.lastCapture {
                Text("Last: \(last)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The filename is the one thing here that says which frame
                    // just landed, so it wins space over the readouts to its
                    // left rather than being the first thing pushed off the
                    // end. It truncates in the middle, which keeps both the
                    // roll prefix and the frame number legible.
                    .layoutPriority(1)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { FooterItemToggles(settings: settings) }
    }

    /// Where captures land: the folder's name, the full path in the tooltip,
    /// and a pencil that opens Settings on the Capture tab, which already owns
    /// the chooser.
    @ViewBuilder
    private func folderReadout() -> some View {
        let path = (settings.captureFolder.path as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 4) {
            // The path tooltip goes on the readout alone, because on the
            // outer stack it overrides the pencil's own tooltip.
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(settings.captureFolder.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("Captures are saved to \(path)")
            Button {
                // Set the tab first, so an open window switches and a closed
                // one opens on Capture. openSettings also brings an open
                // window to the front.
                settings.settingsTab = .capture
                openSettings()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Change where captures are saved")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func connectionBadge() -> some View {
        let (color, text): (Color, String) = {
            switch model.ui {
            case .disconnected: return (.gray, "Disconnected")
            case .enumerating: return (.yellow, "Connecting…")
            case .ready: return (.green, "Ready")
            case .streaming: return (.green, "Streaming")
            case .error: return (.red, "Error")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
            if let wait = model.cameraWait {
                WaitGlyph(wait: wait)
            }
        }
    }
}

/// The status line's wait glyph (CameraWait): the small spinner, shown once a
/// camera call has run past 5 s inside its budget, with the explanation in a
/// tooltip and a click popover rather than a sentence on the bar. The timeline
/// only ticks while a wait exists.
private struct WaitGlyph: View {
    let wait: CameraWait
    @State private var shows = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if wait.isVisible(at: context.date) {
                Button { shows.toggle() } label: {
                    ProgressView().controlSize(.mini)
                }
                .buttonStyle(.borderless)
                .help(wait.tooltip)
                .accessibilityLabel(wait.tooltip)
                .popover(isPresented: $shows, arrowEdge: .top) {
                    InfoPopoverBody(text: wait.popover)
                }
            }
        }
    }
}

/// The footer's optional items, as toggles for the footer's right-click menu
/// (a hidden affordance). Settings > Camera > Status bar has the same
/// switches, so they can be found. All off by default.
struct FooterItemToggles: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Toggle("Metered Shutter", isOn: $settings.showMeteredShutter)
        Toggle("Camera Battery", isOn: $settings.showBatteryIndicator)
        Toggle("Camera Clock", isOn: $settings.showCameraClock)
        Toggle("White Balance Gains", isOn: $settings.showWhiteBalanceGains)
        Toggle("Crop Corners", isOn: $settings.showCropDetail)
    }
}
