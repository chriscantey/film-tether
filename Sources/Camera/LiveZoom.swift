import Foundation
import CoreGraphics
import ImageIO
import CGPhoto2

/// Controls the camera's digital sensor-crop zoom for live view (the "punch-in" feature
/// equivalent to pressing the magnifier button on the camera body).
///
/// Some 2009-era EOS bodies can silently ignore an `eoszoom` write while returning OK
/// status. On the 7D the punch-in took effect every time it was measured, so
/// AppModel.startLiveView assumes it works, and the App layer falls back to
/// client-side JPEG-crop zoom when a zoom write throws (AppModel.applyZoom).
@CameraActor
public final class LiveZoom {
    public enum Mode: Int, Sendable {
        case fit = 1
        case fivex = 5
        // No 10× case: on the 7D a 10× write looks identical to 5× (see
        // setZoom), so 5× is the only punch-in factor.
    }

    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    public func setZoom(_ mode: Mode) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "eoszoom"
        )
        defer { gp_widget_unref(root) }
        let t = WidgetHelpers.widgetType(leaf)
        if t == GP_WIDGET_RADIO || t == GP_WIDGET_MENU {
            // Log the choices when the driver offers a list (libgphoto2
            // 2.5.33's ptp2 builds eoszoom as TEXT). On the 7D, 5x and 10x
            // look identical, which suggests the body clamps 10 → 5.
            let choices = (try? WidgetHelpers.choices(leaf)) ?? []
            if !choices.isEmpty {
                CameraLog.liveZoom.info("eoszoom choices: \(choices.joined(separator: ", "), privacy: .public)")
            }
            try WidgetHelpers.writeString(leaf, value: "\(mode.rawValue)")
        } else if t == GP_WIDGET_TEXT {
            try WidgetHelpers.writeString(leaf, value: "\(mode.rawValue)")
        } else if t == GP_WIDGET_RANGE {
            try WidgetHelpers.writeFloat(leaf, value: Float(mode.rawValue))
        } else if t == GP_WIDGET_TOGGLE {
            try WidgetHelpers.writeToggle(leaf, value: Int32(mode.rawValue))
        } else {
            throw CameraError.widgetTypeMismatch(
                expected: "TEXT/RADIO/MENU/RANGE/TOGGLE",
                got: WidgetHelpers.typeName(t)
            )
        }
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "eoszoom", leaf: leaf)
        CameraLog.liveZoom.info("setZoom(\(mode.rawValue, privacy: .public)) committed (widget type=\(WidgetHelpers.typeName(t), privacy: .public))")
    }

    /// Position the zoom rect within the frame, in the body's `eoszoomposition`
    /// units.
    public func setZoomPosition(x: Int, y: Int) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "eoszoomposition"
        )
        defer { gp_widget_unref(root) }
        try WidgetHelpers.writeString(leaf, value: "\(x),\(y)")
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "eoszoomposition", leaf: leaf)
    }

}

/// JPEG-crop fallback (ImageIO and CoreGraphics) the App layer uses in place of the
/// body's zoom (AppModel.handleFrame). Crops a rect of the JPEG and returns it as a
/// new JPEG at the cropped size.
public enum JPEGCrop {
    /// Returns a JPEG cropped to a `1/divisor` rect of the source, centered
    /// at the normalized `center` point (0..1 in each axis). divisor=5 →
    /// crop is 1/5 × 1/5 of the source. Returns nil when decoding, cropping
    /// or encoding fails, and the source as is when divisor is 1 or less.
    /// The crop is clamped so it always lies entirely inside the source.
    public static func cropAt(_ jpeg: Data, divisor: Int, center: CGPoint) -> Data? {
        guard divisor > 1 else { return jpeg }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let w = img.width, h = img.height
        let cropW = w / divisor
        let cropH = h / divisor
        let rawX = Int(center.x * CGFloat(w)) - cropW / 2
        let rawY = Int(center.y * CGFloat(h)) - cropH / 2
        let cropX = max(0, min(w - cropW, rawX))
        let cropY = max(0, min(h - cropH, rawY))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let cropped = img.cropping(to: cropRect) else { return nil }
        return jpegRepresentation(of: cropped, quality: 0.85)
    }

    private static func jpegRepresentation(of image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
