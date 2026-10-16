import SwiftUI
import FilmStyle
import Camera
import Scan

struct ExposureBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    /// Width of each piece of the row, measured from the pieces themselves
    /// rather than guessed. Slot 0 is the focus cluster and 1 the settings
    /// cluster.
    ///
    /// A hardcoded width goes wrong as soon as a cluster outgrows it. A region
    /// centers its content, so an over-wide cluster spills equally out of both
    /// ends: the divider draws through the gap between a label and its value,
    /// and the Format picker is clipped by the window edge.
    struct ClusterWidths: PreferenceKey {
        static let defaultValue: [Int: CGFloat] = [:]
        static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
            value.merge(nextValue()) { max($0, $1) }
        }
    }

    /// Total width row 1 needs before anything crowds. `MainView` turns this
    /// into the window's minimum width.
    struct RequiredWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Smallest gap allowed between a cluster and the divider, the same 24pt
    /// minimum rows 2 and 3 use.
    private static let minGap: CGFloat = 24

    @State private var widths: [Int: CGFloat] = [:]

    var body: some View {
        // Two clusters with one divider between them, the same two-group
        // shape as rows 2 and 3. Capture and Live View live on row 3, since
        // three groups cannot all be centered against each other.
        HStack(spacing: 0) {
            // Each cluster is centered in its own half rather than pinned to
            // the margin, so this row does not share a column with the rows
            // below.
            focusGroup().fixedSize().measuring(0)
                .frame(maxWidth: .infinity)
            Divider().frame(height: 28)
            settingsCluster().measuring(1)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ClusterWidths.self) { widths = $0 }
        .preference(key: RequiredWidth.self,
                    value: (widths[0] ?? 0) + (widths[1] ?? 0) + 1 + Self.minGap * 2)
    }

    private func settingsCluster() -> some View {
        HStack(spacing: 10) {
            menuPicker(
                label: "ISO",
                currentRaw: model.snapshot.iso,
                currentLabel: model.snapshot.isoLabel,
                choices: model.isoChoices,
                propName: "iso",
                widthHint: 80,     // fits "ISO 12800"
                isDisabled: !writableForCurrentMode("iso"),
                explain: """
                     The tethered camera's sensor ISO: the camera photographing the negative, \
                     not the film. The stock's box speed belongs in the Film field on the \
                     bottom row, and that is what gets saved in the capture's metadata.

                     The light source is constant, so there is rarely a reason to raise this. \
                     Low ISO and a longer shutter beats high ISO and noise in the shadows you \
                     are about to invert.
                     """,
                onPick: { raw in Task { await model.setISO(raw) } }
            )
            shutterPicker()
            menuPicker(
                label: "Aperture",
                currentRaw: model.snapshot.aperture,
                currentLabel: model.snapshot.apertureLabel,
                choices: model.apertureChoices,
                propName: "aperture",
                widthHint: 56,     // "f/2.8" widest, "f/22"/"f/32" shorter
                isDisabled: !writableForCurrentMode("aperture"),
                explain: """
                     The tethered camera's aperture: the scanning lens, not the lens the \
                     negative was shot on.

                     A negative is flat, so depth of field buys little here and diffraction \
                     costs real sharpness. Most macro lenses are at their best two or three \
                     stops down from wide open.
                     """,
                onPick: { raw in Task { await model.setAperture(raw) } }
            )
            whiteBalancePicker()
            kelvinStepper()
            imageFormatPicker()
        }
        .fixedSize()
    }

    // MARK: - Pickers

    /// - Parameter explain: what this control is, in the operator's terms. It
    ///   shows whether the picker is enabled or not, because "locked by the
    ///   mode dial" answers why you cannot touch it and never answers what it
    ///   would have done.
    @ViewBuilder
    private func menuPicker(
        label: String,
        currentRaw: String,
        currentLabel: String,
        choices: [String],
        propName: String,
        widthHint: CGFloat,
        isDisabled: Bool,
        explain: String,
        onPick: @escaping (String) -> Void
    ) -> some View {
        let transformed = PropertyLabels.transform(choices: choices, forProperty: propName)
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            popup(currentRaw: currentRaw, currentLabel: currentLabel,
                  items: transformed, width: widthHint, onPick: onPick)
            .disabled(isDisabled || choices.isEmpty)
            .opacity(isDisabled ? 0.5 : 1.0)
            .help(isDisabled
                  ? "\(explain)\n\nLocked by the camera's mode dial (\(model.snapshot.modeLabel)). Switch the body to Manual to set it from here."
                  : "\(explain)\n\nCurrent: \(currentLabel). Click to change.")
        }
        .frame(width: widthHint + 6)
    }

    /// The popup behind every dropdown on this bar. A pop-up button, not a
    /// pull-down `Menu`: it opens with the current value under the pointer and
    /// ticked, where a `Menu` opens at the top of the list every time and a
    /// 50-entry shutter list would mean scrolling back to 1/125 on each click.
    ///
    /// The body can report a value that is not among the choices: Auto in Av
    /// or P, or the placeholder dash with an empty list while disconnected. A
    /// Picker bound to a tag it does not hold draws blank, so that value gets a
    /// row of its own, and choosing it does nothing because it is not a
    /// settable choice. The setters are async, so the binding reads the
    /// snapshot and a pick spawns the Task. The popup shows the new value when
    /// the body confirms it.
    @ViewBuilder
    private func popup(
        currentRaw: String,
        currentLabel: String,
        items: [(raw: String, label: String)],
        width: CGFloat,
        onPick: @escaping (String) -> Void
    ) -> some View {
        let known = items.contains { $0.raw == currentRaw }
        Picker("", selection: Binding<String>(
            get: { currentRaw },
            set: { raw in
                guard raw != currentRaw, items.contains(where: { $0.raw == raw }) else { return }
                onPick(raw)
            }
        )) {
            if !known {
                Text(currentLabel).tag(currentRaw)
            }
            ForEach(items, id: \.raw) { item in
                Text(item.label).tag(item.raw)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        // No up-down arrows: with them "1/8000" truncates to "1/8..." in the
        // 66pt slot.
        .menuIndicator(.hidden)
        // A pop-up takes its ideal width and will not stretch to the slot.
        // With a real choice list that is the widest entry, capped by this
        // frame, so it fills the slot. Disconnected (the dash, no choices) it is
        // narrower, and leading keeps it under its label. The slot is fixed
        // either way, so the bar's widths never move.
        .frame(width: width + 6, alignment: .leading)
    }

    /// Shutter picker. Picker label shows whatever value the body reports
    /// (often "Auto" in Av/P modes). The status footer can show the last
    /// metered value (off by default), so it is not duplicated here.
    @ViewBuilder
    private func shutterPicker() -> some View {
        let primaryLabel = model.snapshot.shutterLabel
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text("Shutter").font(.caption2).foregroundStyle(.secondary)
                // One glyph when the center of the frame clips, with the
                // suggestion in its tooltip and popover.
                if let advice = model.exposureAdvice {
                    // Double-click sets the suggested shutter, the
                    // same path as picking it from the menu.
                    InfoGlyph(systemName: "sun.max.fill", tint: .orange,
                              text: advice.tooltip, popoverText: advice.popover,
                              accessibility: "Highlights clip",
                              onDoubleClick: {
                                  guard let raw = advice.shutterToApply(writable: writableForCurrentMode("shutterspeed")) else { return }
                                  Task { await model.setShutter(raw) }
                              })
                        .imageScale(.small)
                }
            }
            let transformed = PropertyLabels.transform(choices: model.shutterChoices, forProperty: "shutterspeed")
            popup(currentRaw: model.snapshot.shutter, currentLabel: primaryLabel,
                  items: transformed, width: 60,   // "1/8000" widest
                  onPick: { raw in Task { await model.setShutter(raw) } })
            .disabled(!writableForCurrentMode("shutterspeed") || model.shutterChoices.isEmpty)
            .opacity(writableForCurrentMode("shutterspeed") ? 1.0 : 0.5)
            .help("""
                  The tethered camera's shutter speed: how long the camera exposes the \
                  negative, nothing to do with the exposure the negative itself was shot at.

                  On a light box this is the main exposure control, since ISO wants to stay \
                  low and the aperture wants to stay near the lens's sweet spot. In Av or P \
                  the body picks it and shows Auto here. Settings > Camera > Status bar can \
                  show the last metered value, which updates after a capture or a settings \
                  change.

                  """ + (writableForCurrentMode("shutterspeed")
                          ? "Current: \(primaryLabel). Click to change."
                          : "Locked by the camera's mode dial (\(model.snapshot.modeLabel)). Switch the body to Manual to set it from here."))
        }
        .frame(width: 60 + 6)
    }

    /// White-balance mode. Choices come from the body, so PC-set custom
    /// modes show up by their real names.
    @ViewBuilder
    private func whiteBalancePicker() -> some View {
        menuPicker(
            label: "WB Mode",
            currentRaw: model.snapshot.whiteBalance,
            currentLabel: model.snapshot.whiteBalanceLabel,
            choices: model.whiteBalanceChoices,
            propName: "whitebalance",
            // 88.4pt is "Fluorescent" and "Temperature" measured in this exact
            // face ("Temperature" is PropertyLabels' short form of "Color
            // Temperature"). 96 gives both a little air and nothing more. A PC-set
            // custom mode ("Custom Whitebalance: PC-1") truncates, and the
            // tooltip carries it in full.
            widthHint: 96,
            isDisabled: model.whiteBalanceChoices.isEmpty,
            explain: """
                     The tethered camera's white-balance mode, recorded into the RAW it shoots.

                     Not the same thing as WB on the row below. That one samples the \
                     unexposed film base, neutralizes its cast in the preview, and saves it \
                     in the capture's metadata. This picker is a camera setting, and that \
                     button is about this particular roll.

                     Choose Temperature to type an exact Kelvin value in the stepper beside \
                     this picker.
                     """,
            onPick: { raw in Task { await model.setWhiteBalanceMode(raw) } }
        )
    }

    @ViewBuilder
    private func kelvinStepper() -> some View {
        // Only meaningful in Color Temperature mode. Every other mode ignores
        // the value outright. Dimmed in those modes, and changing the
        // temperature also tries to switch the body into the mode
        // (setWhiteBalanceKelvin).
        let active = model.kelvinIsActive
        VStack(alignment: .leading, spacing: 1) {
            Text("Temperature").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(model.snapshot.kelvinLabel)
                    .font(.body.monospacedDigit())
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)    // "10000K" measured
                Stepper("", value: Binding<Int>(
                    get: { model.snapshot.whiteBalanceKelvin ?? 5500 },
                    set: { v in Task { await model.setWhiteBalanceKelvin(v) } }
                ), in: 2500...10000, step: 100)
                    .labelsHidden()
            }
            .opacity(active ? 1.0 : 0.5)
            .help("""
                  The exact Kelvin the tethered camera white-balances by, from 2500 to 10000 \
                  in steps of 100. For a green or magenta cast, use WB on the row below.

                  """ + (active
                          ? "The body is in Temperature mode, so this value is live."
                          : "The body is in \(model.snapshot.whiteBalanceLabel) mode, which ignores this number. Changing it switches the body to Temperature so it takes effect."))
        }
    }

    @ViewBuilder
    private func imageFormatPicker() -> some View {
        let transformed = PropertyLabels.transform(choices: model.imageFormatChoices, forProperty: "imageformat")
        VStack(alignment: .leading, spacing: 1) {
            Text("Format").font(.caption2).foregroundStyle(.secondary)
            popup(currentRaw: model.snapshot.imageFormat, currentLabel: model.snapshot.imageFormatLabel,
                  items: transformed, width: 120,   // tail-truncates if longer, tooltip shows full
                  onPick: { raw in Task { await model.setImageFormat(raw) } })
            .disabled(model.imageFormatChoices.isEmpty)
            .help("""
                  What the tethered camera writes for each frame.

                  A RAW setting is what this app is for: every sensor value as measured, no \
                  contrast curve, no white balance baked in. That matters more for a negative \
                  than for anything else, because inverting it stretches the shadows hard and \
                  a JPEG has already thrown that range away.

                  RAW+JPEG adds a JPEG to every transfer that the rest of the pipeline ignores. \
                  A smaller RAW (mRAW, sRAW) is a real resolution loss, not a compression \
                  setting.

                  Current: \(model.snapshot.imageFormatLabel).
                  """)
        }
        .frame(width: 120 + 6)
    }

    // MARK: - Focus group

    /// Six manual-drive buttons (3 toward Near, 3 toward Far) for fine
    /// adjustment without touching the lens, a way to affect focus remotely.
    ///
    /// Then the AF button. Two camera behaviors shape it. A DoAf with no
    /// closing cancel latches the half press, so the body ignores every later
    /// DoAf and step, which is why AppAutofocus always ends with AfCancel,
    /// after the d1c0 marker or the cap. Repeated prepared sessions stall the
    /// 7D's event pipe, so the run happens inside the app's one open session
    /// and never opens another.
    ///
    /// With live view off, or the lens switch on MF (focusmode reads
    /// Manual), the steps and AF are off, and one info icon says why
    /// (DisabledReasons).
    @ViewBuilder
    private func focusGroup() -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Focus").font(.caption2).foregroundStyle(.secondary)
                if let why = DisabledReasons.focus(liveViewOn: model.isLiveViewOn,
                                                   focusMode: model.snapshot.focusMode) {
                    InfoGlyph(systemName: "info.circle", tint: .secondary,
                              text: why,
                              accessibility: "Why focus is off")
                }
            }
            HStack(spacing: 2) {
                focusButton("⟪⟪⟪", help: "Focus far, coarse step (−3). Big jump toward infinity.  ⌨ ⌃,", step: .farLarge)
                focusButton("⟪⟪",  help: "Focus far, medium step (−2).  ⌨ ,", step: .farSmall)
                focusButton("⟪",   help: "Focus far, fine step (−1). Smallest nudge toward infinity.  ⌨ ⌥,", step: .farTiny)
                focusButton("⟫",   help: "Focus near, fine step (+1). Smallest nudge toward the subject.  ⌨ ⌥.", step: .nearTiny)
                focusButton("⟫⟫",  help: "Focus near, medium step (+2).  ⌨ .", step: .nearSmall)
                focusButton("⟫⟫⟫", help: "Focus near, coarse step (+3). Big jump toward the subject.  ⌨ ⌃.", step: .nearLarge)
                AutofocusButton()
            }
        }
    }

    @ViewBuilder
    private func focusButton(_ glyph: String, help: String, step: CameraProperties.ManualFocusStep) -> some View {
        Button {
            Task { await model.driveManualFocus(step) }
        } label: {
            Text(glyph)
                .font(.caption2)
                .frame(width: 24)   // narrow, six of these share the row
        }
        .controlSize(.small)
        // Hold-to-repeat: keep a button pressed and it fires repeatedly,
        // instead of mashing. driveManualFocus's in-flight drop flag caps the
        // USB write rate no matter how fast repeats arrive.
        .buttonRepeatBehavior(.enabled)
        .help(help)
        .disabled(!model.isLiveViewOn || model.focusBlockedByLensSwitch || model.autofocusBusy)
    }

    private func writableForCurrentMode(_ prop: String) -> Bool {
        CameraProperties.isWritable(prop: prop, inMode: model.snapshot.mode)
    }
}

private extension View {
    /// Report this piece's own intrinsic width up to `ExposureBar`. Safe from
    /// a layout feedback loop because every piece this is applied to is
    /// `.fixedSize()`, so the width measured is intrinsic and does not depend
    /// on the space the row happened to give it.
    func measuring(_ slot: Int) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ExposureBar.ClusterWidths.self,
                                   value: [slot: geo.size.width])
        })
    }
}

/// The AF button and its result glyph. Busy shows a spinner in place of the
/// label. After a run a small glyph beside it says whether sharpness on the
/// next frame confirmed it, with advice behind it when the run failed or
/// was not confirmed.
private struct AutofocusButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Button {
                Task { await model.autofocus() }
            } label: {
                ZStack {
                    Text("AF").font(.caption2)
                        .opacity(model.autofocusBusy ? 0 : 1)
                    if model.autofocusBusy { ProgressView().controlSize(.mini) }
                }
                .frame(width: 24)
            }
            .controlSize(.small)
            .help(model.autofocusBusy ? "Autofocus running" : "Autofocus: the camera focuses on the live view, then lets go of the lens. Needs the lens switch on AF and the camera not set to manual focus.  ⌨ /")
            .disabled(!model.isLiveViewOn || model.focusBlockedByLensSwitch || model.autofocusBusy)
            .accessibilityLabel("Autofocus")
            // A fixed slot, so the glyph coming and going never moves the bar.
            resultGlyph.frame(width: 14)
        }
    }

    @ViewBuilder
    private var resultGlyph: some View {
        switch model.autofocusResult {
        case .confirmed?:
            InfoGlyph(systemName: "checkmark.circle", tint: .green,
                      text: "Autofocus done. The live view is sharp.",
                      accessibility: "Autofocus confirmed")
        case .notConfirmed(let advice)?:
            InfoGlyph(systemName: "questionmark.circle", tint: .secondary,
                      text: [advice.message, advice.hint].compactMap { $0 }.joined(separator: " "),
                      detail: advice.detail,
                      accessibility: "Autofocus not confirmed")
        case .failed(let advice)?:
            InfoGlyph(systemName: "exclamationmark.triangle", tint: .orange,
                      text: [advice.message, advice.hint].compactMap { $0 }.joined(separator: " "),
                      detail: advice.detail,
                      accessibility: "Autofocus failed")
        case nil:
            EmptyView()
        }
    }
}

/// A small glyph whose explanation is a tooltip on hover and a popover on
/// click, so explanations live in info icons rather than on the bar.
/// `detail` only ever appears in the popover.
private struct InfoGlyph: View {
    let systemName: String
    let tint: Color
    let text: String
    var detail: String? = nil
    /// A longer explanation for the popover, when the tooltip is the short form.
    var popoverText: String? = nil
    let accessibility: String
    /// When set, a double-click runs this and a single click still opens the
    /// popover. A Button cannot tell the two apart, so the glyph takes taps.
    var onDoubleClick: (() -> Void)? = nil
    @State private var shows = false

    var body: some View {
        if let onDoubleClick {
            Image(systemName: systemName).foregroundStyle(tint)
                .contentShape(Rectangle())
                // Double first, so a single click waits out the double-click
                // interval instead of opening the popover under the second.
                .onTapGesture(count: 2) { shows = false; onDoubleClick() }
                .onTapGesture { shows.toggle() }
                .help(text)
                .accessibilityElement()
                .accessibilityLabel(accessibility)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { shows.toggle() }
                .accessibilityAction(named: "Apply") { onDoubleClick() }
                .popover(isPresented: $shows, arrowEdge: .bottom) {
                    InfoPopoverBody(text: popoverText ?? text, detail: detail)
                }
        } else {
            Button { shows.toggle() } label: {
                Image(systemName: systemName).foregroundStyle(tint)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help(text)
            .accessibilityLabel(accessibility)
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                InfoPopoverBody(text: popoverText ?? text, detail: detail)
            }
        }
    }
}
