#!/usr/bin/env python3
"""Frame-time and power metrics for one capture made by capture.sh.

    scripts/bench/analyze.py <label> --process <name|pid|substring> [...]
        [--trim-start S] [--trim-end S] [--exclude A-B ...]

Frames: every drawable the chosen process put on screen, from the trace's
`ca-client-presented-handler` table. Its "Requested Time" column is the
drawable's presentedTime, the moment Core Animation reports the frame reached
the display, which is the same source Recall's benchmark uses. (The
WindowServer-side `displayed-surfaces-interval` table stays empty without
root, so it is not used.) A frame interval is the gap between two consecutive
on-screen frames of that process.

Definitions follow Recall's docs/PERFORMANCE.md:
  average FPS       frames / measured time
  1% / 0.1% low FPS frame rate over the slowest 1% / 0.1% of frame intervals
                    (their count divided by their summed duration)
  frame time        median, 95th and 99th percentile of the intervals
  stutter           an interval over 50 ms (per minute) or 100 ms (count)

Power (optional): bench/<label>/power.txt from `powermetrics`, averaged over
the samples that fall inside the measured window.

Writes bench/<label>/metrics.json and prints a Markdown table.
"""
import argparse
import datetime
import json
import math
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
BENCH = REPO / "bench"
SAME_VSYNC_NS = 500_000  # presentations closer than this count as one frame


# ---------------------------------------------------------------- trace export

def xctrace(args, stdout):
    """Run xctrace quietly; it prints dylib-overlap noise on most traces."""
    done = subprocess.run(["xcrun", "xctrace", *args], stdout=stdout, stderr=subprocess.PIPE, text=True)
    if done.returncode:
        raise SystemExit(f"xctrace {' '.join(args)} failed:\n{done.stderr[-2000:]}")


def export(trace, out, xpath):
    """Export one table (cached next to the trace)."""
    if not out.exists() or out.stat().st_mtime < trace.stat().st_mtime:
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp")
        xctrace(["export", "--input", str(trace), "--xpath", xpath, "--output", str(tmp)],
                subprocess.DEVNULL)
        tmp.replace(out)
    return out


def prefetch(trace, cache, schemas):
    """Export the TOC and tables in parallel; each xctrace run reloads the trace."""
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [pool.submit(export_toc, trace, cache)]
        jobs += [pool.submit(export_table, trace, cache, schema) for schema in schemas]
        for job in jobs:
            job.result()


def export_table(trace, cache, schema):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    return export(trace, cache / f"{schema}.xml", xpath)


def export_toc(trace, cache):
    out = cache / "toc.xml"
    if not out.exists() or out.stat().st_mtime < trace.stat().st_mtime:
        cache.mkdir(parents=True, exist_ok=True)
        with out.open("wb") as stream:
            xctrace(["export", "--input", str(trace), "--toc"], stream)
    return out


class Cell:
    """One resolved cell of an exported row. xctrace writes each distinct
    value once with an id and refers back to it with ref= afterwards."""
    __slots__ = ("tag", "text", "fmt", "kids")

    def __init__(self, tag, text, fmt, kids):
        self.tag, self.text, self.fmt, self.kids = tag, text, fmt, kids

    def find(self, tag):
        for kid in self.kids:
            if kid.tag == tag:
                return kid
            found = kid.find(tag)
            if found:
                return found
        return None

    def __bool__(self):
        return True


def rows(path):
    """Yield the rows of an exported table as dicts keyed by column mnemonic."""
    ids = {}
    columns = []

    def resolve(el):
        ref = el.get("ref")
        if ref is not None:
            return ids[ref]
        cell = Cell(el.tag, (el.text or "").strip(), el.get("fmt"),
                    [resolve(kid) for kid in el])
        if el.get("id") is not None:
            ids[el.get("id")] = cell
        return cell

    for event, el in ET.iterparse(path, events=("end",)):
        if el.tag == "mnemonic":
            columns.append(el.text)
        elif el.tag == "row":
            yield {name: resolve(kid) for name, kid in zip(columns, el)}
            el.clear()


def integer(cell):
    return int(cell.text) if cell is not None and cell.tag != "sentinel" and cell.text else None


# ---------------------------------------------------------------- frames

def timebase(trace, cache):
    """Scale from the presented-time column to nanoseconds.

    That column holds mach host time multiplied by the timebase once more
    than the trace's own nanosecond columns (125/3 on Apple silicon)."""
    for row in rows(export_table(trace, cache, "time-info")):
        fields = row["timebase-info"].kids
        numer, denom = int(fields[0].text), int(fields[1].text)
        return denom / numer
    return 1.0


def presented_frames(trace, cache):
    """{pid: {"name": str, "times": [trace-relative ns]}} of on-screen frames."""
    scale = timebase(trace, cache)
    raw = {}
    for row in rows(export_table(trace, cache, "ca-client-presented-handler")):
        shown = integer(row.get("at-time"))
        callback = integer(row.get("timestamp"))
        process = row.get("process")
        if not shown or callback is None or process is None:
            continue  # dropped drawable: never reached the screen
        pid = integer(process.find("pid"))
        entry = raw.setdefault(pid, {"name": process_name(process.fmt, pid), "pairs": []})
        entry["pairs"].append((shown * scale, callback))
    procs = {}
    for pid, entry in raw.items():
        # The presented handler fires shortly after the frame was shown; the
        # smallest callback-minus-shown gap maps host time onto trace time.
        offset = min(cb - shown for shown, cb in entry["pairs"])
        times = sorted(shown + offset for shown, _ in entry["pairs"])
        procs[pid] = {"name": entry["name"], "times": times, "source": "presentedTime"}
    return procs


def requested_frames(trace, cache):
    """Fallback: present requests (when the app asked, not when it showed)."""
    procs = {}
    for row in rows(export_table(trace, cache, "ca-client-present-request")):
        process = row.get("process")
        t = integer(row.get("timestamp"))
        if process is None or t is None:
            continue
        pid = integer(process.find("pid"))
        entry = procs.setdefault(pid, {"name": process_name(process.fmt, pid), "times": [],
                                       "source": "present request (not on-screen time)"})
        entry["times"].append(t)
    for entry in procs.values():
        entry["times"].sort()
    return procs


def process_name(fmt, pid):
    return re.sub(rf"\s*\({pid}\)$", "", fmt or "?")


def toc_info(trace, cache):
    root = ET.parse(export_toc(trace, cache)).getroot()
    run = root.find("run")
    info = {"start": run.findtext("info/summary/start-date"),
            "duration_s": float(run.findtext("info/summary/duration") or 0),
            "paths": {}}
    for proc in run.iter("process"):
        if proc.get("pid"):
            info["paths"][int(proc.get("pid"))] = proc.get("path") or ""
    return info


def choose(procs, wanted, paths):
    """Pick the processes matching --process (pid, exact name or substring)."""
    chosen = set()
    for want in wanted:
        hits = set()
        if want.isdigit() and int(want) in procs:
            hits = {int(want)}
        if not hits:
            hits = {pid for pid, p in procs.items() if p["name"] == want}
        if not hits:
            low = want.lower()
            hits = {pid for pid, p in procs.items()
                    if low in p["name"].lower() or low in paths.get(pid, "").lower()}
        chosen |= hits
    return chosen


def list_processes(procs, paths, stream=sys.stderr):
    print(f"{'pid':>7}  {'frames':>7}  name  (path)", file=stream)
    for pid, p in sorted(procs.items(), key=lambda kv: -len(kv[1]["times"])):
        print(f"{pid:>7}  {len(p['times']):>7}  {p['name']}  ({paths.get(pid, '')})", file=stream)


# ---------------------------------------------------------------- metrics

def percentile(values, fraction):
    """Linear interpolation between closest ranks (same as Recall)."""
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    low = int(position)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (position - low)


def low_fps(intervals_ms, fraction):
    """Frame rate over the slowest `fraction` of frame intervals."""
    slowest = sorted(intervals_ms, reverse=True)[:max(1, math.ceil(len(intervals_ms) * fraction))]
    return len(slowest) / (sum(slowest) / 1000)


def in_window(t, window, excluded):
    return window[0] <= t <= window[1] and not any(a <= t <= b for a, b in excluded)


def frame_metrics(times_ns, window, excluded):
    """Intervals whose both ends lie in the window and outside exclusions."""
    merged = []
    for t in times_ns:
        if merged and t - merged[-1] < SAME_VSYNC_NS:
            continue
        merged.append(t)
    intervals = []
    for a, b in zip(merged, merged[1:]):
        sa, sb = a / 1e9, b / 1e9
        if in_window(sa, window, excluded) and in_window(sb, window, excluded) \
                and not any(sa < x0 and x1 < sb for x0, x1 in excluded):
            intervals.append((b - a) / 1e6)
    if len(intervals) < 2:
        raise SystemExit("Fewer than two frame intervals in the measured window.")
    measured = sum(intervals) / 1000
    minutes = measured / 60
    return {
        "frames": len(intervals),
        "merged_same_vsync": len(times_ns) - len(merged),
        "measured_s": round(measured, 2),
        "average_fps": round(len(intervals) / measured, 2),
        "low_1pct_fps": round(low_fps(intervals, 0.01), 2),
        "low_0_1pct_fps": round(low_fps(intervals, 0.001), 2),
        "median_ms": round(statistics.median(intervals), 3),
        "p95_ms": round(percentile(intervals, 0.95), 3),
        "p99_ms": round(percentile(intervals, 0.99), 3),
        "worst_ms": round(max(intervals), 3),
        "stutters_50ms": sum(v > 50 for v in intervals),
        "stutters_50ms_per_min": round(sum(v > 50 for v in intervals) / minutes, 2),
        "stutters_100ms": sum(v > 100 for v in intervals),
    }


# ---------------------------------------------------------------- power

SAMPLE_RE = re.compile(r"\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\)")
POWER_RE = re.compile(r"^(CPU Power|GPU Power|ANE Power|Combined Power[^:]*):\s*([\d.]+)\s*mW", re.M)
GPU_RES_RE = re.compile(r"^GPU (?:HW )?active residency:\s*([\d.]+)%", re.M)


def parse_power(text):
    """Samples from powermetrics text output: [{time, cpu_mw, gpu_mw, combined_mw}]."""
    samples = []
    parts = SAMPLE_RE.split(text)
    # parts = [preamble, stamp, elapsed, body, stamp, elapsed, body, ...]
    for i in range(1, len(parts) - 2, 3):
        stamp, elapsed, body = parts[i], float(parts[i + 1]), parts[i + 2]
        try:
            end = datetime.datetime.strptime(stamp, "%a %b %d %H:%M:%S %Y %z").timestamp()
        except ValueError:
            end = None
        values = {}
        for key, mw in POWER_RE.findall(body):
            values[key.split()[0].lower() if not key.startswith("Combined") else "combined"] = float(mw)
        if "combined" not in values and "cpu" in values:
            values["combined"] = values["cpu"] + values.get("gpu", 0) + values.get("ane", 0)
        if "combined" not in values:
            continue
        residency = GPU_RES_RE.findall(body)
        samples.append({
            "mid": end - elapsed / 2000 if end is not None else None,
            "cpu_mw": values.get("cpu"), "gpu_mw": values.get("gpu"),
            "combined_mw": values["combined"],
            "gpu_active_pct": float(residency[0]) if residency else None,
        })
    return samples


def power_metrics(path, trace_start, window, excluded, fps):
    samples = parse_power(path.read_text(errors="replace"))
    if not samples:
        return {"note": f"no samples parsed from {path.name}"}
    aligned = "unaligned (all samples)"
    if trace_start is not None and all(s["mid"] is not None for s in samples):
        inside = [s for s in samples if in_window(s["mid"] - trace_start, window, excluded)]
        if not inside:
            note = f"{path.name} has no samples inside the measured window; power left out"
            print(f"warning: {note}", file=sys.stderr)
            return {"note": note}
        samples, aligned = inside, "samples inside the measured window"

    def avg(key):
        vals = [s[key] for s in samples if s[key] is not None]
        return round(statistics.fmean(vals)) if vals else None

    combined = [s["combined_mw"] for s in samples]
    result = {
        "samples": len(samples), "alignment": aligned,
        "combined_avg_mw": avg("combined_mw"),
        "combined_p95_mw": round(percentile(combined, 0.95)),
        "cpu_avg_mw": avg("cpu_mw"), "gpu_avg_mw": avg("gpu_mw"),
        "gpu_active_avg_pct": avg("gpu_active_pct"),
    }
    if fps:
        result["energy_per_frame_mj"] = round(result["combined_avg_mw"] / fps, 2)
    return result


# ---------------------------------------------------------------- GPU state

def overlap_ns(start, end, window, excluded):
    """Nanoseconds of [start, end] inside the window and outside exclusions."""
    lo, hi = max(start, window[0] * 1e9), min(end, window[1] * 1e9)
    if hi <= lo:
        return 0
    total = hi - lo
    for a, b in excluded:
        total -= max(0, min(hi, b * 1e9) - max(lo, a * 1e9))
    return max(0, total)


def duration_share(path, key, window, excluded):
    """Nanoseconds spent in each state value within the measured window."""
    totals = {}
    for row in rows(path):
        start, dur = integer(row.get("start")), integer(row.get("duration"))
        if start is None or dur is None:
            continue
        inside = overlap_ns(start, start + dur, window, excluded)
        if inside:
            state = row[key].text if row.get(key) else "?"
            totals[state] = totals.get(state, 0) + inside
    return totals


GPU_TABLES = ["metal-gpu-state-intervals", "gpu-performance-state-intervals",
              "device-thermal-state-intervals"]


def gpu_metrics(trace, cache, window, excluded):
    span_ns = (window[1] - window[0] - sum(b - a for a, b in excluded)) * 1e9
    out = {}
    states = duration_share(export_table(trace, cache, "metal-gpu-state-intervals"),
                            "state", window, excluded)
    if states:
        out["gpu_busy_pct"] = round(100 * states.get("Active", 0) / span_ns, 1)
    perf = duration_share(export_table(trace, cache, "gpu-performance-state-intervals"),
                          "gpu-performance-state", window, excluded)
    total = sum(perf.values())
    if total:
        out["gpu_perf_state_share_pct"] = {k: round(100 * v / total, 1)
                                           for k, v in sorted(perf.items(), key=lambda kv: -kv[1])}
    thermal = duration_share(export_table(trace, cache, "device-thermal-state-intervals"),
                             "thermal-state", window, excluded)
    total = sum(thermal.values())
    if total:
        out["thermal_state_share_pct"] = {k: round(100 * v / total, 1) for k, v in thermal.items()}
    return out


# ---------------------------------------------------------------- output

ROWS = [
    # (label, key, format)
    ("Average FPS", "average_fps", "{:.1f}"),
    ("1% low FPS", "low_1pct_fps", "{:.1f}"),
    ("0.1% low FPS", "low_0_1pct_fps", "{:.1f}"),
    ("Median frame time", "median_ms", "{:.2f} ms"),
    ("95th-percentile frame time", "p95_ms", "{:.2f} ms"),
    ("99th-percentile frame time", "p99_ms", "{:.2f} ms"),
    ("Stutters over 50 ms", "stutters_50ms_per_min", "{:.1f} per minute"),
    ("Stutters over 100 ms", "stutters_100ms", "{:d}"),
    ("Gameplay measured", "measured_s", "{:.0f} s"),
    ("Average power (CPU + GPU)", "power.combined_avg_mw", "{:.1f} W", 1e-3),
    ("95th-percentile power", "power.combined_p95_mw", "{:.1f} W", 1e-3),
    ("CPU power", "power.cpu_avg_mw", "{:.1f} W", 1e-3),
    ("GPU power", "power.gpu_avg_mw", "{:.1f} W", 1e-3),
    ("Energy per frame", "power.energy_per_frame_mj", "{:.1f} mJ"),
]


def lookup(metrics, key):
    value = metrics
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def fmt_value(spec, value):
    fmt, scale = spec[2], (spec[3] if len(spec) > 3 else 1)
    return fmt.format(value * scale if scale != 1 else value)


def markdown(metrics, name):
    lines = [f"| | {name} |", "|---|---:|"]
    for spec in ROWS:
        value = lookup(metrics, spec[1])
        if value is not None:
            lines.append(f"| {spec[0]} | {fmt_value(spec, value)} |")
    return "\n".join(lines)


def parse_range(text):
    a, _, b = text.partition("-")
    return float(a), float(b)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("label")
    ap.add_argument("--process", action="append", default=[],
                    help="process name, pid, or name/path substring (repeatable)")
    ap.add_argument("--trim-start", type=float, default=0, help="seconds dropped from the start")
    ap.add_argument("--trim-end", type=float, default=0, help="seconds dropped from the end")
    ap.add_argument("--exclude", action="append", default=[], type=parse_range,
                    metavar="A-B", help="also drop trace seconds A to B (repeatable)")
    ap.add_argument("--name", help="column name in the printed table (default: label)")
    ap.add_argument("--no-gpu", action="store_true", help="skip GPU state tables (faster)")
    args = ap.parse_args()

    folder = BENCH / args.label
    trace = folder / "trace.trace"
    if not trace.exists():
        raise SystemExit(f"No trace at {trace}")
    cache = folder / "export"
    prefetch(trace, cache, ["time-info", "ca-client-presented-handler"] + ([] if args.no_gpu else GPU_TABLES))
    toc = toc_info(trace, cache)

    procs = presented_frames(trace, cache)
    if not procs:
        print("No presentedTime data in this trace; falling back to present requests.", file=sys.stderr)
        procs = requested_frames(trace, cache)
    if not procs:
        raise SystemExit("No process presented any Metal frames during the trace.")
    if not args.process:
        print("Processes that presented frames (pass one with --process):", file=sys.stderr)
        list_processes(procs, toc["paths"])
        sys.exit(2)
    chosen = choose(procs, args.process, toc["paths"])
    if not chosen:
        print(f"No presenting process matches {args.process}. Candidates:", file=sys.stderr)
        list_processes(procs, toc["paths"])
        sys.exit(2)
    if len(chosen) > 1:
        print(f"{args.process} matches several presenting processes; pass a pid:", file=sys.stderr)
        list_processes({pid: procs[pid] for pid in chosen}, toc["paths"])
        sys.exit(2)
    pid = chosen.pop()
    proc = procs[pid]

    duration = toc["duration_s"] or proc["times"][-1] / 1e9
    window = (args.trim_start, duration - args.trim_end)
    if window[1] <= window[0]:
        raise SystemExit("The trims leave no time to measure.")
    metrics = {
        "label": args.label,
        "process": {"pid": pid, "name": proc["name"], "path": toc["paths"].get(pid, "")},
        "frame_source": proc["source"],
        "trace_start": toc["start"],
        "trace_duration_s": round(duration, 3),
        "window_s": [round(w, 3) for w in window],
        "excluded_s": args.exclude,
    }
    metrics.update(frame_metrics(proc["times"], window, args.exclude))

    trace_start = None
    if toc["start"]:
        trace_start = datetime.datetime.fromisoformat(toc["start"]).timestamp()
    power_file = folder / "power.txt"
    if power_file.exists():
        metrics["power"] = power_metrics(power_file, trace_start, window, args.exclude,
                                         metrics["average_fps"])
    if not args.no_gpu:
        metrics["gpu"] = gpu_metrics(trace, cache, window, args.exclude)
    capture = folder / "capture.json"
    if capture.exists():
        metrics["capture"] = json.loads(capture.read_text())

    (folder / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    print(f"{proc['name']} (pid {pid}), {metrics['frames']} frame intervals, "
          f"window {window[0]:.1f}-{window[1]:.1f} s of {duration:.1f} s; source: {proc['source']}")
    print()
    print(markdown(metrics, args.name or args.label))
    gpu = metrics.get("gpu", {})
    if gpu:
        print()
        print("System-wide (all processes): "
              + "; ".join(f"{k} {v}" for k, v in gpu.items()))
    print(f"\nWrote {folder / 'metrics.json'}")


if __name__ == "__main__":
    main()
