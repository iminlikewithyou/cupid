# Phase 2 brief: Cupid core, CLI and app

Read `docs/PLAN.md` for the design and `docs/SPIKE.md` for what the spike proved on
2026-10-11. This document is the implementation brief. Everything below was verified on
the owner's M2 Max, macOS 26.6.2, unless marked "assumed".

## Outcome

A signed macOS app, `Cupid.app`, that on first run installs Recall's runtime,
builds a Wine prefix, installs the TapTap Global client, downloads Heartopia, and from
then on launches the game directly with the settings below. Its window shows only
setup states. Nothing in it touches Steam.

## Layout

```
Cupid/                                  Swift package + app sources
├── Package.swift
├── Sources/CupidCore/                  all logic, no UI, testable
├── Sources/cupid/                      CLI: setup | play | status | stop | update | uninstall | logs
├── App/                                   AppKit/SwiftUI shell (thin)
├── Resources/
│   ├── runtime/                           NOT in git: fetched by scripts/fetch-runtime.sh
│   ├── config/dxmt.conf                   [xdt.exe] profile template
│   └── Licenses/
├── scripts/
│   ├── fetch-runtime.sh                   Recall DMG -> runtime.tar.gz, sha256-pinned, manifest-verified
│   ├── make-game-mode-app.py              from spike/game_mode_app.py
│   └── build-app.sh                       bundle, codesign (ad hoc or Developer ID), DMG
└── docs/
```

Data root: `~/Library/Application Support/Cupid/` with `runtime/<version>/`,
`prefix/`, `cache/shaders`, `cache/pipelines`, `home/`, `tmp/`, `logs/`, `downloads/`,
`dxmt.conf`, `state.json`. The spike already created this layout; the product must
adopt an existing one rather than rebuild it.

## Runtime (verified)

- Source: Recall 1.3.0 DMG, `https://github.com/AsherJN/recall/releases/download/v1.3.0/Recall-1.3.0.dmg`.
  Mount read-only, copy `Recall.app/Contents/Resources/runtime.tar.gz`
  (sha256 `66ce2eabdbe14572d4bcb485321570bdd1128647aa64f6111642f9f073f92c34`), extract,
  verify every entry of `runtime.json` (sha256 and bytes), refuse unlisted files. Never
  modify or re-sign any Mach-O in it. Copy with `ditto`.
- Add `lib/wine/game-mode/xdt.app` generated from the runtime's own loader by
  `make-game-mode-app.py` (identifier `app.cupid.heartopia`, name Heartopia,
  category `public.app-category.simulation-games`, ad hoc signed until a Developer ID
  exists). `codesign --verify --strict --deep` must pass.
  Bundle version 2 (`CupidBundleVersion`) adds `CFBundleDisplayName` Heartopia and a
  Dock icon, `Contents/Resources/Heartopia.icns`: the largest icon in xdt.exe's PE resources
  (RT_GROUP_ICON/RT_ICON; 256x256 is PNG), drawn on the macOS icon grid (824/1024 rounded
  square, ~10% margins), or Cupid's own icon before the game is installed. An older
  bundle, or one made before xdt.exe existed, is regenerated at setup or before the next
  launch (`GameModeBundle.staleReason`). Unverified: winemac may replace the Dock name and
  icon at runtime.
- Licenses: ship Recall's `licenses/` tree plus Recall's NOTICE and Apache-2.0 text, as
  MacGames does. Corresponding sources are Recall's published ones; link them in
  `docs/THIRD_PARTY.md`.

## Prefix setup (verified)

1. `wine wineboot.exe -u -r`, then `wineserver -w`.
2. `wine winecfg -v win10`.
3. Registry seeds (`wine reg.exe add`):
   - `HKCU\Software\Wine\Mac Driver` `RetinaMode` = `N`. (Retina mode stays off for
     everything: the TapTap installer ignores clicks and shows no cursor at `Y`, the
     Electron launcher is sized wrong at `Y`, and the game's full-panel mode needs `N`.)
   - `HKCU\Software\xd\Heartopia` game prefs, all REG_DWORD, exact hashed names:

     | Name | Value |
     |---|---|
     | `UnityGraphicsQuality_h1669003810` | 1 (High) |
     | `QualityLevel_h4026849054` | 1 |
     | `NewUserGraphicsQualityString_h2322609765` | 1 (stops the first-run auto-pick of Ultra) |
     | `ORIGIN_QUALITY_h3319388771` | 1 |
     | `RenderScaleString_h868707778` | 2 (High) |
     | `ShaderQualityString_h3156345780` | 1 (Medium) |
     | `FXAAEnabledString_h219820651` | 0 |
     | `BloomEnabledString_h1769754614` | 1 |
     | `PcUICanvasScale_h3623448666` | 1 (85%) |
     | `SoundVolumeString_h3855669083` | 25 (music 25%) |
     | `SoundEffectVolume_h2094452281` | 50 (effects 50%) |
     | `Screenmanager Fullscreen mode_h3630240806` | 1 |

     No resolution or screen-size values (`PcResolutionLevelString`,
     `LastPcResolutionLevelStringV1`, `Screenmanager Resolution Use Native/Width/Height`):
     with them the first launch asked "Resolution switched to 3840x2160@120 FPS. Apply?"
     (fresh-install runs 1 and 2, docs/PLAN.md); without them the game picks the desktop size
     itself, as the spike's unseeded first launch did. To verify on the next fresh run. The
     frame rate is capped at 60 in `dxmt.conf` (`d3d11.preferredMaxFrameRate`) for power.
   - Seeds are applied only when the key or value is absent, so the player's later
     in-game changes are kept. A "Reset graphics" action re-applies them.
4. Replace any symlinks in `drive_c/users/*/` with empty directories (this Wine made none,
   keep the step).
5. Link macOS's Arial files (`/System/Library/Fonts/Supplemental/Arial.ttf`, `Arial Bold`, `Arial Italic`, `Arial Bold Italic`, `Arial Unicode`) into `drive_c/windows/Fonts` when missing and present on the Mac (`WindowsFonts.all`); Unity's built-in Arial is found only there, and without it the XD SDK agreement dialog has no text. `status` lists missing ones.

## Launch contract (verified)

Environment for every Wine process, after stripping inherited `CX_`, `WINE*`, `DYLD_`,
`ROSETTA_`, `MTL_`, `DXMT_`, `GST_`:

```
WINEPREFIX=<data>/prefix  WINESERVER=<rt>/bin/wineserver  WINELOADER=<rt>/bin/wine
WINEDLLPATH=<rt>/lib/wine  WINEARCH=win64  WINEDEBUG=-all
WINEMSYNC=1  WINEESYNC=0  ROSETTA_ADVERTISE_AVX=1  WINE_SIMULATE_WRITECOPY=1
CX_ACTIVE_GRAPHICS_BACKEND=dxmt  CX_GRAPHICS_BACKEND=dxmt
CX_APPLEGPTK_LIBD3DSHARED_PATH=<rt>/lib/external/libd3dshared.dylib
WINEDLLOVERRIDES=d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=
DXMT_CONFIG_FILE=Z:\<data>\dxmt.conf (backslashes)
DXMT_SHADER_CACHE_PATH=<data>/cache/shaders  DXMT_PIPELINE_CACHE_PATH=<data>/cache/pipelines
DXMT_PIPELINE_CACHE_NAMESPACE=heartopia-v1  DXMT_PIPELINE_CACHE_PREWARM_MS=10000
DXMT_PIPELINE_CACHE_PREWARM_LIMIT=128  DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE=1
DXMT_PREPARE_SHADERS=1  DXMT_USE_DEFAULT_METAL_CACHE=1
DXMT_CANVAS_DRAWABLES=3  DXMT_CANVAS_OVERLAY=0
DXMT_METALFX_SPATIAL_SWAPCHAIN=1
DXMT_LOG_LEVEL=error  DXMT_LOG_PATH=none
GST_PLUGIN_SYSTEM_PATH_1_0=<rt>/lib/gstreamer-1.0  GST_PLUGIN_PATH_1_0=<rt>/lib/gstreamer-1.0
GST_REGISTRY_1_0=<data>/cache/gstreamer-registry.bin  GST_REGISTRY_FORK=no  (GST_DEBUG unset)
WINEMAC_MOUSELOOK=xdt.exe  WINE_GAME_MODE=xdt.exe
WINE_NO_DOCK_ICON=TapTapGlobal.exe
WINEMAC_APP_NAME=Heartopia
WINEMAC_NATIVE_FULLSCREEN=xdt.exe  (only with Fullscreen set to "Own Space")
WINEMAC_FULLSCREEN_NORMAL_LEVEL=xdt.exe  (with Fullscreen set to "Fill the screen, show notifications", the default)
WINEMAC_APP_ICON=<rt>/lib/wine/game-mode/xdt.app/Contents/Resources/Heartopia.icns  (only if it exists)
HOME=<data>/home  USER=player  TMPDIR=<data>/tmp
```

The `WINEMAC_APP_*`, `WINEMAC_NATIVE_FULLSCREEN`, and `WINEMAC_FULLSCREEN_NORMAL_LEVEL` variables are read by Cupid's own Mac
driver patches (`patches/cupid/`, runtime `cupid-20261012.4` on) and ignored by older
runtimes: the Dock and Cmd-Tab name the game "Heartopia" with the Game Mode bundle's icon, and
the game's fullscreen window (borderless, covering the screen) gets its own fullscreen Space, or
stays covering the panel at the normal window level. `GameModeBundle` writes the icon when it creates `xdt.app`. The name and
icon are set for every Wine process; only a process that shows a Dock icon is renamed (TapTap's
launcher has none, `WINE_NO_DOCK_ICON`). The fullscreen variables come from one three-way setting
(state.json `fullscreenMode`, Settings "Fullscreen", `play --fullscreen notifications|fill|space`
for one launch; a missing `fullscreenMode` reads as `fillNotifications`, except an older
state.json's `nativeFullscreen: true`, which reads as "space"):
- `fillNotifications` (default, `WINEMAC_FULLSCREEN_NORMAL_LEVEL`): the whole panel at the normal
  window level, beside the notch too, so notification banners appear over the game.
- `fill` (neither variable): the game covers the whole panel, beside the notch too, and floats
  above notification banners.
- `space` (`WINEMAC_NATIVE_FULLSCREEN`): its own fullscreen Space; the game gets 1728x1084 with a
  black strip beside the notch, but notifications, Mission Control, and Cmd-Tab behave as for a
  Mac game.

`dxmt.conf` (rewritten before each launch whenever it differs from the template, so a
changed template reaches existing installs on their next play):

```
[xdt.exe]
d3d11.releaseShaderIR = True
d3d11.preferredMaxFrameRate = 60
d3d11.shaderCompilerThreads = 8
d3d11.shaderCompilerNormalPriority = True
d3d11.metalSpatialUpscaleFactor = 2.0
dxgi.maxFrameLatency = 1
dxgi.presentPacing = True
dxgi.presentPacingMode = 3
dxgi.presentPacingTargetUs = 1000
dxgi.sharpPresentation = True
```

(`dxgi.nativeFullscreen` and the canvas sizes are dropped: this engine never enters
exclusive fullscreen, so Recall's canvas never engages.)

Game launch, from cwd `C:\TapTapGlobal\Apps\231364`:

```
wine start.exe /exec C:\TapTapGlobal\Apps\231364\xdt.exe
```

`start.exe` matters: Game Mode only engages when the game is created through
CreateProcess so Recall's ntdll hook can exec it from `xdt.app`. Verified by the HUD.

Optional: Metal HUD via `MTL_HUD_ENABLED=1 MTL_HUD_DISABLE_MENU_BAR=1
MTL_HUD_ELEMENTS=device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders`.

Stop: `wineserver -k` then `wineserver -w`.

## TapTap install and game download (verified, with one open problem)

- Installer: `https://d.tap.io/pc/latest/coop-pc?jid=id231364`, a 302 to a signed
  `pc-packaging.tapimg.net` URL; file `TapTap_Global_PC_Setup_0.3.0.1000_coop-pc-id231364-.exe`,
  78,685,088 bytes, sha256 `e5d931e2e8afa486e47f5844bed1be092367d8dc1f8aab1b99526d9e0621bc38`.
  Pin size and hash; on mismatch, show "TapTap updated its installer" and allow proceeding
  after the user confirms.
- It is NSIS 3.10 with a custom skin. **No silent mode works** (`/S`, `/S=M`, `/D=F /S=M`
  all exit without installing). The welcome window needs two clicks: the "I have read and
  agree" circle, then Install Now. Phase 2 ships this visible, with on-screen instructions.
  Automating it is a stretch goal: a Windows helper (mingw) that posts the clicks to the
  window, or unpacking the NSIS payload with 7-Zip and running the launcher directly.
- Installed launcher: `C:\Program Files\TapTapGlobal\TapTapGlobal.exe`, Electron. It must be
  started as
  `TapTapGlobal.exe --disable-gpu --disable-gpu-compositing --in-process-gpu --use-gl=angle --use-angle=swiftshader --launch-context=startup`
  or its window is blank (DXMT: "cross-process swapchain not supported").
- The launcher shows Heartopia with "Download & Install" (13.0 GB). The user clicks it.
  Progress can be read from the size of `C:\TapTapGlobal\Apps\231364` against
  `GameFileInfo.json` `TotalFileSize` (13,935,655,934) once that file exists. Done when
  `xdt.exe` exists and `GameFileInfo.json` entries all match (md5 per file; spot-check
  a few hundred, not all 13 GB, at setup; full verify on a Repair action).
- `GameFileInfo.json` is the complete file manifest (name, size, md5). Stretch goal:
  find the launcher's package URLs in its logs under `C:\Program Files\TapTapGlobal\logs`
  and download directly, removing the launcher from the download step.
- Updates: the game patches itself in-process on launch (writes to
  `AppData\LocalLow\xd\Heartopia`). Base-client updates come through the launcher; an
  "Update game" menu item runs the launcher with the flags above.

## Sign-in (verified)

The game opens the default browser via Wine's winebrowser and completes a loopback
callback. No app involvement. Document: Chrome may ask to allow local network access.

## Known gaps (do not block Phase 2)

- A blank two-button dialog appears at every launch before the menu; the blue (right)
  button dismisses it. Likely embedded web content. Leave it; Phase 3 investigates.
- Cutscene video is black (H.264 via Media Foundation, no decoder backend in this Wine).
  Phase 3: build `winedmo` against ffmpeg.
- Notch band: the engine renders 1728x1080 inside the 1728x1117 window, leaving 18-point
  bars. Phase 3: Mac driver change reporting the safe area as the screen.
- Cursor renders at 1x with Retina off. Cosmetic.
- Raw mouse path is not needed for this game (visible-cursor camera drag, no warps).

## Process detection

Session alive: a process whose executable path equals `<rt>/bin/wineserver` (via
`proc_listallpids` + `proc_pidpath`). Game running: a process under the runtime whose
argv[0] basename is `xdt.exe` (via `sysctl KERN_PROCARGS2`). Window: the game window is
owned by the Windows process pid and titled "Heartopia". MacGames' `Status.swift` is the
reference implementation and may be re-implemented, not copied (PolyForm license).

## App

- One window, states: Rosetta check, runtime install, prefix setup, TapTap install
  (instructions + "I've installed it"), game download (progress), ready. Then every open
  of the app launches the game and shows nothing unless something fails.
- Menu: Play, Update game, Reset graphics, Metal HUD toggle, Show logs, Repair, Uninstall.
- Settings persisted in `state.json`.

## Tests

- Unit tests for environment assembly, registry seed generation, manifest verification,
  resolution/state parsing, with no Wine required.
- A `scripts/smoke.sh` that runs the CLI end to end on a machine that already has the
  data root from the spike (idempotent: detects existing runtime, prefix and game).

## Order of work

1. `CupidCore` + CLI with `setup` (runtime, prefix, seeds), `play`, `stop`, `status`.
   Reuse the spike scripts as the behavioural spec; delete them when the CLI covers them.
2. TapTap install and download states in the CLI.
3. App shell over the CLI's core.
4. Packaging script, ad hoc signed DMG.
