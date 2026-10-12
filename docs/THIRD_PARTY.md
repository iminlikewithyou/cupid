# Third-party components

Heartport's own code (the `HeartportCore` library, the `heartport` CLI, the app shell, scripts
and documentation) is licensed under the Apache License 2.0 (`LICENSE`, copyright 2026 Heartport
contributors). That grant covers only Heartport's own code. Everything below keeps its own license.

## Bundled in Heartport.app

| What | Where in the app | License | Corresponding source |
|---|---|---|---|
| Recall 1.3.0 Wine runtime (`runtime.tar.gz`, sha256 `66ce2eab…3f92c34`), shipped byte-for-byte as Recall publishes it inside `Recall-1.3.0.dmg` | `Contents/Resources/runtime.tar.gz` | Per component, see below; Recall's own code Apache-2.0 (`Licenses/Recall-NOTICE`, `Licenses/Recall-LICENSE-Apache-2.0`) | https://github.com/AsherJN/recall (tag `v1.3.0`; release https://github.com/AsherJN/recall/releases/tag/v1.3.0). Its `docs/SOURCES.json` pins every input listed below. |
| License texts of everything in the runtime | `Contents/Resources/Licenses/` (the runtime's own `licenses/` tree, copied verbatim) | n/a | n/a |
| `dxmt.conf` template | `Contents/Resources/config/dxmt.conf` | Heartport, Apache-2.0 | this repository |

### Inside the runtime (Recall 1.3.0's documented inputs)

| Component | Version / pin | License | Source |
|---|---|---|---|
| Wine (CodeWeavers' CrossOver sources; not the proprietary CrossOver app) | CrossOver 26.3.0 sources | LGPL-2.1-or-later (`Licenses/Wine-LGPL-2.1`) | https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz |
| Recall's Wine patches (canvas, mouselook, registry save, logging, Mac driver activation, portable directory) | as in Recall 1.3.0 `patches/` with sha256 pins in `docs/SOURCES.json` | LGPL-2.1-or-later (as Wine) | https://github.com/AsherJN/recall/tree/v1.3.0/patches |
| DXMT (Direct3D 10/11 on Metal), NerRobDog's fork | commit `c5dc3a0dfe9108e667da43de871324bd298c9c02`, plus Recall's DXMT patches (v1-private, v1-performance, portable-metal, metalfx-upscaling) | LGPL-2.1-or-later (`Licenses/DXMT-LGPL-2.1`, `Licenses/DXMT-LICENSE`) | https://github.com/NerRobDog/dxmt and Recall's `patches/` |
| DirectX-Headers (DXMT build input) | commit `9df86f2341616ef1888ae59919feaa6d4fad693d` | MIT (`Licenses/DirectX-Headers-COPYING`) | https://github.com/microsoft/DirectX-Headers |
| NVIDIA NVAPI headers (DXMT submodule; DLSS/NVAPI stand-ins contain no NVIDIA code) | commit `d08488fcc82eef313b0464db37d2955709691e94` | MIT (`Licenses/NVAPI-MIT`) | https://github.com/NVIDIA/nvapi |
| LLVM compiler runtime | 15.0.7; llvm-mingw 20251216 | Apache-2.0 with LLVM exception and MinGW notices (`Licenses/LLVM-15-LICENSE.txt`, `Licenses/compiler-runtime/`) | https://github.com/llvm/llvm-project, https://github.com/mstorsjo/llvm-mingw |
| wine-mono | 10.4.1 | Mixed (MIT, LGPL and others; `Licenses/wine-mono/wine-mono-10.4.1/`) | https://github.com/wine-mono/wine-mono/releases/tag/wine-mono-10.4.1 |
| FreeType | 2.13.3 | FTL or GPL-2.0 (`Licenses/freetype/`) | https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz |
| GnuTLS | as in Soju's library stack | LGPL-2.1-or-later (`Licenses/native/gnutls/`) | https://www.gnutls.org/ (via https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz, Soju's referenced archive) |
| Nettle | as above | LGPL-3.0-or-later / GPL-2.0-or-later (`Licenses/native/nettle/`) | https://www.lysator.liu.se/~nisse/nettle/ |
| GMP | as above | LGPL-3.0-or-later / GPL-2.0-or-later (`Licenses/native/gmp/`) | https://gmplib.org/ |
| libinotify-kqueue | as above | MIT (`Licenses/native/inotify/LICENSE`) | https://github.com/libinotify-kqueue/libinotify-kqueue |
| pkgconf | as above | ISC (`Licenses/native/pkgconf/`) | https://github.com/pkgconf/pkgconf |
| MoltenVK | as above | Apache-2.0 (`Licenses/native/MoltenVK-LICENSE`) | https://github.com/KhronosGroup/MoltenVK |
| SDL2 | 2.32.10 (sha256 `5f5993c5…ca5165`) | Zlib (`Licenses/native/sdl2/LICENSE.txt`) | https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz |
| Soju runtime build recipe (referenced, not vendored) | commit `3a350b32bf906dd2a509b18c642a5a2676de022a` | GPL-3.0 (`Licenses/Soju-GPL-3.0`) | https://github.com/BCD1210/soju |
| Apple `libd3dshared.dylib` and support components | as shipped in Recall 1.3.0 | Apple's license (`Licenses/apple/License.rtf`, `Acknowledgements.rtf`, `Read Me.rtf`); proprietary, not covered by Apache-2.0 or the Wine/DXMT licenses | not open source |

Heartport never modifies or re-signs any file of the runtime. On first run it extracts the
archive, verifies every file against the runtime's `runtime.json` (sha256 and size), and adds
one generated file set, `lib/wine/game-mode/xdt.app` (a copy of the runtime's own Wine loader
with a game Info.plist, identifier `app.heartport.heartopia`, ad hoc signed), so macOS Game
Mode can engage.

Rosetta 2 is Apple's and is installed by the user from Apple; it is not bundled.

## Runtime build scripts (not bundled)

`scripts/runtime/` holds copies of Recall's runtime build pipeline (https://github.com/AsherJN/recall,
commit `61a3a59`, Apache-2.0, Copyright 2026 Joshua Asher Nelson; its NOTICE is
`scripts/runtime/RECALL-NOTICE`), modified for Heartport as listed in `scripts/runtime/README.md`,
and `patches/recall/` holds Recall's Wine and DXMT patches unchanged (LGPL-2.1-or-later, as the
code they patch). A runtime built with them (`heartport-*`) carries the same third-party
components as the Recall runtime above, from the same pinned sources, with Heartport's
`LICENSE` and a NOTICE crediting Recall in `licenses/` in place of Recall's, nvngx.dll signed
with Heartport's own certificate, and no `Overwatch.app`.

From `heartport-20261012.2` the runtime also carries **FFmpeg 7.1.5** (libavformat, libavcodec,
libavutil in `lib/`), built from source (https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz, sha256
`de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`) under the **LGPL 2.1 or
later** (`licenses/native/ffmpeg/LICENSE.md`, `COPYING.LGPLv2.1`): no `--enable-gpl`, no
`--enable-nonfree`, no external libraries but the system zlib; only the mov/mp4, avi, wav, asf,
mpeg, mp3, aac, h264 and hevc demuxers, the h264, hevc, aac and mp3 decoders and the
mp4-to-Annex-B filters. The exact configure flags are in `scripts/runtime/README.md`; the
corresponding source is the tarball above. Wine's winedmo links it dynamically.

From `heartport-20261012.3` the runtime also carries GStreamer for Wine's Media Foundation
decoders (winegstreamer), built from source with the flags in `scripts/runtime/README.md`:

| Component | Version | License | Source (sha256-pinned) |
|---|---|---|---|
| GStreamer core (libgstreamer, libgstbase; coreelements plugin) | 1.26.11 | LGPL-2.1-or-later (`licenses/native/gstreamer/`) | https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.26.11.tar.xz |
| gst-plugins-base (libgstaudio/video/tag/pbutils/riff/rtp; playback, typefindfunctions, audioconvert, audioresample, videoconvertscale plugins) | 1.26.11 | LGPL-2.1-or-later (`licenses/native/gst-plugins-base/`) | https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.26.11.tar.xz |
| gst-plugins-good (isomp4, audioparsers, deinterlace, videofilter plugins) | 1.26.11 | LGPL-2.1-or-later (`licenses/native/gst-plugins-good/`) | https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.11.tar.xz |
| gst-plugins-bad (libgstcodecparsers; videoparsersbad plugin) | 1.26.11 | LGPL-2.1-or-later (`licenses/native/gst-plugins-bad/`) | https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.26.11.tar.xz |
| gst-libav (libav plugin, over the FFmpeg above) | 1.26.11 | LGPL-2.1-or-later (`licenses/native/gst-libav/`) | https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.26.11.tar.xz |
| GLib (glib, gobject, gmodule) | 2.86.5 | LGPL-2.1-or-later (`licenses/native/glib/COPYING`) | https://download.gnome.org/sources/glib/2.86/glib-2.86.5.tar.xz |
| proxy-libintl (GLib's gettext stand-in, libintl.8.dylib) | frida/proxy-libintl `33934de09af6a6627eb44e310a8079df009abdbb` | LGPL-2.0-or-later (`licenses/native/glib/proxy-libintl-COPYING`) | https://github.com/frida/proxy-libintl |
| PCRE2 | 10.49 | BSD-3-Clause with PCRE2 exception (`licenses/native/pcre2/LICENCE.md`) | https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2 |
| libffi | 3.5.2 | MIT (`licenses/native/libffi/LICENSE`) | https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz |

ORC is not used (disabled in every module). FFmpeg additionally ships libavfilter (no filters
enabled), which gst-libav links.

## Downloaded at setup, not bundled

- **TapTap Global PC client** (TapTap / XD). Heartport downloads the official installer from
  `https://d.tap.io/pc/latest/coop-pc?jid=id231364` into the data folder, checks its size and
  sha256 against a pin, and runs it. The user accepts TapTap's terms in the installer window.
  Proprietary; governed by TapTap's terms.

## Downloaded by the user, not bundled

- **Heartopia** (XD). The user downloads it with the TapTap client into the Wine prefix
  (`C:\TapTapGlobal\Apps\231364`). Proprietary; governed by XD's terms. Heartport does not
  modify the game files; it only sets registry preferences (graphics defaults) in the prefix.

## Not affiliated

Heartport is an independent community project, not affiliated with or endorsed by XD, TapTap,
Apple, CodeWeavers or the Recall project. Product names are trademarks of their owners.
