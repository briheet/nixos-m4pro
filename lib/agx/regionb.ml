(* InitData region B: the channel table, then statistics and hardware-data
   pointers.

   13.x (m1n1 fw/agx/channels.py, initdata.py): 17 channels of
   { state_addr; ringbuffer_addr } (16 bytes) in the order TA/3D/CL for
   queues 0-3, DevCtrl, Event, FWLog, KTrace, Stats; each channel state is
   0x30 bytes with the read pointer at +0x00 and the write pointer at +0x20.

   27.2 (traced 2026-11-14): a 0x20-byte header, then the 12 queue channels
   and DevCtrl as 0x20-byte records { three state-field pointers 0x10 apart;
   ring }. The state fields are the same offsets as 13.x's (+0x00, +0x20)
   plus one at +0x10; in a busy 3D queue the third field ran one ahead of
   the other two (0x17, 0x17, 0x18), so it is the host's write pointer.
   States sit in per-kind arrays (TA at state+0x000, 3D +0x100, CL +0x200,
   0x40 per queue, queues in reverse order), rings 0x1800 apart. The
   auxiliary channels after 0x1c0 have another shape, not decoded yet.

   Queue ring entries (RunCmdQueueMsg): 0x30 bytes in 13.x (queue type,
   command queue pointer, head, event number, new-queue flag, timestamp, 16
   data bytes); 0x18 in 27.2: queue type, the command queue pointer at +8,
   a u32 that was always 1, a u16 that counts up by 2 per submission, a
   byte that was always 5, and a byte set only on the queue's first
   submission (13.x's new_queue). *)

open Schema

let queue_channels =
  [ "ta_0"; "3d_0"; "cl_0"; "ta_1"; "3d_1"; "cl_1"; "ta_2"; "3d_2"; "cl_2"; "ta_3"; "3d_3"; "cl_3"; "dev_ctrl" ]

let () =
  (* 13.x *)
  Hashtbl.replace structs "ChannelInfo" [ f "state" (Ptr "ChannelState"); f "ring" (Ptr "") ];
  Hashtbl.replace structs "ChannelInfoSet"
    (List.map (fun n -> f n (Struct "ChannelInfo"))
       (queue_channels @ [ "event"; "fw_log"; "ktrace"; "stats" ]));
  (* 27.2 *)
  Hashtbl.replace structs "ChannelInfo27"
    [
      f "read_ptr" (Ptr "ChannelCounter");
      f "ptr_10" (Ptr "ChannelCounter");
      f "write_ptr" (Ptr "ChannelCounter");
      f "ring" (Ptr "");
    ];
  Hashtbl.replace structs "QueueChannels27" (List.map (fun n -> f n (Struct "ChannelInfo27")) queue_channels);
  Hashtbl.replace structs "ChannelCounter" [ f "value" U32; f "pad" (Bytes 0xc) ];
  Hashtbl.replace structs "ChannelState"
    [ f "read_ptr" U32; f "pad_04" (Bytes 0xc); f "field_10" U32 ~gate:(Since "27"); f "pad_14" (Bytes 0xc) ~gate:(Since "27");
      f "pad_10" (Bytes 0x10) ~gate:(Until "27"); f "write_ptr" U32; f "pad_24" (Bytes 0xc) ];
  Hashtbl.replace structs "RunCmdQueueMsg27"
    [
      f "queue_type" U32;
      f "pad_04" U32;
      f "cmd_queue" (Ptr "CommandQueueInfo");
      f "unk_10" U32 (* 1 *);
      f "event" U16 (* +2 per submission *);
      f "unk_16" U8 (* 5 *);
      f "new_queue" U8;
    ];
  Hashtbl.replace structs "RunCmdRing27x8" [ f "entries" (Array (8, Struct "RunCmdQueueMsg27")) ];
  Hashtbl.replace structs "RegionB"
    [
      f "channels" (Struct "ChannelInfoSet") ~gate:(Until "27");
      f "hdr_ring" (Ptr "") ~gate:(Since "27");
      f "hdr_ptr_08" (Ptr "") ~gate:(Since "27");
      f "hdr_ptr_10" (Ptr "") ~gate:(Since "27");
      f "hdr_18" U64 ~gate:(Since "27");
      f "queues" (Struct "QueueChannels27") ~gate:(Since "27");
    ]
