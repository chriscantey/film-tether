# Replacing the bundled LGPL libraries

Film Tether's own code is MIT, and the app carries five libraries under the GNU LGPL: libgphoto2 (with its port library, camera driver and USB driver), libusb, libexif, libintl from gettext, and libltdl from libtool. Each is a separate dynamic library inside the bundle, and you are free to replace any of them with your own build, modified or not. This page shows how, with libgphoto2 as the worked example. The sixth library, libjpeg from libjpeg-turbo, is under the IJG license, and you can swap it the same way.

[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists each library's license, the version a release carries, and the upstream source archive with its checksum. Those source archives are attached to each [GitHub release](https://github.com/chriscantey/film-tether/releases), along with the two patches from 0.4.0 on, and `make release-sources` downloads the same archives and checks their checksums. The license texts are in [licenses](licenses).

## What's in the bundle

```
Film Tether.app/
  Contents/
    Frameworks/
      libgphoto2.6.dylib       libgphoto2, LGPL
      libgphoto2_port.12.dylib libgphoto2, LGPL
      libusb-1.0.0.dylib       libusb, LGPL
      libexif.12.dylib         libexif, LGPL
      libintl.8.dylib          libintl from gettext, LGPL
      libltdl.7.dylib          libltdl from libtool, LGPL
      libjpeg.8.dylib          libjpeg-turbo, IJG
    Resources/
      camlibs/ptp2.so          libgphoto2's camera driver, loaded at runtime
      iolibs/usb1.so           libgphoto2's USB transport, loaded at runtime
      Licenses/                license texts, notices, and VERSIONS-<arch>.txt
```

To see which versions a build carries:

```bash
cat "Film Tether.app/Contents/Resources/Licenses/"VERSIONS-*.txt
```

The compatibility and current versions `otool -L` prints for the dylibs are the libraries' binary interface versions, not their release numbers.

## The patched camera driver

The `ptp2.so` in the released app is built from the libgphoto2 release source (2.5.34 in Film Tether 0.4.0) with the two patches in this repo's [patches](patches) folder applied, by `scripts/build-patched-camlib-slice.sh`. The archive has to match the checksum in `patches/libgphoto2-source.sha256`.

- `eos-capture-target-bounded-wait.diff` limits a wait at connect to 1 second. Without the limit, that wait can hang an EOS 7D. When `FT_RESEND_PCHDD` is set, it also sends the camera the computer's storage details a second time during that wait. Film Tether sets that variable at launch. To launch without the resend, set `FT_NO_RESEND_PCHDD`, as in `open --env FT_NO_RESEND_PCHDD=1 -a "Film Tether"`.
- `eos-imageformat-L-combos.diff` fixes how the "RAW + L" and "cRAW + L" format options decode on bodies like the R5.

A stock build of libgphoto2 works in the app without them, minus those two fixes.

## Build libgphoto2 from source

You need the Xcode command line tools and Homebrew, plus the libraries libgphoto2 builds against:

```bash
brew install pkg-config libexif libusb libtool gettext jpeg-turbo
```

Then build the release the app carries, from its release archive, which needs no `autoreconf`. The same archive is attached to the Film Tether release, if you'd rather take it from there than download it:

```bash
curl -LO https://downloads.sourceforge.net/project/gphoto/libgphoto/2.5.34/libgphoto2-2.5.34.tar.bz2
shasum -a 256 libgphoto2-2.5.34.tar.bz2
# 5df9e774eb4ab6087a193afff84dcafe9f666e3443fe29e73e6779f659ff7f28
tar xjf libgphoto2-2.5.34.tar.bz2
cd libgphoto2-2.5.34
# optional, to keep the two fixes the released app carries:
# for p in /path/to/film-tether/patches/*.diff; do patch -p1 < "$p"; done
./configure --prefix=/tmp/my-libgphoto2 --with-camlibs=ptp2 \
    CPPFLAGS="-I$(brew --prefix)/include" LDFLAGS="-L$(brew --prefix)/lib"
make -j8
make install
```

`--with-camlibs=ptp2` builds only the camera driver the app ships. Leave it out to build them all.

## Swap it into the app

Quit Film Tether first, and work on a copy, so the installed app stays as it was:

```bash
ditto "/Applications/Film Tether.app" "$HOME/Desktop/Film Tether.app"   # adjust to your install location
APP="$HOME/Desktop/Film Tether.app"
```

If a step below fails with "Operation not permitted", macOS is protecting the app bundle: give Terminal access in System Settings > Privacy & Security > App Management.

Replace the two dylibs and the two drivers, keeping the file names the app uses. Copy only `ptp2.so` and `usb1.so`: the app loads every driver in those folders, and the `.la` files `make install` puts next to them are not needed.

```bash
cp /tmp/my-libgphoto2/lib/libgphoto2.6.dylib /tmp/my-libgphoto2/lib/libgphoto2_port.12.dylib \
   "$APP/Contents/Frameworks/"
cp /tmp/my-libgphoto2/lib/libgphoto2/*/ptp2.so "$APP/Contents/Resources/camlibs/"
cp /tmp/my-libgphoto2/lib/libgphoto2_port/*/usb1.so "$APP/Contents/Resources/iolibs/"
```

Your build records absolute install names, so point them back at the bundle:

```bash
install_name_tool -id "@rpath/libgphoto2.6.dylib" "$APP/Contents/Frameworks/libgphoto2.6.dylib"
install_name_tool -id "@rpath/libgphoto2_port.12.dylib" "$APP/Contents/Frameworks/libgphoto2_port.12.dylib"
install_name_tool -change "/tmp/my-libgphoto2/lib/libgphoto2_port.12.dylib" "@rpath/libgphoto2_port.12.dylib" "$APP/Contents/Frameworks/libgphoto2.6.dylib"
```

The drivers need the same treatment, pointed at the bundle's Frameworks folder. Otherwise a driver loads a second copy of `libgphoto2_port` from your build directory instead of the bundled one:

```bash
for f in "$APP/Contents/Resources/camlibs/"*.so "$APP/Contents/Resources/iolibs/"*.so; do
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep '^/tmp/my-libgphoto2/' | while read -r dep; do
    install_name_tool -change "$dep" "@loader_path/../../Frameworks/$(basename "$dep")" "$f"
  done
done
```

Your build links Homebrew's copies of libexif, libltdl and the others by absolute path too. That works on your own Mac. For an app that runs without Homebrew, point those at the bundle the same way: `@rpath/<name>` in the two dylibs and `@loader_path/../../Frameworks/<name>` in the drivers.

## Replacing one of the other LGPL libraries

The same steps work for libusb, libexif, libintl and libltdl: build the library, copy its dylib over the one in `Contents/Frameworks/` under the same file name, set its id with `install_name_tool -id "@rpath/<name>"`, point each of its own Homebrew references at the bundle with `install_name_tool -change <old path> "@rpath/<name>"` (check them with `otool -L`), and re-sign as below.

## Re-sign

Changing a binary invalidates its code signature, and macOS will not load an unsigned library on Apple Silicon. Sign each library and driver, then the app:

```bash
for f in "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Resources/camlibs/"*.so "$APP/Contents/Resources/iolibs/"*.so; do
  codesign --force --sign - "$f"
done
codesign --force --sign - --preserve-metadata=entitlements "$APP"
```

`-` signs ad hoc, which is enough to run the app on your own Mac. To sign with your own Developer ID, use `--sign "Developer ID Application: Your Name (TEAMID)"` in both places. For notarization, add `--timestamp` to the library and driver signatures and `--options runtime --timestamp` to the app's, then submit the app with `notarytool` and staple it, as `scripts/build-universal.sh` does.

Then open the app and plug in the camera. If macOS refuses to open it, clear its quarantine flag with `xattr -dr com.apple.quarantine "$APP"` and try again.
