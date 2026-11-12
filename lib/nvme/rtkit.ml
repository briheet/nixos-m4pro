(* RTKit management messages from upstream/m1n1/src/rtkit.c.
   Ans includes this module, so the names stay on Ans. *)

let mgmt_type_shift = 52
let mgmt_iop_pwr = 6
let power_init = 0x220
let power_on = 0x20
let ep_mgmt = 0
let min_version = 11
let max_version = 12
let msg_hello = 1
let msg_hello_ack = 2
let msg_start_ep = 5
let msg_iop_pwr_ack = 7
let msg_epmap = 8
let msg_ap_pwr = 0xb
let ep_crashlog = 1
let ep_syslog = 2
let ep_debug = 3
let ep_ioreport = 4
let ep_oslog = 8
let epmap_done = 0x8000000000000L
let start_ep_flag = 2L
let msg_buffer = 1
let msg_syslog_log = 5
let iova_mask = 0x3ffffffffffL

let wakeup_msg0 =
  Int64.logor (Int64.shift_left (Int64.of_int mgmt_iop_pwr) mgmt_type_shift) (Int64.of_int power_init)

let with_type typ rest =
  Int64.logor (Int64.shift_left (Int64.of_int typ) mgmt_type_shift) rest

let type_of msg0 =
  Int64.to_int (Int64.logand (Int64.shift_right_logical msg0 mgmt_type_shift) 0xffL)

let field msg0 shift mask =
  Int64.to_int (Int64.logand (Int64.shift_right_logical msg0 shift) mask)

let hello_msg0 ~min_ver ~max_ver =
  with_type msg_hello (Int64.logor (Int64.shift_left (Int64.of_int max_ver) 16) (Int64.of_int min_ver))

(* Firmware stand-in. Two map chunks so the reply uses MORE and then DONE.
   Chunk 0 names the low system endpoints. Chunk 1 names OSLOG and sets DONE.
   A live ANS sends its own bitmap. This one is not a capture from this Mac. *)
let standin_hello = hello_msg0 ~min_ver:min_version ~max_ver:max_version
let standin_epmap_lo = with_type msg_epmap 0x1fL
let standin_epmap_hi = Int64.logor (with_type msg_epmap 0x100L) epmap_done
let iop_power_ack = with_type msg_iop_pwr_ack (Int64.of_int power_on)

let hello_ack_msg0 ver =
  with_type msg_hello_ack (Int64.logor (Int64.shift_left (Int64.of_int ver) 16) (Int64.of_int ver))

let epmap_reply_msg0 ~base ~done_ =
  let msg = with_type msg_epmap (Int64.shift_left (Int64.of_int base) 32) in
  if done_ then Int64.logor msg epmap_done else Int64.logor msg 1L

let start_ep_msg0 ep =
  Int64.logor (with_type msg_start_ep start_ep_flag) (Int64.shift_left (Int64.of_int ep) 32)

let ap_power_msg0 = with_type msg_ap_pwr (Int64.of_int power_on)

let pages_of msg0 = Int64.to_int (Int64.logand (Int64.shift_right_logical msg0 44) 0xffL)
let iova_of msg0 = Int64.logand msg0 iova_mask

let buffer_msg0 ~pages ~iova =
  let body =
    Int64.logor (Int64.shift_left (Int64.of_int pages) 44) (Int64.logand iova iova_mask)
  in
  with_type msg_buffer body
