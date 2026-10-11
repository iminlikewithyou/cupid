#!/usr/bin/env bash
# smoke.sh: run the CLI end to end against an existing data root (the spike's, by default),
# idempotently. It never stops Wine, never launches anything, and never changes the registry
# or dxmt.conf while a Mactopia wineserver is alive:
#   1. build the CLI
#   2. `mactopia status` (and --json) and note whether a session is alive
#   3. `mactopia setup --step runtime` twice: must detect the verified runtime and do nothing
#   4. `mactopia setup --step prefix` twice: must report "up to date" (skipped while a session is
#      alive and the prefix would need changes; the CLI would refuse anyway)
#   5. check dxmt.conf, state.json, user.reg and system.reg are byte-identical before and after,
#      that the game and TapTap are detected as installed, and that no ~/.wine appeared.
# Env: MACTOPIA_DATA (data root), SMOKE_REQUIRE_GAME=0 to allow a data root without the game.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${MACTOPIA_DATA:-$HOME/Library/Application Support/Mactopia}"
export MACTOPIA_DATA="$DATA"
CLI="$REPO/.build/debug/mactopia"
fails=0
pass() { echo "PASS: $*"; }
failed() { echo "FAIL: $*"; fails=$((fails + 1)); }
json() { /usr/bin/plutil -extract "$1" raw -o - "$STATUS_JSON" 2>/dev/null || echo "?"; }
digest() { for f in "$@"; do if [ -f "$f" ]; then shasum -a 256 "$f"; else echo "absent $f"; fi; done; }

echo "== build"
(cd "$REPO" && swift build --product mactopia 2>&1 | tail -1)
[ -d "$DATA" ] || { echo "No data root at $DATA"; exit 1; }
had_wine=no; [ -e "$HOME/.wine" ] && had_wine=yes

WATCHED=("$DATA/dxmt.conf" "$DATA/state.json" "$DATA/prefix/user.reg" "$DATA/prefix/system.reg")
before="$(digest "${WATCHED[@]}")"

echo "== mactopia status"
"$CLI" status
STATUS_JSON="$(mktemp "${TMPDIR:-/tmp}/mactopia-smoke.XXXXXX")"
trap 'rm -f "$STATUS_JSON"' EXIT
"$CLI" status --json > "$STATUS_JSON"
alive="$(json session.alive)"
echo "session alive: $alive"
[ "$alive" = true ] && echo "NOTE: a Mactopia Wine session is running; registry and dxmt.conf are left alone."

echo "== mactopia setup --step runtime (x2)"
for i in 1 2; do
    out="$("$CLI" setup --step runtime 2>&1)" || { echo "$out"; failed "setup --step runtime (run $i) exited non-zero"; continue; }
    echo "$out"
    if grep -q "Runtime ready: nothing to do." <<<"$out"; then pass "runtime step $i was a no-op"; else failed "runtime step $i did work"; fi
done

echo "== mactopia setup --step prefix (x2)"
pending="$(json prefix.pendingSeeds | tr -d '\n')"
win10="$(json prefix.windows10)"
links="$(/usr/bin/plutil -extract prefix.userLinks json -o - "$STATUS_JSON" 2>/dev/null || echo '?')"
if [ "$alive" = true ] && { [ "$win10" != true ] || [ "$links" != "[]" ] || /usr/bin/plutil -extract prefix.pendingSeeds.0 raw -o - "$STATUS_JSON" >/dev/null 2>&1; }; then
    echo "SKIP: the prefix needs changes and a session is alive (the CLI would refuse with exit 3)"
else
    for i in 1 2; do
        set +e; out="$("$CLI" setup --step prefix 2>&1)"; rc=$?; set -e
        echo "$out"
        if [ $rc -eq 0 ] && grep -q "^Prefix up to date" <<<"$out"; then pass "prefix step $i was a no-op"
        elif [ $rc -eq 3 ]; then pass "prefix step $i refused while a session is alive"
        else failed "prefix step $i (exit $rc) did work or failed"; fi
    done
fi

echo "== detection"
[ "$(json runtime.installedVersion)" = "$(json runtime.expectedVersion)" ] && pass "runtime $(json runtime.installedVersion) detected" || failed "runtime not detected"
[ "$(json runtime.gameModeBundle)" = true ] && pass "xdt.app detected" || failed "xdt.app missing"
[ "$(json prefix.exists)" = true ] && pass "prefix detected" || failed "prefix missing"
[ "$(json prefix.retinaMode)" = N ] && pass "RetinaMode=N" || failed "RetinaMode is $(json prefix.retinaMode)"
if [ "${SMOKE_REQUIRE_GAME:-1}" = 1 ]; then
    [ "$(json taptap.launcherInstalled)" = true ] && pass "TapTap launcher detected" || failed "TapTap launcher not detected"
    [ "$(json game.state)" = installed ] && pass "Heartopia detected as installed ($(json game.filesListed) files)" || failed "game state is $(json game.state)"
fi

echo "== nothing changed"
# A live wineserver may itself flush user.reg/system.reg; only compare them when none runs.
after="$(digest "${WATCHED[@]}")"
alive_now="$("$CLI" status --json | /usr/bin/plutil -extract session.alive raw -o - - 2>/dev/null || echo '?')"
if [ "$alive" != true ] && [ "$alive_now" != true ]; then
    [ "$before" = "$after" ] && pass "dxmt.conf, state.json, user.reg, system.reg unchanged" || { failed "files changed"; diff <(echo "$before") <(echo "$after") || true; }
else
    b1="$(grep -F "$DATA/dxmt.conf" <<<"$before")"; a1="$(grep -F "$DATA/dxmt.conf" <<<"$after")"
    [ "$b1" = "$a1" ] && pass "dxmt.conf unchanged (registry not compared: session alive)" || failed "dxmt.conf changed"
fi
if [ "$had_wine" = no ] && [ -e "$HOME/.wine" ]; then failed "~/.wine appeared"; else pass "no stray ~/.wine"; fi

echo
if [ $fails -eq 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED: $fails check(s)"; exit 1; fi
