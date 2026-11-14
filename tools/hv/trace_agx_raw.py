# SPDX-License-Identifier: GPL-2.0-or-later
# Raw GPU (AGX) tracer for m1n1's hypervisor: run with
#   run_guest.py ... -m tools/hv/trace_agx_raw.py kernelcache.macho -- ARGS
#
# It records, and does not interpret (docs/gpu/plan.md, phase 1): every
# gfx-asc mailbox message in both directions as JSON lines, and, when macOS
# first writes to a GPU application endpoint (0x20 and up, which starts the
# firmware), snapshots of the regions iBoot set up and of every page mapped in
# the firmware's address space (UAT context 0). The decoding happens offline
# in nixos-m4pro (lib/agx), against layout schemas per firmware version,
# because m1n1's own AGX tracer only knows firmware up to macOS 14.7.
#
# The UAT walker is used read-only: never UAT.init(), which rewrites tables.
# More snapshots: `echo LABEL > <trace dir>/snap-now` on the host; the next
# GPU message (checked every 64) takes snapshot "trigger-LABEL".
import datetime
import json
import os
import struct
import time

import importlib

from m1n1.trace.asc import ASCTracer, DIR
from m1n1.constructutils import Ver
from m1n1.utils import *

# m1n1 knows GPU generations up to G15X (M3); this is G16 (ADT soc_generation
# H16). The UAT level layout is chosen at import from Ver ("G >= G15": L0 at
# bit 42), so set the closest known generation before (re)loading it.
SOC_GEN = getattr(hv.u.adt["/arm-io"], "soc_generation", "?")
Ver.set_version_key("G", "G15X")
import m1n1.hw.uat
importlib.reload(m1n1.hw.uat)
from m1n1.hw.uat import UAT as _UAT, TTBR, PTE, Page_PTE

# Context 0's tables use the G15 layout on G16 too: L0 at bit 42, so each
# half is 42 bits (the init data says so itself: level shifts 36/25/14 with
# 64/2048/2048 entries). The kernel half macOS allocates in is reached
# through the tables in gfx-shared-region, not context 0's TTBR1 (empty);
# shared_tree() below captures those. AGX_UAT_L0_OFF overrides for checks.
L0_OFF = int(os.environ.get("AGX_UAT_L0_OFF", "42"))
m1n1.hw.uat.UAT_L0_OFF = L0_OFF

class UAT(_UAT):
    L0_OFF = L0_OFF
    L1_SIZE = 1 << (L0_OFF - _UAT.L1_OFF)
    LEVELS = [
        (L0_OFF, _UAT.L0_SIZE, TTBR),
        (_UAT.L1_OFF, 1 << (L0_OFF - _UAT.L1_OFF), PTE),
        (_UAT.L2_OFF, _UAT.Lx_SIZE, PTE),
        (_UAT.L3_OFF, _UAT.Lx_SIZE, Page_PTE),
    ]

OUT = os.environ.get(
    "AGX_RAW_DIR",
    os.path.join("build", "agx", "traces", datetime.datetime.now().strftime("%Y%m%d-%H%M%S")),
)
SNAPSHOT_LIMIT = int(os.environ.get("AGX_RAW_LIMIT", str(256 << 20)))  # bytes of mapped pages
BLOCK_LIMIT = 16 << 20  # skip single mappings larger than this (log them)
# DRAM on this machine: phys_base 0x10000000000, 24 GB. Anything else is a
# device and must not be read.
RAM_LO, RAM_HI = 0x10000000000, 0x10600000000

trace_device("/arm-io/sgx", False)
trace_device("/arm-io/gfx-asc", False)


class RawAGXTracer(ASCTracer):
    ENDPOINTS = {}

    def __init__(self, hv, devpath, out, verbose=1):
        super().__init__(hv, devpath, verbose)
        self.out = out
        os.makedirs(out, exist_ok=True)
        self.events = open(os.path.join(out, "events.jsonl"), "a", buffering=1)
        self.t0 = time.time()
        self.snapshots = 0
        self.snapped_init = False
        self.trigger = os.path.join(out, "snap-now")
        self.sgx = hv.u.adt["/arm-io/sgx"]
        self.uat = UAT(hv.iface, hv.u, hv)
        self.regions = {}
        for name in ("gpu-region", "gfx-shared-region", "gfx-shared-l2-region", "gfx-handoff",
                     "gfx-data", "gfx-data-shared-ro"):
            base = getattr(self.sgx, name + "-base", 0)
            size = getattr(self.sgx, name + "-size", 0)
            if base and size:
                self.regions[name] = (base, size)
        self.event("start", regions={k: [hex(b), hex(s)] for k, (b, s) in self.regions.items()},
                   chip=hex(hv.u.adt["/chosen"].chip_id), soc_generation=SOC_GEN,
                   uat_l0_off=L0_OFF)

    def event(self, kind, **fields):
        fields.update(t=round(time.time() - self.t0, 6), kind=kind)
        self.events.write(json.dumps(fields) + "\n")

    SNAP_AT = (500, 5000)  # more snapshots after this many messages

    def handle_msg(self, direction, r0, r1):
        tx = direction == DIR.TX
        self.nmsg = getattr(self, "nmsg", 0) + 1
        self.event("mbox", dir="tx" if tx else "rx", ep=int(r1.EP), msg=hex(int(r0.value)))
        if tx and int(r1.EP) >= 0x20 and not self.snapped_init:
            self.snapped_init = True
            self.snapshot("first-app-tx-ep%#x" % int(r1.EP))
        elif self.nmsg in self.SNAP_AT:
            self.snapshot("after-%d-msgs" % self.nmsg)
        elif self.nmsg % 64 == 0 and os.path.exists(self.trigger):
            # Snapshot on request from the host: `echo LABEL > OUT/snap-now`.
            with open(self.trigger) as f:
                label = f.read().strip() or "now"
            os.remove(self.trigger)
            self.snapshot("trigger-" + label.replace("/", "_").replace(" ", "_"))
        return super().handle_msg(direction, r0, r1)

    def raw_tables(self):
        """Every page-table page reachable from context 0's roots, whatever the
        level layout: valid entries (bit 0) with the table bit (bit 1) that
        point into RAM are followed, up to 4 levels below the roots. Leaf
        entries are not followed. The layout is decided offline."""
        ram_lo, ram_hi = RAM_LO, RAM_HI
        roots = []
        for half, raw in enumerate(struct.unpack_from("<QQ", self.hv.iface.readmem(self.regions["gpu-region"][0], 16))):
            if raw & 1:
                roots.append((half, raw & ~0x3fff & 0xffffffffffff))
        seen, frontier, tables = set(), [(r, 1, h) for h, r in roots], []
        while frontier:
            phys, depth, half = frontier.pop()
            if phys in seen or depth > 4 or not (ram_lo <= phys < ram_hi):
                continue
            seen.add(phys)
            data = self.hv.iface.readmem(phys, 0x4000)
            tables.append([hex(phys), depth, half])
            self._save(f"table-{phys:#x}.bin", data)
            for e in struct.unpack_from("<2048Q", data):
                if (e & 3) == 3:
                    frontier.append((e & 0x00ffffffffffc000, depth + 1, half))
        with open(os.path.join(self.dir, "tables.json"), "w") as f:
            json.dump({"roots": [[h, hex(r)] for h, r in roots], "tables": tables}, f)
        return len(tables)

    def shared_tree(self, leaf_limit=64 << 20):
        """The kernel/firmware half lives in tables inside gfx-shared-region
        (context 0's TTBR1 is empty on this firmware). Walk from its first
        page: entries with bits 0 and 1 set are followed as tables for two
        more levels; every valid entry of a third-level table is a page,
        saved by physical address. All entries go to shared.json raw (table,
        index, value), so the level layout is decided offline. Output
        addresses are 48 bits (OA mask 0xffffffffc000)."""
        oa = 0xffffffffc000
        root = self.regions["gfx-shared-region"][0]
        entries, leaves, total, seen = [], [], 0, set()
        frontier = [(root, 1)]
        while frontier:
            phys, depth = frontier.pop()
            if phys in seen:
                continue
            seen.add(phys)
            data = self.hv.iface.readmem(phys, 0x4000)
            self._save(f"shared-table-{phys:#x}.bin", data)
            for i, e in enumerate(struct.unpack_from("<2048Q", data)):
                if not e & 1:
                    continue
                entries.append([hex(phys), depth, i, hex(e)])
                target = e & oa
                # The firmware maps the GPU's registers too (0x2201c4000...):
                # reading device memory from here crashed the machine. Only
                # RAM is followed or saved; the rest stays in the entry list.
                if not (RAM_LO <= target < RAM_HI):
                    continue
                if depth < 3 and (e & 3) == 3:
                    frontier.append((target, depth + 1))
                elif depth == 3 and target not in seen and total < leaf_limit:
                    seen.add(target)
                    self._save(f"phys-{target:#x}.bin", self.hv.iface.readmem(target, 0x4000))
                    leaves.append(hex(target))
                    total += 0x4000
        with open(os.path.join(self.dir, "shared.json"), "w") as f:
            json.dump({"root": hex(root), "entries": entries, "leaves": leaves}, f)
        with open(os.path.join(self.dir, "shared.tsv"), "w") as f:
            f.write(f"root\t{root:#x}\n")
            for t, d, i, v in entries:
                f.write(f"entry\t{t}\t{d}\t{i}\t{v}\n")
        return len(leaves)

    def _save(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def snapshot(self, label):
        self.snapshots += 1
        self.dir = os.path.join(self.out, "%02d-%s" % (self.snapshots, label))
        os.makedirs(self.dir, exist_ok=True)
        self.log(f"[agx-raw] snapshot {self.dir}")
        for name, (base, size) in self.regions.items():
            self._save(f"region-{name}-{base:#x}.bin", self.hv.iface.readmem(base, size))
        pages, total, skipped = [], 0, []
        self.uat.invalidate_cache()

        def page(start, end, idx, pte, level, sparse=False):
            nonlocal total
            size = end - start + 1
            if not (RAM_LO <= pte.offset() < RAM_HI) or size > BLOCK_LIMIT or total + size > SNAPSHOT_LIMIT:
                skipped.append([hex(start), hex(size), hex(pte.offset())])
                return
            pages.append((start, size, pte.offset()))
            total += size

        try:
            self.uat.foreach_page(0, page)
        except Exception as e:
            self.event("uat-error", label=label, error=repr(e))
        index = []
        for start, size, phys in pages:
            data = self.hv.iface.readmem(phys, size)
            self._save(f"va-{start & 0xffffffffffffffff:016x}.bin", data)
            index.append([hex(start & 0xffffffffffffffff), hex(size), hex(phys)])
        try:
            ntables = self.raw_tables()
        except Exception as e:
            ntables = -1
            self.event("tables-error", label=label, error=repr(e))
        self.event("tables", label=label, tables=ntables)
        try:
            nleaves = self.shared_tree()
        except Exception as e:
            nleaves = -1
            self.event("shared-error", label=label, error=repr(e))
        self.event("shared", label=label, leaves=nleaves)
        with open(os.path.join(self.dir, "pages.tsv"), "w") as f:
            for va, size, phys in index:
                f.write(f"page\t{va}\t{size}\t{phys}\n")
        with open(os.path.join(self.dir, "pages.json"), "w") as f:
            json.dump({"mapped": index, "skipped": skipped}, f)
        self.event("snapshot", label=label, dir=self.dir, pages=len(index), bytes=total,
                   skipped=len(skipped))


agx_raw = RawAGXTracer(hv, "/arm-io/gfx-asc", OUT, verbose=1)
agx_raw.start()
print(f"[agx-raw] writing to {OUT}")
