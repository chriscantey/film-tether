import Foundation
import AppKit
import SwiftUI
import Camera

/// Called once at process start before any libgphoto2 use.
enum AppLaunch {
    static let bootstrap: Void = {
        CameraEnvironment.setup()
        CameraLog.installGphotoLogBridge()  // no-op unless EOS_DEBUG=1
        CameraLog.session.info("Film Tether launched (debug=\(CameraLog.isDebug, privacy: .public))")
        MainActor.assumeIsolated { uiSnapshotIfRequested() }
    }()

    /// Autonomous UI verification: `FT_SNAP="/path/prefix:1150x820,1500x900"`
    /// renders MainView offscreen at each size to `<prefix>-WxH.png` and
    /// exits. No camera, no Screen Recording permission (this is the app
    /// drawing its own view tree, not capturing the display). Pair with
    /// FT_UI_PREVIEW=1 so the no-camera overlay doesn't cover the layout.
    @MainActor
    private static func uiSnapshotIfRequested() {
        guard let spec = ProcessInfo.processInfo.environment["FT_SNAP"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { fputs("FT_SNAP wants prefix:WxH,WxH\n", stderr); exit(64) }
        let prefix = String(parts[0])
        _ = NSApplication.shared   // window-server connection for AppKit drawing
        let model = AppModel()     // default disconnected state; never start()ed
        for sizeSpec in parts[1].split(separator: ",") {
            let wh = sizeSpec.split(separator: "x").compactMap { Double($0) }
            guard wh.count == 2 else { continue }
            let w = CGFloat(wh[0]), h = CGFloat(wh[1])
            let renderer = ImageRenderer(content: MainView()
                .environmentObject(model)
                .frame(width: w, height: h))
            renderer.scale = 2.0   // retina-equivalent, text stays crisp
            guard let img = renderer.nsImage,
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                fputs("snap FAILED at \(Int(w))x\(Int(h))\n", stderr)
                continue
            }
            let out = "\(prefix)-\(Int(w))x\(Int(h)).png"
            try? png.write(to: URL(fileURLWithPath: out))
            print("snap → \(out)")
        }
        exit(0)
    }
}
