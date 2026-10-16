#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) Film Tether targeting macOS Sonoma (14)+.
# It needs an Intel host: the x86_64 slice links the host's Homebrew
# libgphoto2, and the arm64 slice links the arm64 bottle. Homebrew bottles
# are downloadable pre-builts for the tags a formula lists, so we fetch both
# the `sonoma` (x86_64) and `arm64_sonoma` libgphoto2 bottle sets, build each
# arch slice, bundle each separately (through scripts/bundle.sh and its
# COMPAT_STAGE path, which vendors the staged bottles), then lipo-merge the
# two finished bundles into one universal .app.
#
# Output: "Film Tether.app" that runs native on Intel + Apple Silicon. The
# floor is macOS 14 unless a slice borrows a host library, which the "min
# macOS" lines at the end report.
#
# Env: DEVELOPER_ID      optional "Developer ID Application: NAME (TEAMID)" for
#                        the final re-sign (defaults to ad-hoc "-").
#      NOTARY_PROFILE    optional notarytool keychain profile. With a real
#                        DEVELOPER_ID, the bundle is notarized and stapled.
#      SIGN_KEYCHAIN     optional signing keychain, unlocked with
#      SIGN_KEYCHAIN_PW  this password when both are set. Pass it in the
#                        environment, not on a command line.
#      BUILD_NUMBER      optional whole number stamped into the built bundle as
#                        CFBundleVersion. Without it the bundle keeps the 0
#                        placeholder the source Info.plist carries.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FilmTether"
# The executable inside the bundle carries the space, Apple-style. The SwiftPM
# product, the entitlements filename and the built-binary paths stay APP_NAME.
EXEC_NAME="Film Tether"
BUNDLE="${1:-Film Tether.app}"
IDENTITY="${DEVELOPER_ID:--}"
ARM_TAG="arm64_sonoma"   # macOS 14, Apple Silicon
X86_TAG="sonoma"         # macOS 14, Intel
ARM_STAGE=".compat-libs/$ARM_TAG"
X86_STAGE=".compat-libs/$X86_TAG"
X86_APP=".build/_uni/x86.app"
ARM_APP=".build/_uni/arm.app"

# Optional signing keychain, for signing without the login keychain's GUI
# unlock. It must already hold the Developer ID identity and be on the search
# list. The password arrives in the environment and goes to `security -i` on
# stdin, so `ps -o args` shows only `security -i`, never the password.
# `security -i` reads one command per line and takes a double-quoted argument
# with backslash escapes.
sec_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }
if [[ -n "${SIGN_KEYCHAIN:-}" && -n "${SIGN_KEYCHAIN_PW:-}" ]]; then
    [[ "$SIGN_KEYCHAIN_PW" != *$'\n'* ]] || { echo "FATAL: SIGN_KEYCHAIN_PW holds a newline" >&2; exit 3; }
    printf 'unlock-keychain -p %s %s\n' "$(sec_quote "$SIGN_KEYCHAIN_PW")" "$(sec_quote "$SIGN_KEYCHAIN")" \
        | security -i
    security set-keychain-settings "$SIGN_KEYCHAIN"   # no auto-lock during the build
fi

# The build number comes from the caller, not from the source tree. The source
# plist carries a 0 placeholder. Anything but a whole number stops the build
# here, before an hour of work produces a bundle with no number in it.
BUILD_NUM="${BUILD_NUMBER:-}"
if [[ -n "$BUILD_NUM" ]]; then
    [[ "$BUILD_NUM" =~ ^[0-9]+$ ]] || { echo "FATAL: BUILD_NUMBER must be a whole number, got '$BUILD_NUM'" >&2; exit 3; }
    echo "==> Build number: $BUILD_NUM"
else
    echo "==> No BUILD_NUMBER, so the bundle keeps the 0 placeholder"
fi

echo "==> 1/6  Fetch both-arch Sonoma bottles"
bash scripts/fetch-compat-libs.sh "$X86_TAG" "$X86_STAGE"
bash scripts/fetch-compat-libs.sh "$ARM_TAG" "$ARM_STAGE"
# The patched ptp2 camlib for each slice (bounded AvailableShots wait),
# lipo-merged with the rest below.
bash scripts/build-patched-camlib-slice.sh x86_64 "$X86_STAGE" vendor/camlibs-compat/x86_64
bash scripts/build-patched-camlib-slice.sh arm64 "$ARM_STAGE" vendor/camlibs-compat/arm64

# The arm64 libgphoto2 dylibs from the bottle. We feed these to the arm64 link as
# direct inputs (not -L search): pkg-config emits `-L/usr/local/lib -lgphoto2`,
# whose x86_64 libgphoto2 the linker finds first and skips as wrong-arch without
# continuing the search, so a direct dylib input is the reliable way to supply
# the arm64 symbols. bundle.sh later rewrites their @@HOMEBREW_...@@ install names to
# @rpath, matching the x86 slice.
ARM_LIBDIR="$(dirname "$(find "$ARM_STAGE/libgphoto2" -name 'libgphoto2.6.dylib' | head -1)")"
ARM_GP="$ARM_LIBDIR/libgphoto2.6.dylib"
ARM_PORT="$ARM_LIBDIR/libgphoto2_port.12.dylib"
X86_LIBDIR="$(dirname "$(find "$X86_STAGE/libgphoto2" -name 'libgphoto2.6.dylib' | head -1)")"

echo "==> 2/6  Build x86_64 slice + bundle (Sonoma dylibs)"
# Each slice links its own bottle's libgphoto2 directly, so an Apple Silicon
# host can link x86_64 and an Intel host adds no second load command.
swift build -c release --arch x86_64 ${SWIFT_BUILD_SYSTEM:-} \
  -Xlinker "$X86_LIBDIR/libgphoto2.6.dylib" -Xlinker "$X86_LIBDIR/libgphoto2_port.12.dylib" \
  -Xlinker -dead_strip_dylibs
rm -rf "$X86_APP"; mkdir -p "$(dirname "$X86_APP")"
COMPAT_STAGE="$X86_STAGE" PATCHED_CAMLIBS_DIR=vendor/camlibs-compat/x86_64 bash scripts/bundle.sh "$X86_APP" "$APP_NAME" \
  ".build/x86_64-apple-macosx/release/$APP_NAME" "$EXEC_NAME" >/dev/null
echo "    x86 bundle: $(lipo -archs "$X86_APP/Contents/MacOS/$EXEC_NAME")"

echo "==> 3/6  Build arm64 slice (against arm64 bottle) + bundle"
# -dead_strip_dylibs: on an Apple Silicon host /opt/homebrew's arm64
# libgphoto2 links too, and two load commands for one @rpath name stop dyld
# at launch. The linker drops the copy no symbol binds to.
swift build -c release --arch arm64 ${SWIFT_BUILD_SYSTEM:-} -Xlinker "$ARM_GP" -Xlinker "$ARM_PORT" -Xlinker -dead_strip_dylibs
rm -rf "$ARM_APP"
COMPAT_STAGE="$ARM_STAGE" PATCHED_CAMLIBS_DIR=vendor/camlibs-compat/arm64 bash scripts/bundle.sh "$ARM_APP" "$APP_NAME" \
  ".build/arm64-apple-macosx/release/$APP_NAME" "$EXEC_NAME" >/dev/null
echo "    arm bundle: $(lipo -archs "$ARM_APP/Contents/MacOS/$EXEC_NAME")"

echo "==> 4/6  lipo-merge the two bundles into $BUNDLE"
rm -rf "$BUNDLE"
cp -R "$ARM_APP" "$BUNDLE"
# The copy carries the arm64 slice's library versions only. Add the x86_64
# slice's record, before the re-sign so the signature covers it.
cp "$X86_APP/Contents/Resources/Licenses/VERSIONS-x86_64.txt" "$BUNDLE/Contents/Resources/Licenses/"
# For every Mach-O in the bundle, fuse the x86 + arm slices. Both bundles share
# an identical layout and the same bundle-relative install names, so the fat file's
# load commands are consistent across arches.
while IFS= read -r armf; do
    rel="${armf#"$BUNDLE/"}"
    x86f="$X86_APP/$rel"
    # Fatal, not a warning: skipping leaves an arm-only file in a "universal"
    # app, which dies on Intel the same way a missing library does.
    [[ -f "$x86f" ]] || { echo "FATAL: missing x86 counterpart for $rel" >&2; exit 1; }
    # Through a temp file: Xcode 27's lipo refuses an output path that is one
    # of its inputs (open fails with EEXIST), where older lipo wrote in place.
    lipo -create "$armf" "$x86f" -output "$armf.fat" && mv -f "$armf.fat" "$armf"
done < <(find "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" \
              "$BUNDLE/Contents/Resources/camlibs" "$BUNDLE/Contents/Resources/iolibs" \
              -type f \( -name '*.dylib' -o -name '*.so' -o -name "$EXEC_NAME" \) 2>/dev/null)

# Stamp the number into the built bundle only, before signing so the
# signature covers it. The checked-in plist stays a placeholder.
if [[ -n "$BUILD_NUM" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$BUNDLE/Contents/Info.plist"
fi
# The update line: release, beta or none (FT_UPDATE_LINE, default none). After
# the number, which the dev version string carries.
bash scripts/updates-plist.sh "$BUNDLE/Contents/Info.plist" "${FT_UPDATE_LINE:-none}"

echo "==> 5/6  Re-sign universal bundle ($IDENTITY)"
# lipo invalidated the per-arch signatures. Re-sign every embedded library, then
# the bundle (with the hardened runtime when DEVELOPER_ID is set, which
# notarization requires).
find "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources/camlibs" \
     "$BUNDLE/Contents/Resources/iolibs" -type f \( -name '*.dylib' -o -name '*.so' \) 2>/dev/null \
  | while read -r f; do codesign --force --timestamp --sign "$IDENTITY" "$f" 2>/dev/null || \
                        codesign --force --sign "$IDENTITY" "$f"; done
# lipo did not touch the update framework (it ships universal), but the
# per-arch bundle signed it ad hoc: sign it again, inside out, before the app.
bash scripts/sign-framework.sh "$IDENTITY" "$BUNDLE" Sparkle.framework
RUNTIME_OPT=""; [[ "$IDENTITY" != "-" ]] && RUNTIME_OPT="--options runtime --timestamp"
codesign --force $RUNTIME_OPT --entitlements "Resources/$APP_NAME.entitlements" \
         --sign "$IDENTITY" "$BUNDLE"

# Notarize + staple so the downloaded app opens on another Mac without the
# unidentified-developer block. Runs when NOTARY_PROFILE (a notarytool keychain
# profile) is set and DEVELOPER_ID is set.
if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    echo "==> 6/6  Notarize + staple (submitting to Apple, usually ~1-3 min)"
    NZIP=".build/_uni/notarize.zip"
    ditto -c -k --keepParent "$BUNDLE" "$NZIP"
    xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" \
        ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} --wait
    xcrun stapler staple "$BUNDLE"
    rm -f "$NZIP"
fi

echo ""
echo "OK  →  $BUNDLE"
echo "    binary:     $(lipo -archs "$BUNDLE/Contents/MacOS/$EXEC_NAME")"
echo "    libgphoto2: $(lipo -archs "$BUNDLE/Contents/Frameworks/libgphoto2.6.dylib")"
echo "    codesign:   $(codesign --verify --strict "$BUNDLE" 2>&1 && echo valid || echo FAILED)"
echo "    notarized:  $(xcrun stapler validate "$BUNDLE" >/dev/null 2>&1 && echo 'stapled' || echo 'no ticket')"
echo "    gatekeeper: $(spctl -a -t exec -vv "$BUNDLE" 2>&1 | awk -F'=' '/source/{print $2; exit}')"
PTP2="$BUNDLE/Contents/Resources/camlibs/ptp2.so"
CAMLIB_BAD=0
for arch in x86_64 arm64; do
    thin="$(mktemp -t ptp2)"
    lipo -thin "$arch" "$PTP2" -output "$thin" 2>/dev/null || : > "$thin"
    marker="$(strings "$thin" | grep -c "no AvailableShots after" || true)"
    rm -f "$thin"
    echo "    ptp2.so $arch: bounded-wait marker $marker (want 1)"
    [[ "$marker" == "1" ]] || CAMLIB_BAD=1
done
[[ "$CAMLIB_BAD" == 0 ]] || { echo "FAIL: the merged ptp2.so lacks the patched camlib in a slice" >&2; exit 1; }
# One libgphoto2 load command per slice, or dyld refuses to launch the app.
for arch in x86_64 arm64; do
    gp="$(otool -arch "$arch" -L "$BUNDLE/Contents/MacOS/$EXEC_NAME" | grep -c "libgphoto2\.6\.dylib" || true)"
    echo "    libgphoto2 $arch: $gp load command(s) (want 1)"
    [[ "$gp" == "1" ]] || { echo "FAIL: the $arch slice links libgphoto2 more than once, and dyld will refuse to launch it" >&2; exit 1; }
done
# Per slice, the highest minos across the main binary and every vendored dylib:
# one host-sourced library (see bundle.sh copy_deps) raises the floor for the
# whole slice, and a floor read from the main binary alone would hide that.
for arch in x86_64 arm64; do
    floor=$(for f in "$BUNDLE/Contents/MacOS/$EXEC_NAME" "$BUNDLE/Contents/Frameworks/"*.dylib; do
                otool -arch "$arch" -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'
            done | sort -t. -k1,1n -k2,2n | tail -1)
    echo "    min macOS ($arch): ${floor:-?}"
done
