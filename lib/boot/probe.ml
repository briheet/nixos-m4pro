(* Read-only probe of the live board through m1n1.

   Nothing here writes to the target. Every register goes through [read],
   which is a proxy read32 bracketed by P_GET_EXC_COUNT. m1n1 runs proxy
   reads under GUARD_MARK (src/proxy.c), so a read that faults returns
   0xacce5515abad1dea and bumps exc_count instead of taking m1n1 down. The
   first P_GET_EXC_COUNT clears the counter and the second says whether this
   read faulted. Drivers get a [Soc] record whose write and mask functions
   raise, so a probe that reached for one would stop before touching the
   board. *)

module Proxy = Proto.Proxy
module Wire = Proto.Wire
module Serial = Proto.Serial
module Uart = Soc.Uart
module Wdt = Soc.Wdt
module Aic = Soc.Aic
module Pmgr = Soc.Pmgr

type reading = {
  block : string;
  name : string;
  addr : int64;
  value : int64 option;
}

exception Faulted of int64

let read transport addr =
  ignore (Proxy.call transport Proxy.p_get_exc_count []);
  let value = Proxy.read32 transport addr in
  match Proxy.call transport Proxy.p_get_exc_count [] with
  | 0L -> Some value
  | _ -> None

let read_or_raise transport addr =
  match read transport addr with Some v -> v | None -> raise (Faulted addr)

let no_write _ _ = failwith "probe is read-only"
let no_mask _ _ _ = failwith "probe is read-only"

let reading transport block name addr = { block; name; addr; value = read transport addr }

let uart_readings transport =
  let reg off = Int64.add Uart.t6040_base (Int64.of_int off) in
  List.map
    (fun (name, off) -> reading transport "uart" name (reg off))
    [
      ("ULCON", Uart.ulcon);
      ("UCON", Uart.ucon);
      ("UFCON", Uart.ufcon);
      ("UTRSTAT", Uart.utrstat);
      ("UFSTAT", Uart.ufstat);
      ("UBRDIV", Uart.ubrdiv);
      ("UFRACVAL", Uart.ufracval);
    ]

let wdt_readings transport =
  [
    reading transport "wdt" "COUNT" (Wdt.reg Wdt.count);
    reading transport "wdt" "ALARM" (Wdt.reg Wdt.alarm);
    reading transport "wdt" "CTL" (Wdt.reg Wdt.ctl);
    reading transport "wdt" "secondary" Wdt.secondary.address;
  ]

let aic_readings transport =
  [
    reading transport "aic" "CAP0" (Aic.at Aic.cap0_offset);
    reading transport "aic" "MAXNUMIRQ" (Aic.at Aic.maxnumirq_offset);
  ]

let pmgr_readings transport =
  List.map
    (fun (d : Pmgr.domain) -> reading transport "pmgr" ("PS " ^ d.name) (Pmgr.at d.offset))
    [ Pmgr.ps_pms; Pmgr.ps_aic ]

type report = {
  device : string;
  chip_id : int64;
  base : int64;
  readings : reading list;
  aic : (Aic.layout, string) result;
}

let probe transport ~device =
  let chip_id = Proxy.call transport Proxy.p_get_chipid [] in
  let base = Proxy.call transport Proxy.p_get_base [] in
  let readings =
    uart_readings transport @ wdt_readings transport @ aic_readings transport
    @ pmgr_readings transport
  in
  (* Aic.discover only reads CAP0 and MAXNUMIRQ. Running it here checks the
     driver's decode against silicon rather than the loopback seed. *)
  let aic =
    let t = { Aic.read32 = read_or_raise transport; write32 = no_write; mask32 = no_mask } in
    match Aic.discover t with
    | layout -> Ok layout
    | exception Faulted addr -> Error (Printf.sprintf "read of %#Lx faulted" addr)
    | exception Failure msg -> Error msg
  in
  { device; chip_id; base; readings; aic }

let expected_chip_id = 0x6040L

let pmgr_state value =
  let v = Int64.to_int value in
  Printf.sprintf "target %#x actual %#x" (v land Pmgr.ps_target) ((v land Pmgr.ps_actual) lsr 4)

let note r =
  match (r.block, r.name, r.value) with
  | _, _, None -> ""
  | "uart", "UBRDIV", Some v ->
      let want = Uart.ubrdiv_of_baud Wire.baud in
      if Int64.to_int (Int64.logand v 0xffffL) = want then
        Printf.sprintf "  (%d baud)" Wire.baud
      else Printf.sprintf "  (115200 would be %d)" want
  | "wdt", "CTL", Some 0L -> "  (disabled)"
  | "wdt", "CTL", Some _ -> "  (ARMED)"
  | "pmgr", _, Some v -> "  (" ^ pmgr_state v ^ ")"
  | _ -> ""

let print_report r =
  Printf.printf "device %s\n" r.device;
  Printf.printf "chip id %#Lx%s\n" r.chip_id
    (if r.chip_id = expected_chip_id then " (T6040)" else " (expected 0x6040)");
  Printf.printf "m1n1 base %#Lx\n" r.base;
  List.iter
    (fun x ->
      match x.value with
      | Some v -> Printf.printf "%-5s %-10s %#Lx = %#010Lx%s\n" x.block x.name x.addr v (note x)
      | None -> Printf.printf "%-5s %-10s %#Lx   faulted\n" x.block x.name x.addr)
    r.readings;
  match r.aic with
  | Ok l ->
      Printf.printf "aic discover: %d/%d dies, %d/%d IRQs\n" l.nr_die l.max_die l.nr_irq l.max_irq
  | Error msg -> Printf.printf "aic discover failed: %s\n" msg

let console_printer () =
  let at_line_start = ref true in
  fun s ->
    String.iter
      (fun c ->
        if !at_line_start then prerr_string "TTY> ";
        prerr_char c;
        at_line_start := c = '\n')
      s;
    flush stderr

let run ?device () =
  let device = match device with Some d -> d | None -> Wire.device () in
  let serial = Serial.open_device ~console:(console_printer ()) device in
  Fun.protect
    ~finally:(fun () -> Serial.close serial)
    (fun () ->
      Serial.nop serial;
      let report = probe (Serial.transport serial) ~device in
      print_report report;
      report)
