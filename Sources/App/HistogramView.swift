import SwiftUI
import FilmStyle
import CoreImage

/// Live RGB histogram of the live-view stream, as a scanning aid. Computed on
/// the GPU via CIAreaHistogram (64 bins per channel) on every Nth frame and
/// drawn by `HistogramCard`.
struct HistogramData: Equatable {
    /// Per-channel bin values, scaled together so the tallest bin of any
    /// channel is 1.
    var r: [Double]
    var g: [Double]
    var b: [Double]
    /// Percent of the pooled R, G and B bin counts in the bottom or top bin,
    /// the crushing and clipping number that matters when scanning.
    var clipLowPct: Double
    var clipHighPct: Double
}

enum HistogramCompute {
    static let bins = 64

    /// `PreviewPipeline.renderTapped` passes its own decoded CIImage and its
    /// own (unmanaged) context so the frame is decoded exactly once for
    /// display and histogram. The working space follows the caller's context:
    /// the pipeline's unmanaged context bins gamma-encoded values, matching
    /// the camera's own histogram convention.
    static func compute(image img: CIImage, context: CIContext) -> HistogramData? {
        let hist = img.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: img.extent),
            "inputCount": bins,
            "inputScale": 1.0,
        ])
        var px = [Float](repeating: 0, count: bins * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(hist, toBitmap: buf.baseAddress!, rowBytes: bins * 16,
                           bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        var r = [Double](repeating: 0, count: bins)
        var g = r, b = r
        for i in 0..<bins {
            r[i] = Double(px[i * 4])
            g[i] = Double(px[i * 4 + 1])
            b[i] = Double(px[i * 4 + 2])
        }
        let sums = (r: r.reduce(0, +), g: g.reduce(0, +), b: b.reduce(0, +))
        let total = sums.r + sums.g + sums.b
        guard total > 0 else { return nil }
        let clipLow = 100.0 * (r[0] + g[0] + b[0]) / total
        let clipHigh = 100.0 * (r[bins - 1] + g[bins - 1] + b[bins - 1]) / total
        // Normalize every channel by the global peak so the channels keep
        // their relative heights. Normalizing each channel by its own peak
        // would hide the color balance.
        let peak = max(r.max() ?? 0, g.max() ?? 0, b.max() ?? 0, .leastNonzeroMagnitude)
        func norm(_ a: [Double]) -> [Double] { a.map { $0 / peak } }
        return HistogramData(r: norm(r), g: norm(g), b: norm(b),
                             clipLowPct: clipLow, clipHighPct: clipHigh)
    }
}

enum HistogramCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    static func nearest(right: Bool, bottom: Bool) -> HistogramCorner {
        switch (right, bottom) {
        case (false, false): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (true, true): return .bottomRight
        }
    }
}

/// The floating card: the curves and the clipping badges.
struct HistogramCard: View {
    let data: HistogramData
    static let size = CGSize(width: 180, height: 96)

    var body: some View {
        VStack(spacing: 2) {
            Canvas { context, size in
                context.blendMode = .screen
                let c = FilmStyle.histogramChannels
                for (bins, color) in [(data.r, c[0]), (data.g, c[1]), (data.b, c[2])] {
                    var path = Path()
                    let n = bins.count
                    let step = size.width / CGFloat(n - 1)
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (i, v) in bins.enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(i) * step,
                                                 y: size.height * (1 - CGFloat(v) * 0.95)))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(FilmStyle.histogramOpacity)))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height - 18)
            HStack {
                if data.clipLowPct >= 0.1 {
                    Text("◂ \(clipString(data.clipLowPct))")
                        .foregroundStyle(data.clipLowPct >= 1.0 ? .red : .yellow)
                        .help("Percent of pixels crushed to black. When scanning: give it more exposure or more light.")
                }
                Spacer(minLength: 0)
                if data.clipHighPct >= 0.1 {
                    Text("\(clipString(data.clipHighPct)) ▸")
                        .foregroundStyle(data.clipHighPct >= 1.0 ? .red : .yellow)
                        .help("Percent of pixels clipped to white. When scanning: reduce exposure so highlight detail survives.")
                }
            }
            .font(.caption2.monospacedDigit())
            .frame(width: Self.size.width, height: 12)
        }
        .fixedSize()
        .padding(8)
        .filmCard()
    }

    private func clipString(_ v: Double) -> String {
        v >= 10 ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }
}

/// Positions the card at the chosen corner of the live-view pane. Drag it
/// anywhere and it snaps to the nearest corner on release.
struct HistogramOverlay: View {
    let data: HistogramData
    @Binding var corner: HistogramCorner
    let paneSize: CGSize
    @State private var drag: CGSize = .zero

    var body: some View {
        HistogramCard(data: data)
            .offset(drag)
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { v in
                        let inset: CGFloat = 12
                        let half = CGSize(width: HistogramCard.size.width / 2 + 8,
                                          height: HistogramCard.size.height / 2 + 8)
                        var x = corner.isRight ? paneSize.width - inset - half.width : inset + half.width
                        var y = corner.isBottom ? paneSize.height - inset - half.height : inset + half.height
                        x += v.translation.width
                        y += v.translation.height
                        corner = .nearest(right: x > paneSize.width / 2, bottom: y > paneSize.height / 2)
                        drag = .zero
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .padding(12)
            .animation(.snappy(duration: 0.18), value: corner)
    }
}
