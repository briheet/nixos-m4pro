(* SART in front of the NVMe coprocessor.
   The live node is /arm-io/sart-ans, compatible sart,coastguard,
   sart-version 3. m1n1 selects the SARTv3 registers for that version
   in upstream/m1n1/src/sart.c. A SART is an allow list of physical
   ranges. It does not remap. The caller supplies the range.
   sart3_get_entry stores the config word in a u8, so only the low 8
   bits mark an entry present. A nonzero value found at init is
   protected and later adds and removes leave it alone.
   sart-power-reg-offset and power-canary-offset are in the dump.
   sart_init does not write them. *)

module Proxy = Proto.Proxy

let node = "/arm-io/sart-ans"
let compatible = "sart,coastguard"
let version = 3
let base = 0x40dc50000L
let window = 0xc000
let range_count = 3
let entries = 16
let shift = 12
let flags_allow = 0xff
let size_max = 0x3fffffffL
let power_reg_offset = 0x13e8
let power_canary_offset = 0

let config_off index = 4 * index
let paddr_off index = 0x40 + (4 * index)
let size_off index = 0x80 + (4 * index)

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
}

let of_transport transport =
  { read32 = Proxy.read32 transport; write32 = Proxy.write32 transport }

type status = { protected : int }

let reg offset = Int64.add base (Int64.of_int offset)

let flags_of t index =
  Int64.to_int (Int64.logand (t.read32 (reg (config_off index))) 0xffL)

let init t =
  let protected = ref 0 in
  for index = 0 to entries - 1 do
    if flags_of t index <> 0 then protected := !protected lor (1 lsl index)
  done;
  { protected = !protected }

let aligned value = Int64.logand value (Int64.of_int ((1 lsl shift) - 1)) = 0L

let check_region ~paddr ~size =
  if (not (aligned paddr)) || not (aligned size) then
    invalid_arg "sart: region is not 4K aligned";
  let pages = Int64.shift_right_logical size shift in
  if Int64.unsigned_compare pages size_max > 0 then failwith "sart: region is too large"

let write_entry t index flags ~paddr ~size =
  t.write32 (reg (paddr_off index)) (Int64.shift_right_logical paddr shift);
  t.write32 (reg (size_off index)) (Int64.shift_right_logical size shift);
  t.write32 (reg (config_off index)) (Int64.of_int flags)

let protected_bit status index = status.protected land (1 lsl index) <> 0

let allow t status ~paddr ~size =
  check_region ~paddr ~size;
  let rec loop index =
    if index = entries then failwith "sart: no more free entries"
    else if protected_bit status index || flags_of t index <> 0 then loop (index + 1)
    else (
      write_entry t index flags_allow ~paddr ~size;
      index)
  in
  loop 0

let remove t status ~paddr ~size =
  check_region ~paddr ~size;
  let rec loop index =
    if index = entries then failwith "sart: could not find entry to be removed"
    else if protected_bit status index then loop (index + 1)
    else
      let flags = flags_of t index in
      let entry_paddr = Int64.shift_left (t.read32 (reg (paddr_off index))) shift in
      let entry_size = Int64.shift_left (t.read32 (reg (size_off index))) shift in
      if flags <> 0 && entry_paddr = paddr && entry_size = size then
        write_entry t index 0 ~paddr:0L ~size:0L
      else loop (index + 1)
  in
  loop 0
