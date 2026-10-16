import SwiftUI
import FilmStyle
import Camera

enum EmptyStates {

    struct NoCamera: View {
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Connect a compatible camera")
                    .font(.title2)
                Text("Plug in the USB cable and turn the camera on.\nIf you changed the camera's Communication setting, set it back to PTP.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Link("See supported cameras", destination: AppInfo.supportedCamerasURL)
                    .font(.subheadline)
            }
            .padding(40)
        }
    }

    /// Connected, live view off. The canvas goes black on connect and stays
    /// black until Live View is pressed, and this fills that wait. It has the
    /// same shape as NoCamera (glyph, title, one secondary line, same sizes),
    /// with a glyph from the same metering family, so the two screens read as
    /// one sequence rather than as an error. Centered on the canvas. The
    /// canvas is black in both appearances, so the text is pinned to dark. It
    /// takes no clicks.
    struct LiveViewOff: View {
        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "camera.metering.center.weighted")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
                Text(CameraAdvice.liveViewOffMessage)
                    .font(.title2)
                Text(CameraAdvice.liveViewOffHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    struct ErrorState: View {
        let message: String
        let hint: String?
        /// The error's detail text, behind an info icon: hover for the
        /// tooltip, click for a popover.
        var detail: String? = nil
        @State private var showsDetail = false

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.orange)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let detail {
                        Button {
                            showsDetail.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(detail)
                        .accessibilityLabel("Error details")
                        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                            InfoPopoverBody(text: detail)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal)
                if let hint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(40)
            .filmCard()
        }
    }
}
