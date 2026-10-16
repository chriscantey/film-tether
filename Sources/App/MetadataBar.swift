import SwiftUI
import Scan

/// Row 2: switches that change what you see. Focus and zoom aids (Peaking,
/// Box, zoom, Hist) on the left. On the right, the Meta switch and then the
/// preview treatments (rotate, mirror, invert, B&W, white balance, crop).
/// Row 3 (`MetadataBar`) holds Live View, Capture and the fields that get
/// written.
struct ViewSwitchBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // Clusters pinned to the edges, the Divider centered in the
            // remaining gap by twin equal Spacers, with a hard 24pt minimum
            // on each so the line can never touch a button, at any window
            // width.
            HStack(spacing: 7) {
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
                metaToggle()
                rotateButton()
                mirrorButton()
                invertToggleButton()
                monoToggleButton()
                whiteBalanceButton()
                autoCropButton()
                cropToggleButton()
                centerCropButton()
            }
            .fixedSize()
        }
    }

    // MARK: - View toggles

    /// The master gate for every metadata write, sidecar or embedded. It sits
    /// at the head of the treatment cluster because that cluster is most of
    /// what gets written: rotate, mirror, negative, color, white balance and
    /// the crop all land in the metadata, and so do the Camera and Film fields
    /// a row below.
    private func metaToggle() -> some View {
        Button {
            settings.metadataEnabled.toggle()
        } label: {
            SwitchLabel(title: "Meta", on: settings.metadataEnabled, onImage: "tag.fill", offImage: "tag")
        }
        .controlSize(.small)
        .accessibilityValue(settings.metadataEnabled ? "On" : "Off")
        .help("""
              Writes metadata with each RAW, which other apps can read: a sidecar \
              .xmp beside it, or inside the RAW itself when Settings says so.

              In it: camera make and model, film stock and maker, film size, the day \
              the roll was shot, capture time, the crop and straighten angle, rotate \
              and mirror, the eyedropper sample point and its RGB, the white-balance \
              gains, and the negative and monochrome preview flags.

              A scan with nothing to record gets no metadata at all. Turned off, it \
              writes nothing, not even the crop and rotation.
              """)
    }

    private func histogramToggleButton() -> some View {
        Button {
            settings.histogramEnabled.toggle()
        } label: {
            SwitchLabel(title: "Hist", on: settings.histogramEnabled, onImage: "chart.bar.fill", offImage: "chart.bar")
        }
        .controlSize(.small)
        .accessibilityValue(settings.histogramEnabled ? "On" : "Off")
        .help("""
              Live RGB histogram of what the camera is seeing. Drag the card to any corner. \
              It hides at 500%, since that zoom is for focus and the card would cover the \
              detail. Clipping percentages appear when black or white clipping exceeds 0.1%.

              On a negative the useful signal is a narrow hump well inside both ends: the \
              film base sets the bright limit and there is nothing above it worth exposing \
              for.

              A viewing aid only. Nothing about it reaches the RAW or the sidecar.
              """)
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func peakingToggleButton() -> some View {
        Button {
            model.focusPeakingEnabled.toggle()
        } label: {
            SwitchLabel(title: "Peaking", on: model.focusPeakingEnabled, onImage: "scope", offImage: "circle.dotted")
        }
        .controlSize(.small)
        .accessibilityValue(model.focusPeakingEnabled ? "On" : "Off")
        .help("""
              Outline whatever is in sharpest focus, so you can nail focus without pixel \
              peeping. Cmd-P, and Cmd-Shift-P cycles the color.

              A viewing aid only. Nothing about it reaches the RAW or the sidecar.
              """)
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func boxToggleButton() -> some View {
        Button {
            model.showMeteringOverlay.toggle()
        } label: {
            SwitchLabel(title: "Box", on: model.showMeteringOverlay, onImage: "plus.viewfinder", offImage: "viewfinder")
        }
        .controlSize(.small)
        .accessibilityValue(model.showMeteringOverlay ? "On" : "Off")
        .help("""
              Show or hide the zoom box that aims the camera's sensor punch-in. Click \
              anywhere on the live view to move it, then zoom to 500% to inspect that spot.

              A viewing aid only. Nothing about it reaches the RAW or the sidecar.
              """)
        .disabled(!model.isLiveViewOn)
    }

    /// Percentage zoom. Cycles Fit → 100% → 500%. The label doubles as the
    /// current zoom readout, with Fit carrying its live percentage. 500%
    /// engages the camera punch-in.
    ///
    /// Contributed by Alex Teslik.
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
        .help("""
              Preview zoom, click to cycle. Fit scales the frame to the pane. 100% is one \
              frame pixel per point. 500% is the camera's own sensor punch-in, which is real \
              detail rather than an upscale, and it is the one to focus on.

              Hold Shift for a momentary 500% that snaps back when you let go. Click the \
              live view first to move the zoom box to where it should punch in.

              A viewing aid only. Nothing about it reaches the RAW or the sidecar.
              """)
        .disabled(!model.isLiveViewOn)
    }

    // MARK: - Preview treatments (contributed by Alex Teslik)

    /// Click rotates the preview a quarter turn clockwise. The label doubles as
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
        .help("""
              Rotate the preview 90° clockwise. Cmd-R, or Cmd-Shift-R the other way.

              The RAW keeps every pixel exactly as shot. The rotation is saved in the \
              capture's metadata, though, so an app that reads it can turn the picture the \
              way you are looking at it now.

              Straightening in fine steps is a separate control, on the crop box's \
              rotate band. The footer reads out that angle, and View > Clear \
              Straightening undoes it.
              """)
    }

    /// Horizontal mirror toggle, beside rotate because they answer the same
    /// question: which way is the film sitting in the holder. Icon only,
    /// filled when on and outlined when off, like the zoom button.
    @ViewBuilder
    private func mirrorButton() -> some View {
        let on = model.previewMirrored
        Button {
            model.toggleMirror()
        } label: {
            Label("Mirror", systemImage: on ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                            : "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .labelStyle(.iconOnly)
                .frame(width: 30)
        }
        .controlSize(.small)
        .help("""
              Flip the preview left to right, for film sitting emulsion-side-up in the \
              holder. Cmd-Shift-M. A vertical flip is this plus two rotates.

              The captured RAW's image data is untouched. The flip is saved in the \
              capture's metadata, so an app that reads it can mirror the picture too.

              """ + (on ? "Currently mirrored." : "Currently not mirrored."))
    }

    /// Negative / positive toggle. The label names what you're currently
    /// looking at, matching how the rotation button reads, so it says
    /// Negative while a white balance pick is showing the negative.
    @ViewBuilder
    private func invertToggleButton() -> some View {
        let inverted = model.displayedAdjustments.invert
        Button {
            model.toggleInvert()
        } label: {
            Label(inverted ? "Positive" : "Negative",
                  systemImage: inverted ? "circle.righthalf.filled.inverse" : "film")
                .labelStyle(.titleAndIcon)
                .frame(width: 82)
        }
        .controlSize(.small)
        .help("""
              Invert the preview so a negative reads as the positive image. Cmd-I.

              Judging framing and focus on an un-inverted negative is guesswork, which is \
              what this is for.

              The captured RAW is still the negative, every pixel as shot. The setting is \
              saved in the capture's metadata, so an app that reads it knows which way you \
              were looking.
              """)
    }

    /// Color / B&W preview toggle. Enabled even with live view off, since it's
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
        .help("""
              Show the preview in black and white. Cmd-B.

              Raw pixels off a black and white negative carry no useful color, so exposure and focus \
              read more clearly without it.

              The camera and the RAW's image data are untouched. The setting is saved in \
              the capture's metadata, so an app that reads it knows this roll is black and \
              white.
              """)
    }

    /// Arms the eyedropper. The next click on the preview sets white balance.
    /// Shows the sampled state so it's obvious a correction is active.
    @ViewBuilder
    private func whiteBalanceButton() -> some View {
        // The plain eyedropper in the accent color means the picker is armed,
        // the full eyedropper in the accent color means a value is held, and
        // the plain eyedropper without the accent means nothing is picked.
        // The label stays "WB" in every state, so it never outgrows the
        // button, and what was picked is in the tooltip.
        let armed = model.isPickingWhiteBalance
        let wb = model.previewAdjustments.whiteBalance
        Button {
            model.toggleWhiteBalancePicker()
        } label: {
            SwitchLabel(title: "WB", on: armed || wb != nil,
                        onImage: (wb != nil && !armed) ? "eyedropper.full" : "eyedropper",
                        offImage: "eyedropper")
        }
        .controlSize(.small)
        .accessibilityValue(armed ? "Picking" : (wb != nil ? "Picked" : "Not set"))
        .help(armed
              ? "Click the unexposed film base in the preview. Escape or this button cancels."
              : wb.map { String(format: "White balance picked from the film base, gains R %.2f, G %.2f, B %.2f. Click to pick again. Cmd-Shift-W clears it.", $0.red, $0.green, $0.blue) }
              ?? """
                Click here, then click the unexposed film base in the preview: the clear \
                strip between frames, or the rebate. That sets what "no exposure" looks like \
                on this roll and neutralizes the orange mask. If the preview is showing the \
                positive, it shows the negative while you pick and switches back after.

                Different from WB Mode on the row above, which is a camera setting. This \
                corrects green and magenta as well as blue and amber, which a camera's \
                Kelvin-only white balance cannot do at all.

                Both the point you clicked and the color it measured are saved in the \
                capture's metadata, so an app that reads it can start from the same \
                neutral. Reset it from the View menu.
                """)
        .disabled(!model.canPickWhiteBalance)
    }

    // MARK: - Crop (contributed by Alex Teslik)

    /// Runs detection again on each press and, when it finds the negative,
    /// replaces the box, hand edits included, which is why it is separate
    /// from the toggle. Auto-Crop and the crop toggle are icons rather than
    /// words to keep row 2 narrow, and their tooltips carry the explanation.
    @ViewBuilder
    private func autoCropButton() -> some View {
        Button {
            model.runAutoCrop()
        } label: {
            Image(systemName: "wand.and.rays")
                .frame(width: 34)
        }
        .controlSize(.small)
        .help("""
              Find the negative under the lens and put an adjustable box on it. Press again \
              to detect again. It checks its own result against the film format \
              from the last confident detection, and builds a box from that format when \
              detection cannot be trusted.

              Fit zoom only, because the crop box is only drawn at Fit.

              The box it produces is saved in the capture's metadata.
              """)
        .disabled(!model.isLiveViewOn || model.previewZoom != .fit)
    }

    /// Bring the box back to the middle. Same 30pt icon width as the toggle so
    /// the cluster grows by one narrow button and row 2 stays under row 1.
    @ViewBuilder
    private func centerCropButton() -> some View {
        Button {
            model.centerCrop()
        } label: {
            Image(systemName: "dot.viewfinder")
                .frame(width: 30)
        }
        .controlSize(.small)
        .help("""
              Put the crop box back in the middle of the frame without changing its size. \
              Cmd-Shift-K. Cmd-Shift-0 does the same for the zoom box.

              The moved box is saved in the capture's metadata, like any other crop.
              """)
        .disabled(!model.isCropActive)
    }

    /// Whether the crop is interactive. Labeled with the state it is in rather
    /// than the state it would move to, matching every other toggle here.
    ///
    /// While the crop is being adjusted the overlay covers the whole pane and
    /// takes the clicks, including the one that moves the zoom box. Off is the
    /// resting state, and this button or Cmd-K returns to it.
    @ViewBuilder
    private func cropToggleButton() -> some View {
        let editing = model.isCropEditing
        Button {
            model.toggleCropEditing()
        } label: {
            Image(systemName: editing ? "crop.rotate" : "crop")
                .foregroundStyle(editing ? AnyShapeStyle(Color.accentColor)
                                         : AnyShapeStyle(.primary))
                .frame(width: 30)
        }
        .controlSize(.small)
        .help(editing
              ? "Crop is being adjusted: drag a corner or edge handle to resize, inside the box to move it, or the band just outside the handles to straighten. While this is on, the box takes every click on the preview except the eyedropper's. Turn it off, or press Cmd-K, to fix the box in place."
              : (model.isCropActive
                 ? "Crop is fixed, drawn as a thin outline, and the preview is yours again. Turn it back on to adjust the box. Cmd-K does the same, Cmd-Delete removes the crop."
                 : "No crop yet. Press Auto-Crop to find the negative.")
              + "\n\nThe crop box and the straighten angle are saved in the capture's metadata. The RAW keeps the whole frame, and an app that reads the metadata can apply the box.")
        .disabled(!model.isCropActive)
    }
}

/// Row 3: what gets written into each capture, plus the transport pair. Live
/// View and Capture pinned left, the metadata fields pinned right, divider
/// gap-centered. The fields are wide enough that long film stock names like
/// "Kodak Ektachrome E100" fit without truncation.
struct MetadataBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left: Live View, then Capture, in the order they are used.
            // Capture stays disabled until live view is on.
            HStack(spacing: 8) {
                liveViewToggle()
                captureButton()
            }
            .fixedSize()
            Spacer(minLength: 24)
            Divider().frame(height: 28)
            Spacer(minLength: 24)
            // Right: the fields. The Meta gate sits on row 2 rather than
            // here because it also gates the crop, the straighten, the rotate
            // and mirror, the eyedropper and the preview flags.
            metadataFields()
                .fixedSize()
        }
    }

    /// The film format, the same setting Auto-Crop uses, surfaced beside the
    /// film. Written with each capture as Film:FilmSizeID and Film:FilmSizeName.
    /// A short plain list, then Other, which opens a text field for
    /// anything the list does not name.
    @ViewBuilder
    private func filmSizePicker() -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Size").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: Binding<Int>(
                    get: {
                        settings.filmSizeOther != nil ? MetadataBar.otherSizeTag
                            : settings.expectedFilmSize?.id ?? FilmSize.unknown.id
                    },
                    set: { id in
                        if id == MetadataBar.otherSizeTag {
                            settings.expectedFilmSize = nil
                            if settings.filmSizeOther == nil { settings.filmSizeOther = "" }
                        } else {
                            settings.filmSizeOther = nil
                            settings.expectedFilmSize = id == FilmSize.unknown.id ? nil : FilmSize.resolve(id: id)
                        }
                    }
                )) {
                    ForEach(FilmSize.pickerSizes(including: settings.expectedFilmSize)) { size in
                        Text(size.displayName).tag(size.id)
                    }
                    Divider()
                    Text("Other").tag(MetadataBar.otherSizeTag)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120, alignment: .leading)
                .help("The film format. Written with each capture so an app that reads the sidecar knows it, and Auto-Crop uses it too. Other lets you type one.")
            }
            if settings.filmSizeOther != nil {
                TextField("e.g. 127", text: Binding(
                    get: { settings.filmSizeOther ?? "" },
                    set: { settings.filmSizeOther = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { TextEntryFocus.endEditing() }
                .onExitCommand { TextEntryFocus.endEditing() }
                .help("A format the list does not name. Written with each capture as the film size's name. Auto-Crop uses no film size while Other is chosen.")
            }
        }
    }

    /// The Size picker's tag for Other. No catalog id is negative.
    static let otherSizeTag = -1

    @ViewBuilder
    private func metadataFields() -> some View {
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
            filmSizePicker()
            // The day the roll was shot, per roll like the film. Written as
            // Film:TakenOn, which Film Positive reads as the photo's date.
            MetadataField(
                title: "Taken",
                placeholder: "2026-09-14",
                value: $settings.shotTakenOn,
                history: settings.takenOnHistory,
                onCommit: { settings.commitTakenOn($0) },
                onRemove: { settings.removeTakenOnHistory($0) },
                width: 130,
                help: "The day this roll was shot, as YYYY-MM-DD. Written with each capture, so an app that reads the sidecar can use it as the photo's date. Return saves it to history."
            )
        }
        .disabled(!settings.metadataEnabled)
        .opacity(settings.metadataEnabled ? 1.0 : 0.45)
        .fixedSize()
    }

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
            // A status dot and a fixed label, so the button never changes
            // width: green while live view is on, dimmed white while it is off.
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isLiveViewOn ? Color.green : Color.white.opacity(0.45))
                    .frame(width: 9, height: 9)
                Text("Live View")
            }
            .frame(width: 84)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .keyboardShortcut("l", modifiers: [.command])
        .help(model.isLiveViewOn
              ? "Live view is on. Click, or press Cmd-L, to stop it."
              : "Live view is off. Click, or press Cmd-L, to start it.")
    }

    private func captureButton() -> some View {
        Button {
            Task { await model.captureNow() }
        } label: {
            Label("Capture", systemImage: "camera.shutter.button")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 4)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .help(model.isLiveViewOn
              ? "Capture and download a frame. The capture key (Space unless changed in Settings), Cmd-Return or Cmd-Shift-Return."
              : "Start live view first. This button captures only while live view runs, so the exposure matches the preview.")
        .disabled(!model.isLiveViewOn)
    }
}

/// A single editable metadata field with a removable-history dropdown.
///
/// Behavior:
///   - Typing edits the live value (persisted every keystroke via the binding).
///   - Return commits the value into history (dedup + move-to-front) and
///     ends editing, so the bare-key shortcuts work again.
///   - Escape ends editing without committing to history.
///   - The chevron opens a popover listing prior entries. Tapping one fills the
///     field and commits it, and the trailing "x" deletes just that entry.
/// The value is also committed at capture time (see AppModel.captureNow), so a
/// value used without pressing Return still lands in history.
private struct MetadataField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    let history: [String]
    let onCommit: (String) -> Void
    let onRemove: (String) -> Void
    var width: CGFloat = 300
    var help = "Written to the .xmp sidecar with each capture, or inside the RAW when Settings says so. Return saves it to history and hands the keys back to the app."

    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            // The history chevron rides inside the field's trailing edge
            // rather than beside it, so the field's own edge is the row's
            // edge and the boxes reach the trailing margin every other row
            // reaches. A long stock name ("Kodak Ektachrome E100") measures
            // well under the 300pt box, so the glyph does not sit over
            // text in practice, and the field scrolls if one ever does.
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)   // 300 by default, narrower for Taken
                .onSubmit {
                    onCommit(value)
                    TextEntryFocus.endEditing()
                }
                // Escape leaves the field without the history write. The
                // typed value already persists per keystroke via the binding.
                .onExitCommand { TextEntryFocus.endEditing() }
                .help(help)
                .overlay(alignment: .trailing) {
                    Button {
                        showHistory.toggle()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(history.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 6)
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

/// A view switch's label: the name and its icon only, with the on state
/// shown in the accent color rather than an ON or OFF word. The name never
/// changes, so the button keeps its width without a fixed frame.
struct SwitchLabel: View {
    let title: String
    let on: Bool
    let onImage: String
    let offImage: String

    var body: some View {
        Label(title, systemImage: on ? onImage : offImage)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
    }
}
