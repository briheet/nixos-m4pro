(* The rest of what InitData points to in 27.2 (firmware decode and macOS
   snapshots, 2026-11-14; docs/gpu/firmware-decode.md). Names follow 13.x
   (m1n1 fw/agx/initdata.py) where a field was matched; values in comments
   are macOS's.

   - RegionC (InitData+0x20): a packed block of host settings, ~0xe59
     bytes. The firmware copies ~75 fields into its own state at boot
     (fn_30ac) and again on a device-control command, so the host can
     change them at run time. It writes only +0xe45/+0xe49.
   - PowerMgmt27 (InitData+0xb8): 13.x RegionC's power-management block,
     moved out. Groups of tunables each with an "apply" flag that the
     firmware clears after loading them; status written back from +0x544.
   - FwStatus27 (InitData+0xa8): replaces 13.x FWStatus; flags the firmware
     sets for the host, then the states of the Event/FWLog/KTrace/Stats
     channels (their rings follow the block).
   - KickState27 (InitData+0xb0): firmware-owned device-control, stamp-log
     and idle-handshake state; the host sets five words and answers the
     idle handshake at +0x4ae0 (firmware writes 1, host 2; firmware 3,
     host 0).
   - InitData+0xc0: never read by the firmware, zero under macOS (maybe
     13.x's FWCtl channel); the host allocates it (<= 0x4bc0 bytes). *)

open Schema

let () =
  Hashtbl.replace structs "RegionC27"
    [
      f "ktrace_enable" U32 (* bitmask of periodic actions *);
      f "unk_4" (Array (8, U32));
      f "unk_24_0" U32 (* 3000 *);
      f "unk_28" (Array (2, U32));
      f "unk_30" U32 (* 1; a device-control message overrides the copy *);
      f "unk_34" (Array (3, U32)) (* 1 1 0 *);
      f "unk_40" U32 (* 120 *);
      f "unk_44" (Array (5, U32));
      f "unk_58" U16 (* 4000 *);
      f "unk_5a" U16 (* 40 *);
      f "unk_5c" U16 (* 0xffff *);
      f "unk_5e" (Array (6, U32)) (* packed: 0 1 1 3 1 0; +0x6e is the period of ktrace_enable's actions *);
      f "pad_76" (Bytes 6);
      f "unk_7c" (Array (3, U32)) (* 1 2 902 *);
      f "max_power" U32 (* 56768 mW? *);
      f "power_off_delays" (Array (2, U32)) (* 1000 1000 *);
      f "overrides_94" (Array (2, U32));
      f "unk_9c" U32 (* 1000 *);
      f "unk_a0" (Bytes 0x728) (* power/pstate override knobs at +0xa8..+0xec, used when nonzero *);
      f "perf_period" U32 (* +0x7c8: 1500 *);
      f "perf_tunables" (Array (8, F32)) (* 1.0 0.8 0.2 0.9 0.1 0.25 0.6 0.9 *);
      f "unk_7ec" U32 (* 6 *);
      f "enables_7f0" (Array (2, U32)) (* 1 1 *);
      f "defaults_7f8" (Array (2, U32)) (* 100 100 *);
      f "unk_800" (Bytes 0x18c);
      f "idle_ts" U64 (* +0x98c, packed *);
      f "idle_unk" U64;
      f "progress_check_interval" (Array (3, U32)) (* 3d 40, ta 10, cl 250 *);
      f "unk_9a8" (Array (5, U32)) (* 1 0 0 0 0 *);
      f "idle_off_delay_ms" U32 (* 2 *);
      f "fender_idle_off_delay_ms" U32 (* 40 *);
      f "fw_early_wake_timeout_ms" U32 (* 5 *);
      f "timeouts_9c8" (Array (7, U32)) (* 0 40 50 1 0 50 0: cl context switch 40, cl kill 50 *);
      f "unk_9e4" U32 (* 1: the table follows *);
      f "unk_9e8" (Bytes 0x1b) (* 00 02 02 then 4 x (01 0x 28 0a 01 01); copy macOS *);
      f "pad_a03" U8;
      f "override_mask" U64;
      f "override_a" (Array (64, U64));
      f "override_b" (Array (64, U64));
      f "unk_e0c" U32 (* 250 *);
      f "overrides_e10" (Array (4, U32));
      f "unk_e20" U8;
      f "flags_e21" (Array (7, U32)) (* packed; +0xe21 = 1 *);
      f "unk_e3d" U32 (* 3 *);
      f "unk_e41" U32 (* 1 *);
      f "fw_e45" U32 (* written by the firmware *);
      f "fw_e49" U32 (* written by the firmware *);
      f "unk_e4d" (Array (2, U32));
      f "unk_e55" U32 (* 8 *);
    ];
  Hashtbl.replace structs "PowerZone27" [ f "target" U32; f "target_off" U32; f "filter_tc" U32 ];
  Hashtbl.replace structs "PowerMgmt27"
    [
      f "fw_avg_power" F32;
      f "fw_04" F32;
      f "zones_apply" U32 (* firmware recomputes the zones and clears it *);
      f "power_zone_count" U32;
      f "avg_power_filter_tc_periods" U32 (* 31 = 250 ms / sample period 8 *);
      f "avg_power_ki_dt" F32 (* 0.040465 *);
      f "avg_power_kp" F32 (* 0.8093 *);
      f "avg_power_min_duty_cycle" U32 (* 40 *);
      f "avg_power_target_filter_tc" U32 (* 1 *);
      f "power_zones" (Array (5, Struct "PowerZone27"));
      f "aon_apply" U32;
      f "aon" (Bytes 0x60);
      f "thermal_apply" U32;
      f "unk_8cc" U32 (* 11000 *);
      f "fast_die0_release_temp" U32 (* 8000 = 80 C x 100 *);
      f "unk_d0" U32;
      f "fast_die0_prop_tgt_delta" U32;
      f "fast_die0_gain_a" F32 (* 37.0 *);
      f "fast_die0_gain_b" F32 (* -12.9333 *);
      f "unk_e0" F32;
      f "unk_e4" U32;
      f "thermal_mode" U32;
      f "pad_ec" U32;
      f "consts_f0" (Bytes 0x38) (* 9900 200 .. 100.0 -400.0 200; unread, copy macOS *);
      f "ppm_apply" U32 (* 1 at boot *);
      f "max_power_2" U32 (* 56768 mW *);
      f "ppm_kp" F32 (* 0.40465 *);
      f "ppm_ki_dt" F32 (* 0.18344 *);
      f "ppm_filter_tc" U32;
      f "unk_13c" F32;
      f "unk_140" U32;
      f "pad_144" U32;
      f "perf_apply" U32;
      f "perf_overrides" (Bytes 0x64);
      f "reserved_1b0" (Bytes 0x394);
      f "host_inhibit" U32;
      f "event_count" U64;
      f "accum_time" U64;
      f "pct" U32;
      f "status_55c" U32;
      f "pad_560" (Bytes 0x64);
      f "state_bits" U32;
      f "request" U8;
      f "pad_5c9" (Bytes 7);
      f "timestamp" U64;
      f "pad_5d8" (Bytes 8);
      f "status_5e0" U32;
      f "status_5e4" U32;
      f "pad_5e8" (Bytes 0x3c);
      f "consts_624" (Bytes 0x20) (* -15.0 5.0 32 1000 .. 900 at +0x640; unread *);
      f "reg_override_mask" U64;
      f "reg_override_vals" (Array (36, U8));
      f "pad_670" U32;
      f "submask_a" U64;
      f "submask_b" U64;
      f "afr_skip" U32;
      f "pad_688" U32;
      f "flag_68c" U32;
      f "gcpms_state" U32;
      f "sample_period_aic" U64 (* ADT gpu-pwr-sample-period-aic-clks *);
      f "slot_count" U64;
      f "seq" U32 (* odd while the firmware writes *);
      f "slots" (Array (32, U8));
      f "pad_6c8" (Bytes 0x38);
    ];
  Hashtbl.replace structs "AuxChannelState27" [ f "state" (Struct "ChannelState"); f "pad_30" (Bytes 0x10) ];
  Hashtbl.replace structs "FwStatus27"
    [
      f "trace_mask" U32;
      f "booted" U32 (* firmware sets 1 after a cold boot *);
      f "unk_08" U32;
      f "in_recovery" U32;
      f "awake" U32;
      f "fw_ready" U32;
      f "power_state" U32;
      f "wake_count" U32;
      f "pad_20" (Bytes 0x20);
      f "event" (Struct "AuxChannelState27");
      f "fw_log" (Array (9, Struct "ChannelState")) (* 9 sub-channels (fn_35e20) *);
      f "pad_230" (Bytes 0x10);
      f "ktrace" (Struct "AuxChannelState27");
      f "stats" (Struct "AuxChannelState27");
    ];
  Hashtbl.replace structs "KickState27"
    [
      f "pending" U32;
      f "host_4" U32 (* host sets 1 *);
      f "unk_8" U32;
      f "pad_c" (Bytes 0x400c);
      f "unk_4018" U32;
      f "n_a" U8;
      f "n_b" U8;
      f "unk_401e" U16;
      f "ids" (Array (16, U16));
      f "state" U32;
      f "unk_4044" U32;
      f "unk_4048" U32;
      f "buf" U64 (* packed *);
      f "buf_size" U32;
      f "unk_4058" U64;
      f "slots" U64 (* array of 0x938-byte slots *);
      f "slot_count" U32;
      f "entries" U64 (* array of 0x38-byte entries *);
      f "descriptors" (Bytes 0x1fc);
      f "handle" U64;
      f "unk_4278" U64;
      f "pad_4280" (Bytes 8);
      f "unk_4288" U32;
      f "state_byte" U8;
      f "pad_428d" (Bytes 3);
      f "cur_slot" U32;
      f "pad_4294" U32;
      f "stamp_log" (Array (256, U64));
      f "stamp_idx" U32;
      f "idle_report" (Bytes 0x24);
      f "host_buf_a" U64 (* host: a 0x40-byte object *);
      f "host_buf_b" U64 (* host: host_buf_a + 0x40 *);
      f "idle_seq" U64 (* device-control commands must carry it at +0x18 *);
      f "pad_4ad8" U64;
      f "idle_handshake" U32 (* fw 1 -> host 2; fw 3 -> host 0 *);
      f "pad_4ae4" (Bytes 0xc);
      f "idle_handshake_arg" U32;
      f "pad_4af4" (Bytes 0xc);
      f "event_counter" U32;
      f "pad_4b04" U32;
      f "timestamps" (Array (4, U64));
      f "pad_4b28" (Bytes 0x7de0);
      f "unk_c908" (Array (2, U32));
      f "last_error" U32;
      f "unk_c914" U32 (* firmware sets 6 *);
      f "pad_c918" (Bytes 0xc);
      f "unk_c924" U32 (* firmware sets 1 *);
      f "pad_c928" (Bytes 0x1800);
      f "counter_e128" U32;
      f "pad_e12c" (Bytes 0x5e8);
      f "host_e714" U32 (* host sets 1 *);
      f "unk_e718" U32;
      f "pad_e71c" (Bytes 0x24);
    ]

let names = [ "RegionC27"; "PowerMgmt27"; "FwStatus27"; "KickState27" ]
