# Dependencies

What Film Tether pulls in, and what ends up in the app.

## Swift

No third-party Swift packages. `Package.swift` declares one `systemLibrary` (libgphoto2, via Homebrew) and the project's own modules. There are no `.package(url:)` entries and no `Package.resolved`.

Every other import is an Apple system framework: SwiftUI, AppKit, Foundation, CoreFoundation, CoreGraphics, CoreImage (the whole preview pipeline), ImageIO, ImageCaptureCore, IOKit, os (unified logging), ApplicationServices, and Carbon (for keycode constants).

## Build dependencies (Homebrew)

- **libgphoto2**: the camera-control library. This is the reason the project exists.
- **pkg-config**: resolves build-time include and link flags. Not bundled.

libgphoto2 brings along the usual camera-library companions: libusb, libexif, jpeg-turbo, and gd.

## What ships in the .app

`scripts/bundle.sh` copies the runtime pieces from your local Homebrew install into the bundle, so the shipped app does not need Homebrew:

- `libgphoto2.6.dylib` and `libgphoto2_port.12.dylib`, plus the transitive dylibs they need: `libusb-1.0.0`, `libexif.12`, `libjpeg.8`, `libintl.8` and `libltdl.7`.
- The libgphoto2 camera drivers (camlibs), including `ptp2.so`, which is what Canon EOS bodies use.
- The USB transport, `usb1.so`.

## Network

The app makes no outbound network calls. There are no networking imports in the source. It talks to one USB device and writes files to a folder you choose.
