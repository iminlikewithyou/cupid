#!/usr/bin/env python3
"""Fill a DXMT_METAL_CACHE folder from a shipped runtime's compiled DXMT shaders.

Cupid-only fallback for a Mac without Apple's Metal toolchain (Xcode 26 installs it
separately: `xcodebuild -downloadComponent MetalToolchain`). portable_metal.py, when the
Metal compiler is missing, takes <sha256 of input>.<suffix> from DXMT_METAL_CACHE. This
script writes those entries for DXMT's four shader sources (patched as the build patches
them) from the compiled outputs embedded in a runtime built from the same sources:

- the three airconv shaders (src/airconv/shaders/air_*.metal) are embedded as .air
  files in x86_64-unix/winemetal.so (xxd arrays, each followed by its length);
- dxmt_command.metal's .metallib is embedded in x86_64-windows/d3d11.dll. Its .air is only
  an intermediate, so a stub stands in for it and keys the .metallib entry.

  metal_cache_from_runtime.py RUNTIME DXMT_SOURCE CACHE

A real Metal toolchain makes this unnecessary; rebuild DXMT without DXMT_METAL_CACHE then.
"""
import hashlib
from pathlib import Path
import re
import struct
import sys

AIR = {'air_msad.metal': b'dxmt.msad.i32', 'air_samplepos.metal': b'dxmt.sample_pos.i32',
       'air_tessellation.metal': b'dxmt.generate_workload.triangle.integer'}
WRAPPER = b'\xde\xc0\x17\x0b'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def airs(data):
    """(bytes, length) of each embedded .air: an LLVM bitcode wrapper whose array is followed
    by xxd's length variable (the file may end in padding after the wrapped bitcode)."""
    found, i = [], 0
    while (i := data.find(WRAPPER, i)) >= 0:
        _, version, offset, size, _ = struct.unpack_from('<5I', data, i)
        if version == 0 and offset == 20 and size < 1 << 24:
            end = i + 20 + size
            for pad in range(0, 16, 4):
                if struct.unpack_from('<I', data, end + pad)[0] == 20 + size + pad:
                    found.append(data[i:end + pad])
                    break
        i += 4
    return found


def metallib(data):
    i = 0
    while (i := data.find(b'MTLB', i)) >= 0:
        size = struct.unpack_from('<Q', data, i + 16)[0]
        if 64 < size < 1 << 24 and struct.unpack_from('<I', data, i + size)[0] == size:
            return data[i:i + size]
        i += 4
    raise SystemExit('No embedded metallib with a trailing length found')


def main(runtime, source, cache):
    runtime, source, cache = Path(runtime), Path(source), Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    blobs = airs((runtime / 'lib/wine/x86_64-unix/winemetal.so').read_bytes())
    for name, marker in AIR.items():
        matches = [b for b in blobs if marker in b]
        if len(matches) != 1:
            raise SystemExit(f'{name}: expected one embedded .air, found {len(matches)}')
        key = sha((source / 'src/airconv/shaders' / name).read_bytes())
        (cache / f'{key}.air').write_bytes(matches[0])
        print(f'{name}: {key}.air ({len(matches[0])} bytes, sha256 {sha(matches[0])})')
    command = (source / 'src/dxmt/dxmt_command.metal').read_bytes()
    stub = b'cupid metal cache stub for dxmt_command.metal ' + sha(command).encode() + b'\n'
    (cache / f'{sha(command)}.air').write_bytes(stub)
    lib = metallib((runtime / 'lib/wine/x86_64-windows/d3d11.dll').read_bytes())
    (cache / f'{sha(stub)}.metallib').write_bytes(lib)
    print(f'dxmt_command.metal: {sha(command)}.air (stub), {sha(stub)}.metallib ({len(lib)} bytes, sha256 {sha(lib)})')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
