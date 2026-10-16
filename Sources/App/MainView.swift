import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    /// What row 1 says it needs, measured from its own clusters. The window's
    /// minimum width follows it (`.windowResizability(.contentMinSize)`), so
    /// the window cannot be made narrower than row 1 needs. The static floor
    /// below is what the other rows need, and is also what the first frame
    /// uses before the measurement arrives.
    @State private var rowOneWidth: CGFloat = 0

    /// Rows 2 and 3 are edge-pinned rather than centered, so they need only
    /// their own content width. They do not measure themselves the way row 1
    /// does, so this is a fixed floor with margin over their widest content.
    private static let otherRowsFloor: CGFloat = 1260

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LiveViewPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider()
                // Row 1: camera control. The focus cluster and the exposure
                // pickers each sit centered in their own half, with one
                // divider between them (ExposureBar). The horizontal scroll is
                // the fallback for very narrow windows (content keeps at least
                // the viewport width so the trailing cluster reaches the
                // trailing edge).
                rowOne
                Divider()
                // Row 2: what you see (focus and zoom aids, the Meta switch,
                // preview treatments). Row 3: Live View and Capture, and the
                // fields that get written.
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
            stateOverlay()
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onPreferenceChange(ExposureBar.RequiredWidth.self) { rowOneWidth = $0 }
        // +32 for row 1's horizontal padding (see rowOneWidth).
        .frame(minWidth: max(Self.otherRowsFloor, rowOneWidth + 32), minHeight: 820)
    }

    /// Row 1 inside its horizontal scroll fallback.
    private var rowOne: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ExposureBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // Floor tracks what the row measured, so the scroll fallback
                // engages instead of clipping if the window is ever forced
                // below it.
                .containerRelativeFrame(.horizontal, alignment: .center) { len, _ in
                    max(len, rowOneWidth + 32)
                }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stateOverlay() -> some View {
        switch model.ui {
        case .disconnected, .enumerating:
            EmptyStates.NoCamera()
                .background(.ultraThinMaterial)
        case .ready, .streaming:
            // .ready's prompt lives on the canvas itself (LiveViewPane).
            EmptyView()
        case .error(let msg, let hint, let detail):
            EmptyStates.ErrorState(message: msg, hint: hint, detail: detail)
                .background(.ultraThinMaterial)
        }
    }
}
