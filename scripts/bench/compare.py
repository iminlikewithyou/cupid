#!/usr/bin/env python3
"""Side-by-side Markdown table of two analyzed captures, in the layout of
Recall's docs/PERFORMANCE.md.

    scripts/bench/compare.py <label-a> <label-b> --names "CrossOver" "Heartport"

A is the baseline, B the candidate; the last column reads "B vs. A". Each
label is a bench/<label> folder (or a path to a metrics.json) that
analyze.py has already processed. The better value in each row is bold.
"""
import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # keep __pycache__ out of scripts/bench
sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze import BENCH, ROWS, fmt_value, lookup  # noqa: E402

# key -> (higher_is_better, style, headline)
# style: "pct" signed percent, "ratio" N.N× higher, "shorter"/"fewer"/"lower" percent change,
# None for no comparison.
RULES = {
    "average_fps": (True, "pct", True),
    "low_1pct_fps": (True, "ratio", True),
    "low_0_1pct_fps": (True, "ratio", False),
    "median_ms": (False, "shorter", False),
    "p95_ms": (False, "shorter", False),
    "p99_ms": (False, "shorter", False),
    "stutters_50ms_per_min": (False, "fewer", True),
    "stutters_100ms": (False, None, False),
    "measured_s": (None, None, False),
    "power.combined_avg_mw": (False, "lower", True),
    "power.combined_p95_mw": (False, "lower", False),
    "power.cpu_avg_mw": (False, "lower", False),
    "power.gpu_avg_mw": (False, "lower", False),
    "power.energy_per_frame_mj": (False, "lower", True),
}
OPPOSITE = {"shorter": "longer", "fewer": "more", "lower": "higher"}


def load(label):
    path = Path(label)
    if path.suffix != ".json":
        path = BENCH / label / "metrics.json"
    if not path.exists():
        raise SystemExit(f"No {path}; run analyze.py {label} first.")
    return json.loads(path.read_text())


def change(a, b, style):
    """Text for B relative to A."""
    if style is None or a is None or b is None:
        return ""
    if a == 0:
        return "" if b == 0 else ("from zero" if style in ("pct", "ratio") else f"{OPPOSITE.get(style, 'more')} (from 0)")
    ratio = b / a
    if style == "pct":
        return f"{(ratio - 1) * 100:+.1f}%"
    if style == "ratio":
        if ratio >= 1:
            return f"{ratio:.1f}× higher"
        return f"{(1 - ratio) * 100:.1f}% lower"
    if ratio <= 1:
        return f"{(1 - ratio) * 100:.1f}% {style}"
    return f"{(ratio - 1) * 100:.1f}% {OPPOSITE[style]}"


def table(a, b, name_a, name_b):
    lines = [f"| | {name_a} | {name_b} | {name_b} vs. {name_a} |", "|---|---:|---:|---:|"]
    for spec in ROWS:
        key = spec[1]
        va, vb = lookup(a, key), lookup(b, key)
        if va is None and vb is None:
            continue
        higher_better, style, headline = RULES[key]
        ta = fmt_value(spec, va) if va is not None else "n/a"
        tb = fmt_value(spec, vb) if vb is not None else "n/a"
        b_better = a_better = False
        if higher_better is not None and va is not None and vb is not None and ta != tb:
            b_better = (vb > va) == higher_better
            a_better = not b_better
            if a_better:
                ta = f"**{ta}**"
            else:
                tb = f"**{tb}**"
        text = change(va, vb, style) if va is not None and vb is not None else ""
        if text and headline and b_better:
            text = f"**{text}**"
        lines.append(f"| {spec[0]} | {ta} | {tb} | {text} |")
    return "\n".join(lines)


def setup(a, b, name_a, name_b):
    ca, cb = a.get("capture", {}), b.get("capture", {})
    if not ca and not cb:
        return ""

    def both(key):
        va, vb = ca.get(key), cb.get(key)
        return str(va) if va == vb else f"{name_a}: {va}; {name_b}: {vb}"

    mac = f"{both('mac_model')}, {both('chip')}, {both('memory_gb')} GB memory, macOS {both('macos')}"
    rows = [("Mac", mac), ("Power source", both("power_source")),
            ("Processes measured", f"{name_a}: {a['process']['name']}; {name_b}: {b['process']['name']}"),
            ("Measurement", "Every frame the game put on screen (Metal presentedTime, Instruments "
                            "Metal System Trace); power from powermetrics where present")]
    return "\n".join(["| | |", "|---|---|"] + [f"| {k} | {v} |" for k, v in rows])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("label_a", help="baseline")
    ap.add_argument("label_b", help="candidate")
    ap.add_argument("--names", nargs=2, metavar=("A", "B"), help="column names (default: labels)")
    ap.add_argument("--setup", action="store_true", help="also print a draft Setup table")
    args = ap.parse_args()
    a, b = load(args.label_a), load(args.label_b)
    name_a, name_b = args.names or (args.label_a, args.label_b)
    if args.setup:
        print(setup(a, b, name_a, name_b))
        print()
    print(table(a, b, name_a, name_b))


if __name__ == "__main__":
    main()
