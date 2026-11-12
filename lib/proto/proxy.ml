(* Host side of the m1n1 proxy protocol.
   Frame layout matches upstream/m1n1/proxyclient/m1n1/proxy.py at the
   submodule commit. A request is 7 little-endian u64 words: the opcode
   and 6 arguments. A reply is 3 words: opcode, signed status, value. *)

let frame_args = 6
let request_bytes = 8 * (1 + frame_args)
let reply_bytes = 24

let s_ok = 0L
let s_badcmd = -1L

let p_nop = 0x000L
let p_exit = 0x001L
let p_call = 0x002L
let p_get_bootargs = 0x003L
let p_get_base = 0x004L
let p_set_baud = 0x005L
let p_udelay = 0x006L
let p_set_exc_guard = 0x007L
let p_get_exc_count = 0x008L
let p_el0_call = 0x009L
let p_el1_call = 0x00aL
let p_vector = 0x00bL
let p_gl1_call = 0x00cL
let p_gl2_call = 0x00dL
let p_get_simd_state = 0x00eL
let p_put_simd_state = 0x00fL
let p_reboot = 0x010L
let p_sleep = 0x011L
let p_el3_call = 0x012L
let p_get_chipid = 0x013L
let p_get_cpu_features = 0x014L
let p_put_simd_state_masked = 0x015L

let p_write64 = 0x100L
let p_write32 = 0x101L
let p_write16 = 0x102L
let p_write8 = 0x103L
let p_read64 = 0x104L
let p_read32 = 0x105L
let p_read16 = 0x106L
let p_read8 = 0x107L
let p_set64 = 0x108L
let p_set32 = 0x109L
let p_set16 = 0x10aL
let p_set8 = 0x10bL
let p_clear64 = 0x10cL
let p_clear32 = 0x10dL
let p_clear16 = 0x10eL
let p_clear8 = 0x10fL
let p_mask64 = 0x110L
let p_mask32 = 0x111L
let p_mask16 = 0x112L
let p_mask8 = 0x113L
let p_writeread64 = 0x114L
let p_writeread32 = 0x115L
let p_writeread16 = 0x116L
let p_writeread8 = 0x117L

let p_memcpy64 = 0x200L
let p_memcpy32 = 0x201L
let p_memcpy16 = 0x202L
let p_memcpy8 = 0x203L
let p_memset64 = 0x204L
let p_memset32 = 0x205L
let p_memset16 = 0x206L
let p_memset8 = 0x207L

let p_iodev_set_usage = 0x900L
let p_iodev_can_read = 0x901L
let p_iodev_can_write = 0x902L
let p_iodev_read = 0x903L
let p_iodev_write = 0x904L
let p_iodev_whoami = 0x905L
let p_usb_iodev_vuart_setup = 0x906L

let p_dart_init = 0xb00L
let p_dart_shutdown = 0xb01L
let p_dart_map = 0xb02L
let p_dart_unmap = 0xb03L

let p_pcie_init = 0xe00L
let p_pcie_shutdown = 0xe01L

let p_nvme_init = 0xf00L
let p_nvme_shutdown = 0xf01L
let p_nvme_read = 0xf02L
let p_nvme_flush = 0xf03L

let p_mcc_get_carveouts = 0x1000L
let p_cpufreq_init = 0x1300L

type transport = bytes -> bytes

let put_u64 buf off value =
  let value = ref value in
  for i = 0 to 7 do
    let byte = Int64.to_int (Int64.logand !value 0xffL) in
    Bytes.set buf (off + i) (Char.chr byte);
    value := Int64.shift_right_logical !value 8
  done

let get_u64 buf off =
  let value = ref 0L in
  for i = 7 downto 0 do
    let byte = Char.code (Bytes.get buf (off + i)) in
    value := Int64.logor (Int64.shift_left !value 8) (Int64.of_int byte)
  done;
  !value

let encode_request opcode args =
  if List.length args > frame_args then
    invalid_arg "m1n1 proxy request takes at most 6 arguments";
  let buf = Bytes.make request_bytes '\000' in
  put_u64 buf 0 opcode;
  List.iteri (fun i arg -> put_u64 buf ((i + 1) * 8) arg) args;
  buf

let decode_reply reply =
  if Bytes.length reply <> reply_bytes then
    invalid_arg
      (Printf.sprintf "m1n1 proxy reply is %d bytes, got %d" reply_bytes
         (Bytes.length reply));
  (get_u64 reply 0, get_u64 reply 8, get_u64 reply 16)

let call transport opcode args =
  let reply_opcode, status, value = decode_reply (transport (encode_request opcode args)) in
  if reply_opcode <> opcode then
    failwith
      (Printf.sprintf "m1n1 proxy opcode mismatch: sent %#Lx, got %#Lx" opcode reply_opcode);
  if status = s_badcmd then failwith "m1n1 proxy: bad command";
  if status <> s_ok then failwith (Printf.sprintf "m1n1 proxy status %#Lx" status);
  value

(* The drivers share these. Each one is the proxy opcode m1n1's read32,
   write32, read64, write64, and mask32 lower to. *)
let read32 transport addr = call transport p_read32 [ addr ]

let write32 transport addr value = ignore (call transport p_write32 [ addr; value ])

let read64 transport addr = call transport p_read64 [ addr ]

let write64 transport addr value = ignore (call transport p_write64 [ addr; value ])

let mask32 transport addr clear set = call transport p_mask32 [ addr; clear; set ]
