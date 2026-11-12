(* Finds the T6040 early UART address inside an m1n1 image.
   src/start.S emits that constant when the image is built with
   -DTARGET=0x6040. The submodule sources are left as upstream wrote them. *)

module Uart = Soc.Uart
module Proxy = Proto.Proxy

let early_uart = Uart.t6040_base
let default_path = "upstream/m1n1/build/m1n1.bin"

let needle () =
  let bytes = Bytes.create 8 in
  Proxy.put_u64 bytes 0 early_uart;
  Bytes.to_string bytes

let find_offset path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let length = in_channel_length ic in
      let data = really_input_string ic length in
      let marker = needle () in
      let rec loop index =
        if index > length - 8 then None
        else if String.sub data index 8 = marker then Some index
        else loop (index + 1)
      in
      loop 0)
