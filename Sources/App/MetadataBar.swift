import SwiftUI

/// Row of two free-text metadata fields, Camera and Film, that get written
/// into each captured CR2 so downstream photo apps show the original film
/// camera and film stock the negative was shot on (the Canon DSLR here is just
/// the scanner). Each field is a text box with a history dropdown: type a new
/// value or pick a previous one; every entry is individually removable with a
/// small "x". History is a plain list of strings (no IDs, no records); the
/// last-used value of each field is restored on launch.
/// Row 2: every switch that changes what you SEE, stream control, focus/zoom
/// aids on the left; preview treatments (rotate, invert, B&W, white balance)
/// on the right. Row 3 (`MetadataBar`) holds what gets WRITTEN. The split
/// happened when the preview treatments arrived and one row could no longer
/// hold everything.
struct ViewSwitchBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // Clusters pinned to the edges, the Divider centered in the
            // remaining gap by twin equal Spacers, with a hard 24pt minimum
            // on each so the line can NEVER touch a button, at any window
            // width.
            HStack(spacing: 7) {
                liveViewToggle()
                Divider().frame(height: 28)
                peakingToggleButton()
                boxToggleButton()
                zoomCycleButton()
                histogramToggleButton()
            }
            .fixedSize()
            Spacer(minLength: 24)
            Divider().frame(height: 28)
            Spacer(minLength: 24)
            HStack(spacing: 7) {
                rotateButton()
                invertToggleButton()
                monoToggleButton()
                whiteBalanceButton()
            }
            .fixedSize()
        }
    }

    // MARK: - View toggles (moved from ExposureBar row 1)

    private func liveViewToggle() -> some View {
        Button {
            Task {
                if model.isLiveViewOn {
                    await model.stopLiveView()
                } else {
                    await model.startLiveView()
                }
            }
        } label: {
            Text(model.isLiveViewOn ? "Stop Live View" : "Start Live View")
                .frame(width: 104)
        }
        .controlSize(.small)
        .keyboardShortcut("l", modifiers: [.command])
        .help("Toggle live preview (Cmd-L)")
    }

    private func histogramToggleButton() -> some View {
        Button {
            settings.histogramEnabled.toggle()
        } label: {
            Label(
                settings.histogramEnabled ? "Hist ON" : "Hist OFF",
                systemImage: settings.histogramEnabled ? "chart.bar.fill" : "chart.bar"
            )
            .labelStyle(.titleAndIcon)
            .frame(width: 76)    // fixed width, no jiggle
        }
        .controlSize(.small)
        .help("Live RGB histogram overlay. Drag the card to any corner; it hides while zoomed. Shows black/white clipping percentages when they exceed 0.1%.")
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func peakingToggleButton() -> some View {
        Button {
            model.focusPeakingEnabled.toggle()
        } label: {
            Label(
                model.focusPeakingEnabled ? "Peaking ON" : "Peaking OFF",
                systemImage: model.focusPeakingEnabled ? "scope" : "circle.dotted"
            )
            .labelStyle(.titleAndIcon)
            .frame(width: 96)   // fixed: ON/OFF label change must not jiggle the row
        }
        .controlSize(.small)
        .help("Toggle focus peaking overlay (Cmd-P). Cmd-Shift-P cycles color.")
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func boxToggleButton() -> some View {
        Button {
            model.showMeteringOverlay.toggle()
        } label: {
            Label(
                model.showMeteringOverlay ? "Box ON" : "Box OFF",
                systemImage: model.showMeteringOverlay ? "plus.viewfinder" : "viewfinder"
            )
            .labelStyle(.titleAndIcon)
            .frame(width: 76)    // fixed width, no jiggle
        }
        .controlSize(.small)
        .help("Show/hide the zoom-target crosshair box (default on). Click anywhere on live view to move it.")
        .disabled(!model.isLiveViewOn)
    }

    /// Percentage zoom, contributed by Alex Teslik, restyled to the row's small
    /// fixed-width convention. Cycles Fit → 100% → 500%; the label doubles as the current
    /// zoom readout, with Fit carrying its live percentage. Replaces the old
    /// Zoom 1×/5× toggle, 500% engages the same camera punch-in.
    @ViewBuilder
    private func zoomCycleButton() -> some View {
        let isZoomed = model.previewZoom.engagesCameraPunchIn
        Button {
            Task { await model.cyclePreviewZoom() }
        } label: {
            Label(
                model.previewZoomLabel,
                systemImage: isZoomed ? "magnifyingglass.circle.fill" : "magnifyingglass.circle"
            )
            .labelStyle(.titleAndIcon)
            // Sized for the widest label, "Fit (100%)", so the button doesn't
            // twitch as the percentage changes during a window resize.
            .frame(width: 92)
        }
        .controlSize(.small)
        .help("Preview zoom, click to cycle: Fit (scaled to the pane) → 100% (one frame pixel per point) → 500% (the camera's own sensor punch-in, real detail rather than an upscale). Hold Shift for momentary 500% and it returns to where you were. Drag the overlay rectangle to choose the punch-in location BEFORE zooming.")
        .disabled(!model.isLiveViewOn)
    }

    // MARK: - Preview treatments (contributed by Alex Teslik, restyled to row convention)

    /// Click rotates the preview a quarter turn clockwise; the label doubles as
    /// the current-rotation readout. Counter-clockwise lives on Cmd-Shift-R.
    @ViewBuilder
    private func rotateButton() -> some View {
        Button {
            model.rotatePreviewRight()
        } label: {
            Label(model.previewRotation.displayName, systemImage: "rotate.right")
                .labelStyle(.titleAndIcon)
                // Fixed width for the widest label ("270°"), no jiggle.
                .frame(width: 56)
        }
        .controlSize(.small)
        .help("Rotate the live preview 90° clockwise (Cmd-R; Cmd-Shift-R goes counter-clockwise). Display only — the camera and the saved files are untouched.")
    }

    /// Negative / positive toggle. The label names what you're currently
    /// looking at, matching how the rotation button reads.
    @ViewBuilder
    private func invertToggleButton() -> some View {
        let inverted = model.previewAdjustments.invert
        Button {
            model.toggleInvert()
        } label: {
            Label(inverted ? "Positive" : "Negative",
                  systemImage: inverted ? "circle.righthalf.filled.inverse" : "film")
                .labelStyle(.titleAndIcon)
                .frame(width: 82)
        }
        .controlSize(.small)
        .help("Invert the preview so a negative shows as the positive image (Cmd-I). Judging framing and focus on an inverted image is guesswork. Display only — the captured RAW is still the negative.")
    }

    /// Colour / B&W preview toggle. Enabled even with live view off, since it's
    /// a property of the film you're about to scan, not of the stream.
    @ViewBuilder
    private func monoToggleButton() -> some View {
        let mono = model.previewAdjustments.monochrome
        Button {
            model.toggleMonochrome()
        } label: {
            Label(mono ? "B&W" : "Color",
                  systemImage: mono ? "circle.lefthalf.filled" : "paintpalette")
                .labelStyle(.titleAndIcon)
                .frame(width: 62)
        }
        .controlSize(.small)
        .help("Show the preview in black and white (Cmd-B). Raw pixels off a B&W negative carry no useful colour, so judging exposure and focus is easier without it. Display only — the camera and the saved files are untouched.")
    }

    /// Arms the eyedropper; the next click on the preview sets white balance.
    /// Shows the sampled state so it's obvious a correction is active.
    @ViewBuilder
    private func whiteBalanceButton() -> some View {
        let armed = model.isPickingWhiteBalance
        let isSet = model.previewAdjustments.whiteBalance != nil
        Button {
            model.toggleWhiteBalancePicker()
        } label: {
            Label(armed ? "Pick…" : (isSet ? "WB set" : "WB"),
                  systemImage: armed ? "eyedropper.halffull" : "eyedropper")
                .labelStyle(.titleAndIcon)
                .frame(width: 68)
        }
        .controlSize(.small)
        .help(model.previewAdjustments.invert
              ? "Unavailable while the preview is inverted: with a positive on screen the film base is the darkest part of the picture, not the brightest, which invites clicking the wrong spot. Switch to Negative to sample."
              : "Click here, then click the unexposed film base in the preview to neutralise its colour cast. Corrects both blue/amber and green/magenta, which the camera's Kelvin-only white balance can't. Reset it from the Preview menu.")
        .disabled(!model.canPickWhiteBalance)
    }
}

/// Row 3: what gets WRITTEN into each capture. Meta master toggle pinned left,
/// the Camera/Film fields pinned right, divider gap-centered.
/// Fields got wider when they moved to their own row, long film stock names
/// like "Kodak Ektachrome E100" now fit without truncation.
struct MetadataBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            metadataToggleButton()
                .fixedSize()
            Spacer(minLength: 24)
            Divider().frame(height: 28)
            Spacer(minLength: 24)
            HStack(spacing: 10) {
                MetadataField(
                    title: "Camera",
                    placeholder: "e.g. Leica M6",
                    value: $settings.shotCamera,
                    history: settings.cameraHistory,
                    onCommit: { settings.commitCamera($0) },
                    onRemove: { settings.removeCameraHistory($0) }
                )
                MetadataField(
                    title: "Film",
                    placeholder: "e.g. Kodak Portra 400",
                    value: $settings.shotFilm,
                    history: settings.filmHistory,
                    onCommit: { settings.commitFilm($0) },
                    onRemove: { settings.removeFilmHistory($0) }
                )
            }
            .disabled(!settings.metadataEnabled)
            .opacity(settings.metadataEnabled ? 1.0 : 0.45)
            .fixedSize()
        }
    }

    /// Enable/disable metadata writing. Master gate: when off, the fields gray
    /// out and captures write no metadata (no sidecar, no embed).
    private func metadataToggleButton() -> some View {
        Button {
            settings.metadataEnabled.toggle()
        } label: {
            Label(
                settings.metadataEnabled ? "Meta ON" : "Meta OFF",
                systemImage: settings.metadataEnabled ? "tag.fill" : "tag"
            )
            .labelStyle(.titleAndIcon)
            .frame(width: 80)    // fixed width, no jiggle
        }
        .controlSize(.small)
        .help("Toggle Camera/Film metadata. When off, the fields gray out and captures write no metadata (no sidecar, no embed).")
    }
}

/// A single editable metadata field with a removable-history dropdown.
///
/// Behavior:
///   - Typing edits the live value (persisted every keystroke via the binding).
///   - Return commits the value into history (dedup + move-to-front).
///   - The chevron opens a popover listing prior entries; tapping one fills the
///     field and commits it; the trailing "x" deletes just that entry.
/// The value is also committed at capture time (see AppModel.captureNow), so a
/// value used without pressing Return still lands in history.
private struct MetadataField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let history: [String]
    let onCommit: (String) -> Void
    let onRemove: (String) -> Void

    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 300)   // roomier on the dedicated metadata row (was 230 when sharing with switches)
                    .onSubmit { onCommit(value) }
                    .help("Written to EXIF/XMP of each captured RAW. Press Return to save to history.")

                Button {
                    showHistory.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(history.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .disabled(history.isEmpty)
                .help(history.isEmpty ? "No saved \(title.lowercased()) entries yet" : "Pick a previous \(title.lowercased())")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    historyList()
                }
            }
        }
    }

    @ViewBuilder
    private func historyList() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.isEmpty {
                Text("No history yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(history, id: \.self) { entry in
                    HStack(spacing: 8) {
                        Button {
                            value = entry
                            onCommit(entry)
                            showHistory = false
                        } label: {
                            Text(entry)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            onRemove(entry)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from history")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                    if entry != history.last { Divider() }
                }
            }
        }
        
        .padding(.vertical, 4)
    }
}
