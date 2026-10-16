#!/usr/bin/env bash
# Fetch + extract older-macOS Homebrew bottles for libgphoto2 and the runtime
# dependencies the bundle vendors into a staging directory, so scripts/bundle.sh (COMPAT_STAGE=...)
# can vendor dylibs that target an older macOS than the build host.
#
# `brew install` only gives you the bottle for the macOS you are running. Bottling is
# done per-OS with that OS's deployment target, so a Tahoe (26) host produces
# dylibs with minos 26, which won't load on a macOS 14/15 machine.
# `brew fetch --bottle-tag=<older>` downloads an older bottle without installing,
# for a tag brew knows on this host (see below for the others).
#
# Usage:
#   scripts/fetch-compat-libs.sh <bottle-tag> [stage-dir]
#   e.g. scripts/fetch-compat-libs.sh arm64_sonoma      # macOS 14, Apple Silicon
#        scripts/fetch-compat-libs.sh arm64_sequoia     # macOS 15, Apple Silicon
#        scripts/fetch-compat-libs.sh sonoma            # macOS 14, Intel
#
# Available tags: brew info --json=v2 libgphoto2 | jq '.formulae[0].bottle.stable.files|keys'
set -euo pipefail

TAG="${1:?usage: fetch-compat-libs.sh <bottle-tag> [stage-dir]}"
STAGE="${2:-.compat-libs/$TAG}"

# Only the runtime formulae the bundle uses, not `brew fetch --deps`,
# which pulls in the entire tree including build tools (cmake, ninja, python, nasm,
# autoconf…) and the codec pile (gd, avif, aom…) we don't bundle. For ptp2 + usb1
# the complete runtime set is these 6 formulae → the 7 dylibs we vendor:
#   libgphoto2  → libgphoto2.6, libgphoto2_port.12, ptp2.so, usb1.so
#   libexif     → libexif.12
#   libtool     → libltdl.7
#   gettext     → libintl.8
#   jpeg-turbo  → libjpeg.8
#   libusb      → libusb-1.0.0
# Override with COMPAT_FORMULAE="…" if you widen CAMLIBS/IOLIBS in bundle.sh.
COMPAT_FORMULAE="${COMPAT_FORMULAE:-libgphoto2 libexif libtool gettext jpeg-turbo libusb}"

echo ">> Fetching '$TAG' bottles (no install): $COMPAT_FORMULAE"
brew fetch --force --bottle-tag="$TAG" $COMPAT_FORMULAE || echo ">> brew fetch could not see every $TAG bottle. The fallback below tries GHCR for the rest."

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo ">> Extracting bottles into $STAGE"
# Each extracts as <formula>/<version>/{lib,…}. Install names use @@HOMEBREW_*@@
# placeholders that bundle.sh rewrites to @rpath / @loader_path.
COUNT=0
# Homebrew's per-host API JSON carries only THIS host's bottle tag, so
# `brew fetch --bottle-tag=<other>` reports the bottle "unavailable" even when it
# exists (on an Intel Tahoe host, every arm64_sonoma bottle reads "unavailable"
# while formulae.brew.sh lists all of them). The bottles sit on GHCR, so fall
# back to the public API, or a pin in compat-pins.txt, and pull the
# blob directly, checking its sha256, and keep it beside the stage so a re-run
# does not download it again.
BOTTLES="$STAGE.bottles"
mkdir -p "$BOTTLES"
PINS="$(dirname "$0")/compat-pins.txt"
fetch_from_api() {  # formula -> path of a verified bottle tarball, or empty
    local formula="$1" json url sha out
    json="$(curl -fsS --max-time 60 "https://formulae.brew.sh/api/formula/$formula.json" 2>/dev/null || true)"
    url="$(jq -r ".bottle.stable.files[\"$TAG\"].url // empty" <<< "$json")"
    sha="$(jq -r ".bottle.stable.files[\"$TAG\"].sha256 // empty" <<< "$json")"
    if [[ -z "$url" || -z "$sha" ]] && [[ -f "$PINS" ]]; then
        # The API no longer lists this tag. A pin names the last blob Homebrew
        # published for it (see compat-pins.txt), still on GHCR.
        sha="$(awk -v f="$formula" -v t="$TAG" '$1==f && $2==t {print $3}' "$PINS" | head -1)"
        [[ -n "$sha" ]] && url="https://ghcr.io/v2/homebrew/core/$formula/blobs/sha256:$sha" \
            && echo "   $formula ($TAG): using pinned bottle $sha" >&2
    fi
    [[ -n "$url" && -n "$sha" ]] || return 0
    out="$BOTTLES/$formula.$TAG.$sha.tar.gz"
    if [[ ! -f "$out" ]]; then
        echo "   fetching $formula ($TAG) from GHCR, brew has no $TAG metadata on this host" >&2
        # QQ== is GHCR's anonymous pull token (base64 of "A"), the same one
        # Homebrew sends for public bottles. It is not a credential.
        curl -fsSL --max-time 600 -H "Authorization: Bearer QQ==" -o "$out.part" "$url" || { rm -f "$out.part"; return 0; }
        mv "$out.part" "$out"
    fi
    [[ "$(shasum -a 256 "$out" | cut -d' ' -f1)" == "$sha" ]] || { echo "   sha256 MISMATCH for $formula ($TAG), refusing it" >&2; rm -f "$out"; return 0; }
    echo "$out"
}

for formula in $COMPAT_FORMULAE; do
    CACHE="$(brew --cache --bottle-tag="$TAG" "$formula" 2>/dev/null || true)"
    # When brew has no bottle for the tag it answers with the source tarball's
    # cache path (jpeg-turbo--3.2.0.tar.gz, no ".bottle."), which extracts to
    # source files and zero dylibs. Only a real bottle counts.
    if [[ -z "$CACHE" || ! -f "$CACHE" || "$CACHE" != *.bottle.* ]]; then
        CACHE="$(fetch_from_api "$formula")"
    fi
    if [[ -z "$CACHE" || ! -f "$CACHE" ]]; then
        echo "   (no $TAG bottle for $formula, skipping)"
        continue
    fi
    tar xzf "$CACHE" -C "$STAGE"
    COUNT=$((COUNT + 1))
done

DYLIBS="$(find "$STAGE" -name '*.dylib' | wc -l | tr -d ' ')"
echo ">> Staged $COUNT formulae ($DYLIBS dylibs) in $STAGE"
echo ""
echo "   Now bundle with:  COMPAT_STAGE=\"$STAGE\" make bundle"
echo "   or:               make dist-compat TAG=$TAG"
