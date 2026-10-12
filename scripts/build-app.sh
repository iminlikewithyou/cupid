#!/usr/bin/env bash
# build-app.sh: build Heartport.app (and optionally a DMG) from this package.
#
#   scripts/build-app.sh [--dmg] [--identity NAME]
#
# 1. Refuses to build unless Resources/runtime/runtime.tar.gz exists and its sha256 matches the
#    pin in docs/PHASE2.md (fetch it with scripts/fetch-runtime.sh).
# 2. `swift build -c release` (HeartportCore, the heartport CLI and the HeartportApp shell).
# 3. Assembles build/Heartport.app:
#      Contents/MacOS/Heartport                 the app
#      Contents/Helpers/heartport               the CLI
#      Contents/Resources/runtime.tar.gz       the runtime (Heartport's build, or Recall 1.3.0's)
#      Contents/Resources/runtime-archive.json  its version and sha256 (Heartport builds only)
#      Contents/Resources/config/dxmt.conf     [xdt.exe] profile template
#      Contents/Resources/Licenses/            Recall's licenses/ tree (from the tarball), Recall's
#                                              NOTICE and Apache-2.0 text, Heartport's LICENSE
#      Contents/Resources/AppIcon.icns         drawn by App/Resources/make-icon.swift
# 4. Signs with the hardened runtime (ad hoc unless --identity "Developer ID Application: ...").
# --dmg also writes build/Heartport-<version>.dmg (plain UDZO, app + /Applications link).
set -euo pipefail

TAR_SHA256="66ce2eabdbe14572d4bcb485321570bdd1128647aa64f6111642f9f073f92c34"
VERSION="0.2.0"
BUILD_NUMBER="1"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build"
APP="$BUILD/Heartport.app"
make_dmg=0; identity="-"
while [ $# -gt 0 ]; do
    case "$1" in
        --dmg) make_dmg=1 ;;
        --identity) shift; identity="${1:?--identity needs a value}" ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "== $*"; }

# 1. runtime archive: Heartport's own build (runtime-archive.json beside it, written by
#    scripts/runtime/assemble_portable_runtime.py) or Recall's (pinned here and in docs/PHASE2.md).
TARBALL="$REPO/Resources/runtime/runtime.tar.gz"
DESCRIPTOR="$REPO/Resources/runtime/runtime-archive.json"
[ -f "$TARBALL" ] || die "$TARBALL is missing. Run scripts/fetch-runtime.sh, or copy a build from scripts/runtime."
if [ -f "$DESCRIPTOR" ]; then
    TAR_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$DESCRIPTOR")"
    RUNTIME_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$DESCRIPTOR")"
    step "Runtime $RUNTIME_VERSION (Heartport build)"
else
    grep -q "$TAR_SHA256" "$REPO/docs/PHASE2.md" || die "the runtime pin in this script differs from docs/PHASE2.md"
    step "Runtime phase2-20261007.3 (Recall 1.3.0)"
fi
step "Checking runtime.tar.gz sha256"
got="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
[ "$got" = "$TAR_SHA256" ] || die "runtime.tar.gz sha256 $got does not match $TAR_SHA256"
for f in "$REPO/Resources/config/dxmt.conf" "$REPO/Resources/Licenses/Recall/NOTICE" "$REPO/Resources/Licenses/Recall/LICENSE" "$REPO/LICENSE"; do
    [ -f "$f" ] || die "missing $f"
done

# 2. build
step "swift build -c release"
(cd "$REPO" && swift build -c release 2>&1 | grep -E "error|warning: |Compiling|Build complete" | grep -v "^\[" || true)
(cd "$REPO" && swift build -c release >/dev/null) || die "swift build failed"
BIN="$(cd "$REPO" && swift build -c release --show-bin-path)"
[ -x "$BIN/HeartportApp" ] && [ -x "$BIN/heartport" ] || die "release binaries missing in $BIN"

# 3. bundle
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/config" "$APP/Contents/Resources/Licenses"
ditto "$BIN/HeartportApp" "$APP/Contents/MacOS/Heartport"
ditto "$BIN/heartport" "$APP/Contents/Helpers/heartport"
ditto "$TARBALL" "$APP/Contents/Resources/runtime.tar.gz"
[ -f "$DESCRIPTOR" ] && ditto "$DESCRIPTOR" "$APP/Contents/Resources/runtime-archive.json"
ditto "$REPO/Resources/config/dxmt.conf" "$APP/Contents/Resources/config/dxmt.conf"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD_NUMBER/" "$REPO/App/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "Licenses"
LIC="$APP/Contents/Resources/Licenses"
tmp="$(mktemp -d "$BUILD/.licenses.XXXXXX")"
tar -xzf "$TARBALL" -C "$tmp" licenses
ditto "$tmp/licenses" "$LIC"
rm -rf "$tmp"
cp "$REPO/Resources/Licenses/Recall/NOTICE" "$LIC/Recall-NOTICE"
cp "$REPO/Resources/Licenses/Recall/LICENSE" "$LIC/Recall-LICENSE-Apache-2.0"
cp "$REPO/LICENSE" "$LIC/Heartport-LICENSE-Apache-2.0"
echo "  $(find "$LIC" -type f | wc -l | tr -d ' ') license files"

step "Icon"
ICONSET="$BUILD/AppIcon.iconset"
ICNS="$BUILD/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$REPO/App/Resources/make-icon.swift" -nt "$ICNS" ]; then
    rm -rf "$ICONSET"
    swift "$REPO/App/Resources/make-icon.swift" "$ICONSET" >/dev/null
    iconutil -c icns -o "$ICNS" "$ICONSET"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# 4. sign: inside out, hardened runtime, no special entitlements.
step "Signing (identity: $identity)"
ENT="$REPO/App/Resources/Heartport.entitlements"
ts="--timestamp=none"; [ "$identity" != "-" ] && ts="--timestamp"
codesign --force --options runtime $ts --entitlements "$ENT" -s "$identity" \
    -i app.heartport.cli "$APP/Contents/Helpers/heartport"
codesign --force --options runtime $ts --entitlements "$ENT" -s "$identity" "$APP"
codesign --verify --strict --deep --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
codesign -dv "$APP" 2>&1 | grep -E "Identifier|flags|Signature" | sed 's/^/  /'

# Smoke: the bundled CLI runs and finds the bundled archive.
"$APP/Contents/Helpers/heartport" --help >/dev/null || die "bundled CLI does not run"
du -sh "$APP" | sed 's/^/  size: /'

if [ "$make_dmg" = 1 ]; then
    step "DMG"
    stage="$(mktemp -d "$BUILD/.dmg.XXXXXX")"
    ditto "$APP" "$stage/Heartport.app"
    ln -s /Applications "$stage/Applications"
    DMG="$BUILD/Heartport-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -quiet -volname Heartport -srcfolder "$stage" -fs APFS -format UDZO -ov "$DMG"
    rm -rf "$stage"
    if [ "$identity" != "-" ]; then codesign --force --timestamp -s "$identity" "$DMG"; fi
    echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"
fi

echo "App: $APP"
