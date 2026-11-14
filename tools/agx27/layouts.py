# SPDX-License-Identifier: GPL-2.0-or-later
"""AGX firmware 27.2 (T6040, "g16s b0") structure layouts, as currently decoded.

Transcribed by hand from the OCaml schemas in lib/agx/ (initdata.ml,
regionb.ml, cmdqueue.ml, hwdata.ml) -- those are the source of truth; when
they change, change this file (or, later, generate it: docs/gpu/plan.md tool
6, `agx gen python`). Field names are kept identical so a decode here and an
`nixos-m4pro agx decode` print the same names.

Deliberately not `construct`: a tiny packed-struct engine with the same type
vocabulary as lib/agx/schema.ml (U8..U64, F32, Ptr, Bytes, Array, Struct),
so the transcription is one line per OCaml field and offsets can be
asserted against the anchors the decode established. Everything is
little-endian and packed (no implicit alignment), like the firmware's
structs.

TODO markers name the parts that are NOT decoded; anything built from them
is a guess (zeros or a copy of the macOS snapshot).
"""

import struct

# --------------------------------------------------------------------------
# Type vocabulary (mirrors lib/agx/schema.ml)

class Ty:
    size = 0
    def default(self): raise NotImplementedError
    def pack_into(self, buf, off, v): raise NotImplementedError
    def unpack_from(self, buf, off): raise NotImplementedError

class _Scalar(Ty):
    def __init__(self, fmt, size):
        self.fmt, self.size = "<" + fmt, size
    def default(self): return 0
    def pack_into(self, buf, off, v):
        if self.fmt[-1] in "BHIQ":
            v &= (1 << (8 * self.size)) - 1  # allow -1 for all-ones
        struct.pack_into(self.fmt, buf, off, v)
    def unpack_from(self, buf, off):
        return struct.unpack_from(self.fmt, buf, off)[0]

U8, U16, U32, U64 = _Scalar("B", 1), _Scalar("H", 2), _Scalar("I", 4), _Scalar("Q", 8)
F32 = _Scalar("f", 4)

class Ptr(_Scalar):
    """A 64-bit GPU VA (kernel half, 0xfffffc.. for firmware-visible objects)."""
    def __init__(self, target=""):
        super().__init__("Q", 8)
        self.target = target

class Bytes(Ty):
    def __init__(self, n): self.size = n
    def default(self): return bytes(self.size)
    def pack_into(self, buf, off, v):
        v = bytes(v)
        assert len(v) <= self.size, (len(v), self.size)
        buf[off:off + len(v)] = v
    def unpack_from(self, buf, off): return bytes(buf[off:off + self.size])

class Array(Ty):
    def __init__(self, n, ty):
        self.n, self.ty, self.size = n, ty, n * ty.size
    def default(self): return [self.ty.default() for _ in range(self.n)]
    def pack_into(self, buf, off, v):
        assert len(v) <= self.n, (len(v), self.n)
        for i, x in enumerate(v):
            self.ty.pack_into(buf, off + i * self.ty.size, x)
    def unpack_from(self, buf, off):
        return [self.ty.unpack_from(buf, off + i * self.ty.size) for i in range(self.n)]

class Struct(Ty):
    """Packed struct. fields: list of (name, Ty). Values are plain dicts."""
    def __init__(self, name, fields, size=None, anchors=None):
        self.name, self.fields = name, fields
        self.offsets, off = {}, 0
        for fname, ty in fields:
            assert fname not in self.offsets, (name, fname)
            self.offsets[fname] = off
            off += ty.size
        self.size = off
        if size is not None:
            assert off == size, f"{name}: size {off:#x} != {size:#x}"
        for fname, want in (anchors or {}).items():
            got = self.offsets[fname]
            assert got == want, f"{name}.{fname}: offset {got:#x} != {want:#x}"
        self.types = dict(fields)

    def default(self):
        return {n: t.default() for n, t in self.fields}

    def pack_into(self, buf, off, v):
        for fname, x in v.items():
            if fname not in self.offsets:
                raise KeyError(f"{self.name} has no field {fname}")
            self.types[fname].pack_into(buf, off + self.offsets[fname], x)

    def unpack_from(self, buf, off):
        return {n: t.unpack_from(buf, off + self.offsets[n]) for n, t in self.fields}

    def build(self, values=None, base=None):
        """bytes of the struct: [base] (raw bytes, e.g. a snapshot) overlaid with [values]."""
        buf = bytearray(base[:self.size] if base is not None else bytes(self.size))
        buf += bytes(self.size - len(buf))
        self.pack_into(buf, 0, values or {})
        return bytes(buf)

    def parse(self, data, off=0):
        return self.unpack_from(data, off)

    def offset(self, path):
        """Byte offset of a dotted path, e.g. 'io_mappings.17.virt_addr'."""
        ty, off = self, 0
        for p in path.split("."):
            if isinstance(ty, Struct):
                off += ty.offsets[p]; ty = ty.types[p]
            elif isinstance(ty, Array):
                off += int(p, 0) * ty.ty.size; ty = ty.ty
            else:
                raise KeyError(path)
        return off

    def field_at(self, off):
        """Dotted path of the scalar containing byte [off] (for diff reports)."""
        ty, path = self, []
        while True:
            if isinstance(ty, Struct):
                for n, t in ty.fields:
                    o = ty.offsets[n]
                    if o <= off < o + t.size:
                        path.append(n); off -= o; ty = t; break
                else:
                    return ".".join(path) + f"+{off:#x}?"
            elif isinstance(ty, Array):
                i = off // ty.ty.size
                path.append(str(i)); off -= i * ty.ty.size; ty = ty.ty
            else:
                return ".".join(path) + (f"+{off:#x}" if off else "")


# --------------------------------------------------------------------------
# InitData (lib/agx/initdata.ml). Address goes in message 0x81 on EP 0x20.

INITDATA_FINGERPRINT_27_2 = 0x0C8B6339839804C0  # InitData+0 (ver_info) must equal this

UatLevelInfo = Struct("UatLevelInfo", [
    ("unk_3", U8),         # always 8
    ("unk_1", U8),         # 14
    ("unk_2", U8),         # 14
    ("index_shift", U8),
    ("num_entries", U16),
    ("unk_4", U16),        # 0x4000
    ("unk_8", U64),        # 1
    ("phys_mask", U64),
    ("index_mask", U64),
], size=0x20)

InitData27 = Struct("InitData27", [
    ("ver_info", U64),                     # 13.x: 4 x u16; 27.2 interface fingerprint
    ("region_a", Ptr("RegionA")),          # TODO RegionA: content undecoded (13.x: 0x4000 empty buffer)
    ("unk_8", U32),
    ("unk_c", U32),
    ("region_b", Ptr("RegionB27")),        # firmware global 0x11e9e8, "the ctx"
    ("region_c", Ptr("RegionC27")),        # firmware global 0x126130. TODO RegionC undecoded
    ("unk_28", U32),                       # 13.x fw_status pointer is gone; 0
    ("host_mapped_fw_allocations_27", U32),  # must be nonzero (firmware refuses 0)
    ("uat_page_size", U16),
    ("uat_page_bits", U8),
    ("uat_num_levels", U8),
    ("uat_level_info", Array(3, UatLevelInfo)),
    ("pad_8c", Bytes(0x14)),               # (13.x name; sits at +0x94 here)
    # TODO: the four new pointers. Readers known (firmware-decode.md), targets unnamed.
    ("ptr_a8", Ptr("")),   # -> global 0x11e918; agx_scheduler, MCWWaitForIdle; writes +0xc..+0x1c
    ("ptr_b0", Ptr("")),   # -> global 0x11f398; DrainDeviceControlRing; reads +0..+0x930, ptrs +0x4058..+0x4ad0
    ("ptr_b8", Ptr("")),   # -> global 0x126138; fn_2ff18, perf-state code; u32s +0x8..+0x6a4
    ("ptr_c0", Ptr("")),   # -> global 0x11e8f0; no direct reads; zero in the snapshot
], size=0xc8, anchors={"region_b": 0x18, "region_c": 0x20, "host_mapped_fw_allocations_27": 0x2c,
                       "uat_page_size": 0x30, "uat_level_info": 0x34, "ptr_a8": 0xa8, "ptr_c0": 0xc0})

# --------------------------------------------------------------------------
# RegionB (lib/agx/regionb.ml)

QUEUE_CHANNELS = ["ta_0", "3d_0", "cl_0", "ta_1", "3d_1", "cl_1",
                  "ta_2", "3d_2", "cl_2", "ta_3", "3d_3", "cl_3", "dev_ctrl"]

ChannelCounter = Struct("ChannelCounter", [("value", U32), ("pad", Bytes(0xc))], size=0x10)

# Per-queue state block (0x40): counters at +0 (read), +0x10 (?), +0x20 (host write).
# States sit in per-kind arrays: TA at +0x000, 3D +0x100, CL +0x200, 0x40/queue, queues reversed.
ChannelState27 = Struct("ChannelState27", [
    ("read_ptr", U32), ("pad_04", Bytes(0xc)),
    ("field_10", U32), ("pad_14", Bytes(0xc)),
    ("write_ptr", U32), ("pad_24", Bytes(0xc)),
    ("pad_30", Bytes(0x10)),  # unused in traces
], size=0x40)

ChannelInfo27 = Struct("ChannelInfo27", [
    ("read_ptr", Ptr("ChannelCounter")),
    ("ptr_10", Ptr("ChannelCounter")),
    ("write_ptr", Ptr("ChannelCounter")),
    ("ring", Ptr("")),
], size=0x20)

QueueChannels27 = Struct("QueueChannels27", [(n, ChannelInfo27) for n in QUEUE_CHANNELS], size=13 * 0x20)

RunCmdQueueMsg27 = Struct("RunCmdQueueMsg27", [
    ("queue_type", U32),
    ("pad_04", U32),
    ("cmd_queue", Ptr("CommandQueueInfo27")),
    ("unk_10", U32),      # 1
    ("event", U16),       # +2 per submission
    ("unk_16", U8),       # 5
    ("new_queue", U8),
], size=0x18)

QUEUE_RING_ENTRIES = 0x100   # rings observed 0x1800 apart = 0x100 * 0x18

RegionB27 = Struct("RegionB27", [
    ("hwdata_b", Ptr("HwDataB27")),  # 13.x RegionB+0x1a0
    ("hdr_ptr_08", Ptr("")),         # TODO: same target as hdr_ptr_10 in the snapshot (HwDataB+0xc880)
    ("hdr_ptr_10", Ptr("")),
    ("hdr_18", U64),
    ("queues", QueueChannels27),
    # TODO: auxiliary channels (event, fw log, ktrace, stats?) at +0x1c0: 9 pointers seen,
    # shape not decoded. Then more pointers/u32s up to at least +0x2f0 in the snapshot
    # (+0x2d0.. look like (GPU VA, phys|flags) pairs). Size of RegionB unknown.
    ("aux", Array(9, Ptr(""))),
    ("todo_208", Bytes(0x100)),
], anchors={"queues": 0x20, "aux": 0x1c0})

# --------------------------------------------------------------------------
# Command queues (lib/agx/cmdqueue.ml)

CommandQueuePointers = Struct("CommandQueuePointers", [
    ("gpu_doneptr", U32), ("pad_04", Bytes(0xc)),
    ("unk_10", U32), ("pad_14", Bytes(0xc)),
    ("unk_20", U32), ("pad_24", Bytes(0xc)),
    ("gpu_rptr", U32), ("pad_34", Bytes(0xc)),
    ("cpu_wptr", U32), ("pad_44", Bytes(0xc)),
    ("rb_size", U32),
], size=0x54)

JobList = Struct("JobList", [("first_job", U64), ("last_head", Ptr("")), ("unkptr_10", U64)], size=0x18)

CommandQueueInfo27 = Struct("CommandQueueInfo27", [
    ("pointers", Ptr("CommandQueuePointers")),
    ("rb", Ptr("")),
    ("job_list", Ptr("JobList")),
    ("gpu_rptr1", U32),
    ("gpu_rptr2", U32),
    ("gpu_rptr3", U32),
    ("event_id", U32),    # -1
    ("unk_28", U32),
    ("unk_2c", U32),
    ("unk_30", U64),
    ("unk_38", U32),
    ("unk_3c", U32),
    ("unk_40", U32),      # -1
    ("unk_44", U32),      # per queue; 13.x uuid?
    ("pad_48", Bytes(0x20)),
    ("unk_68", U64),      # a counter
    ("gpu_context", Ptr("")),
    ("unk_78", U64),
], size=0x80)

# Work commands seen (not decoded): type 0xf (0xc0 bytes) and 0x10 (0x40 bytes).

# --------------------------------------------------------------------------
# HwDataB (lib/agx/hwdata.ml), RegionB+0, 0x2850 bytes

IOMapping27 = Struct("IOMapping27", [
    ("phys_addr", U64),
    ("virt_addr", U64),
    ("size", U32),
    ("range_size", U32),
    ("sgx_offset", U64),   # phys - 0x288000000 inside the GPU register space, else 0
    ("flags", U32),        # 0 or 2
    ("pad_24", U32),
], size=0x28)

HwRing27 = Struct("HwRing27", [
    ("gpu_va", U64),
    ("fw_va", U64),
    ("size", U32),         # 0x800
    ("entry_size", U32),   # 0x40
    ("hw_slot", U32),
    ("fw_state", U32),     # written by the firmware
], size=0x20)

V16 = Array(16, U32)
V16x16 = Array(16, Array(16, U32))

HwDataB27 = Struct("HwDataB27", [
    # TODO head: 13.x timestamp_region_base at +0x28, yuv matrices. Not decoded;
    # snapshot has u32/u64s at +0..+0x30 (+0x28 is a kernel VA) and
    # 0x2008/0x24cb-style matrix words at +0xe0 and +0x2d8.
    ("head", Bytes(0x640)),
    ("io_mappings", Array(60, IOMapping27)),
    ("sgx_sram_ptr", U64),
    ("sram_size", U64),            # 0x8000
    ("chip_id", U32),
    ("unk_fb4", Array(14, U32)),   # 13.x unk_454..unk_48c, one fewer
    ("base_clock_khz", U32),
    ("unk_ff0", U32),              # 1
    ("power_sample_period", U32),
    ("unk_ff8", U32),
    ("unk_49c", Array(3, U32)),
    ("pad_1008", U32),
    ("unk_4ac", U32),
    ("unk_1010", U32),
    ("pad_1014", U32),
    ("unk_4b8", U32),
    ("unk_4bc", U32),
    ("unk_4c0", U32),              # 0x1f
    ("unk_4c4", Array(5, U32)),
    ("unk_4d8", U32),
    ("unk_4dc", U32),
    ("unk_4e0", U64),              # 0xc_07002004
    ("unk_4e8", Array(7, U32)),
    ("unk_504_0", U32),
    ("unk_504", U32),              # 0x31
    ("unk_508", Array(7, U32)),
    ("unk_524", U32),              # 1
    ("unk_528", Array(6, U32)),
    ("num_frags", U32),            # 20
    ("unk_10a8", U64),             # 15 = gpu-num-perf-states
    ("unk_10b0", Bytes(0x24)),
    ("gpu_core", U32),             # 19 = G16
    ("gpu_rev", U32),              # 4
    ("num_cores", U32),            # 20
    ("max_pstate", U32),           # 10
    ("frequencies", V16),          # MHz
    ("voltages", V16x16),          # mV
    ("voltages_sram", V16x16),
    ("frequencies_alt", V16),
    ("unk_9b4", Array(16, F32)),   # 1.02
    ("unk_9f4", V16),
    ("rel_max_powers", Array(16, F32)),
    ("rel_boost_freqs", Array(16, F32)),
    ("unk_1a64", Array(16, F32)),
    ("unk_1aa4", Bytes(0x40)),
    ("pstate_map", Array(2, V16)),
    ("cs_table", Bytes(0x148)),    # TODO: zero under macOS; probably cs_* (same size as AFR block)
    ("afr_pstate_limit", U32),
    ("afr_max_pstate", U32),
    ("afr_frequencies", V16),
    ("afr_voltages", Array(16, Array(2, U32))),
    ("afr_voltages_sram", Array(16, Array(2, U32))),
    ("max_pstate_alt", U32),
    ("frequencies_alt2", V16),
    ("voltages_alt", V16x16),
    ("voltages_sram_alt", V16x16),
    ("pad_2638", U32),
    ("pad_263c", Bytes(0x20)),
    ("unk_265c", U32),
    ("unk_2660", U32),             # 5
    ("unk_ae4", Array(4, U32)),    # 6 3 7 7
    ("unk_2674", U32),
    ("unk_2678", U32),
    ("unk_267c", U64),
    ("unk_2684", U32),
    ("unk_2688", Array(4, U32)),   # 0 0x10 0 1
    ("sched_ts_base", U64),
    ("sched_ts_offset", U64),
    ("unk_26a8", Array(2, U32)),
    ("unk_26b0", U32),             # 0x1e0000
    ("unk_b20", U32),
    ("unk_b24", Array(2, U32)),
    ("unk_b2c", U32),
    ("unk_b30", U32),
    ("unk_b34", U32),
    ("unk_b38_0", Array(2, U32)),
    ("gl2_poll_timeout", U32),
    ("unk_b38", Array(6, U64)),    # all ones
    ("unk_b68", U32),
    ("unk_270c", U32),
    ("gin1114_swwa", U32),         # 2
    ("unk_2714", U32),
    ("kick_defer_enable", U32),    # 1
    ("sched_pause_timeout_us", U32),  # 150
    ("unk_2720", Array(2, U32)),
    ("power_hook_disable", U32),
    ("unk_272c", U32),
    ("trace_enable", U32),
    ("unk_2734", U64),
    ("unk_273c", U32),
    ("hw_rings", Array(4, HwRing27)),
    ("unk_27c0", Bytes(0x18)),
    ("counter_ctl", U64),          # GPU VA of a host page of counter thresholds
    ("unk_27e0", U64),             # GPU VA
    ("unk_27e8", U32),
    ("unk_27ec", U32),
    ("unk_27f0", U32),
    ("unk_27f4", Bytes(0x18)),
    ("unk_280c", Array(2, U32)),
    ("unk_2814", Bytes(8)),
    ("unk_281c", U32),
    ("unk_2820", Array(2, U32)),
    ("unk_2828", U8),
    ("unk_2829", U8),
    ("unk_282a", Bytes(0x14)),
    ("hrb_mode", U32),             # +0x283e; 3 = alternate HRB path
    ("unk_2842", U32),
    ("unk_2846", U32),
    ("unk_284a", U32),
    ("pad_284e", Bytes(2)),
], size=0x2850, anchors={
    "io_mappings": 0x640, "sgx_sram_ptr": 0xfa0, "sram_size": 0xfa8, "chip_id": 0xfb0,
    "base_clock_khz": 0xfec, "unk_ff0": 0xff0, "power_sample_period": 0xff4, "unk_ff8": 0xff8,
    "unk_1010": 0x1010, "num_frags": 0x10a4, "unk_10a8": 0x10a8, "gpu_core": 0x10d4,
    "max_pstate": 0x10e0, "frequencies": 0x10e4, "voltages": 0x1124, "voltages_sram": 0x1524,
    "frequencies_alt": 0x1924, "unk_9b4": 0x1964, "rel_max_powers": 0x19e4, "rel_boost_freqs": 0x1a24,
    "pstate_map": 0x1ae4, "cs_table": 0x1b64, "afr_pstate_limit": 0x1cac, "max_pstate_alt": 0x1df4,
    "pad_2638": 0x2638, "unk_ae4": 0x2664, "gl2_poll_timeout": 0x26d4, "unk_b38": 0x26d8,
    "gin1114_swwa": 0x2710, "kick_defer_enable": 0x2718, "sched_pause_timeout_us": 0x271c,
    "power_hook_disable": 0x2728, "trace_enable": 0x2730, "hw_rings": 0x2740,
    "counter_ctl": 0x27d8, "hrb_mode": 0x283e, "unk_2846": 0x2846,
})
assert HwDataB27.offset("io_mappings.17") == 0x8e8  # fn_32224 copies +0x8e8..+0x90b

# --------------------------------------------------------------------------
# TODO: undecoded structures. Only placeholders (sizes are lower bounds from
# the firmware's reads, firmware-decode.md); content must come from the
# snapshot until decoded.

REGION_C_MIN_SIZE = 0xe20     # firmware reads u32s +0..+0xe1c (13.x RegionC was 0x88000)
REGION_A_SIZE = 0x4000        # 13.x; unknown in 27.2
PTR_A8_MIN_SIZE = 0x20        # writes at +0xc..+0x1c
PTR_B0_MIN_SIZE = 0x4ad8      # reads up to pointers at +0x4ad0
PTR_B8_MIN_SIZE = 0x6a8       # u32s +0x8..+0x6a4
PTR_C0_MIN_SIZE = 0x0         # unknown (zero in the snapshot)

# Firmware region-type ids (kAGFIPIORegionType*), the io_mappings slot index.
REGION_NAMES = {
    0x00: "MCacheRegisters", 0x01: "FenderRegsHWL", 0x02: "TempSensorRegister", 0x03: "MTRPMSRegisters",
    0x04: "GPCAICSWInt", 0x05: "AICBankedRegisters", 0x06: "PMGRScratch", 0x07: "SpecialAgentIdleDie0",
    0x09: "SpecialAgentIdleDie1", 0x0a: "PushTelemetryDashboardConfigSpace", 0x0b: "PushTelemetryDashboard",
    0x0c: "GFXCAXI2AFRegisters", 0x0d: "ANE0Registers", 0x0e: "MTRRegisters", 0x0f: "ANE1Registers",
    0x10: "GTIRegisters", 0x11: "(GPU registers, sgx reg 0)", 0x12: "PushTelemetryDashboardReadSpace",
    0x16: "AFRD2DNIRegisters", 0x17: "DVFMMgpuRegisters", 0x18: "AONPTDSpace", 0x19: "PMCRegisters",
    0x1a: "CSRIFPerf", 0x1b: "GPUCTLRIFPerf", 0x1d: "HAT", 0x1e: "DPEPRegisters",
    0x20: "FenderRegsGFenderCfg", 0x21: "GMGIFAFRegisters", 0x22: "CRERegisters", 0x23: "FenderRegsGCPMS",
    0x24: "FenderRegsKSMFE", 0x25: "FenderRegsMCW", 0x26: "FenderRegsScratchRam", 0x27: "FenderRegsBumper",
    0x28: "FenderRegsPRC", 0x29: "FenderRegsDFenderMGPUCfg", 0x2a: "FenderRegsDFenderPowerTransG16G",
    0x2b: "FenderRegsDFenderCSCfg", 0x2c: "PMPDoorbell", 0x2d: "FenderRegsIVDM", 0x2e: "GFXCLKGENMGPU",
    0x2f: "ThrtlStatCntrsCSRegisters", 0x30: "AVMRControllerFastRegisters", 0x31: "FenderRegsAFRNIA",
    0x35: "DVFMAFRRegisters", 0x36: "DpwrMXURegisters", 0x37: "PmgrMiscDie0", 0x38: "AFRDCPMS",
    0x39: "PmgrMiscDie1", 0x3a: "ThrtlStatCntrsRegisters", 0x3b: "AFRRegisters",
}

ALL = [UatLevelInfo, InitData27, ChannelCounter, ChannelState27, ChannelInfo27, QueueChannels27,
       RunCmdQueueMsg27, RegionB27, CommandQueuePointers, JobList, CommandQueueInfo27,
       IOMapping27, HwRing27, HwDataB27]

if __name__ == "__main__":
    for s in ALL:
        print(f"{s.name:24s} {s.size:#07x}")
