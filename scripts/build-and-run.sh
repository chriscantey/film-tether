#!/usr/bin/env bash
# Film Tether: one-shot build + bundle + launch.
#
# Usage:
#   Apple Silicon: `bash scripts/build-and-run.sh`
#   Intel Mac:     `ARCH=x86_64 bash scripts/build-and-run.sh`
#
# What it does:
#   1. Sanity-check the environment (brew, libgphoto2, Xcode CLT)
#   2. With WITH_PULL=1, git pull --ff-only first
#   3. Quit any running Film Tether
#   4. Build via SwiftPM (release config, configurable ARCH)
#   5. Bundle into "Film Tether.app" with libgphoto2 vendored
#   6. Launch the .app
#
# Env vars:
#   ARCH         arm64 (default) or x86_64
#   DEVELOPER_ID optional codesign identity (default: ad-hoc "-")
#   WITH_PULL=1  run `git pull --ff-only` before building
#   NO_LAUNCH=1  build + bundle only, don't open
#   WITH_DEBUG=1 also build the FilmTetherDebug headless CLI binary and launch
#                the GUI with EOS_DEBUG=1.

set -euo pipefail

ARCH="${ARCH:-arm64}"
APP_NAME="FilmTether"
# The executable inside the bundle carries the space, matching
# CFBundleExecutable in Resources/Info.plist.
EXEC_NAME="Film Tether"
DISPLAY_NAME="Film Tether"
BUNDLE="${DISPLAY_NAME}.app"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Film Tether build-and-run"
echo "    repo:   $REPO_ROOT"
echo "    arch:   $ARCH"
echo "    bundle: $BUNDLE"

if ! command -v brew >/dev/null 2>&1; then
    echo "FATAL: Homebrew not found. Install from https://brew.sh first."
    exit 1
fi

if ! brew list libgphoto2 >/dev/null 2>&1; then
    echo "==> libgphoto2 not installed via brew, installing it now (this is one-time)"
    brew install libgphoto2 pkg-config
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "FATAL: swift compiler not found. Install Xcode Command Line Tools:"
    echo "       xcode-select --install"
    exit 1
fi

# Make sure the brew prefix's pkg-config is on PATH so SwiftPM finds libgphoto2.
BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

if [[ "${WITH_PULL:-0}" == "1" ]] && [[ -e .git ]]; then
    echo "==> git pull"
    git pull --ff-only || echo "    (pull failed, continuing with local tree)"
fi

pkill -x "$EXEC_NAME" 2>/dev/null || true
sleep 0.3

# Builds only the GUI product unless WITH_DEBUG=1, which builds every product,
# FilmTetherDebug included. bundle.sh copies only the binary passed to it, so
# the .app holds the GUI binary either way.
if [[ "${WITH_DEBUG:-0}" == "1" ]]; then
    echo "==> swift build (arch=$ARCH, config=release, WITH_DEBUG=1, builds GUI + FilmTetherDebug CLI)"
    swift build --arch "$ARCH" -c release
else
    echo "==> swift build (arch=$ARCH, config=release, product=FilmTether, GUI only)"
    swift build --arch "$ARCH" -c release --product FilmTether
fi

BUILD_DIR=".build/${ARCH}-apple-macosx/release"
BINARY="${BUILD_DIR}/${APP_NAME}"

if [[ ! -x "$BINARY" ]]; then
    echo "FATAL: build succeeded but binary missing at $BINARY"
    exit 1
fi

echo "==> bundling into $BUNDLE"
rm -rf "$BUNDLE"
bash scripts/bundle.sh "$BUNDLE" "$APP_NAME" "$BINARY" "$EXEC_NAME"

if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    echo "==> NO_LAUNCH=1, skipping open. Bundle ready at: $BUNDLE"
    exit 0
fi

echo "==> open '$BUNDLE'"
if [[ "${WITH_DEBUG:-0}" == "1" ]]; then
    echo "    WITH_DEBUG=1, launching with EOS_DEBUG=1"
    EOS_DEBUG=1 open --env EOS_DEBUG=1 "$BUNDLE"
    echo "    Stream the logs from another terminal with:"
    echo "    log stream --predicate 'subsystem == \"co.wonders.filmtether\"' --info --debug"
else
    open "$BUNDLE"
fi

sleep 1
if pgrep -lf "$BUNDLE" >/dev/null; then
    echo "==> running."
    pgrep -lf "$BUNDLE" | head -3
else
    echo "WARN: launched but no process found. Check Console.app for crash logs."
fi
