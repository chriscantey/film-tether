import SwiftUI
import AppKit
import Camera
import Scan

/// Wraps an NSImageView for the live-view stream. SwiftUI's `Image` repaint
/// cycle is too slow for a 30 fps JPEG stream. Falls back to a placeholder
/// when not streaming.
///
/// The zoom box marks where the 500% punch-in looks. It is drawn into the
/// frame (`AppModel.drawZoomBox`), toggled from the View menu or the Box
/// switch on row 2, and moved by a click or drag in the pane.
struct LiveViewPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            // Aspect-ratio constraint so the pane letterboxes inside the
            // available space instead of cropping. 3:2 normally, 2:3 when the
            // preview is rotated a quarter turn.
            ImagePaneRepresentable()
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
                .background(paneSizeReporter())
            // Connected, live view off, so the canvas is black. Centered on
            // it, gone the moment startLiveView sets .streaming.
            if model.ui == .ready {
                EmptyStates.LiveViewOff()
            }
            // The eyedropper takes over the picture while armed, so a click
            // samples white balance instead of moving the zoom box. It
            // outranks the zoom box layer deliberately: the two would otherwise
            // fight over the same click.
            // Both interaction layers are gated off 100% (.actual): at
            // .scaleNone the NSImageView draws a center crop of the frame, so
            // a view-fraction click no longer names the frame pixel under it.
            // The mapping below is only valid for the scaled modes.
            if model.isPickingWhiteBalance && model.isLiveViewOn
                && model.previewZoom != .actual {
                EyedropperLayer { display in
                    // Back through the mirror, the quarter turn and the
                    // straightening, so the sample comes from the pixel that
                    // was under the crosshair. The eyedropper reads
                    // the frame as the camera sent it, which is none of the
                    // three.
                    model.sampleWhiteBalance(atSensor: model.sensorPoint(fromDisplay: display))
                }
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
            }
            // Interaction layer only, same rect as the image. The visible
            // box is composited into the frame (AppModel.drawZoomBox) while
            // the overlay toggle is on and the camera punch-in is off. A click
            // or drag anywhere moves the box (the zoom target), centered on
            // that point.
            else if model.showMeteringOverlay && model.isLiveViewOn && model.zoomMode == .fit
                && model.previewZoom != .actual {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)   // 0 → a plain click also fires this
                                .onChanged { value in
                                    let f = AppModel.zoomBoxFraction
                                    // The gesture reports a point in the
                                    // rotated, mirrored, straightened view.
                                    // meteringCenter is sensor space, so undo
                                    // all three before clamping (clamping in
                                    // the wrong space would pin the wrong
                                    // edges).
                                    let display = CGPoint(
                                        x: value.location.x / max(geo.size.width, 1),
                                        y: value.location.y / max(geo.size.height, 1)
                                    )
                                    let s = model.sensorPoint(fromDisplay: display)
                                    // Box centered on the click/drag point, clamped so it
                                    // stays fully in frame and can reach every edge.
                                    let nx = min(max(s.x, f/2), 1 - f/2)
                                    let ny = min(max(s.y, f/2), 1 - f/2)
                                    model.meteringCenter = CGPoint(x: nx, y: ny)
                                }
                        )
                }
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
            }
            // The crop box, over the image and under the histogram card. Only
            // at Fit: at 100% and 500% the pane is a window onto part of the
            // frame, so a box drawn in pane coordinates would not sit where it
            // claims to.
            //
            // Not aspect-fitted, unlike the image and the click layers. The
            // overlay covers the whole pane and finds the picture inside it
            // itself, so its rotate handles can reach into the letterbox (see
            // CropOverlay).
            //
            // It takes the click only while the box is being adjusted, and
            // hands it back the moment the crop is fixed or the eyedropper is
            // armed, so click-to-move-the-zoom-box underneath keeps working.
            if model.isCropActive, model.previewZoom == .fit, model.isLiveViewOn {
                CropOverlay(
                    rect: Binding(get: { model.cropDisplayRect ?? .zero },
                                  set: { model.cropDisplayRect = $0 }),
                    fineRotation: Binding(get: { model.displayStraightenDegrees },
                                          set: { model.displayStraightenDegrees = $0 }),
                    imageAspect: model.previewAspectRatio,
                    isInteractive: model.isCropEditing && !model.isPickingWhiteBalance)
            }
            // Live histogram card in a corner. It hides at 500% (that zoom is
            // for focus, and the card would cover the detail).
            if let hist = histogramCard {
                GeometryReader { geo in
                    HistogramOverlay(data: hist,
                                     corner: $settings.histogramCorner,
                                     paneSize: geo.size)
                }
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
            }
        }
    }

    /// The histogram card's data, or nil when the card is hidden: the Hist
    /// switch is off, live view is off, or the camera punch-in is engaged.
    private var histogramCard: HistogramData? {
        guard settings.histogramEnabled && model.isLiveViewOn && model.zoomMode == .fit
        else { return nil }
        return model.histogramData
    }

    /// Publishes the pane's laid-out size to the model so the zoom button can
    /// show a real "Fit (N%)". It has to come from actual geometry: the number
    /// changes with every window resize and every rotation.
    private func paneSizeReporter() -> some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size, initial: true) { _, newValue in
                    guard model.previewPaneSize != newValue else { return }
                    model.previewPaneSize = newValue
                }
        }
    }
}

/// Click target for the white-balance eyedropper, showing a crosshair cursor so
/// it's unambiguous which pixel is about to be sampled.
///
/// The crosshair is pushed on hover and popped on exit. `NSCursor.push()` is a
/// stack, so an unbalanced pop leaks the cursor to the whole app, hence the
/// `pushed` flag guarding both directions, plus the `onDisappear` cleanup.
/// Taking a sample disarms the picker, so this view is usually torn down while
/// the pointer is still inside it and no hover-exit ever arrives.
private struct EyedropperLayer: View {
    /// Called with the click position, normalized to the picture and y-down.
    let onPick: (CGPoint) -> Void

    @State private var pushed = false

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside, !pushed {
                        NSCursor.crosshair.push()
                        pushed = true
                    } else if !inside, pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onTapGesture { location in
                    onPick(CGPoint(
                        x: location.x / max(geo.size.width, 1),
                        y: location.y / max(geo.size.height, 1)
                    ))
                }
        }
        .onDisappear {
            if pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}

private struct ImagePaneRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> ImagePane {
        let pane = ImagePane()
        pane.imageAlignment = .alignCenter
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.black.cgColor
        // At 100% the image is routinely larger than the pane, so the overflow
        // has to be clipped rather than drawn over the control rows.
        pane.layer?.masksToBounds = true
        return pane
    }

    func updateNSView(_ nsView: ImagePane, context: Context) {
        nsView.image = model.latestFrame
        // .scaleNone draws one image pixel per point, which is what "100%"
        // means here. Fit and the 5× punch-in both scale to the pane instead.
        nsView.imageScaling = model.previewZoom == .actual
            ? .scaleNone
            : .scaleProportionallyUpOrDown
    }

    final class ImagePane: NSImageView {
        override var acceptsFirstResponder: Bool { true }

        /// NSImageView reports the image's pixel size as its intrinsic size,
        /// which SwiftUI honors, so a rotated (tall) frame or a frame larger
        /// than the pane would grow the VStack past the window and push the
        /// control rows and status footer off-screen. The enclosing SwiftUI
        /// `aspectRatio` already decides how big this view should be, so opt
        /// out entirely.
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
}
