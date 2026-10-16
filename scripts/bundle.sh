#!/usr/bin/env bash
# Assemble Film Tether.app from `swift build` output.
#
# Args: $1 = bundle name (e.g. Film Tether.app)
#       $2 = app name (e.g. FilmTether)
#       $3 = path to compiled binary
#       $4 = executable name inside the bundle (default: $2). Carries a space
#            ("Film Tether") the way Apple names its own. The SwiftPM product,
#            the entitlements filename and the zips all stay on $2.
#
# Env:  DEVELOPER_ID, optional codesign identity (default: ad-hoc "-")

set -euo pipefail

BUNDLE="${1:?bundle name required}"
APP="${2:?app name required}"
BINARY="${3:?binary path required}"
EXEC="${4:-$APP}"
IDENTITY="${DEVELOPER_ID:--}"

if [[ ! -x "$BINARY" ]]; then
    echo "error: binary not found at $BINARY" >&2
    echo "       run 'make build' first" >&2
    exit 1
fi

BREW_PREFIX="$(brew --prefix)"
LIBGPHOTO2_PREFIX="$(brew --prefix libgphoto2)"

# Compat mode: COMPAT_STAGE points at a directory of extracted OLDER-macOS
# Homebrew bottles (produced by scripts/fetch-compat-libs.sh). When set, vendor
# the camera dylibs from there instead of the natively-installed brew, so the
# app targets an older macOS than the build host and runs on an earlier OS.
# Bottle install names carry @@HOMEBREW_PREFIX@@/@@HOMEBREW_CELLAR@@
# placeholders (not real paths), copy_deps resolves them by basename, and the
# install-name rewrites below match the placeholders too.
COMPAT_POOL=""
if [[ -n "${COMPAT_STAGE:-}" ]]; then
    LIBGPHOTO2_PREFIX="$(dirname "$(find "$COMPAT_STAGE/libgphoto2" -mindepth 2 -maxdepth 2 -name lib -type d 2>/dev/null | head -1)")"
    COMPAT_POOL="$(find "$COMPAT_STAGE" -name '*.dylib' 2>/dev/null)"
    [[ -d "$LIBGPHOTO2_PREFIX/lib" ]] || { echo "FATAL: COMPAT_STAGE=$COMPAT_STAGE has no extracted libgphoto2 bottle" >&2; exit 1; }
    echo ">> COMPAT mode: vendoring older-OS bottles from $LIBGPHOTO2_PREFIX"
fi

LIBGPHOTO2_VERSION="$(basename "$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2" -mindepth 1 -maxdepth 1 -type d | head -1)")"

echo ">> Assembling $BUNDLE (libgphoto2 $LIBGPHOTO2_VERSION)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources/camlibs"
mkdir -p "$BUNDLE/Contents/Resources/iolibs"
mkdir -p "$BUNDLE/Contents/Frameworks"

cp "$BINARY" "$BUNDLE/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# Sparkle, the update framework, built by SwiftPM beside the executable as a
# binary framework. The whole framework goes in, XPC services and helpers
# inside; scripts/sign-framework.sh signs it inside out below.
SRC_FW="$(dirname "$BINARY")/Sparkle.framework"
[[ -d "$SRC_FW" ]] || { echo "FATAL: $SRC_FW not found beside the executable (swift build puts it there)" >&2; exit 1; }
cp -R "$SRC_FW" "$BUNDLE/Contents/Frameworks/Sparkle.framework"

# Stamp the bundle with the commit's short hash and the build time. About Film
# Tether shows it, so a report from a user can name the exact build.
BUILD_STAMP="$(git rev-parse --short HEAD 2>/dev/null || echo nogit) $(date '+%H:%M:%S')"
/usr/libexec/PlistBuddy -c "Add :BuildStamp string $BUILD_STAMP" "$BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :BuildStamp $BUILD_STAMP" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
# The update line (FT_UPDATE_LINE, default none): the feed keys and the version
# string, before anything is signed. A cut with a build number runs it again
# after the stamp and signs again.
bash scripts/updates-plist.sh "$BUNDLE/Contents/Info.plist" "${FT_UPDATE_LINE:-none}"
echo "    build stamp: $BUILD_STAMP"

# App icon: pack the prebuilt Resources/AppIcon.iconset with iconutil.
#
# The slices are packed as drawn, never generated from one raster: one raster scaled ten
# ways cannot carry size-specific artwork, and the 16 and 32 pixel slices are
# drawn separately from the larger ones (Resources/ICON.md says how).
#
# Resources/AppIcon.png is the 1024 master, kept for reference and for anyone
# re-deriving the set. The build does not read it. The source of truth is the
# iconset. `iconutil -c icns` is byte-deterministic over a fixed set of slices.
ICONSET_SRC="Resources/AppIcon.iconset"
if [[ ! -d "$ICONSET_SRC" ]]; then
    echo "FATAL: $ICONSET_SRC is missing, the app would ship with no icon" >&2
    exit 1
fi
# Count the slices before packing. iconutil accepts a partial iconset without
# complaint, so a half-copied set would build an app whose Dock icon is fine at
# one size and blank at another, and nothing downstream would say so.
ICON_SLICES=$(ls "$ICONSET_SRC"/icon_*.png 2>/dev/null | wc -l | tr -d ' ')
if [[ "$ICON_SLICES" != "10" ]]; then
    echo "FATAL: $ICONSET_SRC holds $ICON_SLICES slices, expected 10" >&2
    exit 1
fi
echo ">> Packing AppIcon.icns from $ICONSET_SRC ($ICON_SLICES slices)"
iconutil -c icns "$ICONSET_SRC" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

for dylib in libgphoto2 libgphoto2_port; do
    src="$(ls "$LIBGPHOTO2_PREFIX/lib/$dylib".*.dylib 2>/dev/null | head -1)"
    if [[ -z "$src" ]]; then
        echo "warning: $dylib not found under $LIBGPHOTO2_PREFIX/lib" >&2
        continue
    fi
    dst="$BUNDLE/Contents/Frameworks/$(basename "$src")"
    cp "$src" "$dst"
    chmod +w "$dst"
done

# Copy the Homebrew dylibs the bundled ones need, and theirs in turn. Libraries
# outside Homebrew (the system's own) are left alone.
copy_deps() {
    local target="$1"
    otool -L "$target" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                base="$(basename "$dep")"
                if [[ ! -f "$BUNDLE/Contents/Frameworks/$base" ]]; then
                    # In compat mode otool reports @@HOMEBREW_...@@ placeholders, so
                    # resolve by basename from the staged bottle pool. Otherwise
                    # copy the real brew path.
                    srcdep="$dep"
                    if [[ -n "$COMPAT_POOL" ]]; then
                        # `|| true`: under set -e a grep with no match inside the
                        # substitution would kill the whole script here with no
                        # message, so the "missing dep" line below would not print.
                        srcdep="$(printf '%s\n' "$COMPAT_POOL" | grep "/$base\$" | head -1 || true)"
                        if [[ -z "$srcdep" ]]; then
                            # No bottle of this dylib for the compat tag. Fall
                            # back to the host's own copy so the slice still
                            # builds, and say so loudly: that one library then
                            # carries the host's minimum macOS, which the
                            # per-slice "min macOS" line of build-universal.sh reports.
                            host="$BREW_PREFIX/lib/$base"
                            want="$(lipo -archs "$BINARY" 2>/dev/null | awk '{print $1}')"
                            if [[ -f "$host" ]] && lipo -archs "$(readlink -f "$host")" 2>/dev/null | grep -qw "$want"; then
                                srcdep="$(readlink -f "$host")"
                                echo "   ! no compat bottle for $base, using host copy $srcdep (raises min macOS of this slice)" >&2
                            else
                                # A host copy of the wrong architecture is not
                                # used. Leave it missing and let the link-closure
                                # check below name it.
                                echo "   ! no compat bottle for $base and no $want host copy" >&2
                            fi
                        fi
                    fi
                    if [[ -z "$srcdep" || ! -f "$srcdep" ]]; then
                        echo "   ! missing dep $base (compat=${COMPAT_POOL:+yes})" >&2
                        continue
                    fi
                    echo "   + $base"
                    cp "$srcdep" "$BUNDLE/Contents/Frameworks/$base"   # by dependent name, since the host fallback resolves a symlink
                    chmod +w "$BUNDLE/Contents/Frameworks/$base"
                    copy_deps "$BUNDLE/Contents/Frameworks/$base"
                fi
                ;;
        esac
    done
}

echo ">> Vendoring transitive dylib deps"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib; do
    copy_deps "$f"
done

# Copy only ptp2.so, the PTP driver libgphoto2 uses for Canon EOS bodies. The
# other camlibs are for non-EOS gear (webcams, photo frames, older serial
# PowerShots through canon.so) and pull in libgd and a set of image and video
# codecs (libavif, libaom, libdav1d, libvmaf, libwebp, libtiff, libfreetype).
# Set CAMLIBS="ptp2 ..." to add more.
CAMLIBS_WANTED="${CAMLIBS:-ptp2}"
PATCHED_CAMLIBS_USED=""
echo ">> Vendoring camlibs: $CAMLIBS_WANTED"
for cam in $CAMLIBS_WANTED; do
    src="$LIBGPHOTO2_PREFIX/lib/libgphoto2/$LIBGPHOTO2_VERSION/$cam.so"
    # Prefer a repo-local patched camlib (built by scripts/build-patched-camlib.sh
    # with every patch in patches/) when its libgphoto2 version matches the one
    # being vendored. Native builds only: compat/universal
    # builds target other OS/arch bottles the local build doesn't match.
    patched="vendor/camlibs/$LIBGPHOTO2_VERSION/$cam.so"
    if [[ -z "${COMPAT_STAGE:-}" && -f "$patched" ]]; then
        echo "   using patched $cam.so from $patched"
        src="$patched"
        PATCHED_CAMLIBS_USED="$PATCHED_CAMLIBS_USED $cam"
    fi
    # Compat slices: PATCHED_CAMLIBS_DIR names the per-slice patched camlibs
    # built by scripts/build-patched-camlib-slice.sh against this stage. When
    # it is set, a missing camlib is fatal: a slice must never quietly fall
    # back to the stock camlib, which lacks the bounded AvailableShots wait.
    if [[ -n "${COMPAT_STAGE:-}" && -n "${PATCHED_CAMLIBS_DIR:-}" ]]; then
        slice_patched="$PATCHED_CAMLIBS_DIR/$LIBGPHOTO2_VERSION/$cam.so"
        [[ -f "$slice_patched" ]] || { echo "FATAL: no patched $cam.so at $slice_patched" >&2; exit 1; }
        echo "   using patched $cam.so from $slice_patched"
        src="$slice_patched"
        PATCHED_CAMLIBS_USED="$PATCHED_CAMLIBS_USED $cam"
    fi
    if [[ -f "$src" ]]; then
        cp "$src" "$BUNDLE/Contents/Resources/camlibs/"
    else
        echo "warning: camlib $cam.so not found at $src" >&2
    fi
done

# Copy iolibs, only usb1 (USB transport, every EOS body here is USB-tethered).
# disk/ptpip/serial are unused. Override with IOLIBS="usb1 ptpip" if needed.
IOLIBS_WANTED="${IOLIBS:-usb1}"
echo ">> Vendoring iolibs: $IOLIBS_WANTED"
PORT_VERSION_DIR="$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2_port" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
if [[ -n "$PORT_VERSION_DIR" ]]; then
    for io in $IOLIBS_WANTED; do
        src="$PORT_VERSION_DIR/$io.so"
        if [[ -f "$src" ]]; then
            cp "$src" "$BUNDLE/Contents/Resources/iolibs/"
        else
            echo "warning: iolib $io.so not found at $src" >&2
        fi
    done
fi

# The camlibs/iolibs (.so) are dlopen'd at runtime and have their own brew-path
# dependencies (libgphoto2, libgphoto2_port, libexif, libusb, ...). Vendor any
# that the top-level sweep missed, so nothing the camlib needs resolves back to
# Homebrew at runtime, which would load a second copy of libgphoto2_port and
# fail on a Mac without Homebrew.
echo ">> Vendoring camlib/iolib transitive deps"
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    copy_deps "$f"
done

# Strip the inherited Homebrew code signatures before rewriting install names.
# Homebrew ships its dylibs ad-hoc signed, and install_name_tool then floods stderr
# with "changes being made to the file will invalidate the code signature"
# (one line per dylib per change, dozens of them). The signatures are
# meaningless here anyway: we re-sign every embedded binary at the end. Removing
# them first makes install_name_tool silent without hiding real errors.
echo ">> Stripping inherited signatures (re-signed at the end)"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib \
         "$BUNDLE/Contents/Resources/camlibs/"*.so \
         "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    codesign --remove-signature "$f" 2>/dev/null || true   # no-op if already unsigned
done

# Rewrite install names to @rpath so the bundled binary finds the bundled dylibs.
# install_name_tool errors are not suppressed, so a failed rewrite stops the build.
echo ">> Rewriting install names to @rpath"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib; do
    base="$(basename "$f")"
    install_name_tool -id "@rpath/$base" "$f"
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                depbase="$(basename "$dep")"
                install_name_tool -change "$dep" "@rpath/$depbase" "$f"
                ;;
        esac
    done
done

for dep in $(otool -L "$BUNDLE/Contents/MacOS/$EXEC" | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
        @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
            depbase="$(basename "$dep")"
            install_name_tool -change "$dep" "@rpath/$depbase" "$BUNDLE/Contents/MacOS/$EXEC"
            ;;
    esac
done

# Rewrite camlib/iolib deps to the bundled Frameworks. These .so files live in
# Contents/Resources/{camlibs,iolibs}/ and are dlopen'd by libgphoto2 at runtime.
# @loader_path resolves relative to each .so, so ../../Frameworks reaches the
# bundled dylibs. Without this the bundled ptp2.so loads Homebrew's
# libgphoto2_port by absolute path, a second copy of the port library, and the
# bundle quietly depends on Homebrew. @rpath isn't used here because the
# camlibs carry no LC_RPATH, and @loader_path is unconditional.
echo ">> Rewriting camlib/iolib install names to @loader_path/../../Frameworks"
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                depbase="$(basename "$dep")"
                install_name_tool -change "$dep" "@loader_path/../../Frameworks/$depbase" "$f"
                ;;
        esac
    done
done

# Verify no camlib or iolib still references /opt/homebrew, /usr/local/Cellar or
# a bottle placeholder. A leftover absolute path means a second dylib copy at
# runtime, so fail loudly.
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -qE '^/opt/homebrew/|^/usr/local/Cellar/|^@@HOMEBREW'; then
        echo "FATAL: $(basename "$f") still links a brew/placeholder path, would load a 2nd libgphoto2_port copy" >&2
        otool -L "$f" | grep -E '/opt/homebrew/|/usr/local/Cellar/|@@HOMEBREW' >&2
        exit 1
    fi
done

# Tell the executable to look in Contents/Frameworks.
# install_name_tool -add_rpath errors out if the rpath already exists in the
# binary's load commands, so check first via otool and only add if missing.
RPATH="@executable_path/../Frameworks"
if otool -l "$BUNDLE/Contents/MacOS/$EXEC" | grep -A 2 "LC_RPATH" | grep -q "path $RPATH "; then
    echo "   rpath '$RPATH' already present, skipping add_rpath"
else
    install_name_tool -add_rpath "$RPATH" "$BUNDLE/Contents/MacOS/$EXEC"
    echo "   added rpath '$RPATH' to binary"
fi

# Verify the binary links a libgphoto2 library through @rpath and that the
# rpath is in place. If either is missing the app won't launch, so fail loudly
# here rather than ship a bundle that dyld will reject.
if ! otool -L "$BUNDLE/Contents/MacOS/$EXEC" | grep -q "@rpath/libgphoto2"; then
    echo "FATAL: binary doesn't reference @rpath/libgphoto2, dyld will fail at launch" >&2
    otool -L "$BUNDLE/Contents/MacOS/$EXEC" | head -20 >&2
    exit 1
fi
if ! otool -l "$BUNDLE/Contents/MacOS/$EXEC" | grep -A 2 "LC_RPATH" | grep -q "path $RPATH "; then
    echo "FATAL: binary missing LC_RPATH $RPATH, dyld can't find bundled dylibs" >&2
    exit 1
fi

# Link closure: every bundled library a Mach-O in the bundle names must be IN
# the bundle. copy_deps only warns on a missing dep ("! missing dep"), and a
# bundle missing a library still signs, notarizes and staples clean, then dies
# in dyld at launch. Signing and Gatekeeper cannot see this, only a launch or
# this check can.
echo ">> Checking link closure"
closure_fail=0
for f in "$BUNDLE/Contents/MacOS/$EXEC" "$BUNDLE/Contents/Frameworks/"*.dylib \
         "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    while read -r dep; do
        case "$dep" in
            @rpath/*.framework/*|@executable_path/../Frameworks/*.framework/*)
                # A framework: @rpath/Name.framework/Versions/B/Name resolves
                # under Contents/Frameworks by its own path.
                if [[ ! -f "$BUNDLE/Contents/Frameworks/${dep#*/}" ]]; then
                    echo "FATAL: $(basename "$f") needs $dep, which is not in Contents/Frameworks" >&2
                    closure_fail=1
                fi
                ;;
            @rpath/*|@loader_path/../../Frameworks/*|@executable_path/../Frameworks/*)
                if [[ ! -f "$BUNDLE/Contents/Frameworks/$(basename "$dep")" ]]; then
                    echo "FATAL: $(basename "$f") needs $dep, which is not in Contents/Frameworks" >&2
                    closure_fail=1
                fi
                ;;
        esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done
[[ $closure_fail -eq 0 ]] || exit 1

# The license texts and notices for the libraries the default camlib and iolib
# set carries (THIRD-PARTY-NOTICES.md says which file covers which library),
# and a record of the library versions this bundle vendors, so the exact
# upstream source of any build can be found. Copied before signing so the
# signature covers them.
LICENSES_DIR="$BUNDLE/Contents/Resources/Licenses"
echo ">> Copying licenses and notices into Contents/Resources/Licenses"
mkdir -p "$LICENSES_DIR"
cp LICENSE "$LICENSES_DIR/FilmTether-LICENSE.txt"
cp THIRD-PARTY-NOTICES.md licenses/*.txt "$LICENSES_DIR/"
# film-sidecar is compiled into the app. Its LICENSE comes from the copy vendored
# under Packages/, or else from ../film-sidecar.
SIDECAR_LICENSE=""
for d in Packages/film-sidecar ../film-sidecar; do
    if [[ -f "$d/LICENSE" ]]; then SIDECAR_LICENSE="$d/LICENSE"; break; fi
done
[[ -n "$SIDECAR_LICENSE" ]] || { echo "FATAL: no film-sidecar LICENSE in Packages/film-sidecar or ../film-sidecar" >&2; exit 1; }
cp "$SIDECAR_LICENSE" "$LICENSES_DIR/film-sidecar-LICENSE.txt"

# A compat build reads each version from the staged bottle's directory name
# (<stage>/<formula>/<version>), and a native build from the Homebrew keg.
formula_version() {
    local f="$1" d=""
    if [[ -n "${COMPAT_STAGE:-}" ]]; then
        d="$(find "$COMPAT_STAGE/$f" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "$d" ]]; then
        d="$(brew --prefix "$f" 2>/dev/null || true)"
        if [[ -n "$d" && -e "$d" ]]; then d="$(readlink -f "$d")"; else d=""; fi
    fi
    if [[ -n "$d" ]]; then basename "$d"; else echo unknown; fi
}
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist" 2>/dev/null || echo unknown)"
MANIFEST_ARCH="$(lipo -archs "$BINARY" 2>/dev/null | tr ' ' '-' || true)"
MANIFEST="$LICENSES_DIR/VERSIONS-${MANIFEST_ARCH:-unknown}.txt"
{
    echo "Film Tether $APP_VERSION (${MANIFEST_ARCH:-unknown}). Libraries in this bundle, by Homebrew formula and version:"
    # The runtime formulae for ptp2 and usb1, the same set fetch-compat-libs.sh stages.
    for f in libgphoto2 libusb libexif gettext libtool jpeg-turbo; do
        echo "$f $(formula_version "$f")"
    done
    for cam in $CAMLIBS_WANTED; do
        if [[ " $PATCHED_CAMLIBS_USED " == *" $cam "* ]]; then
            echo "$cam.so: built from the libgphoto2 $LIBGPHOTO2_VERSION release source with $(cd patches && echo *.diff) applied"
        else
            echo "$cam.so: Homebrew's build of libgphoto2 $LIBGPHOTO2_VERSION, unpatched"
        fi
    done
} > "$MANIFEST"
sed 's/^/   /' "$MANIFEST"

# Codesign the embedded dylibs first, then the bundle.
# macOS Sequoia's codesign hits "internal error in Code Signing subsystem"
# intermittently when signing many files in rapid succession. Each file gets
# three quiet tries half a second apart, then one more with stderr shown. The
# failure is almost always transient.
codesign_one() {
    local f="$1"
    for attempt in 1 2 3; do
        if codesign --force --sign "$IDENTITY" "$f" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    codesign --force --sign "$IDENTITY" "$f"
}

echo ">> Codesigning ($IDENTITY)"
bash scripts/sign-framework.sh "$IDENTITY" "$BUNDLE" Sparkle.framework
for f in "$BUNDLE/Contents/Frameworks/"*.dylib \
         "$BUNDLE/Contents/Resources/camlibs/"*.so \
         "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    codesign_one "$f"
done
# --deep is deprecated. Inner binaries were signed individually above.
# Bundle-level sign also gets the retry wrapper since it can hit the same
# transient failure.
bundle_sign() {
    for attempt in 1 2 3; do
        if codesign --force --sign "$IDENTITY" \
            --entitlements "Resources/${APP}.entitlements" \
            "$BUNDLE" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    codesign --force --sign "$IDENTITY" \
        --entitlements "Resources/${APP}.entitlements" \
        "$BUNDLE"
}
bundle_sign

echo ">> Verifying"
file "$BUNDLE/Contents/MacOS/$EXEC" | head -1
codesign --verify --verbose "$BUNDLE" 2>&1 | head -3

echo ""
echo "OK  →  $BUNDLE"
