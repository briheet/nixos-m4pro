let usage () =
  prerr_endline "usage: nixos-m4pro            run the boot sequence on the loopback";
  prerr_endline "       nixos-m4pro probe [DEV] read-only probe of the live board through m1n1";
  prerr_endline "       nixos-m4pro power-aic [DEV]  power the pms and aic domains (writes; no-op if already on)";
  prerr_endline "       nixos-m4pro disable-wdt [DEV] disable both watchdogs (writes; no-op if already off)";
  prerr_endline "       nixos-m4pro aic-init [DEV]    route aic-ext-intr-cfg IRQs (writes; m1n1 did the same at boot)";
  prerr_endline "       nixos-m4pro power-apcie0 [DEV] power the apcie0 domains, parents first (writes)";
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
  | _ -> usage ()
