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

let mask_checked transport addr clear set =
  ignore (Proxy.call transport Proxy.p_get_exc_count []);
  let value = Proxy.mask32 transport addr clear set in
  match Proxy.call transport Proxy.p_get_exc_count [] with
  | 0L -> value
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
