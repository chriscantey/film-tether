import SwiftUI

/// The small set of visual values Film Positive and Film Tether share.
/// Deliberately tiny and layout-free: each app owns its own layout, and this
/// target holds only values and two leaf views. It is a separate target from
/// FilmSidecar, which does not depend on SwiftUI because it is the metadata
/// contract between the apps.
public enum FilmStyle {
    /// The spacing scale, in points.
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
    }

    /// Corner radius of a card (the histogram, an error card), drawn with the
    /// continuous corner style.
    public static let cardRadius: CGFloat = 6

    /// The fixed width of an info popover's text. It wraps downward from here.
    public static let popoverWidth: CGFloat = 240

    /// Histogram channel colors, drawn at `histogramOpacity` with a screen
    /// blend, so where all three overlap reads white.
    public static let histogramChannels: [Color] = [
        Color(red: 1, green: 0.23, blue: 0.19),
        Color(red: 0.20, green: 0.84, blue: 0.29),
        Color(red: 0.20, green: 0.48, blue: 1),
    ]
    public static let histogramOpacity: Double = 0.75
}

/// A card's background: regular material, 6 pt continuous corners and a
/// hairline separator edge.
public struct FilmCardBackground: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: FilmStyle.cardRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

public extension View {
    /// The shared card finish. See `FilmCardBackground`.
    func filmCard() -> some View { modifier(FilmCardBackground()) }
}

/// The inside of an info popover: body text at `FilmStyle.popoverWidth` that
/// wraps to as many lines as it needs, and an optional secondary detail line.
/// A max width with nothing letting the text grow downward squeezes the
/// sentence onto one line and cuts it off.
public struct InfoPopoverBody: View {
    let text: String
    let detail: String?

    public init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FilmStyle.Space.m) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: FilmStyle.popoverWidth, alignment: .leading)
        .padding(FilmStyle.Space.l)
    }
}
