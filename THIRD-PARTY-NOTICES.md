# Third-party notices

Film Tether's own code is under the MIT license in [LICENSE](LICENSE). The app also carries the libraries below in compiled form. Their license texts are in [licenses](licenses). Inside the app, `Film Tether.app/Contents/Resources/Licenses/` holds the same license texts and this file, with Film Tether's license as FilmTether-LICENSE.txt and film-sidecar's as film-sidecar-LICENSE.txt.

## What the app carries

| Library | Files in the app | License | License text |
| --- | --- | --- | --- |
| libgphoto2, with its port library, the `ptp2` camera driver and the `usb1` USB driver | `libgphoto2.6.dylib`, `libgphoto2_port.12.dylib`, `camlibs/ptp2.so`, `iolibs/usb1.so` | GNU LGPL, version 2 or later | `libgphoto2-COPYING.txt`, `libgphoto2_port-COPYING.LIB.txt` |
| libusb | `libusb-1.0.0.dylib` | GNU LGPL, version 2.1 or later | `libusb-COPYING.txt` |
| libexif | `libexif.12.dylib` | GNU LGPL, version 2 or later | `libexif-COPYING.txt` |
| libintl, from GNU gettext | `libintl.8.dylib` | GNU LGPL, version 2.1 or later | `gettext-libintl-COPYING.LIB.txt` |
| libltdl, from GNU Libtool | `libltdl.7.dylib` | GNU LGPL, version 2 or later | `libtool-libltdl-COPYING.LIB.txt` |
| libjpeg-turbo, its libjpeg library | `libjpeg.8.dylib` | IJG license | `libjpeg-turbo-IJG-license.txt` |
| film-sidecar | compiled into the app | MIT | `Packages/film-sidecar/LICENSE` |
| Sparkle, the update framework | `Sparkle.framework`, with its XPC services and helpers inside | MIT | `sparkle-LICENSE.txt` |

The licenses named above are the ones each library's own source files state. Each LGPL library is copyright its authors, who are listed in the `AUTHORS` file of its source release. The libintl and libltdl sources are copyright the Free Software Foundation.

This software is based in part on the work of the Independent JPEG Group.

## Versions and source

The libraries come from Homebrew's builds, which Homebrew makes from the unmodified upstream release using the build recipe in its formula. The one exception is `ptp2.so`: the released app builds it from the libgphoto2 release source with the two patches in the repository's [patches](https://github.com/chriscantey/film-tether/tree/v0.4.0/patches) folder applied, as described in [RELINKING.md](https://github.com/chriscantey/film-tether/blob/v0.4.0/RELINKING.md). The patches change libgphoto2's source, so they are under libgphoto2's license, the GNU LGPL, version 2 or later, not the MIT license.

Each build records the versions of the six Homebrew libraries below in `Contents/Resources/Licenses/VERSIONS-<arch>.txt`. The released Film Tether 0.4.0 carries these releases:

| Library | Version | Upstream source archive | SHA-256 |
| --- | --- | --- | --- |
| libgphoto2 | 2.5.34 | https://downloads.sourceforge.net/project/gphoto/libgphoto/2.5.34/libgphoto2-2.5.34.tar.bz2 | `5df9e774eb4ab6087a193afff84dcafe9f666e3443fe29e73e6779f659ff7f28` |
| libusb | 1.0.30 | https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 | `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf` |
| libexif | 0.6.26 | https://github.com/libexif/libexif/releases/download/v0.6.26/libexif-0.6.26.tar.bz2 | `0830ed253fceeb60444fb309598bc8a9491d3007dc054aad3a50a347c5597c57` |
| gettext (libintl) | 1.0 | https://ftp.gnu.org/gnu/gettext/gettext-1.0.tar.gz | `85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a` |
| libtool (libltdl) | 2.6.2 | https://ftp.gnu.org/gnu/libtool/libtool-2.6.2.tar.xz | `2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e` |
| jpeg-turbo | 3.2.0 | https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz | `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` |
| Sparkle | 2.10.0 | https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip | `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959` |

The checksums for the six Homebrew libraries are the ones Homebrew's formulae record. Sparkle is not a Homebrew library. Swift Package Manager downloads the archive in its row, checked against the checksum in Sparkle's own `Package.swift`, and the app carries the framework from it, signed again with the app's signature and otherwise unchanged.

## Where to get the source

The source archives of the six Homebrew libraries above, exactly as their projects publish them, and the two patch files `ptp2.so` is built with are attached to the [GitHub release](https://github.com/chriscantey/film-tether/releases) of each version from 0.4.0 on. The 0.3.0 release page has the source archives for the libraries that release carries. Its `ptp2.so` is Homebrew's unpatched build, so it has no patches. `make release-sources` downloads the same archives and checks each against its checksum above, and `scripts/release-sources.sh upload <tag> --run` attaches them to a release.

The table above describes the released app. An app you build yourself can carry other versions, and its `VERSIONS-<arch>.txt` lists the ones that build vendored.
