(* DART IOMMU for this Mac.
   All 30 nodes are compatible dart,t8110. The register sequence is
   dart_init in upstream/m1n1/src/dart.c for DART_T8110. The page tables
   are memory on the machine. This client only programs the registers
   from a table address the caller already has.
   m1n1 polls dart->regs + DART_T8110_TLB_CMD_OP. That macro is the
   opcode bitfield, value 0x700, not the command register. The busy bit
   is bit 31 of the command register at offset 0x80, so the poll here
   reads that register. *)

module Proxy = Proto.Proxy

let compatible = "dart,t8110"
let sid_count = 256
let page_size = 0x4000
let ttbr_shift = 14

let protect = 0x200
let protect_ttbr_tcr = 1
let enable_streams = 0xc00
let tcr = 0x1000
let tcr_translate = 1
let ttbr = 0x1400
let ttbr_valid = 1
let tlb_cmd = 0x80
let tlb_busy = 0x80000000
let tlb_flush_sid = 0x100
let poll_timeout = 100

type instance = {
  name : string;
  base : int64;
  length : int;
}

let instances =
  [|
    { name = "dart-isp0"; base = 0x5828c0000L; length = 0xc000 };
    { name = "dart-apcie0"; base = 0x410000000L; length = 0x20000 };
    { name = "dart-apcie1"; base = 0x411000000L; length = 0x20000 };
    { name = "dart-mtp"; base = 0x514800000L; length = 0xc000 };
    { name = "dart-apciec0"; base = 0x384000000L; length = 0x20000 };
    { name = "dart-acio0"; base = 0x381a80000L; length = 0xc000 };
    { name = "dart-apciec1"; base = 0x38c000000L; length = 0x20000 };
    { name = "dart-acio1"; base = 0x389a80000L; length = 0xc000 };
    { name = "dart-apciec2"; base = 0x394000000L; length = 0x20000 };
    { name = "dart-acio2"; base = 0x391a80000L; length = 0xc000 };
    { name = "dart-aop"; base = 0x510f00000L; length = 0xc000 };
    { name = "dart-sio"; base = 0x429060000L; length = 0x20000 };
    { name = "dart-pmp"; base = 0x500300000L; length = 0xc000 };
    { name = "dart-sep"; base = 0x404c80000L; length = 0x20000 };
    { name = "dart-usb0"; base = 0x382f00000L; length = 0xc000 };
    { name = "dart-usb1"; base = 0x38af00000L; length = 0xc000 };
    { name = "dart-usb2"; base = 0x392f00000L; length = 0xc000 };
    { name = "dart-disp0"; base = 0x402300000L; length = 0xc000 };
    { name = "dart-dcp"; base = 0x402340000L; length = 0x20000 };
    { name = "dart-dcpext0"; base = 0x3a2340000L; length = 0x20000 };
    { name = "dart-dispext0"; base = 0x3a2300000L; length = 0xc000 };
    { name = "dart-dcpext1"; base = 0x602340000L; length = 0xc000 };
    { name = "dart-dispext1"; base = 0x602300000L; length = 0xc000 };
    { name = "dart-scaler0"; base = 0x521260000L; length = 0xc000 };
    { name = "dart-ave0"; base = 0x2830a0000L; length = 0xc000 };
    { name = "dart-apr0"; base = 0x301020000L; length = 0xc000 };
    { name = "dart-jpeg0"; base = 0x487020000L; length = 0xc000 };
    { name = "dart-jpeg1"; base = 0x487080000L; length = 0xc000 };
    { name = "dart-ane0"; base = 0x485800000L; length = 0xc000 };
    { name = "dart-avd0"; base = 0x281020000L; length = 0xc000 };
  |]

let count = Array.length instances

let find name =
  let rec loop i =
    if i = count then raise Not_found
    else if instances.(i).name = name then instances.(i)
    else loop (i + 1)
  in
  loop 0

let apcie0 = find "dart-apcie0"

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
}

let of_transport transport =
  { read32 = Proxy.read32 transport; write32 = Proxy.write32 transport }

let reg base offset = Int64.add base (Int64.of_int offset)

let encode_ttbr table =
  let page = Int64.shift_right_logical table ttbr_shift in
  Int64.logor (Int64.shift_left (Int64.logand page 0x0fffffffL) 2) (Int64.of_int ttbr_valid)

let stream_shift stream = 4 * (stream lsr 5)

let flush t base stream =
  let cmd = Int64.logor (Int64.of_int tlb_flush_sid) (Int64.of_int (stream land 0xff)) in
  let addr = reg base tlb_cmd in
  t.write32 addr cmd;
  let rec poll left =
    if left = 0 then failwith "dart: TLB command busy did not clear"
    else if Int64.logand (t.read32 addr) (Int64.of_int tlb_busy) = 0L then ()
    else poll (left - 1)
  in
  poll poll_timeout

type status = { locked : bool }

let init t instance ~stream ~table =
  if stream < 0 || stream >= sid_count then
    failwith (Printf.sprintf "dart: stream %d is too big" stream);
  if Int64.logand table (Int64.of_int (page_size - 1)) <> 0L then
    invalid_arg "dart: page table is not 16K aligned";
  let base = instance.base in
  let locked = Int64.logand (t.read32 (reg base protect)) (Int64.of_int protect_ttbr_tcr) <> 0L in
  t.write32 (reg base (enable_streams + stream_shift stream)) (Int64.shift_left 1L (stream land 31));
  let ttbr_addr = reg base (ttbr + (4 * stream)) in
  let existing = t.read32 ttbr_addr in
  if (not locked) || Int64.logand existing (Int64.of_int ttbr_valid) = 0L then
    t.write32 ttbr_addr (encode_ttbr table);
  if not locked then t.write32 (reg base (tcr + (4 * stream))) (Int64.of_int tcr_translate);
  flush t base stream;
  { locked }
