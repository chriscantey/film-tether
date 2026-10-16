.PHONY: build bundle run run-debug clean tests check format help doctor dist dist-compat dist-universal debug debug-test patched-camlib release-sources

APP_NAME       := FilmTether
# The executable inside the bundle carries the space, the way Apple names its
# own (Activity Monitor.app/Contents/MacOS/Activity Monitor). The SwiftPM
# product stays FilmTether (product names cannot hold spaces), so APP_NAME
# still names the built binary, the entitlements file and the zips.
EXEC_NAME      := Film Tether
# Display-friendly bundle filename. macOS supports spaces in .app paths, and
# it matches CFBundleName and CFBundleDisplayName in Finder, the menu bar and the Dock.
DISPLAY_NAME   := Film Tether
BUNDLE         := $(DISPLAY_NAME).app
ARCH           := arm64
CONFIG         := release
BUILD_DIR      := .build/$(ARCH)-apple-macosx/$(CONFIG)
BINARY         := $(BUILD_DIR)/$(APP_NAME)
DEBUG_BIN      := $(BUILD_DIR)/FilmTetherDebug
# Extra flags for `swift build`, for example SWIFT_FLAGS="-Xswiftc -warnings-as-errors".
SWIFT_FLAGS    ?=
# The build system for every swift build and swift test, empty for the default.
# SwiftPM 6.4 defaults to Swift Build, whose output layout the scripts here do
# not read, so a Mac on 6.4 sets SWIFT_BUILD_SYSTEM="--build-system native" in
# its environment. The test step needs it as well as the build, or it looks
# for test bundles the build never wrote.
SWIFT_BUILD_SYSTEM ?=

# Brew env, exported so `swift build` and `pkg-config` find libgphoto2 on Apple Silicon
# even when run from contexts that don't source ~/.zshrc (Make, GUI launchers).
BREW_PREFIX   := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
export PKG_CONFIG_PATH := $(BREW_PREFIX)/lib/pkgconfig:$(PKG_CONFIG_PATH)
export PATH := $(BREW_PREFIX)/bin:$(PATH)

# Repo-local patched ptp2 camlib (built by `make patched-camlib` with every
# patch in patches/ applied), used only when it matches the
# installed brew libgphoto2 version. bundle.sh does its own equivalent check,
# and this one routes the headless debug CLI through the same patched camlib.
GP_VERSION      := $(shell basename "$$(find "$$(brew --prefix libgphoto2 2>/dev/null)/lib/libgphoto2" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)" 2>/dev/null)
PATCHED_CAMLIBS := $(if $(wildcard vendor/camlibs/$(GP_VERSION)/ptp2.so),$(CURDIR)/vendor/camlibs/$(GP_VERSION))

help:
	@echo "Film Tether build"
	@echo ""
	@echo "  make build    Compile via SwiftPM (release, arm64)"
	@echo "  make tests    Run the unit tests (CameraTests and ScanTests)"
	@echo "  make bundle   Build + assemble $(BUNDLE) with libgphoto2 vendored"
	@echo "  make run      Build + bundle + open the .app"
	@echo "  make run-debug  Same as run, launched with EOS_DEBUG=1"
	@echo "  make dist     Build + bundle + zip to run on another Mac (no brew needed there)"
	@echo "  make debug-test  Run the headless test suite against a connected camera"
	@echo "  make debug CMD=\"…\"  Run a single CLI subcommand (snapshot, capture, meter, …)"
	@echo "  make patched-camlib  Build ptp2.so with every patch in patches/ (7D connect wait, R5 RAW + L)"
	@echo "  make dist-compat [TAG=arm64_sonoma]  Zip a bundle for an older macOS (stock camlib)"
	@echo "  make dist-universal  Universal (arm64 + x86_64) release bundle and zip, macOS 14+ (needs an Intel Mac)"
	@echo "  make release-sources  Download and checksum the bundled libraries' source archives"
	@echo "  make clean    Remove .build/ and $(BUNDLE)"
	@echo "  make check    Static checks (swift package describe + plist lint)"
	@echo "  make format   Format Sources and Tests with swift-format, if installed"
	@echo "  make doctor   Print brew, pkg-config, Swift and camlib diagnostics"
	@echo ""
	@echo "Env:"
	@echo "  DEVELOPER_ID    Optional Developer ID Application string for codesign"
	@echo "  NOTARY_PROFILE  Optional notarytool keychain profile (dist-universal)"
	@echo "  BUILD_NUMBER    Optional build number for the dist-universal bundle (default 0)"
	@echo "  SWIFT_FLAGS     Optional extra flags for swift build"
	@echo "  SIGN_KEYCHAIN   Optional signing keychain for dist-universal, unlocked with SIGN_KEYCHAIN_PW"
	@echo "  SIGN_KEYCHAIN_PW  Its password. Set it in the environment, not on the make command line"
	@echo ""

build:
	@swift build -c $(CONFIG) --arch $(ARCH) $(SWIFT_BUILD_SYSTEM) $(SWIFT_FLAGS)

# Release, with testing enabled. The scan tests run minutes in a debug build
# and seconds in release (290 s against 1.6 s, measured when there were 162 of
# them), because the region sweep runs about thirty detections per planner
# call and debug bounds-checking pays for every index.
tests:
	@swift build -c release --build-tests -Xswiftc -enable-testing --arch $(ARCH) $(SWIFT_BUILD_SYSTEM) $(SWIFT_FLAGS)
	@swift test -c release --skip-build --arch $(ARCH) $(SWIFT_BUILD_SYSTEM)
	@bash Tests/scripts/updates-plist-test.sh

# Run the headless test suite against a connected camera. It refuses to run
# while the GUI app is running (the USB can only be claimed by one process at
# a time).
# Output is PASS/FAIL per check with evidence.
debug-test: build
	@if pgrep -x "$(EXEC_NAME)" >/dev/null 2>&1; then \
		echo "Film Tether GUI is running. Quit it first (USB is single-claim)."; \
		exit 1; \
	fi
	@$(if $(PATCHED_CAMLIBS),CAMLIBS="$(PATCHED_CAMLIBS)") $(DEBUG_BIN) test

# Run a single CLI subcommand without launching the GUI. Examples:
#   make debug CMD="snapshot"
#   make debug CMD="meter 10"
#   make debug CMD="sync-clock"
debug: build
	@if pgrep -x "$(EXEC_NAME)" >/dev/null 2>&1; then \
		echo "Film Tether GUI is running. Quit it first (USB is single-claim)."; \
		exit 1; \
	fi
	@$(if $(PATCHED_CAMLIBS),CAMLIBS="$(PATCHED_CAMLIBS)") $(DEBUG_BIN) $(CMD)

bundle: build
	@bash scripts/bundle.sh "$(BUNDLE)" "$(APP_NAME)" "$(BINARY)" "$(EXEC_NAME)"

run: bundle
	@open "$(BUNDLE)"

# Launch with EOS_DEBUG=1, which hooks libgphoto2's internal log into the
# app's. Homebrew builds libgphoto2 with that log compiled out, so nothing
# arrives from it. The app's own debug lines are kept with or without
# EOS_DEBUG. Stream the app's lines from another terminal with:
#   log stream --predicate 'subsystem == "co.wonders.filmtether"' --info --debug
run-debug: bundle
	@pkill -x "$(EXEC_NAME)" 2>/dev/null || true
	@sleep 0.5
	@EOS_DEBUG=1 open --env EOS_DEBUG=1 "$(BUNDLE)"
	@echo ""
	@echo "Stream the app's logs (run in another terminal):"
	@echo "  log stream --predicate 'subsystem == \"co.wonders.filmtether\"' --info --debug"

# Build the patched ptp2 camlib with every patch in patches/ applied:
#   eos-capture-target-bounded-wait.diff  bounds the AvailableShots wait that
#       can hang an EOS 7D's first config read of a session.
#   eos-imageformat-L-combos.diff  restores "RAW + L" and "cRAW + L" to the
#       Format menu on the EOS R5 (a libgphoto2 decode bug).
# Output lands in vendor/camlibs/ and is picked up automatically by
# bundle/run/dist and the debug targets. dist-compat does not use it.
# Re-run after a `brew upgrade libgphoto2`.
patched-camlib:
	@bash scripts/build-patched-camlib.sh

clean:
	@rm -rf .build "$(BUNDLE)"

check:
	@swift package describe > /dev/null
	@plutil -lint Resources/Info.plist
	@plutil -lint Resources/$(APP_NAME).entitlements
	@echo "OK"

format:
	@swift-format -i -r Sources Tests || echo "(swift-format not installed, skipping)"

dist: bundle
	@echo ">> Zipping $(BUNDLE) for distribution..."
	@rm -f "$(APP_NAME).zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME).zip"
	@SIZE=$$(du -h "$(APP_NAME).zip" | cut -f1); \
	echo ""; echo "OK  →  $(APP_NAME).zip ($$SIZE)"; \
	echo ""; echo "  To run it on another Mac (no brew needed there, same macOS as this one or newer):"; \
	echo "    1. Copy $(APP_NAME).zip to that Mac"; \
	echo "    2. Unzip it, then clear the quarantine flag once:"; \
	echo "         xattr -dr com.apple.quarantine \"/path/to/$(BUNDLE)\""; \
	echo "       (right-click → Open sometimes works, but xattr is reliable)"; \
	echo "    3. Plug in a Canon EOS camera with PTP enabled and shoot"

# Build a bundle that runs on an older macOS than this host. Pulls the
# Homebrew bottles for an older OS tag (default macOS 14 / Sonoma on Apple
# Silicon), vendors those instead of your native ones, and zips separately.
# Same packages as your normal build, compiled for the older OS, with one
# difference: the camlib is the stock ptp2.so from the bottle, without the
# patches in patches/ (no bounded AvailableShots wait, no R5 "RAW + L" fix).
# dist-universal builds patched camlibs for its slices.
#   make dist-compat                    # arm64_sonoma (macOS 14)
#   make dist-compat TAG=arm64_sequoia  # macOS 15
TAG ?= arm64_sonoma
dist-compat:
	@bash scripts/fetch-compat-libs.sh "$(TAG)" ".compat-libs/$(TAG)"
	@swift build -c $(CONFIG) --arch $(ARCH) $(SWIFT_BUILD_SYSTEM) $(SWIFT_FLAGS)
	@COMPAT_STAGE=".compat-libs/$(TAG)" bash scripts/bundle.sh "$(BUNDLE)" "$(APP_NAME)" "$(BINARY)" "$(EXEC_NAME)"
	@rm -f "$(APP_NAME)-$(TAG).zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME)-$(TAG).zip"
	@SIZE=$$(du -h "$(APP_NAME)-$(TAG).zip" | cut -f1); \
	echo ""; echo "OK  →  $(APP_NAME)-$(TAG).zip ($$SIZE), runs on $(TAG) and newer"; \
	echo "       Use this one on a Mac with the older macOS, and clear quarantine as above."

# Build one universal (arm64 + x86_64) bundle targeting macOS Sonoma (14)+.
# This is the release build, and it needs an Intel Mac: the x86_64 slice links
# the libgphoto2 in the host's Homebrew, which on Apple Silicon is arm64. It
# fetches both-arch Homebrew bottles, builds each slice and lipo-merges them,
# and the result runs native on Intel and Apple Silicon. Set DEVELOPER_ID=...
# to sign for real.
#   make dist-universal
#   make dist-universal DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#   make dist-universal DEVELOPER_ID="..." NOTARY_PROFILE=<profile>
# With NOTARY_PROFILE as well, the bundle is notarized and stapled.
#   make dist-universal BUILD_NUMBER=7   # stamps 7 as the bundle's build number
# Without BUILD_NUMBER the bundle keeps the 0 the source Info.plist carries.
# SIGN_KEYCHAIN and SIGN_KEYCHAIN_PW name an optional signing keychain and its
# password. Set them in the environment. The export below hands them to the
# script without writing them into the recipe's command line.
export SIGN_KEYCHAIN SIGN_KEYCHAIN_PW
dist-universal:
	@DEVELOPER_ID="$(DEVELOPER_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" \
	 BUILD_NUMBER="$(BUILD_NUMBER)" bash scripts/build-universal.sh "$(BUNDLE)"
	@# The version comes from the built bundle, so the zip's name always
	@# matches the version inside it.
	@VER=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(BUNDLE)/Contents/Info.plist"); \
	ZIP="$(APP_NAME)-$$VER-universal.zip"; \
	rm -f "$$ZIP"; \
	ditto -c -k --keepParent "$(BUNDLE)" "$$ZIP"; \
	echo ""; echo "OK  →  $$ZIP ($$(du -h "$$ZIP" | cut -f1)), universal, macOS 14+"; \
	echo "    stapled:    $$(xcrun stapler validate "$(BUNDLE)" >/dev/null 2>&1 && echo 'yes' || echo 'NO: not notarized, so other Macs will warn')"

# Download the upstream source archives of the libraries the release carries
# into release-sources/<version>/ and check each SHA-256 against the table in
# scripts/release-sources.sh, which must match THIRD-PARTY-NOTICES.md.
# `scripts/release-sources.sh upload <tag>` prints the command that attaches
# them, with patches/*.diff, to a GitHub release.
release-sources:
	@bash scripts/release-sources.sh fetch

doctor:
	@echo "=== brew prefix ==="
	@brew --prefix
	@echo
	@echo "=== brew --prefix libgphoto2 ==="
	@brew --prefix libgphoto2 2>/dev/null || echo "NOT INSTALLED. Run: brew install libgphoto2 pkg-config"
	@echo
	@echo "=== pkg-config --cflags libgphoto2 ==="
	@pkg-config --cflags libgphoto2 || echo "pkg-config can't find libgphoto2. Check PKG_CONFIG_PATH."
	@echo
	@echo "=== pkg-config --libs libgphoto2 ==="
	@pkg-config --libs libgphoto2
	@echo
	@echo "=== swift toolchain ==="
	@swift --version | head -2
	@echo
	@echo "=== xcode-select ==="
	@xcode-select -p
	@echo
	@echo "=== libgphoto2 camlibs ==="
	@ls "$$(brew --prefix libgphoto2)/lib/libgphoto2/" 2>/dev/null || echo "(none found)"
	@echo
	@echo "=== ptpcamerad status ==="
	@launchctl print system/com.apple.imagecapture.ptpcamerad 2>&1 | head -3 | grep -E "state =|state-status" || echo "(ptpcamerad is not registered)"
