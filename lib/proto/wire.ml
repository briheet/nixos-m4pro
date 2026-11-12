(* Outer framing of the m1n1 UART proxy.
   A command is 64 bytes: u32 command, 56-byte payload, u32 checksum.
   A reply is 36 bytes: u32 command, i32 status, 24-byte data, u32 checksum.
   The checksum covers every byte except its own field. The mix is the one
   in src/uartproxy.c: start at 0xDEADBEEF, then per byte
   sum = sum * 31337 + (byte lxor 0x5A), then xor 0xADDEDBAD.
   All of that arithmetic is modulo 2^32. *)

let command_len = 64
let payload_len = 56
let reply_len = 36
let reply_data_len = 24

let req_nop = 0x00aa55ff
let req_proxy = 0x01aa55ff
let req_memread = 0x02aa55ff
let req_memwrite = 0x03aa55ff
let req_boot = 0x04aa55ff
let req_event = 0x05aa55ff

let st_ok = 0
let st_badcmd = -1
let st_inval = -2
let st_xfrerr = -3
let st_csumerr = -4

let checksum_init = 0xdeadbeef
let checksum_final = 0xaddedbad
let checksum_sentinel = 0xd0decade
let data_end_sentinel = 0xb0cacc10

(* Darwin default in proxyclient/m1n1/proxy.py. The live device appears
   only while this Mac is booted into m1n1 and a second machine is the client. *)
let darwin_device = "/dev/cu.usbmodemP_01"
let baud = 115200

let u32 n = n land 0xffffffff

let put_u32 buf off value =
  let value = u32 value in
  for i = 0 to 3 do
    Bytes.set buf (off + i) (Char.chr ((value lsr (8 * i)) land 0xff))
  done

let get_u32 buf off =
  let value = ref 0 in
  for i = 0 to 3 do
    let byte = Char.code (Bytes.get buf (off + i)) in
    value := !value lor (byte lsl (8 * i))
  done;
  u32 !value

let get_i32 buf off =
  let value = get_u32 buf off in
  if value >= 0x80000000 then value - 0x100000000 else value

let checksum buf off len =
  let sum = ref checksum_init in
  for i = 0 to len - 1 do
    let byte = Char.code (Bytes.get buf (off + i)) in
    sum := u32 ((!sum * 31337) + (byte lxor 0x5a))
  done;
  u32 (!sum lxor checksum_final)

type command = {
  cmd : int;
  payload : bytes;
  checksum_ok : bool;
}

let encode_command cmd payload =
  if Bytes.length payload > payload_len then
    invalid_arg "m1n1 uart command payload is at most 56 bytes";
  let buf = Bytes.make command_len '\000' in
  put_u32 buf 0 cmd;
  Bytes.blit payload 0 buf 4 (Bytes.length payload);
  put_u32 buf (command_len - 4) (checksum buf 0 (command_len - 4));
  buf

let parse_command frame =
  if Bytes.length frame <> command_len then
    invalid_arg
      (Printf.sprintf "m1n1 uart command is %d bytes, got %d" command_len (Bytes.length frame));
  let payload = Bytes.sub frame 4 payload_len in
  let got = get_u32 frame (command_len - 4) in
  let expected = checksum frame 0 (command_len - 4) in
  { cmd = get_u32 frame 0; payload; checksum_ok = got = expected }

let encode_reply cmd status data =
  if Bytes.length data > reply_data_len then
    invalid_arg "m1n1 uart reply data is at most 24 bytes";
  let buf = Bytes.make reply_len '\000' in
  put_u32 buf 0 cmd;
  put_u32 buf 4 status;
  Bytes.blit data 0 buf 8 (Bytes.length data);
  put_u32 buf (reply_len - 4) (checksum buf 0 (reply_len - 4));
  buf

exception Checksum_error of { expected : int; got : int }

type reply = {
  cmd : int;
  status : int;
  data : bytes;
}

let decode_reply frame =
  if Bytes.length frame <> reply_len then
    invalid_arg
      (Printf.sprintf "m1n1 uart reply is %d bytes, got %d" reply_len (Bytes.length frame));
  let got = get_u32 frame (reply_len - 4) in
  let expected = checksum frame 0 (reply_len - 4) in
  if got <> expected then raise (Checksum_error { expected; got });
  { cmd = get_u32 frame 0; status = get_i32 frame 4; data = Bytes.sub frame 8 reply_data_len }

type peer = bytes -> bytes

let proxy_transport (peer : peer) request =
  let reply = decode_reply (peer (encode_command req_proxy request)) in
  if reply.cmd <> req_proxy then
    failwith
      (Printf.sprintf "m1n1 uart proxy command mismatch: sent %#x, got %#x" req_proxy reply.cmd);
  if reply.status <> st_ok then failwith (Printf.sprintf "m1n1 uart proxy status %d" reply.status);
  reply.data
