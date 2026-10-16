// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FilmTether",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FilmTether", targets: ["App"]),
        .library(name: "Camera", targets: ["Camera"]),
        .library(name: "Hotkey", targets: ["Hotkey"]),
        // Scan is not a product. The app links it as a target, but it stays
        // out of `products` because its API is still changing.
    ],
    dependencies: [
        // film-sidecar reads and writes the <base>.xmp sidecar in the Film:
        // namespace that Film Positive also uses. The path below names the
        // copy this checkout builds against.
        .package(path: "Packages/film-sidecar"),
        // Sparkle checks for and installs updates, the one way every app of
        // ours does it. The only dependency from outside the project.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CGPhoto2",
            path: "Sources/CGPhoto2",
            pkgConfig: "libgphoto2",
            providers: [
                .brew(["libgphoto2"]),
            ]
        ),
        .target(
            name: "UsbReset",
            path: "Sources/UsbReset",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "Camera",
            dependencies: [
                "CGPhoto2", "UsbReset",
                .product(name: "FilmSidecar", package: "film-sidecar"),
            ],
            path: "Sources/Camera",
            linkerSettings: [
                // A fallback for `ld` if pkg-config fails. pkg-config already
                // provides -L for libgphoto2.
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
            ]
        ),
        .target(
            name: "Hotkey",
            dependencies: [],
            path: "Sources/Hotkey"
        ),
        // Film-scanning domain logic: preview transforms, the auto-crop
        // detectors, the exposure advisor, sharpness scoring, white-balance
        // gains and film sizes. Free of libgphoto2 and SwiftUI so it stays
        // unit-testable.
        .target(
            name: "Scan",
            dependencies: [],
            path: "Sources/Scan"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Camera", "Hotkey", "Scan",
                           .product(name: "FilmStyle", package: "film-sidecar"),
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/App",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        // A CLI that drives the Camera stack from a terminal: capture, live
        // view, manual focus and metering. Unlike the app it needs no window
        // server, so it also runs over SSH.
        .executableTarget(
            name: "FilmTetherDebug",
            dependencies: ["Camera", "Scan"],
            path: "Sources/Debug",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .testTarget(
            name: "CameraTests",
            dependencies: ["Camera", "Hotkey", .product(name: "FilmSidecar", package: "film-sidecar")],
            path: "Tests/CameraTests"
        ),
        .testTarget(
            name: "ScanTests",
            dependencies: ["Scan"],
            path: "Tests/ScanTests"
        ),
    ]
)
