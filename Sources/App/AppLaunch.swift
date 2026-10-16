import Foundation
import AppKit
import SwiftUI
import Camera

/// Called once at process start before any libgphoto2 use.
enum AppLaunch {
    static let bootstrap: Void = {
        let toolTipDelayKey = "NSInitialToolTipDelay"
        if UserDefaults.standard.object(forKey: toolTipDelayKey) == nil {
            UserDefaults.standard.set(600, forKey: toolTipDelayKey)
        }
        CameraEnvironment.setup()
        CameraLog.installGphotoLogBridge()  // no-op unless EOS_DEBUG=1
        CameraLog.session.info("Film Tether launched (debug=\(CameraLog.isDebug, privacy: .public))")
    }()
}
