(* Power domains of this Mac, from its own Apple device tree.

   /arm-io/pmgr "devices" is an array of 48-byte records. The layout is
   PMGRDevices in m1n1's proxyclient/m1n1/adt.py:

     0      flags: bit 4 no_ps (no power-state register), bit 3 critical
     3      id1 (u8)
     4..7   parents: two u8 when ids are u8, else two u16
     10     psidx      11  psreg
     16..18 offset (u24, used with ps-groups)
     19     group
     26..27 id2 (u16)
     32..47 name

   Ids are u8 when the first two records' id1 differ. A domain's register is
   ps-regs[psreg] (u32 reg index, u32 offset, ...) at offset + 8 * psidx into
   that pmgr reg range; without ps-regs (as on T6040) it is the reg range of
   ps-groups[group] (12-byte entries) plus the record's u24 offset.

   The kernel's t6041-pmgr.dtsi was written for the M4 Max. This table is
   what the M4 Pro's firmware says, and [dtsi] turns it into the file the
   kernel includes instead. *)

type domain = {
  id : int;
  name : string;
  parents : int list;
  critical : bool;
  base : int;  (** pmgr block, CPU physical *)
  offset : int;  (** of the power-state register in that block *)
}

let path = "/arm-io/pmgr"
let record = 48

let u8 s o = Char.code s.[o]
let u16 s o = u8 s o lor (u8 s (o + 1) lsl 8)
let u24 s o = u16 s o lor (u8 s (o + 2) lsl 16)
let u32 = Adt.u32_at

let domains adt =
  let pmgr = Adt.node_at adt path in
  let devs = Adt.prop_exn pmgr "devices" in
  let n = String.length devs / record in
  if n < 2 then failwith "pmgr: fewer than two devices";
  let rec_ i = String.sub devs (i * record) record in
  let u8id = u8 (rec_ 0) 3 <> u8 (rec_ 1) 3 in
  let ps_regs = Adt.prop pmgr "ps-regs" in
  let ps_groups = Adt.prop pmgr "ps-groups" in
  let location r =
    match ps_regs with
    | Some regs ->
        let e = 16 * u8 r 11 in
        let reg_idx = u32 regs e and off = u32 regs (e + 4) in
        (fst (Adt.reg adt path reg_idx), off + (8 * u8 r 10))
    | None -> (
        match ps_groups with
        | Some groups ->
            (* ps-groups entries are 12 bytes: reg index, offset, mask. On
               this Mac there are four, pointing at reg 0, 2, 54 and 1. *)
            let e = 12 * u8 r 19 in
            (fst (Adt.reg adt path (u32 groups e)), u24 r 16)
        | None -> failwith "pmgr: neither ps-regs nor ps-groups")
  in
  List.init n rec_
  |> List.filter (fun r -> u8 r 0 land 0x10 = 0)
  |> List.map (fun r ->
         let id = if u8id then u8 r 3 else u16 r 26 in
         let parents = if u8id then [ u8 r 4; u8 r 5 ] else [ u16 r 4; u16 r 6 ] in
         let base, offset = location r in
         {
           id;
           name = String.lowercase_ascii (Adt.cstring (String.sub r 32 16));
           parents = List.filter (( <> ) 0) parents;
           critical = u8 r 0 land 0x08 <> 0;
           base;
           offset;
         })

(* The power-state domains behind a device's "clock-gates", parents first,
   as m1n1's pmgr_adt_power_enable() walks them: a gate may be a record
   without a power-state register of its own (flag 0x10), which only stands
   for its parents. Ids are the low 16 bits of each gate; the die (bits
   16+) is 0 on this single-die chip. *)
let power_chain adt gates =
  let pmgr = Adt.node_at adt path in
  let devs = Adt.prop_exn pmgr "devices" in
  let n = String.length devs / record in
  let rec_ i = String.sub devs (i * record) record in
  let u8id = u8 (rec_ 0) 3 <> u8 (rec_ 1) 3 in
  let id_of r = if u8id then u8 r 3 else u16 r 26 in
  let parents_of r =
    List.filter (( <> ) 0) (if u8id then [ u8 r 4; u8 r 5 ] else [ u16 r 4; u16 r 6 ])
  in
  let records = List.init n rec_ in
  let find id =
    match List.find_opt (fun r -> id_of r = id) records with
    | Some r -> r
    | None -> failwith (Printf.sprintf "pmgr: no device with id %#x" id)
  in
  let by_id = Hashtbl.create 256 in
  List.iter (fun (d : domain) -> Hashtbl.replace by_id d.id d) (domains adt);
  let seen = Hashtbl.create 16 and out = ref [] in
  let rec walk id =
    if not (Hashtbl.mem seen id) then begin
      Hashtbl.add seen id ();
      let r = find id in
      List.iter walk (parents_of r);
      match Hashtbl.find_opt by_id id with Some d -> out := d :: !out | None -> ()
    end
  in
  List.iter (fun g -> walk (g land 0xffff)) gates;
  List.rev !out

(* CPU cluster and core domains (ecpu_N, pcpuN_M, ecpm, pcpmN) are handled
   by the hardware and m1n1's cpufreq setup. Asahi's pmgr files leave them
   out, so Linux never gates a CPU; so does [dtsi]. *)
let is_cpu_domain d =
  List.exists
    (fun p -> String.length d.name >= String.length p && String.sub d.name 0 (String.length p) = p)
    [ "ecpu"; "pcpu"; "ecpm"; "pcpm" ]

(* Domains the firmware does not mark critical but that must stay on, found
   by powering each candidate off on the live machine (tools/pd-trial) and
   waiting for a reset. Only ans did it: the machine resets 193 s after it is
   gated, every time. Asahi's t8132-pmgr.dtsi (base M4) marks ans always-on
   for the same reason ("Device reboots after 3-5 minutes if disabled"). The
   other 62 domains Linux turns off at boot stayed off for 240 s. *)
let must_stay_on =
  [
    ("ans", "the machine resets about 3 minutes after this is gated (193 s on J614s)");
    (* Asahi's curated t6041-pmgr.dtsi marks aic always-on; the ADT does not
       flag it critical. *)
    ("aic", "the interrupt controller; always-on in Asahi's t6041 list");
  ]

(* Domains the ADT flags critical that must not be forced on. The pms_fpwm
   domains sit at actual state 0x4 and never report the requested state, so
   the driver's power-on at probe fails ("Failed to reach power state 0xf")
   and is followed by an SError. Asahi's t6041-pmgr.dtsi leaves them as
   ordinary domains too. *)
let not_always_on = [ "pms_fpwm0"; "pms_fpwm1"; "pms_fpwm2"; "pms_fpwm3"; "pms_fpwm4" ]

(* Display domains Asahi's curated t6041-pmgr.dtsi treats specially, which
   the ADT does not flag. The display coprocessors' CPU domains are locked by
   the firmware ("Locked, don't touch"): setting AUTO_ENABLE on disp_cpu, as
   the driver does at probe, raised an SError on J614s. disp_fe keeps a
   minimum state of 4 (clock-gated, never power-gated). *)
let locked = [ "disp_cpu"; "dispext0_cpu"; "dispext1_cpu" ]
let min_state = [ ("disp_fe", 4) ]

(* The GPU's PMGR block (gpx, afr, gfx) is left out until there is a GPU
   driver. Powering afr on at probe raised an SError on J614s, and Asahi's
   trees for t8132, t6031 and t8122 do not describe the GPU PMGR either. *)
let gpu_block = 0x288e80000

(* Labels of the pmgr nodes in t6041.dtsi, which the generated file fills. *)
let block_labels =
  [ (0x288e80000, "pmgr_gfx"); (0x502280000, "pmgr"); (0x502800000, "pmgr1"); (0x508300000, "pmgr_mini") ]

let dtsi ?(compat = "t6040") ds =
  let by_id = Hashtbl.create 256 in
  List.iter (fun d -> Hashtbl.replace by_id d.id d) ds;
  let ds = List.filter (fun d -> not (is_cpu_domain d) && d.base <> gpu_block) ds in
  let b = Buffer.create 65536 in
  let p fmt = Printf.bprintf b fmt in
  p "// SPDX-License-Identifier: GPL-2.0+ OR MIT\n";
  p "/*\n * PMGR power domains for Apple T6040 \"M4 Pro\", generated by\n";
  p " * `nixos-m4pro pmgr-dtsi` from this machine's Apple device tree\n";
  p " * (/arm-io/pmgr devices and ps-regs). Do not edit by hand.\n */\n";
  let blocks = List.sort_uniq compare (List.map (fun d -> d.base) ds) in
  List.iter
    (fun base ->
      let label =
        match List.assoc_opt base block_labels with
        | Some l -> l
        | None -> failwith (Printf.sprintf "pmgr: no DT label for block %#x" base)
      in
      p "\n&%s {\n" label;
      ds
      |> List.filter (fun d -> d.base = base)
      |> List.sort (fun a b -> compare a.offset b.offset)
      |> List.iteri (fun i d ->
             if i > 0 then p "\n";
             p "\tps_%s: power-controller@%x {\n" d.name d.offset;
             p "\t\tcompatible = \"apple,%s-pmgr-pwrstate\", \"apple,t8103-pmgr-pwrstate\";\n" compat;
             p "\t\treg = <%#x 4>;\n" d.offset;
             p "\t\tlabel = \"%s\";\n" d.name;
             p "\t\t#power-domain-cells = <0>;\n";
             (match List.filter_map (Hashtbl.find_opt by_id) d.parents with
             | [] -> ()
             | ps ->
                 p "\t\tpower-domains = %s;\n"
                   (String.concat ", " (List.map (fun q -> "<&ps_" ^ q.name ^ ">") ps)));
             p "\t\t#reset-cells = <0>;\n";
             (match List.assoc_opt d.name min_state with
             | Some st -> p "\t\tapple,min-state = <%d>;\n" st
             | None -> ());
             (match List.assoc_opt d.name must_stay_on with
             | Some why when not d.critical -> p "\t\tapple,always-on; /* %s */\n" why
             | _ -> if d.critical && not (List.mem d.name not_always_on) then p "\t\tapple,always-on;\n");
             if List.mem d.name locked then p "\n\t\tstatus = \"disabled\"; /* Locked, don't touch */\n";
             p "\t};\n");
      p "};\n")
    blocks;
  Buffer.contents b
