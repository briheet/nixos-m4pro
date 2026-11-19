#!/usr/bin/env python3
"""Read the GPU's KSM (hardware kick scheduler) queue registers through /dev/mem
(as root, while aurora.ko is loaded), for one look at whether the KSM holds a
queue as valid. Only plain status registers are read; the host-port FIFO at
sgx+0x4090/+0x4098 is never touched, since reading a FIFO can pop it.

sgx = 0x2_8800_0000 (GPU node reg "sgx"). The 27.2 firmware programs queue
validity at +0x21068 (QIDs 0-63) / +0x21070 (64-127) and the invalidations at
+0x21078 / +0x21080 (nixos-m4pro docs/gpu/driver-27.2-diff.md §18).

    sudo python3 ksm.py [qid ...]
"""
import mmap
import os
import struct
import sys

SGX = 0x2_8800_0000
PAGE = 0x4000
REGS = {
    "valid 0-63": 0x21068,
    "valid 64-127": 0x21070,
    "invalid 0-63": 0x21078,
    "invalid 64-127": 0x21080,
}

qids = [int(q) for q in sys.argv[1:]]
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
base = SGX + 0x21068 & ~(PAGE - 1)
m = mmap.mmap(fd, PAGE, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
for name, off in REGS.items():
    o = SGX + off - base
    lo, hi = struct.unpack_from("<II", m, o)
    word = lo | hi << 32
    bits = [b for b in range(64) if word >> b & 1]
    mark = ""
    for q in qids:
        if (q < 64) == (off in (0x21068, 0x21078)):
            mark += f" q{q}={'set' if word >> (q % 64) & 1 else 'clear'}"
    print(f"ksm {name:15} sgx+{off:#07x} = {word:#018x} bits {bits}{mark}")
