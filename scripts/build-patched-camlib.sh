#!/usr/bin/env bash
# Build a patched ptp2.so camlib matching the installed Homebrew libgphoto2.
#
# Every patches/*.diff is applied, in name order:
#
#   eos-capture-target-bounded-wait.diff  bounds the AvailableShots wait after
#       the capture destination switches to the PC. An EOS 7D sometimes never
#       reports shots there and stock libgphoto2 polls GetEvent forever, which
#       hangs the first config read of a session.
#   eos-imageformat-L-combos.diff  the Format decode fix below.
#
# The Format patch: libgphoto2 (2.5.34, and master as of 2026-07) mis-decodes Canon's EOS
# ImageFormat property on bodies that use the user/custom JPEG compression
# scheme (e.g. the EOS R5): the "RAW + L" and "cRAW + L" combos collapse into
# plain "RAW"/"cRAW", so they vanish from the Format menu and the current
# value reads back wrong. patches/eos-imageformat-L-combos.diff fixes the
# decode. This script downloads the matching libgphoto2 source, applies the
# patches, builds it with ptp2 as the only camlib, and installs that camlib at
#
#     vendor/camlibs/<libgphoto2-version>/ptp2.so
#
# scripts/bundle.sh prefers that file over the stock brew camlib when the
# versions match, in native builds only. build-universal.sh
# passes PATCHED_CAMLIBS_DIR with per-slice camlibs from
# build-patched-camlib-slice.sh, and `make dist-compat`, which passes
# neither, ships the stock camlib.
# If brew upgrades libgphoto2 to a new version, the vendored camlib no longer
# matches and is skipped, and the bundle's VERSIONS file records the camlib as
# unpatched. Re-run this script to rebuild it.
#
# The produced .so is relinked against brew's own libgphoto2 dylibs, so it is
# a drop-in replacement for the stock camlib everywhere brew's library runs.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
PATCHES=("$REPO"/patches/*.diff)
[[ -f "${PATCHES[0]}" ]] || { echo "FATAL: no patches/*.diff found" >&2; exit 1; }

LIBGPHOTO2_PREFIX="$(brew --prefix libgphoto2)"
VERSION="$(basename "$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2" -mindepth 1 -maxdepth 1 -type d | head -1)")"
[[ -n "$VERSION" ]] || { echo "FATAL: can't determine brew libgphoto2 version" >&2; exit 1; }

WORK="$REPO/.camlib-build"
SRC="$WORK/libgphoto2-$VERSION"
STAGE="$WORK/stage"
OUT="$REPO/vendor/camlibs/$VERSION"
TARBALL="$WORK/libgphoto2-$VERSION.tar.bz2"
URL="https://downloads.sourceforge.net/project/gphoto/libgphoto/$VERSION/libgphoto2-$VERSION.tar.bz2"

mkdir -p "$WORK"

if [[ ! -f "$TARBALL" ]]; then
    echo ">> Downloading libgphoto2 $VERSION source"
    curl -fsSL -o "$TARBALL" "$URL"
fi

# A listed version must match patches/libgphoto2-source.sha256. A version with
# no line there (a newer Homebrew libgphoto2) builds with a warning.
SUMS="$REPO/patches/libgphoto2-source.sha256"
WANT="$(awk -v f="libgphoto2-$VERSION.tar.bz2" '$2 == f {print $1}' "$SUMS" 2>/dev/null | head -1 || true)"
GOT="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [[ -z "$WANT" ]]; then
    echo "   warning: no checksum for libgphoto2-$VERSION.tar.bz2 in patches/libgphoto2-source.sha256, sha256 is $GOT" >&2
elif [[ "$GOT" != "$WANT" ]]; then
    echo "FATAL: libgphoto2-$VERSION.tar.bz2 has sha256 $GOT, expected $WANT" >&2
    rm -f "$TARBALL"
    exit 1
fi

echo ">> Extracting fresh source tree"
rm -rf "$SRC" "$STAGE"
tar xjf "$TARBALL" -C "$WORK"

for PATCH in "${PATCHES[@]}"; do
    echo ">> Applying $(basename "$PATCH")"
    (cd "$SRC" && patch -p1 < "$PATCH")
done

echo ">> Configuring (ptp2 camlib only)"
(cd "$SRC" && ./configure --prefix="$STAGE" --disable-silent-rules \
    --with-camlibs=ptp2 > "$WORK/configure.log" 2>&1) \
    || { tail -20 "$WORK/configure.log" >&2; exit 1; }

echo ">> Building"
make -C "$SRC" -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1 \
    || { tail -20 "$WORK/make.log" >&2; exit 1; }
make -C "$SRC" install > "$WORK/install.log" 2>&1 \
    || { tail -20 "$WORK/install.log" >&2; exit 1; }

SO="$STAGE/lib/libgphoto2/$VERSION/ptp2.so"
[[ -f "$SO" ]] || { echo "FATAL: build produced no $SO" >&2; exit 1; }

# The freshly-built camlib links the staging copies of libgphoto2/_port.
# Repoint those two deps at brew's dylibs so the camlib is a drop-in for the
# stock one (same version, same ABI). Everything else already resolves to brew.
echo ">> Relinking against brew's libgphoto2 dylibs"
otool -L "$SO" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    base="$(basename "$dep")"
    case "$base" in
        libgphoto2.*.dylib|libgphoto2_port.*.dylib)
            if [[ "$dep" != "$LIBGPHOTO2_PREFIX"/* ]]; then
                install_name_tool -change "$dep" "$LIBGPHOTO2_PREFIX/lib/$base" "$SO"
            fi
            ;;
    esac
done
# install_name_tool invalidated the signature, and arm64 requires a valid one.
codesign --force --sign - "$SO"

if otool -L "$SO" | tail -n +2 | awk '{print $1}' | grep -q "$WORK"; then
    echo "FATAL: ptp2.so still references the build staging dir:" >&2
    otool -L "$SO" | grep "$WORK" >&2
    exit 1
fi

mkdir -p "$OUT"
cp "$SO" "$OUT/ptp2.so"

echo ""
echo "OK  →  vendor/camlibs/$VERSION/ptp2.so"
echo "    make bundle / make run / make dist now vendor the patched camlib."
echo "    (Re-run this script after a brew upgrade of libgphoto2.)"
