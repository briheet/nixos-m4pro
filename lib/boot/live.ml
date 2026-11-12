(* Writes to the live board, one driver step at a time.

   The first step is Pmgr.power_aic: pmgr_set_mode for ps_pms, then ps_aic.
   m1n1 has already powered both, so on this Mac the step is a write of the
   value already there. It runs only when both domains read back active
   before the write, which keeps it a no-op. Every access checks m1n1's
   exception counter, as in [Probe]. *)

module Proxy = Proto.Proxy
module Wire = Proto.Wire
module Serial = Proto.Serial
module Pmgr = Soc.Pmgr
module Wdt = Soc.Wdt
module Aic = Soc.Aic

let mask_checked transport addr clear set =
  ignore (Proxy.call transport Proxy.p_get_exc_count []);
  let value = Proxy.mask32 transport addr clear set in
  match Proxy.call transport Proxy.p_get_exc_count [] with
  | 0L -> value
  | _ -> raise (Probe.Faulted addr)

let write_checked transport addr value =
  ignore (Proxy.call transport Proxy.p_get_exc_count []);
  Proxy.write32 transport addr value;
  match Proxy.call transport Proxy.p_get_exc_count [] with
  | 0L -> ()
  | _ -> raise (Probe.Faulted addr)

let actual value = (Int64.to_int value land Pmgr.ps_actual) lsr 4

let domain_state transport (d : Pmgr.domain) =
  match Probe.read transport (Pmgr.at d.offset) with
  | None -> failwith (Printf.sprintf "pmgr %s at %#Lx faulted" d.name (Pmgr.at d.offset))
  | Some v -> v

type step = {
  domain : string;
  before : int64;
  after : int64;
}

let power_aic transport =
  let domains = [ Pmgr.ps_pms; Pmgr.ps_aic ] in
  let before = List.map (domain_state transport) domains in
  List.iter2
    (fun (d : Pmgr.domain) v ->
      if actual v <> Pmgr.ps_active then
        failwith
          (Printf.sprintf "pmgr %s is in state %#x, not active; refusing to change it" d.name
             (actual v)))
    domains before;
  let pmgr = { Pmgr.read32 = Probe.read_or_raise transport; mask32 = mask_checked transport } in
  Pmgr.power_aic pmgr;
  let after = List.map (domain_state transport) domains in
  let chip = Proxy.call transport Proxy.p_get_chipid [] in
  if chip <> Probe.expected_chip_id then
    failwith (Printf.sprintf "chip id after the write is %#Lx" chip);
  List.map2
    (fun (d : Pmgr.domain) (b, a) -> { domain = d.name; before = b; after = a })
    domains (List.combine before after)

(* Wdt.disable writes 0 to CTL and, for version 2, 0 to the second
   watchdog. m1n1 did both at startup, so this runs only while both still
   read 0. A non-zero CTL means something armed it since, and then this is
   no longer the safe step it is meant to be. *)
let wdt_registers = [ ("CTL", Wdt.reg Wdt.ctl); ("secondary", Wdt.secondary.address) ]

let disable_wdt transport =
  let read_reg (name, addr) =
    match Probe.read transport addr with
    | None -> failwith (Printf.sprintf "wdt %s at %#Lx faulted" name addr)
    | Some v -> v
  in
  let before = List.map read_reg wdt_registers in
  List.iter2
    (fun (name, _) v ->
      if v <> 0L then
        failwith (Printf.sprintf "wdt %s is %#Lx, not 0; refusing to change it" name v))
    wdt_registers before;
  let wdt = { Wdt.read32 = Probe.read_or_raise transport; write32 = write_checked transport } in
  Wdt.disable wdt;
  let after = List.map read_reg wdt_registers in
  let chip = Proxy.call transport Proxy.p_get_chipid [] in
  if chip <> Probe.expected_chip_id then
    failwith (Printf.sprintf "chip id after the write is %#Lx" chip);
  List.map2
    (fun (name, _) (b, a) -> { domain = name; before = b; after = a })
    wdt_registers (List.combine before after)

(* Aic.init is discover, then one P_MASK32 per aic-ext-intr-cfg entry that
   sets the target nibble of that IRQ's config word. m1n1's aic23_init made
   the same writes at startup, so the target is expected to be set already.
   The step reports each word before and after, and fails if anything outside
   the target nibble moved or the target did not land. *)
type cfg_step = {
  irq : int;
  addr : int64;
  target : int;
  cfg_before : int64;
  cfg_after : int64;
}

let target_of v = Int64.to_int v land Aic.irq_cfg_target

let aic_init transport =
  let t =
    {
      Aic.read32 = Probe.read_or_raise transport;
      write32 = write_checked transport;
      mask32 = mask_checked transport;
    }
  in
  let layout = Aic.discover t in
  let entries = Aic.decode_ext Aic.ext_intr_cfg in
  let read_cfg (die, irq, _) = Probe.read_or_raise transport (Aic.config_addr layout die irq) in
  let before = List.map read_cfg entries in
  let _ = Aic.init t in
  let after = List.map read_cfg entries in
  let chip = Proxy.call transport Proxy.p_get_chipid [] in
  if chip <> Probe.expected_chip_id then
    failwith (Printf.sprintf "chip id after the write is %#Lx" chip);
  let keep = Int64.lognot (Int64.of_int Aic.irq_cfg_target) in
  let steps =
    List.map2
      (fun (die, irq, target) (b, a) ->
        let addr = Aic.config_addr layout die irq in
        if target_of a <> target then
          failwith (Printf.sprintf "aic irq %#x target is %d after init, wanted %d" irq (target_of a) target);
        if Int64.logand a keep <> Int64.logand b keep then
          failwith (Printf.sprintf "aic irq %#x: bits outside the target moved, %#Lx -> %#Lx" irq b a);
        { irq; addr; target; cfg_before = b; cfg_after = a })
      entries (List.combine before after)
  in
  (layout, steps)

let with_device ?device f =
  let device = match device with Some d -> d | None -> Wire.device () in
  let serial = Serial.open_device ~console:(Probe.console_printer ()) device in
  Fun.protect
    ~finally:(fun () -> Serial.close serial)
    (fun () ->
      Serial.nop serial;
      Printf.printf "device %s\n" device;
      f (Serial.transport serial))

let run_disable_wdt ?device () =
  with_device ?device (fun transport ->
      let steps = disable_wdt transport in
      List.iter
        (fun s ->
          Printf.printf "wdt %-9s before %#010Lx after %#010Lx%s\n" s.domain s.before s.after
            (if s.after = 0L then "  (disabled)" else "  (ARMED)"))
        steps;
      Printf.printf "m1n1 still answers, chip id %#Lx\n" Probe.expected_chip_id;
      steps)

let run_aic_init ?device () =
  with_device ?device (fun transport ->
      let layout, steps = aic_init transport in
      Printf.printf "aic %d/%d dies, %d/%d IRQs\n" layout.nr_die layout.max_die layout.nr_irq
        layout.max_irq;
      List.iter
        (fun s ->
          Printf.printf "aic irq %#x cfg %#Lx before %#010Lx after %#010Lx target %d%s\n" s.irq s.addr
            s.cfg_before s.cfg_after s.target
            (if s.cfg_before = s.cfg_after then "  (unchanged)" else "  (CHANGED)"))
        steps;
      Printf.printf "m1n1 still answers, chip id %#Lx\n" Probe.expected_chip_id;
      steps)

let run_power_aic ?device () =
  let device = match device with Some d -> d | None -> Wire.device () in
  let serial = Serial.open_device ~console:(Probe.console_printer ()) device in
  Fun.protect
    ~finally:(fun () -> Serial.close serial)
    (fun () ->
      Serial.nop serial;
      let steps = power_aic (Serial.transport serial) in
      Printf.printf "device %s\n" device;
      List.iter
        (fun s ->
          Printf.printf "pmgr PS %-4s before %#010Lx after %#010Lx  (%s)\n" s.domain s.before s.after
            (Probe.pmgr_state s.after))
        steps;
      Printf.printf "m1n1 still answers, chip id %#Lx\n" Probe.expected_chip_id;
      steps)
