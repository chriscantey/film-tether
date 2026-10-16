# Dependencies

What Film Tether pulls in, and what ends up in the app.

## Swift

No third-party Swift packages. `Package.swift` declares one `systemLibrary` (libgphoto2, via Homebrew), the project's own modules, and film-sidecar. film-sidecar is a small MIT package of mine and the sidecar format Film Tether shares with Film Positive. It has two libraries: `FilmSidecar` reads and writes the `.xmp` sidecar, and `FilmStyle` holds shared SwiftUI styling (a spacing scale, a card background, an info popover and the histogram colors). It has no dependencies of its own and is vendored in this repository under `Packages/film-sidecar`, where `VENDORED.txt` says which Film Tether version it ships with. There are no `.package(url:)` entries and no `Package.resolved`.

Every other import is an Apple system framework: SwiftUI, AppKit, Foundation, CoreFoundation, CoreGraphics, CoreImage (the whole preview pipeline), ImageIO, ImageCaptureCore, IOKit, os and OSLog (unified logging, and reading it back for Help > Export Log), ApplicationServices, Carbon (for keycode constants), and CryptoKit (film-sidecar, to fingerprint the RAW a sidecar belongs to).

## Build dependencies (Homebrew)

- **libgphoto2**: the camera-control library the app talks to the camera through.
- **pkg-config**: resolves build-time include and link flags. Not bundled.
- **gphoto2**: libgphoto2's command-line tool, handy for checking the camera connection outside the app. Not needed to build and not bundled.
- **jq**: reads a bottle's URL and checksum from Homebrew's API for `make dist-compat` and `make dist-universal`. Not needed for `make run` or `make dist`, and not bundled.

## What ships in the .app

`scripts/bundle.sh` copies the runtime pieces into the bundle, so the shipped app does not need Homebrew:

| In the app's `Contents` folder | Library | License |
| --- | --- | --- |
| `Contents/Frameworks/libgphoto2.6.dylib`, `Contents/Frameworks/libgphoto2_port.12.dylib` | libgphoto2 | LGPL 2 or later |
| `Contents/Resources/camlibs/ptp2.so`, the camera driver Canon EOS bodies use | libgphoto2 | LGPL 2 or later |
| `Contents/Resources/iolibs/usb1.so`, the USB transport | libgphoto2 | LGPL 2 or later |
| `Contents/Frameworks/libusb-1.0.0.dylib` | libusb | LGPL 2.1 or later |
| `Contents/Frameworks/libexif.12.dylib` | libexif | LGPL 2 or later |
| `Contents/Frameworks/libintl.8.dylib` | libintl, from GNU gettext | LGPL 2.1 or later |
| `Contents/Frameworks/libltdl.7.dylib` | libltdl, from GNU Libtool | LGPL 2 or later |
| `Contents/Frameworks/libjpeg.8.dylib` | libjpeg, from libjpeg-turbo | IJG |

The released build's `ptp2.so` is built from libgphoto2's release source with the two patches in `patches/` applied, and the archive it builds from has to match the checksum in `patches/libgphoto2-source.sha256`. The rest are Homebrew's own builds.

The bundle also carries the license texts, `THIRD-PARTY-NOTICES.md` and the MIT licenses of Film Tether and film-sidecar, in `Contents/Resources/Licenses/`. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) has each library's version, upstream source archive and checksum.

## Where the versions come from

The library versions come from Homebrew, with two limits for the released build: the patched `ptp2.so` builds only from a libgphoto2 archive listed in `patches/libgphoto2-source.sha256`, and `scripts/compat-pins.txt` names the macOS 14 bottles of jpeg-turbo and gettext to use where Homebrew no longer lists one. `bundle.sh` records what it vendored in `Contents/Resources/Licenses/VERSIONS-<arch>.txt`, including whether `ptp2.so` is the patched build.

- A local `make run` or `make dist` takes the libraries from your own Homebrew install, so they carry your macOS version as their minimum.
- The released build is made with `make dist-universal` on an Intel Mac, because its x86_64 slice links the host's Homebrew libgphoto2. It fetches Homebrew's macOS 14 bottles for each architecture (`scripts/fetch-compat-libs.sh`, or the bottle named in `scripts/compat-pins.txt` once Homebrew stops listing one), builds the patched `ptp2.so` against each, and merges the two into one universal app. Its build number is 0 unless you pass one, as in `make dist-universal BUILD_NUMBER=7`. It also needs `jq`.

## Network

The app makes no outbound network calls. There are no networking imports in the source. It talks to one USB device and writes files to a folder you choose. The only web pages it opens are the supported-cameras and contributors pages, in your browser, when you click their links.

The build scripts do download things: Homebrew packages, and for the patched camera driver, the matching libgphoto2 source archive, which is checked against `patches/libgphoto2-source.sha256` when that file lists its version. `make release-sources` downloads the six source archives [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists and checks each one's checksum.
