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
  | [ _; "pmgr-dtsi"; adt ] ->
      print_string (Nixos_m4pro.Pmgr_adt.dtsi (Nixos_m4pro.Pmgr_adt.domains (Nixos_m4pro.Adt.of_file adt)))
  | [ _; "pmgr-list"; adt ] ->
      List.iter
        (fun (d : Nixos_m4pro.Pmgr_adt.domain) ->
          Printf.printf "%4d %-20s %#x+%#05x%s parents=[%s]\n" d.id d.name d.base d.offset
            (if d.critical then " always-on" else "")
            (String.concat "," (List.map string_of_int d.parents)))
        (Nixos_m4pro.Pmgr_adt.domains (Nixos_m4pro.Adt.of_file adt))
  | _ -> usage ()
