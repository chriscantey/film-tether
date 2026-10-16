import Foundation

@globalActor
public actor CameraActor {
    public static let shared = CameraActor()

    private static let executor = PinnedThreadExecutor(label: "co.wonders.filmtether.camera-thread")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }
}
