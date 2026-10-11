#!/usr/bin/env bash
# fetch-runtime.sh: Recall 1.3.0 DMG -> Resources/runtime/runtime.tar.gz (sha256-pinned).
#
#   scripts/fetch-runtime.sh [--verify] [--keep-dmg]
#
# 1. Downloads Recall-1.3.0.dmg (cached in Resources/runtime/, gitignored) and checks its
#    sha256 against both the published .sha256 file and the pin below.
# 2. Mounts it read-only (no Finder window), copies Recall.app/Contents/Resources/runtime.tar.gz
#    with ditto, detaches.
# 3. Checks the tarball's sha256 and moves it to Resources/runtime/runtime.tar.gz.
# --verify additionally extracts it to a temporary directory and verifies every file against
# its runtime.json with `mactopia verify-runtime` (builds the CLI if needed).
# Re-running is a no-op once the tarball is in place and matches.
set -euo pipefail

DMG_URL="https://github.com/AsherJN/recall/releases/download/v1.3.0/Recall-1.3.0.dmg"
DMG_SHA_URL="$DMG_URL.sha256"
DMG_SHA256="dbe066d52fc41825b4d0afc146a0d81561c6e729319f8939a2de2a733bef2b16"
TAR_SHA256="66ce2eabdbe14572d4bcb485321570bdd1128647aa64f6111642f9f073f92c34"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO/Resources/runtime"
OUT="$OUT_DIR/runtime.tar.gz"
DMG="$OUT_DIR/Recall-1.3.0.dmg"
verify=0; keep_dmg=0
for a in "$@"; do
    case "$a" in
        --verify) verify=1 ;;
        --keep-dmg) keep_dmg=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
mkdir -p "$OUT_DIR"

if [ -f "$OUT" ] && [ "$(sha "$OUT")" = "$TAR_SHA256" ]; then
    echo "runtime.tar.gz already present and verified: $OUT"
else
    published=$(curl -fsSL --proto '=https' --proto-redir '=https' "$DMG_SHA_URL" | awk '{print $1}')
    [ "$published" = "$DMG_SHA256" ] || die "published DMG sha256 ($published) differs from the pin ($DMG_SHA256)"

    if [ -f "$DMG" ] && [ "$(sha "$DMG")" = "$DMG_SHA256" ]; then
        echo "DMG cached: $DMG"
    else
        echo "Downloading $DMG_URL"
        curl -fL --retry 3 --proto '=https' --proto-redir '=https' -o "$DMG.part" "$DMG_URL"
        got=$(sha "$DMG.part")
        [ "$got" = "$DMG_SHA256" ] || { rm -f "$DMG.part"; die "DMG sha256 $got != $DMG_SHA256"; }
        mv "$DMG.part" "$DMG"
    fi
    echo "DMG sha256 OK: $DMG_SHA256"

    work="$(mktemp -d "${TMPDIR:-/tmp}/mactopia-fetch.XXXXXX")"
    mnt="$work/mnt"; mkdir -p "$mnt"
    cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$work"; }
    trap cleanup EXIT
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$DMG" >/dev/null
    src="$mnt/Recall.app/Contents/Resources/runtime.tar.gz"
    [ -f "$src" ] || die "runtime.tar.gz not found in the DMG at Recall.app/Contents/Resources/"
    ditto "$src" "$work/runtime.tar.gz"
    hdiutil detach -quiet "$mnt"
    got=$(sha "$work/runtime.tar.gz")
    [ "$got" = "$TAR_SHA256" ] || die "runtime.tar.gz sha256 $got != $TAR_SHA256"
    mv "$work/runtime.tar.gz" "$OUT"
    echo "runtime.tar.gz sha256 OK: $TAR_SHA256 -> $OUT"
    [ "$keep_dmg" = 1 ] || rm -f "$DMG"
fi

if [ "$verify" = 1 ]; then
    cli="$REPO/.build/debug/mactopia"
    [ -x "$cli" ] || (cd "$REPO" && swift build --product mactopia >/dev/null)
    "$cli" verify-runtime --archive "$OUT"
fi
