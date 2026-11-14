let usage () =
  prerr_endline "usage: nixos-m4pro            run the boot sequence on the loopback";
  prerr_endline "       nixos-m4pro probe [DEV] read-only probe of the live board through m1n1";
  prerr_endline "       nixos-m4pro power-aic [DEV]  power the pms and aic domains (writes; no-op if already on)";
  prerr_endline "       nixos-m4pro disable-wdt [DEV] disable both watchdogs (writes; no-op if already off)";
  prerr_endline "       nixos-m4pro aic-init [DEV]    route aic-ext-intr-cfg IRQs (writes; m1n1 did the same at boot)";
  prerr_endline "       nixos-m4pro power-apcie0 [DEV] power the apcie0 domains, parents first (writes)";
  prerr_endline "       nixos-m4pro pmgr-list ADT     power domains in an Apple device tree dump";
  prerr_endline "       nixos-m4pro pmgr-dtsi ADT     the kernel's pmgr .dtsi for this machine";
  prerr_endline "       nixos-m4pro gpu ADT           the GPU (AGX) and its firmware, decoded";
  prerr_endline "       nixos-m4pro power-chain ADT PATH  the PMGR domains a node's clock-gates need, parents first";
  prerr_endline "       nixos-m4pro gpu-probe [DEV]   live GPU ground truth through m1n1 (build/agx/)";
  prerr_endline "       nixos-m4pro fw DIR ...         GPU firmware read statically (fw DIR help)";
  prerr_endline "       nixos-m4pro agx init TRACE SNAP          decode InitData from a trace snapshot";
  prerr_endline "       nixos-m4pro agx dump TRACE SNAP VA LEN   hexdump GPU memory (* = resolvable pointer)";
  prerr_endline "       nixos-m4pro agx decode TRACE SNAP STRUCT VA  decode a structure (27.2 layouts)";
  prerr_endline "       nixos-m4pro agx ptrs TRACE SNAP VA LEN   resolvable pointers at any 2-byte offset";
  prerr_endline "       nixos-m4pro agx queue TRACE SNAP VA N    a command queue and its first N commands";
  prerr_endline "       nixos-m4pro agx graph TRACE SNAP VA|init DEPTH  pointer graph from an address";
  prerr_endline "                               DEV defaults to $M1N1DEVICE, then the debug USB channel";
  exit 2

let () =
  match Array.to_list Sys.argv with
  | [ _ ] -> Nixos_m4pro.Client.run ()
  | [ _; "probe" ] -> ignore (Nixos_m4pro.Probe.run ())
  | [ _; "probe"; device ] -> ignore (Nixos_m4pro.Probe.run ~device ())
  | [ _; "power-aic" ] -> ignore (Nixos_m4pro.Live.run_power_aic ())
  | [ _; "power-aic"; device ] -> ignore (Nixos_m4pro.Live.run_power_aic ~device ())
  | [ _; "disable-wdt" ] -> ignore (Nixos_m4pro.Live.run_disable_wdt ())
  | [ _; "disable-wdt"; device ] -> ignore (Nixos_m4pro.Live.run_disable_wdt ~device ())
  | [ _; "aic-init" ] -> ignore (Nixos_m4pro.Live.run_aic_init ())
  | [ _; "aic-init"; device ] -> ignore (Nixos_m4pro.Live.run_aic_init ~device ())
  | [ _; "power-apcie0" ] -> ignore (Nixos_m4pro.Live.run_power_apcie0 ())
  | [ _; "power-apcie0"; device ] -> ignore (Nixos_m4pro.Live.run_power_apcie0 ~device ())
  | [ _; "adt-props"; adt; path ] ->
      let root = Nixos_m4pro.Adt.of_file adt in
      let n = Nixos_m4pro.Adt.node_at root path in
      List.iter
        (fun (k, v) ->
          let shown =
            (* A string only if it is printable text up to its first NUL and
               padding after it; anything else (often a number with a zero low
               byte) as hex. *)
            let c = Nixos_m4pro.Adt.cstring v in
            let rest = String.sub v (String.length c) (String.length v - String.length c) in
            if String.length v <= 64 && c <> ""
               && String.for_all (fun c -> c >= ' ' && c <= '~') c
               && String.for_all (fun c -> c = '\000') rest
            then Printf.sprintf "%S" c
            else String.concat " " (List.init (min 16 (String.length v)) (fun i -> Printf.sprintf "%02x" (Char.code v.[i])))
          in
          Printf.printf "%-28s %6d  %s\n" k (String.length v) shown)
        n.props;
      Printf.printf "children: %s\n" (String.concat " " (List.map (fun (c : Nixos_m4pro.Adt.node) -> c.name) n.children))
  | [ _; "gpu"; adt ] ->
      print_string (Nixos_m4pro.Gpu_adt.summary (Nixos_m4pro.Gpu_adt.of_adt (Nixos_m4pro.Adt.of_file adt)))
  | [ _; "gpu-probe" ] -> Nixos_m4pro.Gpu_probe.run ~out_dir:"build/agx" ()
  | [ _; "gpu-probe"; device ] -> Nixos_m4pro.Gpu_probe.run ~device ~out_dir:"build/agx" ()
  | [ _; "agx"; "init"; trace; snap ] ->
      let module A = Nixos_m4pro.Agx in
      let va = Option.get (A.Snapshot.init_va ~trace_dir:trace) in
      let s = A.Snapshot.load (Filename.concat trace snap) in
      Printf.printf "InitData at %016Lx (firmware 27.2)\n" (Int64.of_int va);
      (match A.Schema.decode s ~version:[ 27; 2 ] "InitData" va with
      | Some v ->
          print_endline (A.Schema.to_string v);
          let lv = A.Initdata.levels v in
          Printf.printf "\nUAT levels it declares: %s\n"
            (String.concat " " (List.map (fun (l : A.Snapshot.level) -> Printf.sprintf "%d/%d" l.shift l.entries) lv))
      | None -> print_endline "not in the snapshot")
  | [ _; "agx"; "decode"; trace; snap; name; va ] ->
      let module A = Nixos_m4pro.Agx in
      ignore A.Regionb.queue_channels;
      ignore A.Initdata.levels;
      ignore A.Cmdqueue.show;
      ignore A.Hwdata.region_names;
      ignore A.Regions27.names;
      let s = A.Snapshot.load (Filename.concat trace snap) in
      (match A.Schema.decode s ~version:[ 27; 2 ] name (A.Snapshot.int_of_hex va) with
      | Some v -> print_endline (A.Schema.to_string v)
      | None -> print_endline "not in the snapshot")
  | [ _; "agx"; "ptrs"; trace; snap; va; len ] ->
      let module A = Nixos_m4pro.Agx in
      let s = A.Snapshot.load (Filename.concat trace snap) in
      List.iter
        (fun (o, t) -> Printf.printf "+%#06x -> %s\n" o (A.Explore.hex64 t))
        (A.Explore.pointers s (A.Snapshot.int_of_hex va) (int_of_string len))
  | [ _; "agx"; "queue"; trace; snap; va; n ] ->
      let module A = Nixos_m4pro.Agx in
      let s = A.Snapshot.load (Filename.concat trace snap) in
      print_string (A.Cmdqueue.show s (A.Snapshot.int_of_hex va) (int_of_string n))
  | [ _; "agx"; "dump"; trace; snap; va; len ] ->
      let module A = Nixos_m4pro.Agx in
      let s = A.Snapshot.load (Filename.concat trace snap) in
      A.Explore.hexdump s (A.Snapshot.int_of_hex va) (int_of_string len)
  | [ _; "agx"; "graph"; trace; snap; va; depth ] ->
      let module A = Nixos_m4pro.Agx in
      let s = A.Snapshot.load (Filename.concat trace snap) in
      let va = if va = "init" then Option.get (A.Snapshot.init_va ~trace_dir:trace) else A.Snapshot.int_of_hex va in
      A.Explore.print_graph (A.Explore.graph ~depth:(int_of_string depth) s va)
  | [ _; "power-chain"; adt; path ] ->
      let root = Nixos_m4pro.Adt.of_file adt in
      let n = Nixos_m4pro.Adt.node_at root path in
      let gates = match Nixos_m4pro.Adt.prop n "clock-gates" with
        | Some v -> List.init (String.length v / 4) (fun i -> Nixos_m4pro.Adt.u32_at v (4 * i))
        | None -> failwith "no clock-gates" in
      List.iter (fun (d : Nixos_m4pro.Pmgr_adt.domain) ->
          Printf.printf "%4d %-20s %#x+%#x%s\n" d.id d.name d.base d.offset
            (if d.critical then " always-on" else ""))
        (Nixos_m4pro.Pmgr_adt.power_chain root gates)
  | [ _; "pmgr-dtsi"; adt ] ->
      print_string (Nixos_m4pro.Pmgr_adt.dtsi (Nixos_m4pro.Pmgr_adt.domains (Nixos_m4pro.Adt.of_file adt)))
  | [ _; "pmgr-list"; adt ] ->
      List.iter
        (fun (d : Nixos_m4pro.Pmgr_adt.domain) ->
          Printf.printf "%4d %-20s %#x+%#05x%s parents=[%s]\n" d.id d.name d.base d.offset
            (if d.critical then " always-on" else "")
            (String.concat "," (List.map string_of_int d.parents)))
        (Nixos_m4pro.Pmgr_adt.domains (Nixos_m4pro.Adt.of_file adt))
  | _ :: "fw" :: rest -> Nixos_m4pro.Fw.Cli.run rest
  | _ -> usage ()
