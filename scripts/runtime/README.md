# Runtime build (Wine + DXMT from pinned sources)

These scripts build Heartport's own Wine + DXMT runtime from pinned upstream sources. They are
copies of Recall's release pipeline, adapted for Heartport:

- Origin: https://github.com/AsherJN/recall, commit `61a3a59` ("Docs: MetalFX upscaling page"),
  `scripts/`. Recall is Copyright 2026 Joshua Asher Nelson and licensed under the Apache License
  2.0; its NOTICE is kept here as `RECALL-NOTICE`. Each copied script carries a header saying so.
- Recall's patches are in `../../patches/recall/`, byte-for-byte (8 Wine patches, 4 DXMT
  patches and their README). The scripts check each patch's sha256 before applying it.
- `config/dxmt-source60-1200.conf` is Recall's renderer profile, which the assembler installs
  as the runtime's `config/dxmt.conf` (identical to Recall 1.3.0's).

The first build (`heartport-20261012.1`) is a parity build: the same inputs and patches as
Recall's runtime `phase2-20261007.3`. See docs/PLAN.md, "Runtime build", for what came out.

## Layout

Everything large lives outside the repo, in `../mactopia-runtime/` beside the checkout (the
path must not contain spaces: autoconf):

```text
mactopia-runtime/
  toolchains/            LLVM 15.0.7, llvm-mingw 20251216, bison 3.8.2, python venv (meson, ninja)
  phase-2/               the build workspace (the scripts require this folder name)
  apple-original/        redist/lib/external/libd3dshared.dylib and Apple's three RTFs
  signing/heartport-nvngx/   the self-made certificate that signs DXMT's nvngx.dll
  metal-cache/           DXMT_METAL_CACHE entries (only without a Metal toolchain, see below)
  artifacts/<version>/   runtime/ tree, runtime.tar.gz, runtime.json, runtime-archive.json,
                         build-proof.json
  logs/                  one log per step
```

## Steps

```sh
W=../mactopia-runtime
python3 scripts/runtime/build_portable_runtime.py --workspace $W/phase-2 --download-only
python3 scripts/runtime/build_portable_dependencies.py --workspace $W/phase-2 --jobs 8
python3 scripts/runtime/build_portable_runtime.py --workspace $W/phase-2 --jobs 10
python3 scripts/runtime/build_portable_dxmt.py --workspace $W/phase-2 --jobs 4
python3 scripts/runtime/assemble_portable_runtime.py --workspace $W/phase-2 \
    --version heartport-YYYYMMDD.N --identity - --apple-original $W/apple-original
```

Then install it with Heartport (the `runtime-archive.json` beside the tarball names its version
and sha256):

```sh
HEARTPORT_RUNTIME_ARCHIVE=$W/artifacts/<version>/runtime.tar.gz .build/debug/heartport setup --step runtime
```

The signing certificate is made once with
`python3 scripts/runtime/sign_pe.py create-certificate ../mactopia-runtime/signing/heartport-nvngx`
(OpenSSL 3). Keep its keys out of git.

### Metal shaders

DXMT compiles four Metal shaders. Xcode 26 installs the Metal compiler as a separate component
(`xcodebuild -downloadComponent MetalToolchain`; on a fresh Xcode first `sudo xcodebuild
-runFirstLaunch`). Run the DXMT step with
`METAL_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so only the Metal tools come
from Xcode while C/C++ stays on the Command Line Tools. With Apple metal 32023.883 the compiled
`.air` and `.metallib` files are byte-identical to the ones in Recall's `phase2-20261007.3`.

Fallback without the Metal toolchain: `metal_cache_from_runtime.py RUNTIME DXMT_SOURCE CACHE`
fills a `DXMT_METAL_CACHE` folder from the compiled shaders embedded in a runtime built from the
same shader sources (e.g. Recall's `phase2-20261007.3`), and the build reuses them (iteration 1
was built that way).

### FFmpeg

`build_portable_dependencies.py` builds FFmpeg **7.1.5**
(https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz, sha256
`de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`; ffmpeg.org publishes GPG
signatures only, the sha256 is the one Homebrew's `ffmpeg@7` formula pins for the same URL) for
Wine's `winedmo`. LGPL 2.1 or later; configure:

```text
--prefix=<clean-deps> --enable-shared --disable-static --arch=x86_64 --target-os=darwin
--cc='/usr/bin/clang -arch x86_64' --cxx='/usr/bin/clang++ -arch x86_64'
--extra-cflags='-O2 -g0 -ffile-prefix-map=<workspace>=/build/heartport' --extra-ldflags=-L<clean-deps>/lib
--pkg-config=false --disable-autodetect --enable-zlib --disable-x86asm --disable-doc
--disable-programs --enable-ffprobe --disable-avdevice --disable-avfilter --disable-postproc
--disable-network --disable-everything --enable-protocol=file
--enable-demuxer=mov,avi,wav,asf,mpegps,mpegvideo,mp3,aac,h264,hevc
--enable-parser=h264,hevc,aac,mpegaudio,mpegvideo
--enable-decoder=h264,hevc,aac,mp3,mp3float
--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,null --enable-swscale --enable-swresample
```

No `--enable-gpl`, no `--enable-nonfree`, no external codec libraries (only the system zlib),
no VideoToolbox, no x86 assembly (no nasm in the toolchain; winedmo only demuxes, so decode
speed does not matter today). The workspace path is replaced by `/build/heartport` in the
embedded configure line. `ffprobe` stays in `clean-deps/bin` for checks and is never shipped.
Wine is configured with `FFMPEG_CFLAGS=-I<clean-deps>/include` and
`FFMPEG_LIBS=-L<clean-deps>/lib -lavutil -lavformat -lavcodec`; `winedmo.so` links
`@rpath/libavformat.61.dylib`, `libavcodec.61.dylib` and `libavutil.59.dylib`, which the
assembler copies to `lib/` (swscale and swresample are built but nothing links them, so they are
not shipped). Licences: `licenses/native/ffmpeg/{LICENSE.md,COPYING.LGPLv2.1}`.

## Changes from Recall's scripts

All scripts:
- `ROOT` is the repo root (`parents[2]`); toolchains default to `../mactopia-runtime/toolchains`.
- `-ffile-prefix-map` maps the workspace to `/build/heartport` (Recall: `/build/overwatch-2-mac`).
- `--jobs` accepts 1–16 (Recall: 1–4).

`build_portable_runtime.py`: patches from `patches/recall/`; Wine configured with FFmpeg
(`HAVE_FFMPEG` required in config.h); a marker in the Wine source records the applied patches,
so a rerun on a patched tree skips patching (the patches overlap, and Recall's `apply_once` stops
on such a tree).

`build_portable_dependencies.py`: FFmpeg (see above); `--only ffmpeg`.

`build_portable_dxmt.py`: the source is reset to the base commit and cleaned before patching
(reruns work); patches from `patches/recall/`; the wrapper from
`scripts/runtime/portable_metal.py`; `--signing` (default `../mactopia-runtime/signing/heartport-nvngx`);
`DEVELOPER_DIR` and `SDKROOT` default to the Command Line Tools and the macOS 26.5 SDK, as for
Wine; the build proof records the Metal developer directory and the cache's origin.

`portable_metal.py`: `METAL_DEVELOPER_DIR` runs only the Metal tools from another developer
directory.

`sign_pe.py`: the certificate is "Heartport Root" / "Heartport" in `heartport*.der/key`.

`assemble_portable_runtime.py`:
- `--apple-original DIR` (Recall: `<workspace>/apple-original`), `--toolchains`, `--output`
  (default `../mactopia-runtime/artifacts`); the result goes to `<output>/<version>/`:
  the tree in `runtime/`, `runtime.tar.gz`, a copy of `runtime.json`, `build-proof.json`
  (Recall's `<version>.json`) and `runtime-archive.json` (version, sha256, minimum_macos) for
  Heartport's installer.
- No game app: Recall made `lib/wine/game-mode/Overwatch.app` here; Heartport creates
  `lib/wine/game-mode/xdt.app` at install time (RuntimeInstaller.ensureGameModeBundle).
- `--identity -` signs ad hoc, without `--options runtime` and `--timestamp`; a real identity
  is signed as Recall signs (hardened runtime, timestamp).
- `licenses/PROJECT-APACHE-2.0` is Heartport's `LICENSE` and `licenses/PROJECT-NOTICE` is
  `licenses/PROJECT-NOTICE` here (Heartport's, with Recall's attribution). It also adds the
  license files Recall's shipped runtime carries from its later derivations
  (`DXMT-LICENSE`, `DXMT-LGPL-2.1`, `NVAPI-MIT`, `LLVM-15-LICENSE.txt`).
- `nvngx.dll` is not stripped, so its Authenticode signature stays valid (Recall's assembler
  stripped every DLL; its 1.3 runtime got nvngx.dll through `derive_runtime.py`, which copies
  it as built), and the assembler checks the signature.
- The development-path scan also covers the toolchains folder.

`metal_cache_from_runtime.py` is Heartport's (see "Metal shaders").

## Toolchains

| Toolchain | Source | sha256 |
|---|---|---|
| LLVM 15.0.7 x86_64 | https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.7/clang+llvm-15.0.7-x86_64-apple-darwin21.0.tar.xz | `d16b6d536364c5bec6583d12dd7e6cf841b9f508c4430d9ee886726bd9983f1c` (size 728344840 as GitHub lists; upstream publishes a GPG signature, not a sha256, and it was not checked) |
| llvm-mingw 20251216 UCRT macOS universal | https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/llvm-mingw-20251216-ucrt-macos-universal.tar.xz | `38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160` (matches GitHub's asset digest) |
| GNU Bison 3.8.2 | https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz, built into `toolchains/bison` | `9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2` (GNU's published value) |
| meson 1.5.2, ninja 1.11.1.1 | PyPI, into the venv `toolchains/python` (python3 3.13) | pip-verified wheels |

LLVM 15.0.7 and llvm-mingw are unpacked under `toolchains/` with their archive names
(`clang+llvm-15.0.7-x86_64-apple-darwin21.0`, `llvm-mingw-20251216-ucrt-macos-universal`).
