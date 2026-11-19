# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline reader for a tools/hv/trace_agx_raw.py snapshot (Python twin of
lib/agx/snapshot.ml), so the agx27 tools can compare against macOS without
dune. Read-only, no device access.

    snap = Snapshot("build/agx/traces/27.2-boot5/03-after-5000-msgs")
    snap.read(0xfffffc20c07a0000, 0x2850)
    snap.pte(va)            # raw leaf entry (attributes) for a kernel-half VA
"""

import os

PAGE = 0x4000
OA_MASK = 0xFFFFFFFFC000
LEVELS = [(36, 64), (25, 2048), (14, 2048)]   # InitData's uat_level_info
HALF_BITS = 42


def _int(s):
    return int(s.strip(), 16)


class Snapshot:
    def __init__(self, path):
        self.dir = path
        self.root = None
        self.entries = {}
        for line in open(os.path.join(path, "shared.tsv")):
            f = line.rstrip("\n").split("\t")
            if f[0] == "root":
                self.root = _int(f[1])
            elif f[0] == "entry":
                self.entries[(_int(f[1]), int(f[3]))] = _int(f[4])
        self.low = []
        p = os.path.join(path, "pages.tsv")
        if os.path.exists(p):
            for line in open(p):
                f = line.rstrip("\n").split("\t")
                if f[0] == "page":
                    va = _int(f[1])
                    self.low.append((va, _int(f[2]), os.path.join(path, f"va-{va:016x}.bin")))

    @staticmethod
    def is_kernel(va):
        return va >> HALF_BITS == (1 << (64 - HALF_BITS)) - 1

    def walk(self, va):
        """List of raw entries from root to leaf (stops at an invalid one)."""
        out, table = [], self.root
        for shift, n in LEVELS:
            e = self.entries.get((table, (va >> shift) & (n - 1)))
            if e is None or not e & 1:
                return out
            out.append(e)
            table = e & OA_MASK
        return out

    def pte(self, va):
        w = self.walk(va)
        return w[-1] if len(w) == len(LEVELS) else None

    def translate(self, va):
        e = self.pte(va) if self.is_kernel(va) else None
        return None if e is None else (e & OA_MASK) | (va & (PAGE - 1))

    def _page(self, va):
        if self.is_kernel(va):
            e = self.pte(va)
            if e is None:
                return None
            f = os.path.join(self.dir, f"phys-{e & OA_MASK:#x}.bin")
            return open(f, "rb").read() if os.path.exists(f) else None
        for base, size, f in self.low:
            if base <= va < base + size:
                d = open(f, "rb").read()
                o = (va & ~(PAGE - 1)) - base
                return d[o:o + PAGE]
        return None

    def read(self, va, n):
        out = bytearray()
        while n:
            off = va & (PAGE - 1)
            k = min(n, PAGE - off)
            p = self._page(va)
            if p is None or len(p) < off + k:
                return None
            out += p[off:off + k]
            va += k; n -= k
        return bytes(out)

    def init_va(self, trace_dir=None):
        """InitData VA from events.jsonl: first EP 0x20 tx msg of type 0x81."""
        import json
        trace_dir = trace_dir or os.path.dirname(self.dir.rstrip("/"))
        for line in open(os.path.join(trace_dir, "events.jsonl")):
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("ep") == 0x20 and ev.get("dir") == "tx":
                m = int(str(ev.get("msg")), 16)
                if (m >> 48) & 0xff == 0x81:
                    return sign_extend_initdata(m & 0xFFFFFFFFFFFF)
        return None


def sign_extend_initdata(a):
    """What the firmware does: orr x8, x8, #0xfffff00000000000 (fn_32224)."""
    return a | 0xFFFFF00000000000
