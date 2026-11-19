# SPDX-License-Identifier: GPL-2.0-or-later
# GPU contexts other than 0, for trace_agx_raw.py's snapshots. Run in the
# hypervisor shell of a traced guest (it uses agx_raw and hv from there):
#   exec(open("tools/hv/agx_ctx_dump.py").read()); dump_contexts("label")
#
# Each process using the GPU has its own context: a TTBR0/TTBR1 pair in
# gpu-region (16 bytes per context, the context number in the top bits of
# each root). Unlike context 0, other contexts have their own TTBR1 tables,
# so both halves are walked (3 levels, shifts 36/25/14 as InitData declares),
# save its tables, and save the RAM pages of contexts that map at most
# max_bytes (the big ones are WindowServer and friends; skipped and logged).
# Output under <snapshot dir>/ctx-<n>-ttbr<0|1>/ with pages.tsv (va size phys).
import json
import os
import struct

def dump_contexts(label, max_bytes=64 << 20, contexts=range(1, 64)):
    oa = 0xffffffffc000
    agx_raw.snapshots += 1
    base = os.path.join(agx_raw.out, "%02d-%s" % (agx_raw.snapshots, label))
    os.makedirs(base, exist_ok=True)
    gpu_region = agx_raw.regions["gpu-region"][0]
    roots = agx_raw.hv.iface.readmem(gpu_region, 64 * 16)
    summary = []
    for ctx in contexts:
        for half in (0, 1):
            raw = struct.unpack_from("<Q", roots, ctx * 16 + 8 * half)[0]
            if not raw & 1:
                continue
            root = raw & oa
            if not (RAM_LO <= root < RAM_HI):
                continue
            # TTBR1 addresses are the high half: sign-extended from bit 42.
            top = (0xffffffffffffffff << 42) & 0xffffffffffffffff if half else 0
            d = os.path.join(base, "ctx-%d-ttbr%d" % (ctx, half))
            os.makedirs(d, exist_ok=True)
            leaves = []

            def walk(table, level, va):
                data = agx_raw.hv.iface.readmem(table, 0x4000)
                with open(os.path.join(d, "table-%#x.bin" % table), "wb") as f:
                    f.write(data)
                shift = (36, 25, 14)[level]
                count = (64, 2048, 2048)[level]
                for i, e in enumerate(struct.unpack_from("<%dQ" % count, data)):
                    if not e & 1:
                        continue
                    target = e & oa
                    if not (RAM_LO <= target < RAM_HI):
                        continue
                    if level < 2:
                        if (e & 3) == 3:
                            walk(target, level + 1, va | (i << shift))
                    else:
                        leaves.append((top | va | (i << shift), target))

            walk(root, 0, 0)
            total = len(leaves) * 0x4000
            saved = total <= max_bytes
            if saved:
                with open(os.path.join(d, "pages.tsv"), "w") as f:
                    for va, phys in leaves:
                        with open(os.path.join(d, "va-%016x.bin" % va), "wb") as g:
                            g.write(agx_raw.hv.iface.readmem(phys, 0x4000))
                        f.write("page\t%#x\t0x4000\t%#x\n" % (va, phys))
            summary.append([ctx, half, hex(raw), len(leaves), saved])
    with open(os.path.join(base, "contexts.json"), "w") as f:
        json.dump(summary, f)
    agx_raw.event("contexts", label=label, dir=base, contexts=summary)
    agx_raw.log("[agx-raw] contexts %s: %s" % (base, summary))
