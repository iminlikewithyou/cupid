# Cupid

Cupid is a Mac app that plays **Heartopia**, XD's Windows game, on Apple silicon. Heartopia is
distributed through TapTap's PC client, and Cupid installs that client and lets you download the
game through it. You do not need Steam, CrossOver, or a Windows licence.

Cupid sets up a private Windows environment with its own build of Wine and DXMT (Direct3D 11 on
Metal), installs TapTap, and from then on starts Heartopia directly when you open it.

## Requirements

- A Mac with Apple silicon.
- macOS 26 or later.
- Rosetta 2. Cupid checks for it and links Apple's instructions if it is missing.
- About 17 GB of free space: about 1.5 GB for the runtime, about 13 GB for Heartopia, plus
  caches.
- A TapTap account (for the TapTap client) and an XD account (for the game).

## First run

1. Open **Cupid.app** and press **Get Started**.
2. If Rosetta 2 is missing, install it with Apple's instructions (**Open Apple's
   Instructions**) or with `softwareupdate --install-rosetta --agree-to-license` in Terminal,
   then press **Check Again**.
3. Press **Set Up**. Cupid installs the game runtime and creates the Windows environment.
   Progress is shown in the window.
4. Press **Launch Installer**. TapTap's installer opens in its own window, "Welcome to TapTap
   Setup". Pick your language if it asks, click the circle next to "I have read and agree to
   the above terms" (this is your acceptance of TapTap's terms), click **Install Now**, and
   press **Launch** when it says the installation is complete. Then press **I've Installed It**
   in Cupid.
5. In TapTap, sign in if it asks, find Heartopia, and click **Download & Install**. In the
   Install Path dialog keep the defaults and click **Start Install**. Leave TapTap open until
   the download finishes; Cupid shows the progress. If TapTap is closed, press **Open TapTap**;
   if its window is blank, press **Restart TapTap**.
6. When the download is done, Cupid closes TapTap and shows "Cupid is ready". Press **Play**.

The first time you sign in to Heartopia, the game opens your web browser to sign in to your
XD account. Chrome may ask to allow access to the local network so the sign-in can return to
the game.

From then on, opening Cupid starts Heartopia directly and shows no window unless something
goes wrong. Hold Option while opening Cupid to show its window instead of starting the game.
When you quit Heartopia, Cupid quits too (unless its window is open). If the game stops
unexpectedly, Cupid shows its window with the error and a way to the logs.

## Settings

Open Settings from the Cupid menu.

- **Fullscreen** decides how Heartopia's fullscreen window behaves:
  - **Fill the screen, show notifications** (the default): covers the whole screen, including
    beside the camera, and lets notification banners appear over the game. The menu bar and
    Dock appear when the pointer reaches the edge.
  - **Fill the screen**: covers the whole screen and keeps notifications hidden while you play.
  - **Own Space**: puts Heartopia in its own Space, like a Mac game, so notifications, Mission
    Control, and app switching work normally. The strip beside the camera stays black.
- **Performance overlay** shows frame rate, GPU time, and Game Mode status in a corner of the
  game.
- **Data folder** shows where Cupid keeps everything, with a Show in Finder button.

Changes take effect the next time Heartopia starts.

## The Cupid menu

- **About Cupid**: the installed Heartopia and runtime versions, credits, and **Show
  Licences**, which reveals the bundled licence files.
- **Play**: starts Heartopia.
- **Update Game**: opens TapTap so it can update its client and Heartopia. Press Play when it
  is done.
- **Reset Graphics**: puts Cupid's recommended graphics settings back, replacing changes made
  in the game.
- **Show Logs**: opens the logs folder.
- **Repair**: reinstalls the runtime, re-checks the Windows environment, and checks every
  Heartopia file. Game data and settings are kept.
- **Uninstall**: moves the data folder (runtime, Windows environment with TapTap and Heartopia,
  caches, and logs) to the Trash. Cupid itself stays; open it again to set up from scratch.

Cupid's data lives in `~/Library/Application Support/Cupid`.

## Runtime

Cupid ships its own runtime, built from pinned sources by the scripts in
[`scripts/runtime`](scripts/runtime/README.md):

- **Wine**, built from CodeWeavers' CrossOver sources (the open source part, not the CrossOver
  app), with Recall's Wine patches and Cupid's own.
- **DXMT**, which runs Direct3D 11 on Metal, with Recall's DXMT patches.
- **GStreamer** and **FFmpeg** (LGPL builds), which Wine's Media Foundation uses to decode the
  game's videos.
- Apple's Direct3D shared library (`libd3dshared.dylib`) and its support files, as shipped by
  Recall.

The build pipeline and the Wine and DXMT patches in `patches/recall` come from
[Recall](https://github.com/AsherJN/recall) by AsherJN (Apache License 2.0), adapted for
Cupid. Recall's NOTICE is kept in `scripts/runtime/RECALL-NOTICE` and in the app's licences.

Cupid's own Wine patches ([`patches/cupid`](patches/cupid/README.md)):

- **Video textures**: Wine's Media Foundation source reader now hands out shareable textures,
  as Windows does. Unity's video player needs them, so Heartopia's logo video and cutscenes
  play instead of staying black.
- **DispatcherQueue**: a minimal `Windows.System.DispatcherQueue` in CoreMessaging, which the
  game asks for right after its logo.
- **Dock identity**: the Dock and Cmd-Tab show "Heartopia" with the game's icon instead of
  `xdt.exe` and its oversized icon.
- **Fullscreen modes**: the Mac driver can put a borderless fullscreen window in its own Space,
  or keep it at the normal window level so notifications show over it. These are the Own Space
  and Fill the screen, show notifications settings.

The Mac driver patches do nothing unless Cupid sets their environment variables. On first run
Cupid extracts the runtime, verifies every file against its manifest, and adds one bundle,
`lib/wine/game-mode/xdt.app`, so macOS Game Mode engages for the game. It does not modify the
runtime's other files.

Licences for every bundled component are listed in
[docs/THIRD_PARTY.md](docs/THIRD_PARTY.md). TapTap and Heartopia are downloaded from their
publishers and are not part of Cupid.

## Building

Requires Xcode 26 (Swift 6). There are no third-party Swift packages.

```sh
swift build && swift test
scripts/build-app.sh [--dmg]   # build/Cupid.app, ad hoc signed; --dmg adds build/Cupid-<version>.dmg
```

`build-app.sh` needs the runtime archive in `Resources/runtime/` (not in git):

- **Cupid's runtime** (what the app is made for): build it with `scripts/runtime` (see its
  [README](scripts/runtime/README.md)), then copy `runtime.tar.gz` and `runtime-archive.json`
  from `artifacts/<version>/` into `Resources/runtime/`. The script checks the archive against
  the sha256 in `runtime-archive.json`.
- **Recall's runtime**: `scripts/fetch-runtime.sh` downloads Recall 1.3.0's DMG and extracts
  its prebuilt runtime, both sha256-pinned. An app built with it starts the game, but has none
  of Cupid's patches, GStreamer, or FFmpeg: no video, no fullscreen modes, and the Dock shows
  the exe's name.

`build-app.sh --identity "Developer ID Application: ..."` signs with a real identity instead of
ad hoc.

## Command line

The app bundles the same engine as a command-line tool at
`Cupid.app/Contents/Helpers/cupid`:

| Command | What it does |
|---|---|
| `setup [--step runtime\|prefix\|taptap\|all]` | Installs what is missing: runtime, Windows environment, TapTap |
| `install-game` | Opens TapTap and follows the game download |
| `play [--hud\|--no-hud] [--fullscreen notifications\|fill\|space]` | Starts the game |
| `stop` | Ends every Wine process |
| `status [--json] [--verify]` | Reports the runtime, Windows environment, TapTap, game, and session |
| `update` | Opens TapTap to update the game |
| `logs [--lines N] [--name FILE] [--path]` | Shows the logs |
| `reset-graphics` | Re-applies the seeded graphics settings |
| `uninstall` | Moves the data folder to the Trash |
| `verify-runtime [--archive PATH \| DIR]` | Verifies a runtime folder or archive |

Run `cupid --help` for every option. `--data DIR` points the tool at another data folder; the
`CUPID_DATA_ROOT` environment variable does the same for both the tool and the app.

## Status

Working:

- The full setup: runtime, Windows environment, TapTap install, and the game download.
- Playing, with macOS Game Mode, the browser sign-in, and the game's agreement dialog.
- The logo video and cutscenes.
- All three fullscreen modes.
- Updates: Heartopia's own updates go through TapTap, which **Update Game** opens.

Not done:

- A signed and notarised release. Builds are ad hoc signed, so macOS does not open a
  downloaded build without your approval.
- Benchmarks.

Known limitations:

- TapTap's installer has no silent mode under Wine, so its clicks are yours.
- The mouse cursor is drawn at 1x, slightly soft, because Retina mode is off for the game.

## Licence

Cupid's own code is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). The bundled
runtime and its components keep their own licences; see
[docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).
