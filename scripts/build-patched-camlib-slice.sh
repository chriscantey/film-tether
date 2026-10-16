#!/usr/bin/env bash
# Build the patched ptp2 camlib for one slice of a compat (Sonoma bottle)
# bundle: the arch comes from the first argument and the libgphoto2 version
# from the stage, so the
# camlib matches the libgphoto2 the bundle vendors, which can differ from the
# version of the host's brew.
#
#   scripts/build-patched-camlib-slice.sh <x86_64|arm64> <compat-stage> <out-dir>
#
# Output: <out-dir>/<version>/ptp2.so, a Mach-O bundle for that arch with
# minos 14.0, every patches/*.diff applied in name order, and its dependency
# install names set to the same placeholders the stock bottle camlib carries
# (@@HOMEBREW_CELLAR@@/libgphoto2/<v>/lib/..., @@HOMEBREW_PREFIX@@/opt/<f>/lib/...),
# so scripts/bundle.sh vendors and rewrites it exactly like the stock one.
#
# The native patched camlib (build-patched-camlib.sh) is built against
# the host's brew, so it cannot go into a compat slice. The bounded
# AvailableShots wait fixes the first config read stall and has to be in
# both slices.
#
# arm64 on an Intel host is a cross build: clang -arch arm64 against the
# stage's arm64 bottles for every dependency, with configure told the host.
set -euo pipefail

ARCH="${1:?usage: build-patched-camlib-slice.sh <x86_64|arm64> <compat-stage> <out-dir>}"
STAGE="${2:?compat stage}"
OUT="${3:?out dir}"
cd "$(dirname "$0")/.."
REPO="$PWD"
case "$STAGE" in /*) ;; *) STAGE="$REPO/$STAGE" ;; esac
case "$OUT" in /*) ;; *) OUT="$REPO/$OUT" ;; esac

PATCHES=("$REPO"/patches/*.diff)
[[ -f "${PATCHES[0]}" ]] || { echo "FATAL: no patches/*.diff found" >&2; exit 1; }

formula_dir() { find "$STAGE/$1" -mindepth 1 -maxdepth 1 -type d | head -1; }
GP="$(formula_dir libgphoto2)"
[[ -d "$GP/lib" ]] || { echo "FATAL: $STAGE has no extracted libgphoto2 bottle" >&2; exit 1; }
VERSION="$(basename "$GP")"
EXIF="$(formula_dir libexif)"; LTDL="$(formula_dir libtool)"; INTL="$(formula_dir gettext)"
JPEG="$(formula_dir jpeg-turbo)"
for d in "$EXIF" "$LTDL" "$INTL" "$JPEG"; do
    [[ -d "$d/lib" && -d "$d/include" ]] || { echo "FATAL: stage dependency missing: $d" >&2; exit 1; }
done

WORK="$REPO/.camlib-build"
SRC="$WORK/$ARCH/libgphoto2-$VERSION"
TARBALL="$WORK/libgphoto2-$VERSION.tar.bz2"
URL="https://downloads.sourceforge.net/project/gphoto/libgphoto/$VERSION/libgphoto2-$VERSION.tar.bz2"
mkdir -p "$WORK/$ARCH"
if [[ ! -f "$TARBALL" ]]; then
    echo ">> Downloading libgphoto2 $VERSION source"
    curl -fsSL -o "$TARBALL" "$URL"
fi
# The archive must match patches/libgphoto2-source.sha256, so the release
# compiles exactly the source THIRD-PARTY-NOTICES.md names. A version with no
# line there stops the build until its checksum is added.
SUMS="$REPO/patches/libgphoto2-source.sha256"
WANT="$(awk -v f="libgphoto2-$VERSION.tar.bz2" '$2 == f {print $1}' "$SUMS" 2>/dev/null | head -1 || true)"
[[ -n "$WANT" ]] || { echo "FATAL: no checksum for libgphoto2-$VERSION.tar.bz2 in patches/libgphoto2-source.sha256" >&2; exit 1; }
GOT="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
[[ "$GOT" == "$WANT" ]] || { echo "FATAL: libgphoto2-$VERSION.tar.bz2 has sha256 $GOT, expected $WANT" >&2; rm -f "$TARBALL"; exit 1; }
rm -rf "$SRC"
tar xjf "$TARBALL" -C "$WORK/$ARCH"
for P in "${PATCHES[@]}"; do
    echo ">> [$ARCH] applying $(basename "$P")"
    (cd "$SRC" && patch -p1 -s < "$P")
done

HOST_TRIPLE="$([[ "$ARCH" == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)"
BUILD_TRIPLE="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
MIN="-mmacosx-version-min=14.0"
CPP="-I$EXIF/include -I$LTDL/include -I$INTL/include -I$JPEG/include"
LDF="-arch $ARCH $MIN -L$EXIF/lib -L$LTDL/lib -L$INTL/lib -L$JPEG/lib"

echo ">> [$ARCH] configuring libgphoto2 $VERSION for $HOST_TRIPLE (ptp2 only)"
# pkg-config is pointed at nothing, so no host library, which carries the
# host's min macOS, can leak in. Every dependency is named explicitly from
# the stage.
(cd "$SRC" && env PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH= \
    CC="clang -arch $ARCH" CFLAGS="-O2 $MIN" CPPFLAGS="$CPP" LDFLAGS="$LDF" \
    LIBEXIF_CFLAGS="-I$EXIF/include" LIBEXIF_LIBS="-L$EXIF/lib -lexif" \
    LTDLINCL="-I$LTDL/include" LIBLTDL="-L$LTDL/lib -lltdl" \
    LIBJPEG_CFLAGS="-I$JPEG/include" LIBJPEG_LIBS="-L$JPEG/lib -ljpeg" \
    ./configure --host="$HOST_TRIPLE" --build="$BUILD_TRIPLE" --prefix="$WORK/$ARCH/stage" \
    --disable-silent-rules --with-camlibs=ptp2 --with-libintl-prefix="$INTL" \
    --with-libcurl=no --with-gdlib=no > "$WORK/$ARCH/configure.log" 2>&1) \
    || { tail -30 "$WORK/$ARCH/configure.log" >&2; exit 1; }

echo ">> [$ARCH] building the port library, libgphoto2 and the ptp2 camlib"
# Only what ptp2.so links against. The iolibs are not needed here and would
# want an arm64 libusb.
J="$(sysctl -n hw.ncpu)"
{ make -C "$SRC/libgphoto2_port/libgphoto2_port" -j"$J" \
  && make -C "$SRC/libgphoto2" -j"$J" \
  && make -C "$SRC/camlibs" -j"$J"; } > "$WORK/$ARCH/make.log" 2>&1 \
    || { tail -40 "$WORK/$ARCH/make.log" >&2; exit 1; }

SO="$(find "$SRC/camlibs" -path '*/.libs/ptp2.so' | head -1)"
[[ -f "$SO" ]] || { echo "FATAL: [$ARCH] build produced no ptp2.so" >&2; exit 1; }
mkdir -p "$OUT/$VERSION"
DEST="$OUT/$VERSION/ptp2.so"
cp "$SO" "$DEST"

# Match the stock bottle camlib's install names, so bundle.sh treats it the same.
echo ">> [$ARCH] rewriting install names to the bottle placeholders"
otool -L "$DEST" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    b="$(basename "$dep")"
    case "$b" in
        libgphoto2.6.dylib|libgphoto2_port.12.dylib) new="@@HOMEBREW_CELLAR@@/libgphoto2/$VERSION/lib/$b" ;;
        libexif.*.dylib) new="@@HOMEBREW_PREFIX@@/opt/libexif/lib/$b" ;;
        libltdl.*.dylib) new="@@HOMEBREW_PREFIX@@/opt/libtool/lib/$b" ;;
        libintl.*.dylib) new="@@HOMEBREW_PREFIX@@/opt/gettext/lib/$b" ;;
        libjpeg.*.dylib) new="@@HOMEBREW_PREFIX@@/opt/jpeg-turbo/lib/$b" ;;
        *) continue ;;
    esac
    [[ "$dep" == "$new" ]] || install_name_tool -change "$dep" "$new" "$DEST"
done
codesign --force --sign - "$DEST"

GOT_ARCH="$(lipo -archs "$DEST")"
MINOS="$(otool -l "$DEST" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
MARK="$(strings "$DEST" | grep -c "no AvailableShots after" || true)"
LEAK="$(otool -L "$DEST" | tail -n +2 | awk '{print $1}' | grep -cE "^$WORK|^/usr/local|^/opt/homebrew" || true)"
echo "   $DEST: arch $GOT_ARCH, minos $MINOS, bounded-wait marker $MARK, host-path deps $LEAK"
[[ "$GOT_ARCH" == "$ARCH" ]] || { echo "FATAL: [$ARCH] built $GOT_ARCH" >&2; exit 1; }
[[ "$MINOS" == "14.0" ]] || { echo "FATAL: [$ARCH] minos $MINOS, want 14.0" >&2; exit 1; }
[[ "$MARK" == "1" ]] || { echo "FATAL: [$ARCH] bounded-wait patch missing" >&2; exit 1; }
[[ "$LEAK" == "0" ]] || { echo "FATAL: [$ARCH] a dependency points at the build or host brew" >&2; otool -L "$DEST" >&2; exit 1; }
echo "OK  →  $DEST"
