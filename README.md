# Cupid

Cupid plays **Heartopia** on your Mac. It installs the game for you and starts it when you
open Cupid. It's that simple.

## Download

1. Go to the [latest release](https://github.com/iminlikewithyou/cupid/releases/latest).
2. Under **Assets**, click the file ending in `.dmg` to download it.
3. Open the downloaded file and drag **Cupid** into the **Applications** folder next to it.
4. Open Cupid from Applications. The first time, macOS says it could not verify Cupid and
   will not open it. Close that message, open **System Settings**, go to **Privacy &
   Security**, scroll down, and click **Open Anyway** next to Cupid. It opens normally from
   then on.
5. Follow the steps in Cupid's window.

You need a Mac with Apple silicon (M1 or later) running macOS 26 or later, Rosetta 2 (Cupid
helps you install it if it is missing), and about 17 GB of free space.

## Settings

Three fullscreen modes: fill the screen with notifications showing (the default), fill the
screen with notifications hidden, or an own Space like a Mac game. There is also a
performance overlay. Hold Option while opening Cupid to see its window instead of starting
the game.

## How it works

Cupid runs the Windows version of Heartopia in a private Windows environment with its own
build of Wine and DXMT (Direct3D 11 on Metal). No Steam, CrossOver, or Windows licence is
involved.

The runtime is built from pinned sources by [`scripts/runtime`](scripts/runtime/README.md):
Wine from CodeWeavers' CrossOver sources, DXMT, and GStreamer and FFmpeg for the game's
videos, plus Apple's Direct3D shared library as shipped by Recall. The build pipeline and the
patches in `patches/recall` come from [Recall](https://github.com/AsherJN/recall) by AsherJN
(Apache License 2.0). Cupid's own Wine patches are in
[`patches/cupid`](patches/cupid/README.md): shareable video textures, a minimal
DispatcherQueue, the game's name and icon in the Dock, and the fullscreen modes.

Licences for every bundled component are in [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).
TapTap and Heartopia are downloaded from their publishers and are not part of Cupid.

## Building

Requires Xcode 26. No third-party Swift packages.

```sh
swift build && swift test
scripts/build-app.sh [--dmg]   # build/Cupid.app, ad hoc signed
```

`build-app.sh` needs the runtime archive in `Resources/runtime/`: build it with
`scripts/runtime` and copy `runtime.tar.gz` and `runtime-archive.json` there.
`scripts/fetch-runtime.sh` fetches Recall's prebuilt runtime instead, which lacks Cupid's
patches.

The app bundles a command-line tool at `Cupid.app/Contents/Helpers/cupid` with the same
engine; run `cupid --help`.

## Licence

Apache License 2.0 ([LICENSE](LICENSE)). Bundled components keep their own licences.
