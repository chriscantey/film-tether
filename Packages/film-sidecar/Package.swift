// swift-tools-version:5.10
import PackageDescription

// FilmSidecar: the one sidecar both Film Tether and Film Positive read and write,
// <base>.xmp next to the image. One type and one store for both apps.
let package = Package(
    name: "FilmSidecar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FilmSidecar", targets: ["FilmSidecar"]),
        // Shared visual values and two leaf views (SwiftUI). Separate so the
        // sidecar target does not depend on SwiftUI.
        .library(name: "FilmStyle", targets: ["FilmStyle"]),
    ],
    targets: [
        .target(name: "FilmSidecar", path: "Sources/FilmSidecar"),
        .target(name: "FilmStyle", path: "Sources/FilmStyle"),
        .testTarget(name: "FilmSidecarTests", dependencies: ["FilmSidecar"], path: "Tests/FilmSidecarTests"),
    ]
)
