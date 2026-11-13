#!/usr/bin/env python3
"""m1n1's stock tools/linux.py, for an initrd larger than m1n1's heap.

linux.py takes every buffer from m1n1's heap (128 MiB). The installer's
initrd carries the whole system (well over 1 GiB with the desktop), so this
runs linux.py unchanged except that allocations over 64 MiB come from a
plain bump allocator in RAM above m1n1's heap. kboot_set_initrd() still
tells Linux where the initrd is and reserves it.

  M1N1DEVICE=... tools/linux-big.py <linux.py arguments>
"""
import pathlib
import runpy
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "upstream/m1n1/proxyclient"))

from m1n1.setup import u  # noqa: E402  (the instance linux.py's import gets too)

BIG = 64 << 20
# RAM above m1n1 (base ~0x100_0500_0000, heap ~128 MiB) and well below the
# end of usable memory (~0x105_daef_c000) on the J614s.
_next = [0x102_0000_0000]
_limit = 0x105_0000_0000
_memalign = u.memalign


def memalign(align, size):
    if size <= BIG:
        return _memalign(align, size)
    addr = (_next[0] + align - 1) & ~(align - 1)
    if addr + size > _limit:
        raise Exception("linux-big: out of high RAM")
    _next[0] = addr + size
    return addr


u.memalign = memalign
sys.argv = [str(REPO / "upstream/m1n1/proxyclient/tools/linux.py")] + sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
