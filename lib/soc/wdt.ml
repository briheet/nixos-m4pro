(* Watchdog for this Mac.
   The disable sequence is wdt_disable in upstream/m1n1/src/wdt.c.
   Addresses are the IODeviceMemory ranges of /arm-io/wdt, which are the
   CPU physical addresses adt_get_reg returns. Range 0 is the primary
   window. wdt-version on this machine is 2, so m1n1 also stores 0 at
   range 2 with no added offset. The stub Linux tree only lists range 0. *)

module Proxy = Proto.Proxy

let compatible = "wdt,t8101"
let node = "/arm-io/wdt"
let version = 2

let count = 0x10
let alarm = 0x14
let ctl = 0x1c

(* Values wdt_reboot writes. That sequence resets the machine. *)
let reboot_alarm = 0x100000L
let reboot_ctl = 4L

type range = {
  index : int;
  address : int64;
  length : int;
}

let ranges =
  [|
    { index = 0; address = 0x50836c000L; length = 0x4000 };
    { index = 1; address = 0x508338260L; length = 4 };
    { index = 2; address = 0x508330008L; length = 4 };
    { index = 3; address = 0x50833002cL; length = 4 };
    { index = 4; address = 0x508330020L; length = 4 };
  |]

let primary = ranges.(0)
let secondary = ranges.(2)
let clears_secondary = version = 2 || version = 3

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
}

let of_transport transport =
  { read32 = Proxy.read32 transport; write32 = Proxy.write32 transport }

let reg offset = Int64.add primary.address (Int64.of_int offset)

let disable t =
  t.write32 (reg ctl) 0L;
  if clears_secondary then t.write32 secondary.address 0L

let reboot t =
  t.write32 (reg alarm) reboot_alarm;
  t.write32 (reg count) 0L;
  t.write32 (reg ctl) reboot_ctl
