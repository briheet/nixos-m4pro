(* InitData: the structure the host hands the GPU firmware at boot (message
   0x81 on endpoint 0x20 carries its address).

   Baseline: m1n1 proxyclient/m1n1/fw/agx/initdata.py (macOS 13.x firmware).
   27.2 (J614s, g16s b0), from the snapshot of 2026-11-14: identical up to
   0x28, where 13.x has fw_status_addr (a pointer) and 27.2 has two u32
   (0, 1); the second is 13.x's host_mapped_fw_allocations, moved (the
   firmware refuses 0: "Host-mapped FW allocations are disabled"); InitData+0
   (ver_info) must be 0x0c8b6339839804c0, the 27.2 interface fingerprint.
   The UAT description that follows is at the same offset and reads
   back the level layout the snapshot walker uses (36/25/14, 64/2048/2048).
   After the 0x14 bytes of padding, 13.x has five u32 (the first must be 1);
   27.2 has four kernel pointers (0xa8..0xc7), then zeros. *)

open Schema

let () =
  Hashtbl.replace structs "UatLevelInfo"
    [
      f "unk_3" U8 (* always 8 *);
      f "unk_1" U8 (* 14 *);
      f "unk_2" U8 (* 14 *);
      f "index_shift" U8;
      f "num_entries" U16;
      f "unk_4" U16 (* 0x4000 *);
      f "unk_8" U64 (* 1 *);
      f "phys_mask" U64;
      f "index_mask" U64;
    ];
  Hashtbl.replace structs "InitData"
    [
      f "ver_info" (Array (4, U16)) ~gate:(Since "13.0");
      f "region_a" (Ptr "RegionA");
      f "unk_8" U32;
      f "unk_c" U32;
      f "region_b" (Ptr "RegionB");
      f "region_c" (Ptr "RegionC");
      f "fw_status" (Ptr "FwStatus") ~gate:(Until "27");
      f "unk_28" U32 ~gate:(Since "27");
      f "host_mapped_fw_allocations_27" U32 ~gate:(Since "27") (* must be nonzero: the firmware refuses 0 *);
      f "uat_page_size" U16;
      f "uat_page_bits" U8;
      f "uat_num_levels" U8;
      f "uat_level_info" (Array (3, Struct "UatLevelInfo"));
      f "pad_8c" (Bytes 0x14);
      f "host_mapped_fw_allocations" U32 ~gate:(Until "27") (* must be 1 *);
      f "unk_ac" U32 ~gate:(Until "27");
      f "unk_b0" U32 ~gate:(Until "27");
      f "unk_b4" U32 ~gate:(Until "27");
      f "unk_b8" U32 ~gate:(Until "27");
      (* 27.2: four pointers instead, all into the kernel half; what they
         point to is the next thing to name (agx graph). *)
      f "ptr_a8" (Ptr "") ~gate:(Since "27");
      f "ptr_b0" (Ptr "") ~gate:(Since "27");
      f "ptr_b8" (Ptr "") ~gate:(Since "27");
      f "ptr_c0" (Ptr "") ~gate:(Since "27");
    ]

(* The page-table levels an InitData declares, for [Snapshot.with_levels]. *)
let levels = function
  | Fields fs -> (
      match List.assoc_opt "uat_level_info" fs with
      | Some (List ls) ->
          List.filter_map
            (function
              | Fields l -> (
                  match (List.assoc_opt "index_shift" l, List.assoc_opt "num_entries" l) with
                  | Some (Int shift), Some (Int entries) -> Some { Snapshot.shift; entries }
                  | _ -> None)
              | _ -> None)
            ls
      | _ -> [])
  | _ -> []
