#!/usr/bin/env python3
# Derived from Recall (https://github.com/AsherJN/recall, commit 61a3a59), scripts/build_portable_runtime.py,
# Copyright 2026 Joshua Asher Nelson, licensed under the Apache License 2.0.
# Modified for Cupid (see scripts/runtime/README.md for the list of changes).
"""Build a separate Wine runtime from pinned upstream inputs; never install it.

Developer tool only. The native setup worker does not require Python, Homebrew,
an installed development engine, or this checkout on a player's Mac.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
# Cupid: Recall's patches live in patches/recall/; toolchains outside the repo.
PATCHES_DIR = ROOT / 'patches/recall'
# Cupid's own Wine patches, applied after Recall's set (see patches/cupid/README.md).
CUPID_PATCHES_DIR = ROOT / 'patches/cupid'
CUPID_PATCHES = {
    'wine-winemac-dock-identity.patch': '9bffbed675ca6b4635a9e1489b339923d5320eb706caac9b96e7f8cf33f5ad03',
    'wine-winemac-native-fullscreen.patch': '1ac4047a6c38f7c921d7fa116698a8abb83a9effd5c11eec39ae13c9c1a8a48f',
    'wine-winemac-fullscreen-normal-level.patch': '0f183c50141c0c3eebe744eacc26e3e03c9412d5db4906ef68f2068b3c21e7ab',
    'wine-mfreadwrite-shared-textures.patch': '6743b0dce57bbd50c98aec3c3a3090a987a81a4ba0bed295ea71c1197755577b',
    'wine-coremessaging-dispatcher-queue.patch': '4460c42fd31a31afbe295739855a91eb7732e1b674ccc5d72d9c4b09a48bd818',
}
# Cupid: the build workspace, CUPID_RUNTIME_WORKSPACE or ../cupid-runtime beside the checkout.
WORKSPACE = Path(os.environ.get('CUPID_RUNTIME_WORKSPACE') or ROOT.parent / 'cupid-runtime')
TOOLCHAINS = WORKSPACE / 'toolchains'
PREFIX_MAP = '/build/cupid'
CONFIGURATION = 'vulkan-sdl2-ffmpeg-gstreamer-enabled-v1\n'
SOJU = '3a350b32bf906dd2a509b18c642a5a2676de022a'
INPUTS = {
    'wine.tar.gz': ('https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz', 'ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872'),
    'libraries.tar.gz': ('https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz', '01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3'),
    'freetype.tar.gz': ('https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz', '5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747'),
    'soju.tar.gz': ('https://codeload.github.com/BCD1210/soju/tar.gz/' + SOJU, 'e719e417fe92f2600ef4dc3896eb499c0933f05d785918cf7aa8f616cdd75e38'),
    'mono.tar.xz': ('https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-x86.tar.xz', 'a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb'),
}
PATCHES = {
    'ncrypt-persisted-keys.patch': '6283b3637b1d98bf43f68618c0991ee23e719c8bddaed05eff05e3989c954efe',
}


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(command, **kwargs):
    subprocess.run([str(a) for a in command], check=True, **kwargs)


def fetch(work):
    downloads = work / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in INPUTS.items():
        target = downloads / name
        if not target.exists():
            part = target.with_suffix(target.suffix + '.part')
            run(['/usr/bin/curl', '--fail', '--location', '--retry', '2',
                 '--proto', '=https', '--proto-redir', '=https', '-o', part, url])
            if sha(part) != expected:
                raise RuntimeError('Downloaded input hash mismatch: ' + name)
            part.rename(target)
        if sha(target) != expected:
            raise RuntimeError('Input hash mismatch: ' + name)


def extract(work, name, prefix=None):
    destination = work / 'sources' / name
    marker = destination / '.extracted.json'
    filename = name + ('.tar.xz' if name == 'mono' else '.tar.gz')
    identity = INPUTS[filename][1]
    if marker.exists():
        if json.loads(marker.read_text())['sha256'] != identity:
            raise RuntimeError('Source identity changed: ' + name)
        return destination
    # An interrupted extraction is repeatable only inside this owned source tree.
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(work / 'downloads' / filename) as archive:
        members = [m for m in archive.getmembers() if not prefix or m.name.startswith(prefix)]
        archive.extractall(destination, members=members, filter='data')
    marker.write_text(json.dumps({'sha256': identity}) + '\n')
    return destination


V1_PATCHES = {
    'wine-server-registry-save.patch': '8f89556d5daff60c75ae60720ae5125c68021abc244a95df5f6352468323a1a3',
    'wine-ntdll-syscall-log.patch': 'beac5bba576e36a0971e6581e812817e87f5cb8c41003c2e4edfe0e8f269623a',
    'wine-win32u-display-log.patch': '1d0dae5d4810becf72bbb79d2259b97683f09481c91617ae543fd510d853aeff',
    'wine-winemac-activation.patch': '5cce039910a420a16e7d9f8907e17206b1413c6cc4092248548d3d6b29f1138d',
}


def apply_once(source, patch):
    result = subprocess.run(['git', 'apply', '--check', str(patch)], cwd=source,
                            capture_output=True)
    if result.returncode == 0:
        run(['git', 'apply', patch], cwd=source)
    else:
        reverse = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)],
                                 cwd=source, capture_output=True)
        if reverse.returncode == 0:
            return
        # Some pinned Soju patches have overlapping hunk context rejected by
        # git apply. BSD patch accepts them without fuzzy context matching.
        run(['/usr/bin/patch', '--dry-run', '-N', '-F0', '-p1', '-i', patch], cwd=source)
        run(['/usr/bin/patch', '-N', '-F0', '-p1', '-i', patch], cwd=source)


def apply_cupid_patches(wine):
    """Apply Cupid's patches on top of Recall's set, in order.

    The source tree keeps a copy of each applied patch in `.cupid-own-patches/` with a
    marker listing them, so a rerun skips what is already applied, and a patch that changed
    (or was removed) is reversed from its stored copy, together with every later one, before
    the current set is applied. Recall's marker (`.cupid-patches.json`) is unaffected.
    """
    for name, expected in CUPID_PATCHES.items():
        if sha(CUPID_PATCHES_DIR / name) != expected:
            raise RuntimeError('A Cupid patch changed: ' + name)
    store = wine / '.cupid-own-patches'
    store.mkdir(exist_ok=True)
    marker = store / 'applied.json'
    applied = json.loads(marker.read_text()) if marker.exists() else []
    wanted = [[name, digest] for name, digest in CUPID_PATCHES.items()]
    keep = 0
    while keep < min(len(applied), len(wanted)) and applied[keep] == wanted[keep]:
        keep += 1
    def save():
        marker.write_text(json.dumps(applied, indent=1) + '\n')
    while len(applied) > keep:
        name, _ = applied[-1]
        run(['git', 'apply', '--reverse', store / name], cwd=wine)
        (store / name).unlink()
        applied.pop()
        save()
        print('Reversed ' + name, flush=True)
    for name, digest in wanted[keep:]:
        patch = CUPID_PATCHES_DIR / name
        run(['git', 'apply', '--check', patch], cwd=wine)
        run(['git', 'apply', patch], cwd=wine)
        shutil.copy2(patch, store / name)
        applied.append([name, digest])
        save()
        print('Applied ' + name, flush=True)


def build(work, tools, headers, jobs):
    fetch(work)
    wine = extract(work, 'wine', 'sources/wine/') / 'sources/wine'
    libraries = extract(work, 'libraries', 'Libraries/Wine/lib/') / 'Libraries/Wine/lib'
    ft = extract(work, 'freetype') / 'freetype-2.13.3'
    soju = extract(work, 'soju') / ('soju-' + SOJU)
    mono = extract(work, 'mono') / 'wine-mono-10.4.1'
    # Cupid: the patches overlap, so on a tree that carries all of them the first one
    # neither applies nor reverses and Recall's apply_once stops. A marker written after the
    # last patch makes reruns (a reconfigure, a new dependency) skip patching the same tree.
    marker = wine / '.cupid-patches.json'
    applied = json.dumps({'wine-v1-canvas.patch': '33d57c155761838988d98777a7cddb1b2d00417d07b2e19ca9533221aa9b6f65',
                          'wine-mouselook.patch': '4e9d4ab2aff6ec38b03100d4802d2764efe1e33caf151cdb4c5de7a8dfa3dfdb',
                          'wine-portable-directory-boolean.patch': '9c7f811b1eb83d8c322d42509a82c1bcd786f101ce1b26fc1dc0c5badebe619b',
                          **PATCHES, **V1_PATCHES}, sort_keys=True) + '\n'
    patched = marker.exists() and marker.read_text() == applied
    def apply_once_here(source, p):
        if not patched: apply_once(source, p)
    patch = PATCHES_DIR / 'wine-v1-canvas.patch'
    if sha(patch) != '33d57c155761838988d98777a7cddb1b2d00417d07b2e19ca9533221aa9b6f65':
        raise RuntimeError('The accepted native driver patch changed')
    apply_once_here(wine, patch)
    # Mouselook with raw mouse input, accepted after the owner's play-tests on
    # 2026-09-25 and 2026-09-26. It is inert unless the app lists the game in
    # WINEMAC_MOUSELOOK.
    mouselook = PATCHES_DIR / 'wine-mouselook.patch'
    if sha(mouselook) != '4e9d4ab2aff6ec38b03100d4802d2764efe1e33caf151cdb4c5de7a8dfa3dfdb':
        raise RuntimeError('The accepted mouselook patch changed')
    apply_once_here(wine, mouselook)
    directory_patch = PATCHES_DIR / 'wine-portable-directory-boolean.patch'
    if sha(directory_patch) != '9c7f811b1eb83d8c322d42509a82c1bcd786f101ce1b26fc1dc0c5badebe619b':
        raise RuntimeError('Portable directory-query compatibility patch changed')
    apply_once_here(wine, directory_patch)
    for name, expected in PATCHES.items():
        p = soju / 'patches' / name
        if sha(p) != expected:
            raise RuntimeError('Upstream compatibility patch changed')
        apply_once_here(wine, p)
    # v1.0, after the owner's play-tests of candidates 5-7: the registry save from
    # a forked server, Unix library loads outside the virtual-memory lock, the
    # window driver's activation, canvas and pointer fixes. Their diagnostics
    # (WINESERVER_REGISTRY_LOG, WINE_SYSCALL_LOG, WINE_IO_ERROR_LOG,
    # WINE_DISPLAY_LOG, WINEMAC_INPUT_STATS) stay off unless set.
    for name, expected in V1_PATCHES.items():
        p = PATCHES_DIR / name
        if sha(p) != expected:
            raise RuntimeError('The accepted v1.0 patch changed: ' + name)
        apply_once_here(wine, p)
    marker.write_text(applied)
    # Cupid's own driver patches (Dock identity, native fullscreen Space), inert unless
    # their environment variables are set.
    apply_cupid_patches(wine)
    # The complete native driver supersedes Soju's native-window patches.
    # Omit its GOG-only Chromium injection (not used by the v6 launcher), which
    # also needs a rebase against CodeWeavers' Ubisoft environment-variable hook.
    # Focus and mouse changes come only from the pinned driver patches above.
    deps = work / 'deps'
    (deps / 'lib').mkdir(parents=True, exist_ok=True)
    for p in libraries.glob('*.dylib'):
        shutil.copy2(p, deps / 'lib' / p.name, follow_symlinks=True)
    env = os.environ.copy()
    env.pop('DESTDIR', None)
    # Phase 2 was compiled by the Command Line Tools clang (2100.1.1.101) with
    # the macOS 26.5 SDK. An Xcode update would otherwise switch /usr/bin/clang
    # and the SDK under an existing build tree.
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    env['SDKROOT'] = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
    env['PATH'] = ':'.join([str(tools / 'bison/bin'),
                          str(tools / 'llvm-mingw-20251216-ucrt-macos-universal/bin'),
                          '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    env['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
    flags = '-O2 -g0 -ffile-prefix-map=' + str(work) + '=' + PREFIX_MAP
    logdir = work / 'build-logs'
    logdir.mkdir(exist_ok=True)
    with (logdir / 'freetype.log').open('w') as log:
        if not (ft / '.portable-configured').exists():
            if (ft / 'config.mk').exists():
                run(['make', 'distclean'], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
            run(['/usr/bin/arch', '-x86_64', './configure', '--prefix=' + str(deps),
                 '--without-harfbuzz', '--without-png', '--without-brotli', '--without-bzip2',
                 '--enable-shared', '--disable-static', 'CC=/usr/bin/clang -arch x86_64',
                 'CFLAGS=' + flags], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
            (ft / '.portable-configured').write_text(str(deps))
        if (ft / '.portable-configured').read_text() != str(deps):
            raise RuntimeError('FreeType configured for a different workspace')
        run(['make', '-j' + str(jobs)], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
        run(['make', 'install'], cwd=ft, env=env, stdout=log, stderr=subprocess.STDOUT)
    print('FreeType built from pinned source', flush=True)
    builddir = work / 'wine-build'
    builddir.mkdir(exist_ok=True)
    with (logdir / 'wine.log').open('w') as log:
        configuration = builddir / '.portable-configuration'
        # 1.2 adds SDL2 (controllers other than PlayStation ones); an older tree is
        # configured again so config.h gains SONAME_LIBSDL2. Cupid adds FFmpeg (winedmo,
        # Media Foundation demuxing), so a tree configured without it is configured again.
        if (not (builddir / 'Makefile').exists() or not configuration.exists()
                or configuration.read_text() != CONFIGURATION):
            run(['/usr/bin/arch', '-x86_64', wine / 'configure', '--prefix=/usr/local',
                 '--enable-archs=i386,x86_64', '--without-x', '--disable-tests',
                 '--with-gstreamer', '--with-vulkan',
                 'FREETYPE_CFLAGS=-I' + str(deps / 'include/freetype2'),
                 'FREETYPE_LIBS=-L' + str(deps / 'lib') + ' -lfreetype',
                 'GNUTLS_CFLAGS=-I' + str(headers),
                 'GNUTLS_LIBS=-L' + str(deps / 'lib') + ' -lgnutls',
                 'INOTIFY_CFLAGS=-I' + str(soju / 'third_party/libinotify-kqueue'),
                 'INOTIFY_LIBS=-L' + str(deps / 'lib') + ' -linotify',
                 'SDL2_CFLAGS=-I' + str(work / 'clean-deps/include/SDL2'),
                 'SDL2_LIBS=-L' + str(work / 'clean-deps/lib') + ' -lSDL2',
                 'FFMPEG_CFLAGS=-I' + str(work / 'clean-deps/include'),
                 'FFMPEG_LIBS=-L' + str(work / 'clean-deps/lib') + ' -lavutil -lavformat -lavcodec',
                 # Cupid: GStreamer (clean-deps, build_portable_dependencies.py) for
                 # winegstreamer, Wine's Media Foundation and DirectShow decoders.
                 'GSTREAMER_CFLAGS=' + ' '.join('-I' + str(work / 'clean-deps' / d) for d in
                     ('include/gstreamer-1.0', 'include/glib-2.0', 'lib/glib-2.0/include')),
                 'GSTREAMER_LIBS=-L' + str(work / 'clean-deps/lib') + ' -lgstvideo-1.0 -lgstaudio-1.0'
                     ' -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0',
                 'LDFLAGS=-Wl,-headerpad,0x1000 -L' + str(deps / 'lib'), 'CFLAGS=' + flags,
                 'CROSSCFLAGS=' + flags,
                 'CC=/usr/bin/clang -arch x86_64', 'CXX=/usr/bin/clang++ -arch x86_64'],
                cwd=builddir, env=env, stdout=log, stderr=subprocess.STDOUT)
            configuration.write_text(CONFIGURATION)
        config = builddir / 'include/config.h'
        text = config.read_text()
        for required in ('#define HAVE_SYS_INOTIFY_H 1', '#define SONAME_LIBGNUTLS ', '#define SONAME_LIBFREETYPE ',
                         '#define SONAME_LIBSDL2 ', '#define HAVE_FFMPEG 1',
                         '#define HAVE_LIBAVCODEC_BSF_H 1'):
            if required not in text:
                raise RuntimeError('Wine lacks a required dependency: ' + required)
        for name, library in [('GNUTLS', 'libgnutls.30.dylib'), ('FREETYPE', 'libfreetype.6.dylib'),
                              ('VULKAN', 'libMoltenVK.dylib'), ('MOLTENVK', 'libMoltenVK.dylib'),
                              ('SDL2', 'libSDL2-2.0.0.dylib')]:
            text = re.sub(r'#define SONAME_LIB' + name + r' .*',
                          '#define SONAME_LIB' + name + ' "@rpath/' + library + '"', text)
        if config.read_text() != text:config.write_text(text)
        # Link commands do not themselves invalidate existing make targets.
        # On an older workspace, relink only newly built native outputs once.
        padding = builddir / '.portable-header-padding'
        if not padding.exists():
            for output in list(builddir.glob('dlls/**/*.so')) + [builddir / p for p in
                    ('loader/wine', 'server/wineserver', 'tools/wine/wine')]:
                if output.is_file() and not output.is_symlink(): output.unlink()
        cross_paths = builddir / '.portable-cross-paths'
        if not cross_paths.exists():
            # Wine has separate PE compiler flags. Native CFLAGS alone do not
            # sanitize Windows assertion strings or suppress Windows debug data.
            for architecture in ('i386-windows','x86_64-windows'):
                for output in builddir.glob('**/' + architecture + '/**/*.o'):
                    if not output.is_symlink(): output.unlink()
        nested_paths = builddir / '.portable-cross-nested-paths'
        if not nested_paths.exists():
            for architecture in ('i386-windows','x86_64-windows'):
                for output in builddir.glob('**/' + architecture + '/**/*.o'):
                    if output.parent.name != architecture and not output.is_symlink(): output.unlink()
        print('Building full Wine engine (isolated, two architectures)', flush=True)
        run(['make', '-j' + str(jobs), 'LDFLAGS=-Wl,-headerpad,0x1000 -L' + str(deps / 'lib'),
             'i386_CFLAGS=' + flags, 'x86_64_CFLAGS=' + flags],
            cwd=builddir, env=env, stdout=log, stderr=subprocess.STDOUT)
        if not (builddir / 'dlls/winegstreamer/winegstreamer.so').is_file():
            raise RuntimeError('winegstreamer.so was not built (GStreamer not found by configure)')
        padding.write_text('0x1000\n')
        cross_paths.write_text(flags + '\n')
        nested_paths.write_text(flags + '\n')
        run(['make', 'install', 'DESTDIR=' + str(work / 'install')], cwd=builddir,
            env=env, stdout=log, stderr=subprocess.STDOUT)
    installed = work / 'install/usr/local'
    shutil.copytree(mono, installed / 'share/wine/mono/wine-mono-10.4.1', dirs_exist_ok=True)
    record = {'inputs': {n: {'url': v[0], 'sha256': v[1]} for n,v in INPUTS.items()},
              'wine_patch_sha256': sha(patch), 'mouselook_patch_sha256': sha(mouselook),
              'soju_compatibility_patches': PATCHES,
              'directory_boolean_patch_sha256': sha(directory_patch),
              'v1_patches': V1_PATCHES,
              'cupid_patches': CUPID_PATCHES,
              'gnutls_header_sha256': sha(headers / 'gnutls/gnutls.h'),
              'minimum_macos': '26.0', 'runtime_scope': 'Wine + FreeType built from source; DXMT assembly is separate',
              'without_vulkan': False, 'without_gstreamer': False, 'with_sdl2': True, 'with_ffmpeg': True,
              'native_linker_header_padding': '0x1000',
              'windows_compiler_paths_remapped': True,
              'driver_matches_accepted_patch': True}
    (work / 'wine-build-proof.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Full Wine build complete; no live installation modified', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--toolchains', type=Path, default=TOOLCHAINS)
    parser.add_argument('--gnutls-headers', type=Path,
                        help='Defaults to the pinned native dependency build headers')
    parser.add_argument('--download-only', action='store_true',
                        help='Fetch verified inputs before building native dependencies')
    parser.add_argument('--jobs', type=int, choices=range(1,17), default=2)
    args = parser.parse_args()
    work = args.workspace.resolve()
    if work == ROOT or work in ROOT.parents or work.name != 'phase-2':
        parser.error('Use a dedicated directory named phase-2')
    # A configured tree only rebuilds what changed and reinstalls in place.
    rebuild = (work / 'wine-build/.portable-configuration').exists()
    if shutil.disk_usage(work.parent).free < (3 if rebuild else 12) * 2**30:
        parser.error('A rebuild needs 3 GiB of free working headroom' if rebuild
                     else 'A full source build needs 12 GiB of free working headroom')
    work.mkdir(parents=True, exist_ok=True)
    if args.download_only:
        fetch(work)
    else:
        headers = (args.gnutls_headers or work / 'clean-deps/include').resolve()
        if not (headers / 'gnutls/gnutls.h').is_file():
            parser.error('Build the pinned native dependencies first, or supply --gnutls-headers')
        if not (work / 'clean-deps/include/SDL2/SDL.h').is_file():
            parser.error('Build the pinned native dependencies first: SDL2 is missing')
        build(work, args.toolchains.resolve(), headers, args.jobs)
