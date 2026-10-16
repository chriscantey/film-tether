#!/usr/bin/env bash
# The source archives of the libraries the release carries, for attaching to a
# GitHub release next to the app, with the two patches ptp2.so is built with.
#
#   scripts/release-sources.sh fetch [version]
#       Download the six archives in SOURCES into release-sources/<version>/
#       and check each against its SHA-256. A file already there with a wrong
#       checksum is downloaded again, and a download that does not match is
#       deleted and stops the script. <version> defaults to CFBundleShortVersionString
#       in Resources/Info.plist.
#   scripts/release-sources.sh upload <tag> [version] [--run]
#       Print the `gh release upload` command that attaches the fetched
#       archives and patches/*.diff to the release <tag>. With --run, run it.
#       It checks every archive again first.
#   scripts/release-sources.sh selftest
#       Prove the checksum check fails on a wrong checksum and passes on the
#       right one, using a scratch file.
#
# The table must match THIRD-PARTY-NOTICES.md: fetch and upload stop if any
# URL or checksum below is missing from it.
set -euo pipefail
cd "$(dirname "$0")/.."

# <SHA-256> <URL>, one archive per line.
SOURCES="
5df9e774eb4ab6087a193afff84dcafe9f666e3443fe29e73e6779f659ff7f28 https://downloads.sourceforge.net/project/gphoto/libgphoto/2.5.34/libgphoto2-2.5.34.tar.bz2
fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
0830ed253fceeb60444fb309598bc8a9491d3007dc054aad3a50a347c5597c57 https://github.com/libexif/libexif/releases/download/v0.6.26/libexif-0.6.26.tar.bz2
85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a https://ftp.gnu.org/gnu/gettext/gettext-1.0.tar.gz
2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e https://ftp.gnu.org/gnu/libtool/libtool-2.6.2.tar.xz
6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz
"

die() { echo "FATAL: $*" >&2; exit 1; }

# verify <file> <sha256>: exit status 0 only when the file's SHA-256 is exactly
# the expected value.
verify() {
    local got
    got=$(shasum -a 256 "$1" | awk '{print $1}')
    [ "$got" = "$2" ]
}

app_version() {
    sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist
}

check_notices() {
    local sha url
    while read -r sha url; do
        [ -n "$sha" ] || continue
        grep -q -F -e "$sha" THIRD-PARTY-NOTICES.md || die "$sha is not in THIRD-PARTY-NOTICES.md"
        grep -q -F -e "$url" THIRD-PARTY-NOTICES.md || die "$url is not in THIRD-PARTY-NOTICES.md"
    done <<< "$SOURCES"
}

# check_all <dir>: every archive in SOURCES is in <dir> with its checksum.
check_all() {
    local sha url f
    while read -r sha url; do
        [ -n "$sha" ] || continue
        f="$1/$(basename "$url")"
        [ -f "$f" ] || die "$f is missing. Run: $0 fetch"
        verify "$f" "$sha" || die "$f does not match $sha"
    done <<< "$SOURCES"
}

cmd_fetch() {
    local ver="${1:-$(app_version)}" sha url f
    [ -n "$ver" ] || die "no version given and none found in Resources/Info.plist"
    check_notices
    local dir="release-sources/$ver"
    mkdir -p "$dir"
    while read -r sha url; do
        [ -n "$sha" ] || continue
        f="$dir/$(basename "$url")"
        if [ -f "$f" ] && verify "$f" "$sha"; then
            echo ">> have   $(basename "$f")"
            continue
        fi
        echo ">> fetch  $url"
        rm -f "$f"
        curl -fL --retry 3 -o "$f.part" "$url" || { rm -f "$f.part"; die "download failed: $url"; }
        if ! verify "$f.part" "$sha"; then
            rm -f "$f.part"
            die "$(basename "$f") does not match $sha"
        fi
        mv "$f.part" "$f"
    done <<< "$SOURCES"
    check_all "$dir"
    echo ">> OK: six archives in $dir, every checksum matches"
}

cmd_upload() {
    local tag="" ver="" run=0 arg
    for arg in "$@"; do
        case "$arg" in
            --run) run=1 ;;
            *) if [ -z "$tag" ]; then tag="$arg"; elif [ -z "$ver" ]; then ver="$arg"; else die "unexpected argument: $arg"; fi ;;
        esac
    done
    [ -n "$tag" ] || die "usage: $0 upload <tag> [version] [--run]"
    ver="${ver:-$(app_version)}"
    check_notices
    local dir="release-sources/$ver" sha url
    check_all "$dir"
    local files=()
    while read -r sha url; do
        [ -n "$sha" ] || continue
        files+=("$dir/$(basename "$url")")
    done <<< "$SOURCES"
    files+=(patches/*.diff)
    [ "${#files[@]}" -eq 8 ] || die "expected six archives and two patches, found ${#files[@]} files"
    if [ "$run" = 1 ]; then
        gh release upload "$tag" "${files[@]}"
        echo ">> uploaded ${#files[@]} files to $tag"
    else
        printf 'gh release upload %q' "$tag"
        printf ' %q' "${files[@]}"
        printf '\n'
    fi
}

cmd_selftest() {
    local tmp
    tmp=$(mktemp -d)
    printf 'release-sources selftest\n' > "$tmp/a"
    local right
    right=$(shasum -a 256 "$tmp/a" | awk '{print $1}')
    local wrong="0000000000000000000000000000000000000000000000000000000000000000"
    verify "$tmp/a" "$right" || die "selftest: the right checksum did not pass"
    if verify "$tmp/a" "$wrong"; then die "selftest: a wrong checksum passed"; fi
    rm -rf "$tmp"
    check_notices
    echo ">> selftest OK: a wrong checksum fails, the right one passes, the table matches the notices"
}

case "${1:-}" in
    fetch)    shift; cmd_fetch "$@" ;;
    upload)   shift; cmd_upload "$@" ;;
    selftest) shift; cmd_selftest ;;
    *) echo "usage: $0 fetch [version] | upload <tag> [version] [--run] | selftest" >&2; exit 2 ;;
esac
