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
   (0x40 bytes), alternating in a 3D queue's ring. *)

open Schema

let () =
  Hashtbl.replace structs "CommandQueuePointers"
    [
      f "gpu_doneptr" U32; f "pad_04" (Bytes 0xc);
      f "unk_10" U32; f "pad_14" (Bytes 0xc);
      f "unk_20" U32; f "pad_24" (Bytes 0xc);
      f "gpu_rptr" U32; f "pad_34" (Bytes 0xc);
      f "cpu_wptr" U32; f "pad_44" (Bytes 0xc);
      f "rb_size" U32;
    ];
  Hashtbl.replace structs "JobList" [ f "first_job" U64; f "last_head" (Ptr ""); f "unkptr_10" U64 ];
  Hashtbl.replace structs "CommandQueueInfo27"
    [
      f "pointers" (Ptr "CommandQueuePointers");
      f "rb" (Ptr "");
      f "job_list" (Ptr "JobList");
      f "gpu_rptr1" U32;
      f "gpu_rptr2" U32;
      f "gpu_rptr3" U32;
      f "event_id" U32 (* -1 *);
      f "unk_28" U32;
      f "unk_2c" U32;
      f "unk_30" U64;
      f "unk_38" U32;
      f "unk_3c" U32;
      f "unk_40" U32 (* -1 *);
      f "unk_44" U32 (* differs per queue: 13.x uuid? *);
      f "pad_48" (Bytes 0x20);
      f "unk_68" U64 (* a counter *);
      f "gpu_context" (Ptr "");
      f "unk_78" U64;
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
