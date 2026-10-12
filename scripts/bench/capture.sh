#!/bin/bash
# Record every frame the system presents, system-wide, with Instruments'
# Metal System Trace template. No sudo needed.
#
#   scripts/bench/capture.sh [--power] [--no-countdown] <label> <seconds>
#
# Writes bench/<label>/trace.trace and bench/<label>/capture.json at the repo
# root (bench/ is gitignored). With --power it prints the powermetrics command
# to run with sudo in a second terminal, saving to bench/<label>/power.txt,
# and waits for Return before recording. Ctrl-C ends the recording early and
# still saves the trace.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

power=0
countdown=3
while [ $# -gt 0 ]; do
    case "$1" in
        --power) power=1; shift ;;
        --no-countdown) countdown=0; shift ;;
        -h|--help) usage ;;
        --*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || usage
label=$1
seconds=$2
case "$label" in */*|.*|"") echo "label must be a plain name: $label" >&2; exit 2 ;; esac
case "$seconds" in ''|*[!0-9]*) echo "seconds must be a whole number: $seconds" >&2; exit 2 ;; esac

repo=$(cd "$(dirname "$0")/../.." && pwd)
dir="$repo/bench/$label"
trace="$dir/trace.trace"
if [ -e "$trace" ]; then
    echo "$trace already exists; pick another label or remove it" >&2
    exit 1
fi
mkdir -p "$dir"
# bench/ holds local captures only; keep it out of git without touching .gitignore.
[ -e "$repo/bench/.gitignore" ] || echo "*" > "$repo/bench/.gitignore"

if [ "$power" = 1 ]; then
    samples=$((seconds + countdown + 15))
    echo "In a second terminal, start power sampling now (it runs ${samples} s):"
    echo
    echo "  sudo powermetrics -i 1000 -n $samples --samplers cpu_power,gpu_power -o '$dir/power.txt'"
    echo
    read -r -p "Press Return once it is running... " _
fi

power_source=$(pmset -g ps | head -1 | sed -n "s/.*'\(.*\)'.*/\1/p")
cat > "$dir/capture.json" <<JSON
{
  "label": "$label",
  "seconds": $seconds,
  "mac_model": "$(sysctl -n hw.model)",
  "chip": "$(sysctl -n machdep.cpu.brand_string)",
  "memory_gb": $(( $(sysctl -n hw.memsize) / 1073741824 )),
  "macos": "$(sw_vers -productVersion) ($(sw_vers -buildVersion))",
  "power_source": "$power_source",
  "requested_at": "$(date +%Y-%m-%dT%H:%M:%S%z)"
}
JSON

for ((i = countdown; i > 0; i--)); do
    printf 'Recording in %d...\n' "$i"
    sleep 1
done

# xctrace saves the trace on SIGINT; keep this script alive until it has.
trap '' INT
set +e
xcrun xctrace record --template 'Metal System Trace' --all-processes \
    --time-limit "${seconds}s" --output "$trace" 2>&1 |
while IFS= read -r line; do
    case "$line" in
        "Ctrl-C to stop the recording"*)
            echo ">>> RECORDING $(date +%H:%M:%S) for ${seconds} s (Ctrl-C ends early)" ;;
        "Reached specified time limit"*|"Ending recording"*|*"Stopping recording"*)
            echo ">>> STOPPED $(date +%H:%M:%S); saving the trace (this takes a while)..." ;;
        "Output file saved as"*)
            echo "Saved $trace" ;;
        "Starting recording"*|"Timeline modification failed"*|"    0x"*|"Recording completed"*) ;;
        *) echo "$line" ;;
    esac
done
status=${PIPESTATUS[0]}
set -e
trap - INT
if [ ! -e "$trace" ]; then
    echo "xctrace did not write $trace (exit $status)" >&2
    exit 1
fi
echo "Next: scripts/bench/analyze.py $label --process <name|pid>"
