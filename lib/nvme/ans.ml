(* NVMe coprocessor on this Mac.
   The live node is /arm-io/ans, compatible iop,ascwrap-v6, role ANS2.
   nvme-secure-bar is present, so nvme_init in upstream/m1n1/src/nvme.c
   takes register 9 as the controller base (NVME_T8132). Register 0 is
   the ASC CPU window. The mailbox is 0x8000 bytes into that window.
   wake is asc_cpu_start plus the power-init send from rtkit_boot.
   handshake is the rest of that function: HELLO, the endpoint map,
   START_EP for each system endpoint the map names, the wait until the
   coprocessor reports IOP power ON, and the AP power ON send.
   A live ANS produces HELLO, the map, and the power ack. The loopback
   scripts stand-in replies. setup is the controller programming that
   runs once NVME_BOOT_STATUS reads OK. The queue pointers are physical
   addresses from the caller. create_io_queues submits admin CREATE_CQ
   and CREATE_SQ through the linear doorbell and, once both complete,
   stores the I/O queue pointers. read is nvme_read: one 4 KiB page on
   the I/O queue. The completion is a DMA write from ANS. The loopback
   plants a stand-in completion when the doorbell is rung, and copies a
   stand-in page to PRP1. m1n1 hardcodes a queue depth of 64 and a
   command tag of 0. The device tree says nvme-queue-entries is 0xfd.
   This client follows m1n1.
   Buffer requests are the syslog, crashlog, and ioreport messages
   rtkit_recv answers while it waits for IOP power and while
   nvme_poll_syslog drains the mailbox. ANS has a SART, so a request
   with no IOVA is allocated, allowed, and answered with that physical
   address. The dump has no asc-dram-mask, so the reply IOVA is the
   address on its own, which is dva_base 0.
   The RTKit message codec is rtkit.ml, included below so the names
   stay on this module. *)

module Proxy = Proto.Proxy
module Sart = Soc.Sart

let node = "/arm-io/ans"
let compatible = "iop,ascwrap-v6"
let role = "ANS2"
let secure_bar = true
let nvme_index = 9
let nvme_base = 0x44dcc0000L
let nvme_window = 0x10000
let cpu_base = 0x409600000L
let cpu_window = 0x88000
let mbox_offset = 0x8000
let queue_size = 64

let die =
  Int64.to_int (Int64.logand (Int64.shift_right_logical nvme_base 37) 3L)

let cpu_control = 0x44
let cpu_start = 0x10
let mbox_a2i_control = 0x110
let mbox_full = 0x10000
let mbox_a2i_send0 = 0x800
let mbox_a2i_send1 = 0x808
let mbox_i2a_control = 0x114
let mbox_empty = 0x20000
let mbox_i2a_recv0 = 0x830
let mbox_i2a_recv1 = 0x838

let cc = 0x14
let cc_en = 1
let cc_shn = 0xc000
let csts = 0x1c
let csts_rdy = 1
let aqa = 0x24
let asq = 0x28
let acq = 0x30
let boot_status = 0x1300
let boot_status_ok = 0xde71ce55L
let linear_sq = 0x24908
let linear_sq_en = 1
let max_pend = 0x1210
let ioq_cmds = 0x1200
let ioq_cqes = 0x1208
let nvmmu_num = 0x28100
let nvmmu_asq = 0x28108
let nvmmu_iosq = 0x28110
let db_acq = 0x1004
let db_iocq = 0x100c
let db_linear_asq = 0x2490c
let db_linear_iosq = 0x24910
let tcb_inval = 0x28118
let tcb_stat = 0x29120
let admin_create_sq = 0x01
let admin_create_cq = 0x05
let cmd_read = 0x02
let q_contiguous = 1
let cmd_tag = 0
let cmd_bytes = 64
let cqe_bytes = 16
let tcb_bytes = 128
let dma_to_device = 2
let dma_from_device = 1

include Rtkit

let buffer_base = 0x82000000L
let buffer_align = 16384
let queue_span = 0x4000L
let read_page = 0x1000
let read_buffer = 0x81060000L

let depth = queue_size - 1
let aqa_value = (depth lsl 16) lor depth
let queue_id_word = (depth lsl 16) lor 1

let align_up value align =
  let align = Int64.of_int align in
  Int64.logand (Int64.add value (Int64.pred align)) (Int64.lognot (Int64.pred align))

type endpoints = {
  debug : bool;
  crashlog : bool;
  syslog : bool;
  ioreport : bool;
  oslog : bool;
}

type handshake = { version : int; endpoints : endpoints }

type queues = {
  admin_tcbs : int64;
  io_tcbs : int64;
  admin_cmds : int64;
  admin_cqes : int64;
  io_cmds : int64;
  io_cqes : int64;
}

let demo_queues =
  {
    admin_tcbs = 0x81000000L;
    io_tcbs = 0x81010000L;
    admin_cmds = 0x81020000L;
    admin_cqes = 0x81030000L;
    io_cmds = 0x81040000L;
    io_cqes = 0x81050000L;
  }

(* nvme.c allocates each queue with memalign(16 KiB) and does not add a
   SART entry for it. rtkit_map does add one, rounded up to 16 KiB, when
   a buffer request arrives. This loopback SART starts empty. The host
   allows the stand-in pages the commands name so those DMA ranges have
   an entry. iBoot's protected windows are runtime state and are not
   filled in here. *)
let dma_regions queues =
  [
    (queues.admin_tcbs, queue_span);
    (queues.io_tcbs, queue_span);
    (queues.admin_cmds, queue_span);
    (queues.admin_cqes, queue_span);
    (queues.io_cmds, queue_span);
    (queues.io_cqes, queue_span);
    (read_buffer, Int64.of_int read_page);
  ]

let allow_dma sart status queues =
  List.map (fun (paddr, size) -> Sart.allow sart status ~paddr ~size) (dma_regions queues)

type map = {
  sart : Sart.t;
  status : Sart.status;
  mutable next : int64;
  mutable syslog_buf : int64 option;
  mutable crashlog_buf : int64 option;
  mutable ioreport_buf : int64 option;
}

type buffers = {
  next : int64;
  syslog_buf : int64 option;
  crashlog_buf : int64 option;
  ioreport_buf : int64 option;
}

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
  mask32 : int64 -> int64 -> int64 -> unit;
  read64 : int64 -> int64;
  write64 : int64 -> int64 -> unit;
  mutable map : map option;
}

let of_transport transport =
  {
    read32 = Proxy.read32 transport;
    write32 = Proxy.write32 transport;
    mask32 = (fun addr clear set -> ignore (Proxy.mask32 transport addr clear set));
    read64 = Proxy.read64 transport;
    write64 = Proxy.write64 transport;
    map = None;
  }

let bind_map t sart status =
  t.map <-
    Some
      {
        sart;
        status;
        next = buffer_base;
        syslog_buf = None;
        crashlog_buf = None;
        ioreport_buf = None;
      }

let buffers t =
  match t.map with
  | None -> None
  | Some map ->
      Some
        {
          next = map.next;
          syslog_buf = map.syslog_buf;
          crashlog_buf = map.crashlog_buf;
          ioreport_buf = map.ioreport_buf;
        }

let reg base offset = Int64.add base (Int64.of_int offset)
let mbox offset = reg (Int64.add cpu_base (Int64.of_int mbox_offset)) offset
let nvme offset = reg nvme_base offset

let poll t addr mask target ~timeout message =
  let rec loop left =
    if left = 0 then failwith message
    else if Int64.logand (t.read32 addr) mask = target then ()
    else loop (left - 1)
  in
  loop timeout

let send ?(mbox_timeout = 200000) t msg0 msg1 =
  poll t (mbox mbox_a2i_control) (Int64.of_int mbox_full) 0L ~timeout:mbox_timeout
    "asc: A2I mailbox full for 200ms. Is the ASC stuck?";
  t.write64 (mbox mbox_a2i_send0) msg0;
  t.write64 (mbox mbox_a2i_send1) msg1

(* asc_recv polls I2A EMPTY and then reads the two receive registers.
   Reading the second one consumes the message. *)
let recv ?(timeout = 1000) t ~timeout_message =
  let empty = Int64.of_int mbox_empty in
  let rec loop left =
    if left = 0 then failwith timeout_message
    else if Int64.logand (t.read32 (mbox mbox_i2a_control)) empty <> 0L then loop (left - 1)
    else
      let msg0 = t.read64 (mbox mbox_i2a_recv0) in
      let msg1 = t.read64 (mbox mbox_i2a_recv1) in
      (msg0, msg1)
  in
  loop timeout

(* rtkit_boot's first two steps. handshake continues from the HELLO receive. *)
let wake ?(mbox_timeout = 200000) t =
  t.mask32 (reg cpu_base cpu_control) 0L (Int64.of_int cpu_start);
  send ~mbox_timeout t wakeup_msg0 (Int64.of_int ep_mgmt)

let empty_endpoints =
  { debug = false; crashlog = false; syslog = false; ioreport = false; oslog = false }

let note_ep eps ep =
  if ep >= 0x20 then eps
  else
    match ep with
    | 0 -> eps
    | 1 -> { eps with crashlog = true }
    | 2 -> { eps with syslog = true }
    | 3 -> { eps with debug = true }
    | 4 -> { eps with ioreport = true }
    | 8 -> { eps with oslog = true }
    | _ -> eps

let apply_bitmap eps base bitmap =
  let rec loop i eps =
    if i = 32 then eps
    else
      let eps = if bitmap land (1 lsl i) <> 0 then note_ep eps ((base * 32) + i) else eps in
      loop (i + 1) eps
  in
  loop 0 eps

(* A buffer request with no IOVA is the SART path in
   rtkit_handle_buffer_request. The size field is a count of 4 KiB
   pages. The map is rounded up to 16 KiB, and the reply carries the
   original page count plus the physical address. A request that already
   names an IOVA goes through dart_translate in m1n1. ANS was booted
   with a SART and no DART, so that request cannot be translated. *)
let handle_buffer ?(mbox_timeout = 200000) t ep msg0 =
  (match t.map with
  | Some map when ep = ep_crashlog && map.crashlog_buf <> None -> failwith "rtkit(nvme): IOP crashed!"
  | _ -> ());
  let pages = pages_of msg0 in
  let iova = iova_of msg0 in
  if iova <> 0L then
    failwith
      (Printf.sprintf "rtkit(nvme): failed to translate pre-allocated buffer (ep 0x%x, buf %#Lx)" ep
         iova);
  match t.map with
  | None -> failwith "rtkit(nvme): unable to allocate buffer"
  | Some map ->
      let mapped = align_up (Int64.shift_left (Int64.of_int pages) 12) buffer_align in
      let paddr = map.next in
      ignore (Sart.allow map.sart map.status ~paddr ~size:mapped);
      map.next <- Int64.add paddr mapped;
      (match ep with
      | e when e = ep_syslog -> map.syslog_buf <- Some paddr
      | e when e = ep_crashlog -> map.crashlog_buf <- Some paddr
      | e when e = ep_ioreport -> map.ioreport_buf <- Some paddr
      | _ -> ());
      send ~mbox_timeout t (buffer_msg0 ~pages ~iova:paddr) (Int64.of_int ep)

(* rtkit_recv handles system messages itself. IOP power ON is the signal
   the boot wait is looking for. Syslog and ioreport acks are the same
   words the coprocessor sent. Anything else is left in place, which is
   the management traffic the caller still owns. *)
let service ?(mbox_timeout = 200000) t msg0 msg1 =
  let ep = Int64.to_int msg1 in
  let typ = type_of msg0 in
  if ep >= 0x20 then false
  else if ep = ep_mgmt then typ = msg_iop_pwr_ack && field msg0 0 0xffffL = power_on
  else if (ep = ep_syslog || ep = ep_crashlog || ep = ep_ioreport) && typ = msg_buffer then (
    handle_buffer ~mbox_timeout t ep msg0;
    false)
  else if ep = ep_syslog && typ = msg_syslog_log then (
    send ~mbox_timeout t msg0 msg1;
    false)
  else if ep = ep_ioreport && (typ = 0x8 || typ = 0xc) then (
    send ~mbox_timeout t msg0 msg1;
    false)
  else false

(* m1n1 spins with no timeout until IOP power reads ON. The host bounds
   that wait so a missing ack fails instead of hanging. Buffer requests
   that arrive during the wait are answered, which is what rtkit_recv
   does before the power state is noticed. *)
let rec wait_power ?(mbox_timeout = 200000) t left =
  if left = 0 then failwith "rtkit(nvme): timed out waiting for IOP power on"
  else if Int64.logand (t.read32 (mbox mbox_i2a_control)) (Int64.of_int mbox_empty) <> 0L then
    wait_power ~mbox_timeout t (left - 1)
  else
    let msg0 = t.read64 (mbox mbox_i2a_recv0) in
    let msg1 = t.read64 (mbox mbox_i2a_recv1) in
    if service ~mbox_timeout t msg0 msg1 then () else wait_power ~mbox_timeout t (left - 1)

let handshake ?(recv_timeout = 1000) ?(mbox_timeout = 200000) t =
  let msg0, msg1 = recv ~timeout:recv_timeout t ~timeout_message:"rtkit(nvme): did not receive HELLO" in
  if msg1 <> Int64.of_int ep_mgmt then
    failwith (Printf.sprintf "rtkit(nvme): expected HELLO but got message for EP 0x%Lx" msg1);
  let arrived = type_of msg0 in
  if arrived <> msg_hello then
    failwith (Printf.sprintf "rtkit(nvme): expected HELLO but got message with type 0x%02x" arrived);
  let min_ver = field msg0 0 0xffffL in
  let max_ver = field msg0 16 0xffffL in
  if min_ver > max_version || max_ver < min_version then
    failwith
      (Printf.sprintf "rtkit(nvme): supported versions [%d,%d] must overlap versions [%d,%d]"
         min_version max_version min_ver max_ver);
  let version = min max_version max_ver in
  send ~mbox_timeout t (hello_ack_msg0 version) (Int64.of_int ep_mgmt);
  let rec epmap eps =
    let msg0, msg1 =
      recv ~timeout:recv_timeout t
        ~timeout_message:"rtkit(nvme): couldn't receive message while waiting for endpoint map"
    in
    if msg1 <> Int64.of_int ep_mgmt then
      failwith
        (Printf.sprintf
           "rtkit(nvme): expected management message while waiting for endpoint map but got message for endpoint 0x%Lx"
           msg1);
    let arrived = type_of msg0 in
    if arrived <> msg_epmap then
      failwith (Printf.sprintf "rtkit(nvme): expected endpoint map message but got 0x%x instead" arrived);
    let bitmap = field msg0 0 0xffffffffL in
    let base = field msg0 32 7L in
    let eps = apply_bitmap eps base bitmap in
    let done_ = Int64.logand msg0 epmap_done <> 0L in
    send ~mbox_timeout t (epmap_reply_msg0 ~base ~done_) (Int64.of_int ep_mgmt);
    if done_ then eps else epmap eps
  in
  let endpoints = epmap empty_endpoints in
  let start ep present =
    if present then send ~mbox_timeout t (start_ep_msg0 ep) (Int64.of_int ep_mgmt)
  in
  start ep_debug endpoints.debug;
  start ep_crashlog endpoints.crashlog;
  start ep_syslog endpoints.syslog;
  start ep_ioreport endpoints.ioreport;
  start ep_oslog endpoints.oslog;
  wait_power ~mbox_timeout t recv_timeout;
  send ~mbox_timeout t ap_power_msg0 (Int64.of_int ep_mgmt);
  { version; endpoints }

let write64_lo_hi t addr value =
  t.write32 addr (Int64.logand value 0xffffffffL);
  t.write32 (Int64.add addr 4L) (Int64.shift_right_logical value 32)

let setup ?(boot_timeout = 1000) t queues =
  poll t (nvme boot_status) 0xffffffffL boot_status_ok ~timeout:boot_timeout
    "nvme: ANS did not boot correctly.";
  t.mask32 (nvme linear_sq) 0L (Int64.of_int linear_sq_en);
  t.write32 (nvme max_pend) (Int64.of_int aqa_value);
  t.write32 (nvme nvmmu_num) (Int64.of_int depth);
  write64_lo_hi t (nvme nvmmu_asq) queues.admin_tcbs;
  write64_lo_hi t (nvme nvmmu_iosq) queues.io_tcbs;
  t.mask32 (nvme cc) (Int64.of_int cc_en) 0L;
  poll t (nvme csts) (Int64.of_int csts_rdy) 0L ~timeout:boot_timeout
    "nvme: timeout while waiting for CSTS.RDY to clear";
  write64_lo_hi t (nvme asq) queues.admin_cmds;
  write64_lo_hi t (nvme acq) queues.admin_cqes;
  t.write32 (nvme aqa) (Int64.of_int aqa_value);
  t.mask32 (nvme cc) (Int64.of_int cc_shn) (Int64.of_int cc_en);
  poll t (nvme csts) (Int64.of_int csts_rdy) (Int64.of_int csts_rdy) ~timeout:boot_timeout
    "nvme: timeout while waiting for CSTS.RDY to be set"

type command = {
  opcode : int;
  nsid : int;
  prp1 : int64;
  cdw10 : int;
  cdw11 : int;
  cdw12 : int;
}

type admin = { queues : queues; mutable head : int; mutable phase : int }

type io = { queues : queues; mutable head : int; mutable phase : int }

let slot base tag size = Int64.add base (Int64.of_int (tag * size))

let store_command t addr cmd =
  let word0 = cmd.opcode lor (cmd_tag lsl 16) in
  t.write32 addr (Int64.of_int word0);
  t.write32 (Int64.add addr 4L) (Int64.of_int cmd.nsid);
  t.write32 (Int64.add addr 8L) 0L;
  t.write32 (Int64.add addr 12L) 0L;
  write64_lo_hi t (Int64.add addr 16L) 0L;
  write64_lo_hi t (Int64.add addr 24L) cmd.prp1;
  write64_lo_hi t (Int64.add addr 32L) 0L;
  t.write32 (Int64.add addr 40L) (Int64.of_int cmd.cdw10);
  t.write32 (Int64.add addr 44L) (Int64.of_int cmd.cdw11);
  t.write32 (Int64.add addr 48L) (Int64.of_int cmd.cdw12);
  t.write32 (Int64.add addr 52L) 0L;
  t.write32 (Int64.add addr 56L) 0L;
  t.write32 (Int64.add addr 60L) 0L

let store_tcb t addr cmd =
  let dma =
    if cmd.prp1 = 0L then 0
    else if cmd.opcode land 1 <> 0 then dma_to_device
    else dma_from_device
  in
  t.write32 addr (Int64.of_int ((dma lsl 8) lor (cmd_tag lsl 16)));
  t.write32 (Int64.add addr 4L) (Int64.of_int cmd.cdw12);
  write64_lo_hi t (Int64.add addr 8L) 0L;
  write64_lo_hi t (Int64.add addr 16L) 0L;
  write64_lo_hi t (Int64.add addr 24L) cmd.prp1;
  write64_lo_hi t (Int64.add addr 32L) 0L

(* rtkit_recv returns immediately when the I2A mailbox is empty.
   nvme_exec_command calls that between the doorbell and the completion.
   A buffer request or a syslog line sitting in the mailbox is answered
   here, the same way rtkit_recv answers it. *)
let poll_syslog ?(mbox_timeout = 200000) t =
  let empty = Int64.of_int mbox_empty in
  let rec drain () =
    if Int64.logand (t.read32 (mbox mbox_i2a_control)) empty = 0L then (
      let msg0 = t.read64 (mbox mbox_i2a_recv0) in
      let msg1 = t.read64 (mbox mbox_i2a_recv1) in
      ignore (service ~mbox_timeout t msg0 msg1);
      drain ())
  in
  drain ()

let exec ?(timeout = 1000) t ~adminq ~cmds ~tcbs ~cqes ~get_head ~set_head ~get_phase ~set_phase cmd =
  let cmds_addr = slot cmds cmd_tag cmd_bytes in
  let tcbs_addr = slot tcbs cmd_tag tcb_bytes in
  store_command t cmds_addr cmd;
  store_tcb t tcbs_addr cmd;
  poll_syslog t;
  let sq = if adminq then db_linear_asq else db_linear_iosq in
  t.write32 (nvme sq) (Int64.of_int cmd_tag);
  poll_syslog t;
  let cq_db = if adminq then db_acq else db_iocq in
  let rec wait left =
    if left = 0 then failwith "nvme: could not find command completion in CQ"
    else (
      poll_syslog t;
      let cqe = slot cqes (get_head ()) cqe_bytes in
      let packed = t.read64 (Int64.add cqe 8L) in
      let status = Int64.to_int (Int64.shift_right_logical packed 48) in
      if status land 1 <> get_phase () then wait (left - 1)
      else
        let got = Int64.to_int (Int64.logand (Int64.shift_right_logical packed 32) 0xffffL) in
        t.write32 (nvme tcb_inval) (Int64.of_int got);
        ignore (t.read32 (nvme tcb_stat));
        let next = get_head () + 1 in
        if next = queue_size then (
          set_head 0;
          set_phase (get_phase () lxor 1))
        else set_head next;
        t.write32 (nvme cq_db) (Int64.of_int (get_head ()));
        if got <> cmd_tag then
          failwith (Printf.sprintf "nvme: invalid tag in CQ: expected %d but got %d" cmd_tag got);
        let code = status lsr 1 in
        if code <> 0 then failwith (Printf.sprintf "nvme: command failed with status %d" code))
  in
  wait timeout

let submit ?(timeout = 1000) t admin cmd =
  exec ~timeout t ~adminq:true ~cmds:admin.queues.admin_cmds ~tcbs:admin.queues.admin_tcbs
    ~cqes:admin.queues.admin_cqes
    ~get_head:(fun () -> admin.head)
    ~set_head:(fun head -> admin.head <- head)
    ~get_phase:(fun () -> admin.phase)
    ~set_phase:(fun phase -> admin.phase <- phase)
    cmd

let create_cq ?(timeout = 1000) t admin =
  submit ~timeout t admin
    {
      opcode = admin_create_cq;
      nsid = 0;
      prp1 = admin.queues.io_cqes;
      cdw10 = queue_id_word;
      cdw11 = q_contiguous;
      cdw12 = 0;
    }

let create_sq ?(timeout = 1000) t admin =
  submit ~timeout t admin
    {
      opcode = admin_create_sq;
      nsid = 0;
      prp1 = admin.queues.io_cmds;
      cdw10 = queue_id_word;
      cdw11 = q_contiguous lor (1 lsl 16);
      cdw12 = 0;
    }

(* m1n1 writes the IOQ pointers only after both admin commands succeed.
   A failure here stops. m1n1 would then shut the controller down and
   reset ANS. This client does not take that path. *)
let create_io_queues ?(timeout = 1000) t queues =
  let admin = { queues; head = 0; phase = 1 } in
  create_cq ~timeout t admin;
  create_sq ~timeout t admin;
  write64_lo_hi t (nvme ioq_cqes) queues.io_cqes;
  write64_lo_hi t (nvme ioq_cmds) queues.io_cmds;
  admin

let io_queue queues = { queues; head = 0; phase = 1 }

let load_bytes t addr len =
  let buf = Bytes.create len in
  let rec loop off =
    if off >= len then Bytes.to_string buf
    else
      let word = t.read64 (Int64.add addr (Int64.of_int off)) in
      let room = min 8 (len - off) in
      for b = 0 to room - 1 do
        let byte = Int64.to_int (Int64.logand (Int64.shift_right_logical word (b * 8)) 0xffL) in
        Bytes.set buf (off + b) (Char.chr byte)
      done;
      loop (off + 8)
  in
  loop 0

(* nvme_read. cdw12 is 0, so the transfer is one 4 KiB page. The I/O
   queue has its own head and phase. m1n1 returns false for an unaligned
   buffer and prints nothing. The host raises so that buffer is visible. *)
let read ?(timeout = 1000) t io ~nsid ~lba ~buffer =
  if Int64.logand buffer (Int64.of_int (read_page - 1)) <> 0L then
    failwith "nvme: read buffer is not 4K aligned";
  let lba_lo = Int64.to_int (Int64.logand lba 0xffffffffL) in
  let lba_hi = Int64.to_int (Int64.shift_right_logical lba 32) in
  exec ~timeout t ~adminq:false ~cmds:io.queues.io_cmds ~tcbs:io.queues.io_tcbs ~cqes:io.queues.io_cqes
    ~get_head:(fun () -> io.head)
    ~set_head:(fun head -> io.head <- head)
    ~get_phase:(fun () -> io.phase)
    ~set_phase:(fun phase -> io.phase <- phase)
    { opcode = cmd_read; nsid; prp1 = buffer; cdw10 = lba_lo; cdw11 = lba_hi; cdw12 = 0 };
  load_bytes t buffer read_page
