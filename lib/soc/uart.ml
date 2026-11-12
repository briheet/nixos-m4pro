(* Debug UART for this Mac.
   Register offsets match upstream/m1n1/src/uart_regs.h.
   The base matches EARLY_UART_BASE for T6040 and T6041 in src/soc.h,
   and the IODeviceMemory address of /arm-io/uart0 in the dumped tree.
   The raw ADT reg cell is the address inside the arm-io bus; m1n1
   translates that before it touches the device. *)

module Proxy = Proto.Proxy

let compatible = "uart-1,samsung"
let node = "/arm-io/uart0"
let clock = 24_000_000
let t6040_base = 0x429200000L
let size = 0x4000L
let bus_address = 0x229200000L

let ulcon = 0x000
let ucon = 0x004
let ufcon = 0x008
let utrstat = 0x010
let ufstat = 0x018
let utxh = 0x020
let urxh = 0x024
let ubrdiv = 0x028
let ufracval = 0x02c

let utrstat_txe = 0x4
let utrstat_txbe = 0x2
let utrstat_rxd = 0x1

let ubrdiv_of_baud baud =
  if baud <= 0 then invalid_arg "baud must be positive";
  ((clock / baud) + 7) / 16 - 1

type t = {
  base : int64;
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
}

let of_proxy ~(read32 : int64 -> int64) ~(write32 : int64 -> int64 -> unit) =
  { base = t6040_base; read32; write32 }

let of_transport transport =
  of_proxy ~read32:(Proxy.read32 transport) ~write32:(Proxy.write32 transport)

let reg t offset = Int64.add t.base (Int64.of_int offset)

let status_has t mask =
  Int64.logand (t.read32 (reg t utrstat)) (Int64.of_int mask) <> 0L

let put_byte t byte =
  while not (status_has t utrstat_txbe) do
    ()
  done;
  t.write32 (reg t utxh) (Int64.of_int (byte land 0xff))

let put_char t = function
  | '\n' ->
      put_byte t (Char.code '\r');
      put_byte t (Char.code '\n')
  | c -> put_byte t (Char.code c)

let put_string t s = String.iter (put_char t) s
