(* Command queues and the work they carry.

   13.x (m1n1 fw/agx/cmdqueue.py): CommandQueueInfo is ~0xb0 bytes: pointers
   (CommandQueuePointers), rb (ring of work-command pointers), job_list,
   gpu_buf, three GPU read pointers, event_id (-1), priorities, a uuid that
   counts up per queue, gpu_context. Work commands start with a u32 type:
   0 TA, 1 3D, 3 compute, 4 barrier, 6 init buffer manager, ...

   27.2 (traced 2026-11-14): CommandQueueInfo is 0x80 bytes (queues packed
   0x80 apart). pointers, rb and job_list are where 13.x has them; 13.x's
   gpu_buf pointer at 0x18 is gone, so the read pointers and event_id (-1)
   move up by 8; past 0x38 the fit is not settled (those fields are named unk_NN). The queue
   pointers and job list keep their 13.x layout. Work commands seen: type
   0xf (0xc0 bytes, packed, pointers at 2-byte boundaries) and type 0x10
   (0x40 bytes), alternating in a 3D queue's ring.

   Firmware decode (agfKSMKickQueueGetDMType~, 19-way jump table): 0 TA
   (0x9a0), 1 3D (0x2240), 2 blit (0xa00), 3 compute (0x1040), 4 barrier
   (32-bit stamp), 5 buffer-manager bind (0x18), 6 PMRebuild (fatal here),
   7 and 9 small kickable jobs, 0xc, 0xe, 0xf kick-queue kick (0x88 read),
   0x10 kick-entry parent release (0x18 read), 0x12 barrier (64-bit stamp).
   In the traced queues only 0xf/0x10 (and barriers) appear: each 0xf
   points at a 256 x 0x200-byte hardware kick-queue array, and the work
   travels in those kick entries. *)

open Schema

let () =
  Hashtbl.replace structs "CommandQueuePointers"
    [
      f "gpu_doneptr" U32; f "pad_04" (Bytes 0xc);
      f "unk_10" U32; f "pad_14" (Bytes 0xc);
      f "unk_20" U32; f "pad_24" (Bytes 0xc);
      f "gpu_rptr" U32; f "pad_34" (Bytes 0xc);
      f "cpu_wptr" U32; f "pad_44" (Bytes 0xc);
      f "rb_size" U32 ~gate:(Until "27");
      (* 27.2 (firmware decode): +0x50 is new (0xffffffff; the write index on
         the replay path, fn_17c44) and rb_size moves to +0x60 (0x500, the
         firmware's modulus). The firmware writes +0x00 after dispatch and
         +0x30 (its copy of the consumed write index). *)
      f "replay_wptr" U32 ~gate:(Since "27");
      f "pad_54" (Bytes 0xc) ~gate:(Since "27");
      f "rb_size" U32 ~gate:(Since "27");
    ];
  Hashtbl.replace structs "JobList" [ f "first_job" U64; f "last_head" (Ptr ""); f "unkptr_10" U64 ];
  Hashtbl.replace structs "CommandQueueInfo27"
    [
      f "pointers" (Ptr "CommandQueuePointers");
      f "rb" (Ptr "");
      f "job_list" (Ptr "JobList");
      f "unk_18" U32;
      f "consumed_wptr" U32 (* written by the firmware *);
      f "unk_20" U32;
      f "event_id" U32 (* -1 *);
      f "unk_28" U32;
      f "unk_2c" U32;
      f "unk_30" U64;
      f "unk_38" U32;
      f "unk_3c" U32;
      f "unk_40" U32 (* -1 *);
      f "process_id" U32 (* also in each type 0xf command at +0x5a *);
      f "pad_48" (Bytes 0xc);
      f "barrier_count" U32 (* +0x54, counted by type 0x12 barriers *);
      f "pad_58" (Bytes 0x10);
      f "unk_68" U64 (* a counter *);
      f "gpu_context" (Ptr "");
      f "unk_78" U64;
    ]

let () =
  (* Type 0xf: kick one entry of a hardware kick queue (packed). *)
  Hashtbl.replace structs "KickCmd27"
    [
      f "cmd_type" U32 (* 0xf *);
      f "unk_4" U32;
      f "entries_gpu_va" U64;
      f "entries" (Ptr "") (* 256 x 0x200-byte kick entries; entry+0x18 = owning queue *);
      f "slot" U16 (* firmware kick-queue table 0xce058 *);
      f "mark_slot" U32;
      f "priority" U32;
      f "dm" U32 (* 0 TA, 1 3D, 2 CL *);
      f "has_timestamp" U32;
      f "timestamp" U64 (* low 40 bits TS, top byte stamp index *);
      f "unk_32" U32 (* 1 *);
      f "resource" (Ptr "") (* 0x68-byte object *);
      f "resource_gen" U64 (* -1: unchanged *);
      f "resource_slot" U32;
      f "gpu_context" (Ptr "");
      f "bind_context" U32;
      f "ctx_arg_56" U32 (* a byte used *);
      f "process_id" U32;
      f "ctx_arg_5e" U32 (* a byte used *);
      f "global_bit_enable" U32;
      f "global_bit_value" U32;
      f "flag_6a" U32;
      f "pb_state" (Ptr "") (* parameter-buffer state, 0x90 bytes; TA kicks only *);
      f "pb_gen" U64;
      f "pb_slot" U32;
      f "pb_bit" U32;
    ];
  (* Type 0x10: clear one parent bit of a kick entry (entry+0x128). *)
  Hashtbl.replace structs "KickRelease27"
    [
      f "cmd_type" U32 (* 0x10 *);
      f "slot" U16;
      f "entry_sel" U64 (* low 8 bits: entry index *);
      f "parent_bit" U32 (* 0xfe: the host *);
    ];
  (* Type 4: wait for a 32-bit stamp. *)
  Hashtbl.replace structs "Barrier27"
    [
      f "cmd_type" U32;
      f "stamp" (Ptr "");
      f "seq" U64;
      f "event_slot" U32;
      f "wait_value" U32;
      f "pad_1c" (Bytes 8);
      f "notify_slot" U32;
      f "unk_28" U32;
      f "unk_2c" U32;
      f "pad_30" U32;
      f "unk_34" U32;
      f "pad_38" (Bytes 0x10);
    ]

let u32 s off = Int32.to_int (String.get_int32_le s off) land 0xffffffff

(* The queue, then the first [n] commands of its ring: each one's type (its
   first u32), the distance to the next command of the same stream, and
   where it has resolvable pointers. *)
let show snap va n =
  let b = Buffer.create 4096 in
  (match Schema.decode snap ~version:[ 27; 2 ] "CommandQueueInfo27" va with
  | Some v -> Buffer.add_string b (Schema.to_string v)
  | None -> Buffer.add_string b "queue not in the snapshot");
  Buffer.add_char b '\n';
  (match Snapshot.read snap va 16 with
  | Some s -> (
      let rb = Int64.to_int (String.get_int64_le s 8) in
      match Snapshot.read snap rb (8 * n) with
      | None -> Buffer.add_string b "ring not in the snapshot\n"
      | Some r ->
          for i = 0 to n - 1 do
            let cmd = Int64.to_int (String.get_int64_le r (8 * i)) in
            let ty = match Snapshot.read snap cmd 4 with Some c -> Printf.sprintf "%#x" (u32 c 0) | None -> "?" in
            let ptrs = Explore.pointers snap cmd 0xc0 in
            Printf.bprintf b "rb[%d] %s type %s ptrs %s\n" i (Explore.hex64 cmd) ty
              (String.concat " " (List.map (fun (o, _) -> Printf.sprintf "+%#x" o) ptrs))
          done)
  | None -> ());
  Buffer.contents b
