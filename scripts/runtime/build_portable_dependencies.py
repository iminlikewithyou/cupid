#!/usr/bin/env python3
# Derived from Recall (https://github.com/AsherJN/recall, commit 61a3a59), scripts/build_portable_dependencies.py,
# Copyright 2026 Joshua Asher Nelson, licensed under the Apache License 2.0.
# Modified for Heartport (see scripts/runtime/README.md for the list of changes).
"""Build the runtime's small native dependency closure from pinned inputs.

Developer-only prerequisites: clang, make and pkg-config. Installation stays
inside --workspace; no Homebrew libraries enter the distributed payload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

INPUTS = {
    'pkgconf-2.5.1.tar.xz': ('https://distfiles.dereferenced.org/pkgconf/pkgconf-2.5.1.tar.xz', 'cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243'),
    'nettle-3.10.2.tar.gz': ('https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz', 'fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5'),
    'gnutls-3.8.13.tar.xz': ('https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz', 'ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e'),
    'libinotify-20240724.tar.gz': ('https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/20240724/libinotify-20240724.tar.gz', '5cc3fb7af407b17b7daa871cc98bb882716c4b5c296fadfb66bfe86c37cc599c'),
    'MoltenVK-macos.tar': ('https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.9/MoltenVK-macos.tar', '93369586b116bc027ef7121fd713ff32fcd856febcb4622b6ba527edcadd68ea'),
    'SDL2-2.32.10.tar.gz': ('https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz', '5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165'),
    # Heartport: FFmpeg for Wine's winedmo (Media Foundation demuxing). sha256 as Homebrew's
    # ffmpeg@7 formula pins the same ffmpeg.org URL (ffmpeg.org publishes GPG signatures only).
    'ffmpeg-7.1.5.tar.xz': ('https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz', 'de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f'),
    # Heartport: GStreamer for winegstreamer's Media Foundation decoders (H.264, AAC through
    # gst-libav over the FFmpeg above). sha256 from each project's release page: GitHub's asset
    # digests (libffi, pcre2), download.gnome.org's .sha256sum (glib), and
    # gstreamer.freedesktop.org's .sha256sum files.
    'libffi-3.5.2.tar.gz': ('https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz', 'f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc'),
    'pcre2-10.49.tar.bz2': ('https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2', '53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384'),
    'glib-2.86.5.tar.xz': ('https://download.gnome.org/sources/glib/2.86/glib-2.86.5.tar.xz', 'ce85a947bb8b3c0204dbeff79aec39bcb46371c6fafb64ba5b8726c71e038d5f'),
    'gstreamer-1.26.11.tar.xz': ('https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.26.11.tar.xz', '2e0bd192d0438ea606a6f76a95c8e16542167656ffec2c2bc3aaf6ee0837fbf6'),
    'gst-plugins-base-1.26.11.tar.xz': ('https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.26.11.tar.xz', 'fc50f885d41f5d0407ce0876ec7235d9e7b82d48db2f4bc72c5f244a4ac79263'),
    'gst-plugins-good-1.26.11.tar.xz': ('https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.11.tar.xz', '001deb0876d5d743cd3448abf74a27adec3fd850012fcb1b00994861bd6c1145'),
    'gst-plugins-bad-1.26.11.tar.xz': ('https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.26.11.tar.xz', '110fb82795f0e569b1e27b12ab9699d35c7762e1ff4db95335d6ac8d1442af3d'),
    'gst-libav-1.26.11.tar.xz': ('https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.26.11.tar.xz', '9bb3d2681ef0de92d1b1a9d955186236ee22e64f372db9bfc0d22e2d0df19865'),
}
# Archive name prefix of each dependency that --only can build alone.
ONLY = {'sdl2': 'SDL2-', 'ffmpeg': 'ffmpeg-'}
# Wine's winebus reads every controller that is not a PlayStation one through SDL
# (Xbox pads among them). Only the controller subsystems are built. Apple's
# GameController (MFi) backend stays out: it claims Xbox pads and delivers their
# input only to a foreground app, never to Wine's background device host.
SDL2_OPTIONS = ['--disable-joystick-mfi', '--disable-audio', '--disable-video', '--disable-render',
                '--disable-sensor', '--disable-power', '--disable-hidapi-libusb']
# Heartport: FFmpeg, LGPL only (no --enable-gpl/--enable-nonfree, no external libraries:
# --disable-autodetect, then only the system zlib for compressed MP4 headers). Wine's winedmo
# demuxes MP4/MOV, AVI, WAV, ASF, MPEG-PS and MP3 through libavformat and needs the
# h264_mp4toannexb bitstream filter; the decoders and parsers cover H.264, HEVC, AAC and MP3.
# No x86 assembly (no nasm in the toolchain), no programs but ffprobe (a build-time check
# tool, never shipped: the assembler copies libraries only).
FFMPEG_OPTIONS = ['--disable-autodetect', '--enable-zlib', '--disable-x86asm', '--disable-doc',
                  '--disable-programs', '--enable-ffprobe', '--disable-avdevice',
                  '--disable-postproc', '--disable-network', '--disable-everything',
                  '--enable-protocol=file',
                  '--enable-demuxer=mov,avi,wav,asf,mpegps,mpegvideo,mp3,aac,h264,hevc',
                  '--enable-parser=h264,hevc,aac,mpegaudio,mpegvideo',
                  '--enable-decoder=h264,hevc,aac,mp3,mp3float',
                  '--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,null',
                  '--enable-swscale', '--enable-swresample']
# libavfilter is built (no filters) because gst-libav links it.
# GStreamer stack (Heartport). Autotools: libffi and pcre2 (GLib's dependencies). Meson, cross
# compiled for x86_64 with the venv's meson: GLib, GStreamer and the plugin modules, each limited
# to what winegstreamer's MP4/H.264/AAC path uses (assemble_portable_runtime.py ships the plugins
# in GSTREAMER_PLUGINS). ORC, introspection, NLS, docs, tests and examples are off. GLib's
# gettext is its own proxy-libintl subproject (frida/proxy-libintl at the commit glib's wrap pins).
LIBFFI_OPTIONS = ['--disable-docs', '--disable-multi-os-directory']
PCRE2_OPTIONS = ['--enable-pcre2-8', '--disable-pcre2-16', '--disable-pcre2-32']
MESON_COMMON = ['-Ddoc=disabled', '-Dnls=disabled', '-Dtests=disabled', '-Dexamples=disabled',
                '-Dintrospection=disabled', '-Dorc=disabled']
MESON = {
    'glib': ['-Dintrospection=disabled', '-Dtests=false', '-Dinstalled_tests=false', '-Dselinux=disabled',
             '-Dlibmount=disabled', '-Dnls=disabled', '-Dman-pages=disabled', '-Ddocumentation=false',
             '-Dsysprof=disabled', '-Ddtrace=disabled', '-Dsystemtap=disabled', '-Dlibelf=disabled'],
    'gstreamer': ['-Ddoc=disabled', '-Dnls=disabled', '-Dtests=disabled', '-Dexamples=disabled',
                  '-Dintrospection=disabled', '-Dbenchmarks=disabled', '-Dtools=enabled',
                  '-Dlibunwind=disabled', '-Dlibdw=disabled', '-Dbash-completion=disabled',
                  '-Dptp-helper=disabled', '-Dcheck=disabled'],
    'gst-plugins-base': MESON_COMMON + ['-Dauto_features=disabled', '-Dapp=enabled', '-Daudioconvert=enabled',
                                        '-Daudioresample=enabled', '-Dvideoconvertscale=enabled',
                                        '-Dtypefind=enabled', '-Dplayback=enabled', '-Dvolume=enabled',
                                        '-Dtools=disabled'],
    'gst-plugins-good': [o for o in MESON_COMMON if o != '-Dintrospection=disabled'] + ['-Dauto_features=disabled', '-Disomp4=enabled', '-Daudioparsers=enabled',
                                        '-Ddeinterlace=enabled', '-Dvideofilter=enabled'],
    'gst-plugins-bad': MESON_COMMON + ['-Dauto_features=disabled', '-Dvideoparsers=enabled'],
    'gst-libav': ['-Ddoc=disabled', '-Dtests=disabled'],
}
MESON_PREFIX = '/build/heartport/clean-deps'
WINE_SHA = 'ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872'
TOOLCHAINS = Path(__file__).resolve().parents[2].parent / 'mactopia-runtime/toolchains'


def merge_tree(source, target):
    """Copy SOURCE over TARGET, replacing files and symlinks (copytree cannot replace symlinks)."""
    for p in sorted(source.rglob('*')):
        q = target / p.relative_to(source)
        if p.is_dir() and not p.is_symlink():
            q.mkdir(parents=True, exist_ok=True)
            continue
        if q.is_symlink() or q.exists(): q.unlink()
        if p.is_symlink(): q.symlink_to(p.readlink())
        else: shutil.copy2(p, q)


def meson_cross_file(path, prefix, flags):
    """x86_64 macOS host, the Command Line Tools clang, our pkgconf (relocating .pc prefixes,
    since the meson components install under MESON_PREFIX through a DESTDIR)."""
    q = lambda v: repr(str(v))
    arch = "['-arch', 'x86_64']"
    args = '[' + ', '.join(q(f) for f in flags.split()) + ']'
    path.write_text(f"""[binaries]
c = ['/usr/bin/clang', '-arch', 'x86_64']
cpp = ['/usr/bin/clang++', '-arch', 'x86_64']
objc = ['/usr/bin/clang', '-arch', 'x86_64']
objcpp = ['/usr/bin/clang++', '-arch', 'x86_64']
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = [{q(prefix / 'bin/pkgconf')}, '--define-prefix']

[built-in options]
c_args = {args}
cpp_args = {args}
objc_args = {args}
objcpp_args = {args}
c_link_args = [{q('-L' + str(prefix / 'lib'))}]
cpp_link_args = [{q('-L' + str(prefix / 'lib'))}]
objc_link_args = [{q('-L' + str(prefix / 'lib'))}]

[properties]
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
""")


def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def build(work, jobs, only=None, start=None, toolchains=TOOLCHAINS):
    if any(c.isspace() for c in str(work)):
        raise ValueError('Autoconf source workspace must not contain whitespace; installed runtime supports spaces')
    source = work / 'native-sources'; source.mkdir(parents=True, exist_ok=True)
    prefix = work / 'clean-deps'; prefix.mkdir(exist_ok=True)
    logs = work / 'build-logs'; logs.mkdir(exist_ok=True)
    for name, (url, expected) in INPUTS.items():
        if only and not name.startswith(ONLY[only]): continue
        archive = work / 'downloads' / name
        if not archive.exists():
            part = Path(str(archive) + '.part')
            subprocess.run(['/usr/bin/curl', '-fL', '--proto', '=https', '--proto-redir', '=https', '--retry', '2', '-o', str(part), url], check=True)
            if sha(part) != expected: raise ValueError('Download hash mismatch: ' + name)
            part.rename(archive)
        if sha(archive) != expected: raise ValueError('Input hash mismatch: ' + name)
        marker = source / (name + '.extracted')
        if not marker.exists():
            with tarfile.open(archive) as t: t.extractall(source, filter='data')
            marker.write_text(expected)
    wine = work / 'downloads/wine.tar.gz'
    gnu = work / 'gnu-source'
    if only is None and sha(wine) != WINE_SHA: raise ValueError('CodeWeavers source identity mismatch')
    if only is None and not (gnu / '.extracted').exists():
        with tarfile.open(wine) as t:
            t.extractall(gnu, members=[m for m in t.getmembers() if m.name.startswith(('sources/gnutls/gmp/', 'sources/gnutls/nettle/'))], filter='data')
        (gnu / '.extracted').write_text(WINE_SHA)
    env = os.environ.copy(); env.pop('DESTDIR', None)
    # The toolchain build_portable_runtime.py pins (and the one these libraries were
    # first built with): Command Line Tools clang and the macOS 26.5 SDK, whatever
    # xcode-select points at.
    env.update(DEVELOPER_DIR='/Library/Developer/CommandLineTools',
               SDKROOT='/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
    env.update(PATH=str(prefix / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
               CC='/usr/bin/clang -arch x86_64', CXX='/usr/bin/clang++ -arch x86_64',
               CFLAGS='-O2 -g0 -ffile-prefix-map=' + str(work) + '=/build/heartport',
               LDFLAGS='-L' + str(prefix / 'lib'), CPPFLAGS='-I' + str(prefix / 'include'),
               PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_PATH='',
               MACOSX_DEPLOYMENT_TARGET='26.0')
    if (only or start) and (prefix / 'bin/pkgconf').exists(): env['PKG_CONFIG'] = str(prefix / 'bin/pkgconf')
    components = [
        ('pkgconf', source / 'pkgconf-2.5.1', []),
        ('gmp', gnu / 'sources/gnutls/gmp', ['--disable-cxx']),
        ('nettle', source / 'nettle-3.10.2', ['--disable-documentation']),
        ('gnutls', source / 'gnutls-3.8.13', ['--disable-doc', '--disable-tests', '--disable-tools', '--disable-cxx', '--disable-nls', '--disable-libdane', '--without-p11-kit', '--without-idn', '--without-tpm', '--without-tpm2', '--without-zlib', '--without-brotli', '--without-zstd', '--with-included-libtasn1', '--with-included-unistring', '--with-system-priority-file=']),
        # New SDKs expose fdclosedir only from macOS 26.4; use the upstream
        # compatibility path to retain the runtime's 26.0 deployment target.
        ('inotify', source / 'libinotify-20240724', ['ac_cv_func_fdclosedir=no']),
        ('sdl2', source / 'SDL2-2.32.10', SDL2_OPTIONS),
        ('ffmpeg', source / 'ffmpeg-7.1.5', FFMPEG_OPTIONS),
        ('libffi', source / 'libffi-3.5.2', LIBFFI_OPTIONS),
        ('pcre2', source / 'pcre2-10.49', PCRE2_OPTIONS),
        ('glib', source / 'glib-2.86.5', MESON['glib']),
        ('gstreamer', source / 'gstreamer-1.26.11', MESON['gstreamer']),
        ('gst-plugins-base', source / 'gst-plugins-base-1.26.11', MESON['gst-plugins-base']),
        ('gst-plugins-good', source / 'gst-plugins-good-1.26.11', MESON['gst-plugins-good']),
        ('gst-plugins-bad', source / 'gst-plugins-bad-1.26.11', MESON['gst-plugins-bad']),
        ('gst-libav', source / 'gst-libav-1.26.11', MESON['gst-libav']),
    ]
    selected = [c for c in components if only in (None, c[0])]
    if start:  # --from: the earlier components are already built
        selected = selected[[c[0] for c in selected].index(start):]
    old_proof = work / 'native-build-proof.json'
    previous_options = json.loads(old_proof.read_text()).get('configure_options', {}) if old_proof.exists() else {}
    for name, src, options in selected:
        directory = work / ('native-build-' + name); directory.mkdir(exist_ok=True)
        if name == 'inotify':
            # This release's export-list argument is relative to the build cwd.
            shutil.copy2(src / 'libinotify.sym', directory / 'libinotify.sym')
        with (logs / (name + '.log')).open('w') as log:
            def run(args): subprocess.run([str(a) for a in args], cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            marker = directory / '.configuration.json'
            configuration = {'source': str(src), 'prefix': str(prefix), 'options': options,
                             'compiler': env['CC'], 'flags': env['CFLAGS']}
            changed = ((marker.exists() and json.loads(marker.read_text()) != configuration) or
                       (name in previous_options and previous_options[name] != options))
            if name in MESON:
                # Installed under MESON_PREFIX through a DESTDIR, then copied into the workspace
                # prefix: the paths compiled into GLib and GStreamer (plugin and locale
                # directories, all overridden at run time) name no build machine folder.
                menv = dict(env, PATH=':'.join([str(toolchains / 'python/bin'), str(toolchains / 'bison/bin'), env['PATH']]))
                for k in ('CC', 'CXX', 'CFLAGS', 'LDFLAGS', 'CPPFLAGS'): menv.pop(k, None)
                # pkgconf was configured with this prefix, so it treats <prefix>/include and
                # <prefix>/lib as system paths and drops them; meson needs them spelled out.
                menv.update(PKG_CONFIG_SYSTEM_INCLUDE_PATH='/usr/include', PKG_CONFIG_SYSTEM_LIBRARY_PATH='/usr/lib')
                cross = directory / 'cross-x86_64-macos.ini'
                meson_cross_file(cross, prefix, env['CFLAGS'])
                meson = toolchains / 'python/bin/meson'
                def mrun(args): subprocess.run([str(a) for a in args], cwd=directory, env=menv, stdout=log, stderr=subprocess.STDOUT, check=True)
                build_dir = directory / 'build'
                if changed or not (build_dir / 'build.ninja').exists():
                    shutil.rmtree(build_dir, ignore_errors=True)
                    mrun([meson, 'setup', build_dir, src, '--cross-file', cross, '--prefix', MESON_PREFIX,
                          '--libdir', 'lib', '--buildtype', 'release', '-Ddefault_library=shared',
                          '-Db_ndebug=if-release'] + options)
                marker.write_text(json.dumps(configuration, indent=2) + '\n')
                mrun([meson, 'compile', '-C', build_dir, '-j', str(jobs)])
                root = directory / 'destdir'
                shutil.rmtree(root, ignore_errors=True)
                mrun([meson, 'install', '-C', build_dir, '--no-rebuild', '--destdir', root])
                merge_tree(root / MESON_PREFIX.lstrip('/'), prefix)
                print('Built native dependency: ' + name, flush=True)
                continue
            if changed and (directory / 'Makefile').exists(): run(['make', 'clean'])
            if name == 'ffmpeg':
                # FFmpeg's configure is not autoconf: no --host, and it takes the compiler and
                # flags as options rather than from the environment. --install-name-dir keeps the
                # absolute prefix like the other libraries; the assembler rewrites it to @rpath.
                if changed or not (directory / 'ffbuild/config.mak').exists():
                    run(['/usr/bin/arch', '-x86_64', src / 'configure', '--prefix=' + str(prefix),
                         '--enable-shared', '--disable-static', '--arch=x86_64', '--target-os=darwin',
                         '--cc=' + env['CC'], '--cxx=' + env['CXX'], '--extra-cflags=' + env['CFLAGS'],
                         '--extra-ldflags=' + env['LDFLAGS'], '--pkg-config=false'] + options)
                # The libraries embed the configure command line (avutil_configuration() and
                # friends); keep the workspace path out of it, as the prefix map does for sources.
                config = directory / 'config.h'
                text = config.read_text()
                if str(work) in text: config.write_text(text.replace(str(work), '/build/heartport'))
            elif changed or not (directory / 'config.status').exists():
                run(['/usr/bin/arch', '-x86_64', src / 'configure', '--prefix=' + str(prefix), '--host=x86_64-apple-darwin', '--enable-shared', '--disable-static'] + options)
            marker.write_text(json.dumps(configuration, indent=2) + '\n')
            run(['make', '-j' + str(jobs)])
            run(['make', 'install'])
        print('Built native dependency: ' + name, flush=True)
        if name == 'pkgconf': env['PKG_CONFIG'] = str(prefix / 'bin/pkgconf')
    if only is None:
        molten = source / 'MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib'
        subprocess.run(['/usr/bin/lipo', str(molten), '-thin', 'x86_64', '-output', str(prefix / 'lib/libMoltenVK.dylib')], check=True)
    licenses = prefix / 'licenses'; licenses.mkdir(exist_ok=True)
    for name, src, _ in selected:
        target = licenses / name; target.mkdir(exist_ok=True)
        for p in src.iterdir():
            # FFmpeg is built LGPL-only: its LICENSE.md and the LGPL 2.1 text, not the GPL ones.
            if name == 'ffmpeg' and p.name not in ('LICENSE.md', 'COPYING.LGPLv2.1'): continue
            if p.is_file() and p.name.startswith(('COPYING', 'LICENSE', 'LICENCE', 'AUTHORS', 'NOTICE')): shutil.copy2(p, target / p.name)
        if name == 'glib':  # GLib's gettext stand-in, linked statically into GLib
            shutil.copy2(src / 'subprojects/proxy-libintl/COPYING', target / 'proxy-libintl-COPYING')
    if only is None:
        shutil.copy2(source / 'MoltenVK/LICENSE', licenses / 'MoltenVK-LICENSE')
    record = {'inputs': {n: {'url': v[0], 'sha256': v[1]} for n, v in INPUTS.items()},
              'gmp_source': {'archive_sha256': WINE_SHA, 'path': 'sources/gnutls/gmp', 'version': '6.3.0'},
              'configure_options': {n: opts for n, _, opts in components},
              'files': {p.name: sha(p) for p in (prefix / 'lib').glob('*.dylib')}}
    (work / 'native-build-proof.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--jobs', type=int, choices=range(1, 17), default=2)
    p.add_argument('--only', choices=sorted(ONLY), help='Build only this dependency (it needs none of the others)')
    p.add_argument('--from', dest='start', help='Start at this dependency (the earlier ones are built)')
    p.add_argument('--toolchains', type=Path, default=TOOLCHAINS, help='For meson and ninja (python/bin)')
    a = p.parse_args(); build(a.workspace.resolve(), a.jobs, a.only, a.start, a.toolchains.resolve())
