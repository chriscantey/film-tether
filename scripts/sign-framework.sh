#!/usr/bin/env bash
# Sign a framework inside a bundle, inside out, so the bundle can be signed
# after it. Written for Sparkle (the shared update standard, _AppUpdates 2b),
# where the framework carries its own XPC services, a helper tool and a helper
# app, each of which must be signed on its own before the framework and the
# app that holds it. Under the hardened runtime and library validation an
# unsigned or foreign-signed piece inside the framework stops the app at
# launch, and notarization refuses it.
#
#   tools/sign-framework.sh <identity> <App.app> <Name.framework> [codesign args...]
#
# With a Developer ID identity every piece gets the hardened runtime and a
# secure timestamp. With "-" (ad hoc, a dev bundle) neither applies. Any
# arguments after the third go to every codesign call, such as
# --keychain <file> when the identity lives in a keychain of its own.
#
# The order and flags are Sparkle's own (sparkle-project.org/documentation/
# sandboxing, "Code Signing"): the XPC services with
# --preserve-metadata=entitlements so Downloader.xpc keeps what Sparkle ships
# it with, then Autoupdate and Updater.app plain, then the framework. Never
# --deep, which would put one piece's entitlements on the others. The app is
# signed after this, by the caller, also without --deep.
#
# This is the shared copy, proven end to end on the Home Video pilot. Each app
# vendors it unchanged; a public-image scan rejects a path it does not ship, so
# this comment names no app's own tree.
set -euo pipefail
IDENTITY="${1:?identity}"; APP="${2:?App.app}"; NAME="${3:?Name.framework}"
shift 3
FW="$APP/Contents/Frameworks/$NAME"
[[ -d "$FW" ]] || { echo "FATAL: $FW is not in the bundle" >&2; exit 1; }

OPTS=("$@")
[[ "$IDENTITY" != "-" ]] && OPTS+=(--options runtime --timestamp)

sign() {  # sign <path> [extra codesign args]
    local f="$1"; shift
    local attempt
    echo "    sign ${f#"$APP"/}"
    for attempt in 1 2 3; do
        codesign --force --sign "$IDENTITY" "${OPTS[@]+"${OPTS[@]}"}" "$@" "$f" 2>/dev/null && return 0
        sleep 0.5
    done
    codesign --force --sign "$IDENTITY" "${OPTS[@]+"${OPTS[@]}"}" "$@" "$f"
}

# The current version's contents, deepest first.
V="$FW/Versions/$(readlink "$FW/Versions/Current" 2>/dev/null || echo A)"
[[ -d "$V" ]] || V="$(ls -d "$FW"/Versions/*/ | head -1)"; V="${V%/}"
for xpc in "$V"/XPCServices/*.xpc; do
    [[ -d "$xpc" ]] || continue
    sign "$xpc" --preserve-metadata=entitlements
done
for helper in "$V"/Autoupdate "$V"/*.app; do
    [[ -e "$helper" ]] || continue
    sign "$helper"
done
sign "$FW"

# The executable must reach the framework through its rpath, or dyld dies at
# launch after a signature that looks fine. grep -c reads all of otool's
# output, so pipefail never sees a broken pipe from an early grep -q exit.
EXEC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
RPATHS=$(otool -l "$EXEC" | grep -c 'path @executable_path/../Frameworks ' || true)
if [[ "$RPATHS" == 0 ]]; then
    echo "FATAL: $(basename "$EXEC") has no @executable_path/../Frameworks rpath" >&2; exit 1
fi
codesign --verify --strict "$FW" >/dev/null
echo "    $NAME: signed inside out ($IDENTITY)"
