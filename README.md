# Cupid

Cupid plays **Heartopia** (XD's Windows release, distributed through TapTap) on Apple
silicon Macs. It is a single-game launcher built on the Wine + Rosetta 2 + DXMT (Direct3D 11 on
Metal) runtime from [Recall](https://github.com/AsherJN/recall) 1.3.0. It sets up a private Windows
environment, installs the TapTap client, lets you download the game through it, and from then on
starts Heartopia directly with tuned settings (Game Mode, MetalFX upscaling to the full panel,
High quality preset at 60 fps). It does not use Steam, CrossOver or a Windows license.

## Requirements

- A Mac with Apple silicon (M1 or later).
- macOS 26 (Tahoe) or later.
- Rosetta 2 (Cupid tells you if it is missing and links Apple's instructions).
- About 17 GB of free space: 1.5 GB for the runtime, 13 GB for Heartopia, plus caches.
- A TapTap account (sign-in inside the TapTap client) and an XD account for the game.

## First run

1. Open **Cupid.app**. If Rosetta is missing, install it (Apple's instructions, or
   `softwareupdate --install-rosetta --agree-to-license` in Terminal) and press Check Again.
2. Press **Set Up**. Cupid installs its runtime and creates the Windows environment
   (a few minutes; progress is shown).
3. Press **Launch Installer**. In the small "Welcome to TapTap Setup" window, click the circle
   next to "I have read and agree to the above terms" (this is your acceptance of TapTap's
   terms), then **Install Now**. Back in Cupid, press **I've Installed It**.
4. Press **Launch TapTap to Download Heartopia**. Sign in to TapTap if it asks, find Heartopia
   and click "Download & Install" (about 13 GB). Cupid shows the progress. Keep TapTap open
   until it finishes.
5. Press **Play**. TapTap is closed and Heartopia starts. The first sign-in opens your web
   browser; Chrome may ask to allow access to the local network so the sign-in can return to the
   game.

From then on, opening Cupid starts Heartopia straight away and shows no window unless
something fails. Opening it while the game runs offers **Show Heartopia**.

The **Cupid** menu has Settings (Metal performance HUD), Play, Update Game (opens TapTap for
client and game updates), Reset Graphics (restores Cupid's graphics defaults; not while the
game runs), Show Logs, Repair (reinstalls the runtime, re-checks the Windows environment and every
game file), and Uninstall (moves the data folder to the Trash; the app stays).

Data lives in `~/Library/Application Support/Cupid` (runtime, Wine prefix with TapTap and the
game, shader caches, logs, `state.json`).

## Command line

The app bundles the same engine as a CLI at `Cupid.app/Contents/Helpers/cupid`:
`setup`, `install-game`, `play`, `stop`, `status [--verify] [--json]`, `update`, `logs`,
`reset-graphics`, `uninstall`, `verify-runtime`. Run it with `--help` for options.
`CUPID_DATA_ROOT` points either one at another data folder.

## Building

```
scripts/fetch-runtime.sh      # Recall 1.3.0 DMG -> Resources/runtime/runtime.tar.gz (sha256-pinned)
swift build && swift test
scripts/build-app.sh [--dmg]  # build/Cupid.app, ad hoc signed; --dmg adds build/Cupid-<version>.dmg
```

Requires Xcode 26 (Swift 6). No third-party Swift packages.

## Known gaps

- A blank dialog with two buttons appears at every launch before the menu; the blue (right)
  button dismisses it (probably embedded web content this Wine cannot render).
- Cutscene videos are black (H.264 through Media Foundation has no decoder in this Wine).
- On notched MacBooks the game renders 1728x1080 inside the 1728x1117 window, leaving thin bars
  at the top and bottom.
- The mouse cursor is drawn at 1x (slightly soft) because Retina mode is off for this game.
- The TapTap installer has no silent mode under Wine, so its two clicks are yours.
- The 3840x2160@60 resolution entry Cupid seeds is inferred from the list order; if the
  in-game label differs, pick 3840x2160 @ 60 in the game's settings.

## Licenses

Cupid's own code is Apache-2.0 (`LICENSE`). The bundled runtime and its components keep their
own licenses; see [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md). TapTap and Heartopia are downloaded
from their publishers and are not part of Cupid.
