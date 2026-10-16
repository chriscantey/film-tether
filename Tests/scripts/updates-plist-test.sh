#!/usr/bin/env bash
# scripts/updates-plist.sh writes exactly the update keys each line calls for,
# and the version string, and nothing on the dev line. Runs on a Mac
# (PlistBuddy). `make tests` runs it.
set -euo pipefail
cd "$(dirname "$0")/../.."
PB=/usr/libexec/PlistBuddy
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P="$T/Info.plist"
fail=0
say() { printf '%s\n' "$*"; }
check() { # check <label> <got> <want>
    if [[ "$2" == "$3" ]]; then say "ok   $1"; else say "FAIL $1: got '$2', want '$3'"; fail=1; fi
}
get() { "$PB" -c "Print :$1" "$P" 2>/dev/null || echo "<absent>"; }
fresh() { cp Resources/Info.plist "$P"; "$PB" -c "Add :CFBundleVersion string 61" "$P" 2>/dev/null || "$PB" -c "Set :CFBundleVersion 61" "$P"; }

fresh; bash scripts/updates-plist.sh "$P" release >/dev/null
check "release feed"    "$(get SUFeedURL)" "https://filmtether.app/updates/appcast.xml"
check "release key"     "$(get SUPublicEDKey)" "0yyOh7YbG8zVy6ljIMMWF52Zq9mwr5/AothOaHJu8uI="
check "release interval" "$(get SUScheduledCheckInterval)" "86400"
check "release signed"  "$(get SURequireSignedFeed)" "true"
check "release verify"  "$(get SUVerifyUpdateBeforeExtraction)" "true"
check "release no auto key" "$(get SUEnableAutomaticChecks)" "<absent>"
check "release version" "$(get CFBundleShortVersionString)" "0.4.0"

fresh; FT_BETA_FEED_URL="https://example.test/x/beta.xml" FT_BETA_NUMBER=3 bash scripts/updates-plist.sh "$P" beta >/dev/null
check "beta feed"       "$(get SUFeedURL)" "https://example.test/x/beta.xml"
check "beta version"    "$(get CFBundleShortVersionString)" "0.4.0 beta 3"
check "beta signed"     "$(get SURequireSignedFeed)" "true"

fresh; if FT_BETA_NUMBER=3 bash scripts/updates-plist.sh "$P" beta >/dev/null 2>&1; then say "FAIL beta without a feed URL was accepted"; fail=1; else say "ok   beta refuses without FT_BETA_FEED_URL"; fi

fresh; bash scripts/updates-plist.sh "$P" none >/dev/null
check "none feed"       "$(get SUFeedURL)" "<absent>"
check "none key"        "$(get SUPublicEDKey)" "<absent>"
check "none verify"     "$(get SUVerifyUpdateBeforeExtraction)" "<absent>"
check "none version"    "$(get CFBundleShortVersionString)" "Dev 0.4.0 (61)"

# A second run on the same plist lands on the same answer (the keys are
# replaced, the base version recovered).
bash scripts/updates-plist.sh "$P" release >/dev/null; bash scripts/updates-plist.sh "$P" none >/dev/null
check "rerun version"   "$(get CFBundleShortVersionString)" "Dev 0.4.0 (61)"
check "rerun no feed"   "$(get SUFeedURL)" "<absent>"

if bash scripts/updates-plist.sh "$P" nightly >/dev/null 2>&1; then say "FAIL an unknown line was accepted"; fail=1; else say "ok   unknown line refused"; fi

[[ "$fail" == 0 ]] && say "updates-plist: all checks passed" || { say "updates-plist: FAILED"; exit 1; }
