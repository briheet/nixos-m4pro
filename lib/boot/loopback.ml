(* In-process stand-in for uartproxy_run in upstream/m1n1/src/uartproxy.c.
   It checks the UART framing and answers the proxy opcodes the UART driver
   uses. Bytes written to UTXH are kept, which is what would have left
   /arm-io/uart0. UTRSTAT reports the transmitter empty: that is the Samsung
   UART once the FIFO has drained. On the UART, m1n1 refuses the only
   optional feature bit, so NOP enables nothing. *)

module Ans = Nvme.Ans
module Uart = Soc.Uart
module Dart = Soc.Dart
module Pmgr = Soc.Pmgr
module Pcie = Soc.Pcie
module Proxy = Proto.Proxy
module Wire = Proto.Wire

type t = {
  words : (int64, int64) Hashtbl.t;
  tx : Buffer.t;
  inbox : (int64 * int64) Queue.t;
  sent : (int64 * int64) list ref;
  script : bool;
  complete_cq : bool ref;
  cq_head : int ref;
  cq_phase : int ref;
  io_head : int ref;
  io_phase : int ref;
  block : bytes;
  cqe_code : int ref;
  cqe_tag : int option ref;
}

let fresh_block () =
  let block = Bytes.make Ans.read_page '\000' in
  Bytes.blit_string "loopback" 0 block 0 8;
  block

let create ?(script = true) ?(complete_cq = true) () =
  {
    words = Hashtbl.create 16;
    tx = Buffer.create 64;
    inbox = Queue.create ();
    sent = ref [];
    script;
    complete_cq = ref complete_cq;
    cq_head = ref 0;
    cq_phase = ref 1;
    io_head = ref 0;
    io_phase = ref 1;
    block = fresh_block ();
    cqe_code = ref 0;
    cqe_tag = ref None;
  }

let set_cqe_code t code = t.cqe_code := code
let set_cqe_tag t tag = t.cqe_tag := Some tag
let set_complete_cq t flag = t.complete_cq := flag

let set_block t data =
  Bytes.fill t.block 0 Ans.read_page '\000';
  let n = min Ans.read_page (String.length data) in
  Bytes.blit_string data 0 t.block 0 n

let tx t = Buffer.contents t.tx
let post t msg0 msg1 = Queue.add (msg0, msg1) t.inbox
let sent t = List.rev !(t.sent)
let chip_id = 0x6040L

let mbox offset = Int64.add Ans.cpu_base (Int64.of_int (Ans.mbox_offset + offset))
let a2i_send0 = mbox Ans.mbox_a2i_send0
let a2i_send1 = mbox Ans.mbox_a2i_send1
let i2a_control = mbox Ans.mbox_i2a_control
let i2a_recv0 = mbox Ans.mbox_i2a_recv0
let i2a_recv1 = mbox Ans.mbox_i2a_recv1

let uart_reg offset = Int64.add Uart.t6040_base (Int64.of_int offset)

let is_tlb addr =
  let rec loop i =
    if i = Dart.count then false
    else if Int64.add Dart.instances.(i).base (Int64.of_int Dart.tlb_cmd) = addr then true
    else loop (i + 1)
  in
  loop 0

let read32 t addr =
  if addr = i2a_control then
    if Queue.is_empty t.inbox then Int64.of_int Ans.mbox_empty else 0L
  else if addr = uart_reg Uart.utrstat then Int64.of_int (Uart.utrstat_txbe lor Uart.utrstat_txe)
  else
    match Hashtbl.find_opt t.words addr with
    | Some value ->
        if is_tlb addr && Int64.logand value (Int64.of_int Dart.tlb_busy) <> 0L then
          Hashtbl.replace t.words addr
            (Int64.logand value (Int64.lognot (Int64.of_int Dart.tlb_busy)));
        Int64.logand value 0xffffffffL
    | None -> 0L

let in_pmgr addr =
  let limit = Int64.add Pmgr.base Pmgr.size in
  Int64.unsigned_compare addr Pmgr.base >= 0 && Int64.unsigned_compare addr limit < 0

(* pmgr_set_mode polls PMGR_PS_ACTUAL. The silicon copies the target into
   that field once the transition finishes. The loopback does it on the write. *)
let complete_pmgr value =
  let target = Int64.logand value 0xfL in
  Int64.logor (Int64.logand value (Int64.lognot 0xf0L)) (Int64.shift_left target 4)

let is_phy_ctrl addr =
  addr = Pcie.phy || Array.exists (fun port -> port.Pcie.phy = addr) Pcie.ports

(* pcie_init polls PHY clock acks, a PHY status bit, an RC status bit, and
   the port RUN bit. The loopback raises those bits when the matching
   request is stored. LINKSTS stays 0, so the busy poll sees an idle port. *)
let complete_pcie t addr value =
  let value =
    if is_phy_ctrl addr then (
      let value = if Int64.logand value 1L <> 0L then Int64.logor value 4L else value in
      let value = if Int64.logand value 2L <> 0L then Int64.logor value 8L else value in
      if addr = Pcie.phy && Int64.logand value 0xcL = 0xcL then
        Hashtbl.replace t.words (Int64.add addr 8L) 1L;
      value)
    else value
  in
  if addr = Int64.add Pcie.rc 0x50L && Int64.logand value 1L <> 0L then
    Hashtbl.replace t.words (Int64.add Pcie.rc 0x58L) 1L;
  if Int64.logand value 1L <> 0L then
    Array.iter
      (fun port ->
        if addr = Int64.add port.Pcie.base (Int64.of_int Pcie.port_reset) then
          Hashtbl.replace t.words (Int64.add port.Pcie.base (Int64.of_int Pcie.port_status)) 1L)
      Pcie.ports;
  value

(* nvme_ctrl_disable clears CC.EN and polls CSTS.RDY. nvme_ctrl_enable
   sets CC.EN and polls until RDY is set. The loopback copies that bit.
   A linear doorbell is answered with one completion at the completion
   queue setup or CREATE_CQ stored. ANS DMA-writes that entry. The admin
   queue and the I/O queue each start at phase 1. The tag is the doorbell
   value. A read doorbell also copies the stand-in page to PRP1. *)
let read_ptr t addr =
  let word_at addr =
    match Hashtbl.find_opt t.words addr with Some value -> Int64.logand value 0xffffffffL | None -> 0L
  in
  Int64.logor (word_at addr) (Int64.shift_left (word_at (Int64.add addr 4L)) 32)

let plant_at t cq_reg head_ref phase_ref tag =
  let cq = read_ptr t cq_reg in
  let head = !head_ref in
  let phase = !phase_ref in
  let cqe = Int64.add cq (Int64.of_int (head * Ans.cqe_bytes)) in
  let planted =
    match !(t.cqe_tag) with Some forced -> forced | None -> Int64.to_int (Int64.logand tag 0xffffL)
  in
  let status = (!(t.cqe_code) lsl 1) lor phase in
  let packed =
    Int64.logor (Int64.shift_left (Int64.of_int status) 48) (Int64.shift_left (Int64.of_int planted) 32)
  in
  Hashtbl.replace t.words cqe 0L;
  Hashtbl.replace t.words (Int64.add cqe 8L) packed;
  let next = head + 1 in
  if next = Ans.queue_size then (
    head_ref := 0;
    phase_ref := phase lxor 1)
  else head_ref := next

let write_block t dest =
  let rec loop i =
    if i < Ans.read_page / 8 then (
      let word = ref 0L in
      for b = 0 to 7 do
        let byte = Char.code (Bytes.get t.block ((i * 8) + b)) in
        word := Int64.logor !word (Int64.shift_left (Int64.of_int byte) (b * 8))
      done;
      Hashtbl.replace t.words (Int64.add dest (Int64.of_int (i * 8))) !word;
      loop (i + 1))
  in
  loop 0

let complete_io t tag =
  let base = Ans.nvme_base in
  let cmds = read_ptr t (Int64.add base (Int64.of_int Ans.ioq_cmds)) in
  let slot =
    Int64.add cmds (Int64.of_int (Int64.to_int (Int64.logand tag 0xffffL) * Ans.cmd_bytes))
  in
  let prp1 = read_ptr t (Int64.add slot 24L) in
  write_block t prp1;
  plant_at t (Int64.add base (Int64.of_int Ans.ioq_cqes)) t.io_head t.io_phase tag

let complete_ans t addr value =
  if addr = Int64.add Ans.nvme_base (Int64.of_int Ans.cc) then (
    let csts = Int64.add Ans.nvme_base (Int64.of_int Ans.csts) in
    let old = match Hashtbl.find_opt t.words csts with Some old -> old | None -> 0L in
    let next =
      if Int64.logand value 1L <> 0L then Int64.logor old 1L else Int64.logand old (Int64.lognot 1L)
    in
    Hashtbl.replace t.words csts next);
  if !(t.complete_cq) && addr = Int64.add Ans.nvme_base (Int64.of_int Ans.db_linear_asq) then
    plant_at t (Int64.add Ans.nvme_base (Int64.of_int Ans.acq)) t.cq_head t.cq_phase value;
  if !(t.complete_cq) && addr = Int64.add Ans.nvme_base (Int64.of_int Ans.db_linear_iosq) then
    complete_io t value;
  value

(* asc_recv reads I2A RECV0 and then RECV1 and writes nothing back.
   The read of RECV1 is what retires the message. EMPTY is bit 17 while
   the inbox has nothing queued. *)
let read64 t addr =
  if addr = i2a_recv0 then
    if Queue.is_empty t.inbox then 0L
    else
      let msg0, _ = Queue.peek t.inbox in
      msg0
  else if addr = i2a_recv1 then
    if Queue.is_empty t.inbox then 0L
    else
      let _, msg1 = Queue.take t.inbox in
      msg1
  else match Hashtbl.find_opt t.words addr with Some value -> value | None -> 0L

(* The script is the coprocessor stand-in for rtkit_boot.
   Power-init is answered with HELLO. HELLO_ACK is answered with the two
   endpoint-map chunks. The DONE reply is answered with IOP power ON.
   START_EP does not grow a buffer request. *)
let script_reply t msg0 =
  let typ = Ans.type_of msg0 in
  if msg0 = Ans.wakeup_msg0 then Queue.add (Ans.standin_hello, 0L) t.inbox
  else if typ = Ans.msg_hello_ack then (
    Queue.add (Ans.standin_epmap_lo, 0L) t.inbox;
    Queue.add (Ans.standin_epmap_hi, 0L) t.inbox)
  else if typ = Ans.msg_epmap && Int64.logand msg0 Ans.epmap_done <> 0L then
    Queue.add (Ans.iop_power_ack, 0L) t.inbox

let write64 t addr value =
  Hashtbl.replace t.words addr value;
  if addr = a2i_send1 then (
    let msg0 = match Hashtbl.find_opt t.words a2i_send0 with Some msg0 -> msg0 | None -> 0L in
    t.sent := (msg0, value) :: !(t.sent);
    if t.script then script_reply t msg0)

let write32 t addr value =
  let value = Int64.logand value 0xffffffffL in
  let value = if in_pmgr addr then complete_pmgr value else value in
  let value = if is_tlb addr then Int64.logor value (Int64.of_int Dart.tlb_busy) else value in
  let value = complete_pcie t addr value in
  let value = complete_ans t addr value in
  if addr = uart_reg Uart.utxh then Buffer.add_char t.tx (Char.chr (Int64.to_int value land 0xff))
  else if addr <> uart_reg Uart.utrstat then Hashtbl.replace t.words addr value

let mask32 t addr clear set =
  let old = read32 t addr in
  let cleared = Int64.logand old (Int64.lognot (Int64.logand clear 0xffffffffL)) in
  let value = Int64.logand (Int64.logor cleared (Int64.logand set 0xffffffffL)) 0xffffffffL in
  write32 t addr value;
  value

let answer t payload =
  let opcode = Proxy.get_u64 payload 0 in
  let arg n = Proxy.get_u64 payload ((n + 1) * 8) in
  let status, retval =
    if opcode = Proxy.p_nop then (Proxy.s_ok, 0L)
    else if opcode = Proxy.p_get_chipid then (Proxy.s_ok, chip_id)
    else if opcode = Proxy.p_read32 then (Proxy.s_ok, read32 t (arg 0))
    else if opcode = Proxy.p_read64 then (Proxy.s_ok, read64 t (arg 0))
    else if opcode = Proxy.p_write32 then (
      write32 t (arg 0) (arg 1);
      (Proxy.s_ok, 0L))
    else if opcode = Proxy.p_write64 then (
      write64 t (arg 0) (arg 1);
      (Proxy.s_ok, 0L))
    else if opcode = Proxy.p_mask32 then (Proxy.s_ok, mask32 t (arg 0) (arg 1) (arg 2))
    else (Proxy.s_badcmd, 0L)
  in
  let data = Bytes.make Wire.reply_data_len '\000' in
  Proxy.put_u64 data 0 opcode;
  Proxy.put_u64 data 8 status;
  Proxy.put_u64 data 16 retval;
  data

let handle t frame =
  let command = Wire.parse_command frame in
  if not command.checksum_ok then Wire.encode_reply command.cmd Wire.st_csumerr Bytes.empty
  else if command.cmd = Wire.req_nop then Wire.encode_reply command.cmd Wire.st_ok Bytes.empty
  else if command.cmd = Wire.req_proxy then
    Wire.encode_reply command.cmd Wire.st_ok (answer t command.payload)
  else Wire.encode_reply command.cmd Wire.st_badcmd Bytes.empty
