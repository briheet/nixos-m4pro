(* HwDataB: the host's description of the GPU's hardware, which the firmware
   reads at boot (RegionB+0 in 27.2; 13.x had it at RegionB+0x1a0).

   Identified 2026-11-14 from the firmware itself (lib/fw, docs/gpu/
   firmware-decode.md) and checked against a macOS snapshot:
   - io_mappings at +0x640, as in 13.x, but 60 entries of 0x28 bytes indexed
     by the firmware's kAGFIPIORegionType ids (13.x: 0x19 of 0x20). Slot
     0x11 is the GPU register block (sgx reg 0, phys 0x288000000); its virt
     is the base the HAL uses for most register access.
   - Entry +0x18 holds the block's offset from 0x288000000 when the block is
     inside the GPU's register space (13.x: readwrite); +0x20 is new (0/2).
   - After the table: sgx_sram_ptr, a new u64 (0x8000; the SRAM size?),
     chip_id (0x6040), 14 u32 that follow 13.x's unk_454.. pattern with one
     dropped, base_clock_khz (24000), then a new u32 before
     power_sample_period (8).
   The firmware copies io_mappings[0x11] (+0x8e8..+0x90b) into its globals
   at boot (fn_32224), and walks all 60 for its crash log (fn_35d7c). *)

open Schema

let () =
  Hashtbl.replace structs "IOMapping27"
    [
      f "phys_addr" U64;
      f "virt_addr" U64;
      f "size" U32;
      f "range_size" U32;
      f "sgx_offset" U64 (* phys - 0x288000000 inside the GPU's register space, else 0 *);
      f "flags" U32 (* 0 or 2 *);
      f "pad_24" U32;
    ];
  (* A ring the firmware programs into GPU registers 0x21148 + slot*8 as
     base | size << 48 | 1. *)
  Hashtbl.replace structs "HwRing27"
    [
      f "gpu_va" U64;
      f "fw_va" U64;
      f "size" U32 (* 0x800 *);
      f "entry_size" U32 (* 0x40 *);
      f "hw_slot" U32;
      f "fw_state" U32 (* written by the firmware *);
    ];
  (* RegionA (InitData+0x8): register writes the firmware performs on every
     power-up (fn_7ce4), ended by type 0. reg is an offset in the GPU's
     register space, translated through io_mappings. macOS gives an empty
     list (0x4000 zero bytes); the pointer must still be valid. *)
  Hashtbl.replace structs "RegionAEntry27"
    [
      f "value" U64;
      f "reg" U32;
      f "shift" U32 (* type 3 only *);
      f "kind" U32 (* 0 end, 1 write32, 2 write64, 3 write64 value >> shift *);
      f "pad" U32;
    ];
  Hashtbl.replace structs "HwDataB27"
    [
      (* +0..+0x640: 13.5's layout unchanged; the firmware reads only
         timestamp_region_base. Values are macOS's (13.x m1n1 in brackets). *)
      f "unk_8" U64 (* 0x6f_00000000 [0x14_00000000] *);
      f "unk_18" U64 (* 0xffc00000 *);
      f "unk_20" U64 (* 0x10_00000000 [0x11_00000000] *);
      f "unk_28" U64 (* 0x10_00000000 *);
      f "unk_30" U64 (* 0x2ff_ffff8000: user VA top (0x300_0000_0000) - 2 pages *);
      f "timestamp_region_base" U64
      (* base of a 64 MiB window; completion timestamps are written only
         through command pointers inside it *);
      f "pad_40" (Bytes 0x20);
      f "yuv_matrices" (Array (63, Array (3, Array (4, U16))))
      (* i16; macOS fills slots 6, 7, 27, 38, 39, 59 only *);
      f "pad_1c8" (Bytes 8);
      f "io_mappings" (Array (60, Struct "IOMapping27"));
      f "sgx_sram_ptr" U64;
      f "sram_size" U64 (* new in 27; 0x8000 *);
      f "chip_id" U32;
      f "unk_fb4" (Array (14, U32)) (* 13.x unk_454..unk_48c, one fewer *);
      f "base_clock_khz" U32;
      f "unk_ff0" U32 (* new; 1 *);
      f "power_sample_period" U32;
      (* 13.5 +0x9b0.. at +0x648. Two former paddings are fields now
         (fn_32224 copies +0xff8 and +0x1010). *)
      f "unk_ff8" U32;
      f "unk_49c" (Array (3, U32)) (* 1 1 1 *);
      f "pad_1008" U32;
      f "unk_4ac" U32;
      f "unk_1010" U32;
      f "pad_1014" U32;
      f "unk_4b8" U32;
      f "unk_4bc" U32;
      f "unk_4c0" U32 (* 0x1f *);
      f "unk_4c4" (Array (5, U32));
      f "unk_4d8" U32;
      f "unk_4dc" U32;
      f "unk_4e0" U64 (* 0xc_07002004; 13.x: 4 *);
      f "unk_4e8" (Array (7, U32)) (* 13.x unk_4e8..unk_500; +0x1050 = 1, +0x1054 = 1 *);
      f "unk_504_0" U32;
      f "unk_504" U32 (* 0x31 *);
      f "unk_508" (Array (7, U32));
      f "unk_524" U32 (* 1 *);
      f "unk_528" (Array (6, U32));
      f "num_frags" U32 (* 20 *);
      f "unk_10a8" U64 (* new: 15, the ADT's gpu-num-perf-states *);
      f "unk_10b0" (Bytes 0x24)
      (* zero; 13.x unk_540..unk_554 and gpu_region_base, plus one inserted
         word: not read by the firmware *);
      f "gpu_core" U32 (* 19 = G16 *);
      f "gpu_rev" U32 (* 4 *);
      f "num_cores" U32 (* 20 *);
      (* The DVFS table: 11 live pstates (0..max_pstate) of 16, chosen from
         the ADT's 16 perf states by pstate_map[0]; 16 voltage columns
         (13.x: 8), columns 0/1 = ADT perf tables 0/1 (one per die), the
         rest copies of column 0. *)
      f "max_pstate" U32 (* 10 *);
      f "frequencies" (Array (16, U32)) (* MHz *);
      f "voltages" (Array (16, Array (16, U32))) (* mV *);
      f "voltages_sram" (Array (16, Array (16, U32))) (* max(810, v) *);
      f "frequencies_alt" (Array (16, U32))
      (* 13.x unk_9f4_0: the alternate curve (pstate_map[1]), the lower of
         the two ADT frequencies at each voltage above 765 mV *);
      f "unk_9b4" (Array (16, F32)) (* 1.02 *);
      f "unk_9f4" (Array (16, U32));
      f "rel_max_powers" (Array (16, F32)) (* 13.x u32 *);
      f "rel_boost_freqs" (Array (16, F32)) (* (f - f[1]) / (f[max] - f[1]) * 100; 13.x u32 *);
      f "unk_1a64" (Array (16, F32)) (* new; copied pairwise with afr_frequencies *);
      f "unk_1aa4" (Bytes 0x40);
      f "pstate_map" (Array (2, Array (16, U32))) (* 13.x unk_arr_0: ADT perf-state index per pstate, main/alt *);
      f "cs_table" (Bytes 0x148) (* zero under macOS; same size as the AFR block: probably cs_* *);
      f "afr_pstate_limit" U32 (* 7 *);
      f "afr_max_pstate" U32 (* 7 *);
      f "afr_frequencies" (Array (16, U32)) (* MHz, 13.x [8] *);
      f "afr_voltages" (Array (16, Array (2, U32))) (* [mV, 0] *);
      f "afr_voltages_sram" (Array (16, Array (2, U32)));
      (* new: the alternate curve's full table, same shape as max_pstate.. *)
      f "max_pstate_alt" U32;
      f "frequencies_alt2" (Array (16, U32));
      f "voltages_alt" (Array (16, Array (16, U32)));
      f "voltages_sram_alt" (Array (16, Array (16, U32)));
      f "pad_2638" U32;
      (* The tail (agent decode 2026-11-14 from the firmware's reads;
         fn_32224 copies most of these into globals at 0x121118..). 13.x
         anchors: unk_ae4 at +0x2664, unk_b38 (6 x all-ones) at +0x26d8;
         13.x's zero blob unk_b6c became real fields at +0x2710... *)
      f "pad_263c" (Bytes 0x20);
      f "unk_265c" U32 (* flag bits 0..2 *);
      f "unk_2660" U32 (* 5 *);
      f "unk_ae4" (Array (4, U32)) (* 6 3 7 7 *);
      f "unk_2674" U32;
      f "unk_2678" U32;
      f "unk_267c" U64 (* written to [0x11ff40]+0xa0/0xa4 when nonzero *);
      f "unk_2684" U32;
      f "unk_2688" (Array (4, U32)) (* 0 0x10 0 1 *);
      f "sched_ts_base" U64;
      f "sched_ts_offset" U64 (* added to the timestamp in scheduler logs *);
      f "unk_26a8" (Array (2, U32));
      f "unk_26b0" U32 (* 0x1e0000; fn_1e730 uses it >> 17 as a limit *);
      f "unk_b20" U32;
      f "unk_b24" (Array (2, U32)) (* 1 1 *);
      f "unk_b2c" U32 (* 1; tested at ~157 sites with power state 3 *);
      f "unk_b30" U32;
      f "unk_b34" U32 (* 1 *);
      f "unk_b38_0" (Array (2, U32)) (* 1 1 *);
      f "gl2_poll_timeout" U32 (* 13.x unk_b38_8; -1 none, min 30 *);
      f "unk_b38" (Array (6, U64)) (* all ones *);
      f "unk_b68" U32;
      f "unk_270c" U32;
      f "gin1114_swwa" U32 (* 2; "GIN-1114: AGFGIN1114Init(swwa=%u)" *);
      f "unk_2714" U32;
      f "kick_defer_enable" U32 (* 1: ref-counted deferred kicks *);
      f "sched_pause_timeout_us" U32 (* 150; "Unexpected scheduling pause timeout" *);
      f "unk_2720" (Array (2, U32));
      f "power_hook_disable" U32 (* nonzero skips three power helpers *);
      f "unk_272c" U32;
      f "trace_enable" U32 (* 1; completion/kick trace calls *);
      f "unk_2734" U64 (* 1; combined with unk_273c << 40 into descriptors *);
      f "unk_273c" U32 (* 0x100 *);
      f "hw_rings" (Array (4, Struct "HwRing27"));
      f "unk_27c0" (Bytes 0x18);
      f "counter_ctl" U64 (* GPU VA of a host page of counter thresholds *);
      f "unk_27e0" U64 (* GPU VA *);
      f "unk_27e8" U32 (* 1 *);
      f "unk_27ec" U32 (* 1 *);
      f "unk_27f0" U32;
      f "unk_27f4" (Bytes 0x18);
      f "unk_280c" (Array (2, U32));
      f "unk_2814" (Bytes 8);
      f "unk_281c" U32 (* 1 *);
      f "unk_2820" (Array (2, U32));
      f "unk_2828" U8;
      f "unk_2829" U8;
      f "unk_282a" (Bytes 0x14);
      f "hrb_mode" U32 (* +0x283e, 2-byte aligned; 3 = alternate HRB kick/completion *);
      f "unk_2842" U32;
      f "unk_2846" U32 (* 1: sets GPU register 0xbc08 bit 0, 0xbc00 bits 0x600 *);
      f "unk_284a" U32 (* 1 *);
      f "pad_284e" (Bytes 2);
    ]

(* Region ids the firmware names (kAGFIPIORegionType*, from its name table
   at image offset 0x8bba0), for printing io_mappings. *)
let region_names =
  [ (0x00, "MCacheRegisters"); (0x01, "FenderRegsHWL"); (0x02, "TempSensorRegister"); (0x03, "MTRPMSRegisters");
    (0x04, "GPCAICSWInt"); (0x05, "AICBankedRegisters"); (0x06, "PMGRScratch"); (0x07, "SpecialAgentIdleDie0");
    (0x09, "SpecialAgentIdleDie1"); (0x0a, "PushTelemetryDashboardConfigSpace"); (0x0b, "PushTelemetryDashboard");
    (0x0c, "GFXCAXI2AFRegisters"); (0x0d, "ANE0Registers"); (0x0e, "MTRRegisters"); (0x0f, "ANE1Registers");
    (0x10, "GTIRegisters"); (0x11, "(GPU registers, sgx reg 0)"); (0x12, "PushTelemetryDashboardReadSpace");
    (0x16, "AFRD2DNIRegisters"); (0x17, "DVFMMgpuRegisters"); (0x18, "AONPTDSpace"); (0x19, "PMCRegisters");
    (0x1a, "CSRIFPerf"); (0x1b, "GPUCTLRIFPerf"); (0x1d, "HAT"); (0x1e, "DPEPRegisters");
    (0x20, "FenderRegsGFenderCfg"); (0x21, "GMGIFAFRegisters"); (0x22, "CRERegisters"); (0x23, "FenderRegsGCPMS");
    (0x24, "FenderRegsKSMFE"); (0x25, "FenderRegsMCW"); (0x26, "FenderRegsScratchRam"); (0x27, "FenderRegsBumper");
    (0x28, "FenderRegsPRC"); (0x29, "FenderRegsDFenderMGPUCfg"); (0x2a, "FenderRegsDFenderPowerTransG16G");
    (0x2b, "FenderRegsDFenderCSCfg"); (0x2c, "PMPDoorbell"); (0x2d, "FenderRegsIVDM"); (0x2e, "GFXCLKGENMGPU");
    (0x2f, "ThrtlStatCntrsCSRegisters"); (0x30, "AVMRControllerFastRegisters"); (0x31, "FenderRegsAFRNIA");
    (0x35, "DVFMAFRRegisters"); (0x36, "DpwrMXURegisters"); (0x37, "PmgrMiscDie0"); (0x38, "AFRDCPMS");
    (0x39, "PmgrMiscDie1"); (0x3a, "ThrtlStatCntrsRegisters"); (0x3b, "AFRRegisters") ]
