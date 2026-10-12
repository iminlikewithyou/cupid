# Benchmark tools

Frame-time and power comparison of Heartopia under Heartport and under other
routes (CrossOver first), in the format of Recall's
[performance page](https://github.com/AsherJN/recall/blob/main/docs/PERFORMANCE.md),
with power as an extra axis.

| Script | What it does |
|---|---|
| `capture.sh [--power] <label> <seconds>` | Records an Instruments *Metal System Trace* of the whole system into `bench/<label>/trace.trace`. No sudo. 3-second countdown first; Ctrl-C ends early and still saves. |
| `analyze.py <label> --process <name\|pid\|substring>` | Pulls every frame that process put on screen out of the trace, computes the metrics, writes `bench/<label>/metrics.json` and prints a Markdown column. |
| `compare.py <label-a> <label-b> --names A B` | Prints the side-by-side table with the "B vs. A" column. `--setup` adds a draft Setup table. |
| `selftest.sh` | Builds a small 60 Hz Metal test app that stalls 120 ms every 2 s, captures 10 s, and checks the numbers. Takes 1 to 2 minutes and shows a window. |

`bench/` at the repo root holds the captures and ignores itself in git. A
2-minute trace of a game is roughly 1 to 2 GB; once `metrics.json` exists the
trace can be deleted.

## Running a Heartport vs. CrossOver comparison

1. **Pick one scenario** you can repeat, about 2 minutes of real play: for
   example a fixed walk around town with the camera turning. Same save, same
   time of day in game if possible.
2. **Use identical in-game settings in both apps**: window mode, resolution,
   quality preset, V-Sync, frame rate limit. Note them for the Setup table.
   Same Mac, same display, same power source (on the adapter), other apps
   closed, Low Power Mode off.
3. **CrossOver run.** Start the game in CrossOver and stand at the scenario's
   start. In a terminal:

   ```sh
   scripts/bench/capture.sh --power crossover-town 140
   ```

   It prints a `sudo powermetrics ...` command; run it in a second terminal,
   go back and press Return, switch to the game during the countdown, and
   play the scenario until it says STOPPED. Then quit the game.
4. **Heartport run.** Same again in Heartport with label `heartport-town`.
5. **Find the game process** (Wine processes are all called `wine` or
   `wine64-preloader`, so names alone are ambiguous):

   ```sh
   scripts/bench/analyze.py crossover-town
   ```

   lists every process that presented frames, with counts and paths. The game
   is the one with thousands of frames. Pass its pid, or a substring of its
   path that tells the apps apart.
6. **Analyze both**, trimming the seconds of menu or loading at either end
   (and `--exclude A-B` for a loading screen in the middle; times are
   seconds from the start of the trace):

   ```sh
   scripts/bench/analyze.py crossover-town --process <pid> --trim-start 10 --trim-end 5 --name CrossOver
   scripts/bench/analyze.py heartport-town --process <pid> --trim-start 10 --trim-end 5 --name Heartport
   ```

7. **Compare** (baseline first):

   ```sh
   scripts/bench/compare.py crossover-town heartport-town --names "CrossOver" "Heartport" --setup
   ```

   Paste the output into the README under a heading for the scenario. Add the
   game settings row to the Setup table by hand.

## What is measured

- **Frames** come from the trace's `ca-client-presented-handler` table: the
  `presentedTime` Core Animation reports for each drawable of the chosen
  process, i.e. when the frame reached the display. Recall's page uses the
  same source. Drawables that never reached the screen are left out, and two
  presentations in the same refresh count as one frame. (The WindowServer
  table `displayed-surfaces-interval` stays empty without root, so it is not
  used.)
- **Average FPS** is frames divided by measured time. **1% and 0.1% low FPS**
  are the frame rate over the slowest 1% and 0.1% of frame intervals.
  **Frame time** percentiles are of the gaps between consecutive frames.
  **Stutters** are gaps over 50 ms (reported per minute) and over 100 ms
  (a count). **Gameplay measured** is the summed duration of the intervals.
- **Power** comes from `powermetrics` samples (1 s) that fall inside the
  measured window: the average and 95th percentile of *Combined Power*
  (CPU + GPU + ANE, as powermetrics reports it), the CPU and GPU averages, and
  energy per frame (average power divided by average FPS), which compares
  efficiency when frame rates differ. Without `power.txt` these rows are left
  out.
- **System-wide extras** in `metrics.json`: GPU busy share, GPU performance
  state share, and thermal state over the window. They cover every process,
  not only the game.

## Caveats

- **Frame time is not input latency.** These numbers say how smoothly frames
  reach the screen, not how long a mouse movement takes to show up. Measure
  that separately (see docs/PLAN.md, Measurement).
- One run per app per scenario is noisy; repeat a run if the two runs of the
  same app would disagree by more than the difference you are reporting.
- Instruments itself costs a little CPU while recording, the same for both
  apps.
- A frame-rate cap or V-Sync turns the average FPS into the cap; compare the
  lows, percentiles, stutters and power in that case.
