import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LiveViewPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)   // LiveView eats all remaining space
                Divider()
                // Row 1: camera control. Pickers hug the left, focus cluster
                // hugs the right, and the Capture button floats dead-center
                // of the visible row regardless of what's beside it. The
                // horizontal scroll stays as the fallback for very narrow
                // windows (content keeps at least the viewport width so the
                // right-aligned focus cluster actually right-aligns).
                if UIPreview.on {
                    // ImageRenderer can't draw ScrollView content; snapshots
                    // render the bare row instead.
                    ExposureBar()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        ExposureBar()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .containerRelativeFrame(.horizontal, alignment: .center) { len, _ in max(len, 1200) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                // Row 2: view switches, what you SEE (stream, focus aids,
                // preview treatments). Row 3: metadata, what gets WRITTEN.
                ViewSwitchBar()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
                MetadataBar()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
                StatusFooter()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            overlayContent()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func overlayContent() -> some View {
        // Autonomous UI verification: FT_UI_PREVIEW=1 suppresses the
        // no-camera overlay so toolbar layout can be screenshotted on a
        // build host with no camera attached. Never set in normal launches.
        if ProcessInfo.processInfo.environment["FT_UI_PREVIEW"] == "1" {
            EmptyView()
        } else {
            switch model.ui {
        case .disconnected, .enumerating:
            EmptyStates.NoCamera()
                .background(.ultraThinMaterial)
        case .ready, .streaming:
            EmptyView()
        case .error(let msg, let hint):
            EmptyStates.ErrorState(message: msg, hint: hint)
                .background(.ultraThinMaterial)
        }
        }
    }
}
