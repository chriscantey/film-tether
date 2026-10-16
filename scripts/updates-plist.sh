#!/usr/bin/env bash
# Write the update keys and the version string into a bundle's Info.plist for
# one line, per the shared update standard. Run after the build number is
# stamped into CFBundleVersion, before signing.
#
#   scripts/updates-plist.sh <Info.plist> <release|beta|none>
#
#   release  the public feed on the site, version "0.4.0"
#   beta     the unlisted feed from the environment, version "0.4.0 beta N"
#   none     no feed, no updater, version "Dev 0.4.0 (61)"; a dev build never
#            checks for updates
#
# Env for the beta line, both required: FT_BETA_FEED_URL (the unlisted feed, which
# never lives in this repository) and FT_BETA_NUMBER (the N above).
#
# Re-running on the same plist is safe: the keys are removed and the base
# version recovered before anything is written.
set -euo pipefail
PLIST="${1:?usage: updates-plist.sh <Info.plist> <release|beta|none>}"
LINE="${2:-none}"
PB=/usr/libexec/PlistBuddy

RELEASE_FEED="https://filmtether.app/updates/appcast.xml"
# The public half of the app's EdDSA key. The private half signs each update
# and the feed, and lives nowhere near this repository.
PUBLIC_ED_KEY="0yyOh7YbG8zVy6ljIMMWF52Zq9mwr5/AothOaHJu8uI="

base="$("$PB" -c 'Print :CFBundleShortVersionString' "$PLIST")"
base="${base#Dev }"; base="${base%% beta *}"; base="${base%% (*}"
build="$("$PB" -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo 0)"

for key in SUFeedURL SUPublicEDKey SUScheduledCheckInterval SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUEnableAutomaticChecks; do
    "$PB" -c "Delete :$key" "$PLIST" 2>/dev/null || true
done

case "$LINE" in
    release) feed="$RELEASE_FEED"; version="$base" ;;
    beta)
        feed="${FT_BETA_FEED_URL:?the beta line needs FT_BETA_FEED_URL}"
        n="${FT_BETA_NUMBER:?the beta line needs FT_BETA_NUMBER}"
        version="$base beta $n" ;;
    none) feed=""; version="Dev $base ($build)" ;;
    *) echo "FATAL: update line must be release, beta or none, not '$LINE'" >&2; exit 2 ;;
esac

"$PB" -c "Set :CFBundleShortVersionString $version" "$PLIST"
if [[ -n "$feed" ]]; then
    "$PB" -c "Add :SUFeedURL string $feed" "$PLIST"
    "$PB" -c "Add :SUPublicEDKey string $PUBLIC_ED_KEY" "$PLIST"
    "$PB" -c "Add :SUScheduledCheckInterval integer 86400" "$PLIST"
    "$PB" -c "Add :SURequireSignedFeed bool true" "$PLIST"
    # Goes with the signed feed: without it the updater refuses to start.
    "$PB" -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$PLIST"
fi
echo "    updates:  $LINE ${feed:-no feed}, version $version"
