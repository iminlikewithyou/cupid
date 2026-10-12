#!/bin/bash
# End-to-end check of the bench tools without the game.
#
# Builds a small MetalKit app that presents at 60 Hz and stalls 120 ms every
# 2 s, records 10 s of it with capture.sh, adds a synthetic powermetrics log,
# runs analyze.py and compare.py, and checks the numbers: median frame time
# about 16.7 ms, about 5 stutters over 100 ms, and power samples aligned to
# the recorded window. Needs Xcode (swiftc, xctrace); no sudo. A window
# appears for about 20 s; leave it visible.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
bench="$repo/bench"
label=selftest
mkdir -p "$bench"
[ -e "$bench/.gitignore" ] || echo "*" > "$bench/.gitignore"

echo "== build test app"
swiftc -O -o "$bench/bench-testapp" "$here/testapp/main.swift" -framework MetalKit -framework AppKit

rm -rf "${bench:?}/$label"
"$bench/bench-testapp" 20 2 120 >/dev/null &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT
sleep 1

echo "== capture 10 s"
"$here/capture.sh" "$label" 10

echo "== synthetic power log"
python3 - "$bench/$label" <<'PY'
import datetime, json, sys, pathlib
folder = pathlib.Path(sys.argv[1])
began = json.loads((folder / "capture.json").read_text())["requested_at"]
began = datetime.datetime.strptime(began, "%Y-%m-%dT%H:%M:%S%z")
out = ["Machine model: test", ""]
for i in range(40):  # one sample a second from before the countdown on
    t = began + datetime.timedelta(seconds=i)
    cpu, gpu = 2000 + i, 500
    out += [f"*** Sampled system activity ({t:%a %b %d %H:%M:%S %Y %z}) (1001.20ms elapsed) ***", "",
            "**** Processor usage ****", "", f"CPU Power: {cpu} mW", f"GPU Power: {gpu} mW",
            "ANE Power: 0 mW", f"Combined Power (CPU + GPU + ANE): {cpu + gpu} mW", "",
            "**** GPU usage ****", "", "GPU HW active residency:  12.50% (389 MHz: 12%)",
            f"GPU Power: {gpu} mW", ""]
(folder / "power.txt").write_text("\n".join(out))
PY

echo "== analyze"
python3 "$here/analyze.py" "$label" --process bench-testapp --trim-start 0.5 --trim-end 0.5 --name "Test app"

echo "== compare (against itself)"
python3 "$here/compare.py" "$label" "$label" --names A B >/dev/null

echo "== check"
python3 - "$bench/$label/metrics.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
checks = [
    ("median frame time 16.0-17.4 ms", 16.0 <= m["median_ms"] <= 17.4, m["median_ms"]),
    ("average FPS 50-61", 50 <= m["average_fps"] <= 61, m["average_fps"]),
    ("stutters over 100 ms: 4-6", 4 <= m["stutters_100ms"] <= 6, m["stutters_100ms"]),
    ("stutters over 50 ms per minute 20-40", 20 <= m["stutters_50ms_per_min"] <= 40, m["stutters_50ms_per_min"]),
    ("1% low FPS under 15 (the stalls)", m["low_1pct_fps"] < 15, m["low_1pct_fps"]),
    ("measured 8-10 s", 8 <= m["measured_s"] <= 10, m["measured_s"]),
    ("power samples aligned to window (7-11)", 7 <= m["power"].get("samples", 0) <= 11, m["power"].get("samples", 0)),
    ("combined power = CPU + GPU", "combined_avg_mw" in m["power"] and
     abs(m["power"]["combined_avg_mw"] - m["power"]["cpu_avg_mw"] - m["power"]["gpu_avg_mw"]) <= 1,
     m["power"].get("combined_avg_mw")),
]
failed = 0
for name, ok, value in checks:
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {value}")
    failed += not ok
sys.exit(1 if failed else 0)
PY
echo "selftest passed"
