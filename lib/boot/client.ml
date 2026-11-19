(* Boot sequence for this board. The executable calls [run] and nothing else.
   Under macOS the peer is the in-process loopback. A live UART needs this
   Mac booted into m1n1 and the client on a second machine. *)

module Proxy = Proto.Proxy
module Wire = Proto.Wire
module Uart = Soc.Uart
module Wdt = Soc.Wdt
module Aic = Soc.Aic
module Pmgr = Soc.Pmgr
module Dart = Soc.Dart
module Pcie = Soc.Pcie
module Sart = Soc.Sart
module Ans = Nvme.Ans

let machine = "Mac16,8 / J614s / T6040"

let report_image () =
  let path = M1n1_image.default_path in
  if not (Sys.file_exists path) then Printf.printf "m1n1 image is not built yet (%s)\n" path
  else
    match M1n1_image.find_offset path with
    | None -> Printf.printf "m1n1 image %s has no T6040 early UART constant\n" path
    | Some offset ->
        Printf.printf "m1n1 image %s contains early UART %#Lx at offset %#x\n" path
          M1n1_image.early_uart offset

let run () =
  Printf.printf "nixos-m4pro host client for %s\n" machine;
  Printf.printf "UART %s %s\n" Uart.node Uart.compatible;
  Printf.printf "physical base %#Lx, size %#Lx, clock %d\n" Uart.t6040_base Uart.size Uart.clock;
  Printf.printf "115200 baud divisor %d\n" (Uart.ubrdiv_of_baud 115200);
  let board = Loopback.create () in
  let transport = Wire.proxy_transport (Loopback.handle board) in
  let chip = Proxy.call transport Proxy.p_get_chipid [] in
  Printf.printf "loopback chip id %#Lx\n" chip;
  let uart = Uart.of_transport transport in
  Uart.put_string uart "nixos-m4pro\n";
  Printf.printf "UART TX %S\n" (Loopback.tx board);
  Printf.printf "WDT %s %s version %d\n" Wdt.node Wdt.compatible Wdt.version;
  Printf.printf "primary %#Lx, control %#Lx, secondary %#Lx\n" Wdt.primary.address (Wdt.reg Wdt.ctl)
    Wdt.secondary.address;
  let wdt = Wdt.of_transport transport in
  Wdt.disable wdt;
  Printf.printf "watchdog controls %#Lx %#Lx\n"
    (wdt.read32 (Wdt.reg Wdt.ctl))
    (wdt.read32 Wdt.secondary.address);
  (* Capability registers are silicon state. The loopback has no AIC, so
     the client plants the values `nixos-m4pro probe` read from this Mac. *)
  ignore
    (Proxy.call transport Proxy.p_write32
       [ Int64.add Aic.base (Int64.of_int Aic.cap0_offset); Loopback.aic_cap0 ]);
  ignore
    (Proxy.call transport Proxy.p_write32
       [ Int64.add Aic.base (Int64.of_int Aic.maxnumirq_offset); Loopback.aic_maxnumirq ]);
  let aic = Aic.of_transport transport in
  let layout = Aic.init aic in
  let _die, irq, target = List.hd (Aic.decode_ext Aic.ext_intr_cfg) in
  Printf.printf "AIC %s %s base %#Lx, %d/%d dies, %d/%d IRQs\n" Aic.node Aic.compatible Aic.base
    layout.nr_die layout.max_die layout.nr_irq layout.max_irq;
  Printf.printf "external irq %#x target %d at %#Lx\n" irq target (Aic.config_addr layout 0 irq);
  let pmgr = Pmgr.of_transport transport in
  Pmgr.power_aic pmgr;
  Printf.printf "PMGR %s %s base %#Lx\n" Pmgr.node Pmgr.compatible Pmgr.base;
  Printf.printf "powered %s %#Lx and %s %#Lx\n" Pmgr.ps_pms.name (Pmgr.at Pmgr.ps_pms.offset)
    Pmgr.ps_aic.name
    (Pmgr.at Pmgr.ps_aic.offset);
  let dart = Dart.of_transport transport in
  let table = 0x80000000L in
  let status = Dart.init dart Dart.apcie0 ~stream:0 ~table in
  Printf.printf "DART %s, %d instances\n" Dart.compatible Dart.count;
  Printf.printf "%s base %#Lx stream 0 table %#Lx locked %b\n" Dart.apcie0.name Dart.apcie0.base
    table status.locked;
  let pcie = Pcie.of_transport transport in
  let pcie_status = Pcie.init pcie in
  Printf.printf "PCIe %s %s\n" Pcie.node Pcie.compatible;
  Printf.printf "ECAM %#Lx, RC %#Lx, PHY %#Lx\n" Pcie.ecam Pcie.rc Pcie.phy;
  Printf.printf "brought up %d, skipped %d\n" pcie_status.brought_up pcie_status.skipped;
  let sart = Sart.of_transport transport in
  let sart_status = Sart.init sart in
  let queues = Ans.demo_queues in
  let dma = Ans.allow_dma sart sart_status queues in
  Printf.printf "SART %s %s version %d base %#Lx\n" Sart.node Sart.compatible Sart.version Sart.base;
  Printf.printf "allowed %d DMA pages from %#Lx, protected %#x\n" (List.length dma) queues.admin_tcbs
    sart_status.protected;
  let ans = Ans.of_transport transport in
  Ans.bind_map ans sart sart_status;
  Ans.wake ans;
  let booted = Ans.handshake ans in
  (* BOOT_STATUS is firmware state. The handshake does not produce it.
     This seed is the value m1n1 waits for after RTKit returns.
     A live proxy reads it from the controller. *)
  ignore
    (Proxy.call transport Proxy.p_write32
       [ Int64.add Ans.nvme_base (Int64.of_int Ans.boot_status); Ans.boot_status_ok ]);
  Ans.setup ans queues;
  let admin = Ans.create_io_queues ans queues in
  let io = Ans.io_queue queues in
  let block = Ans.read ans io ~nsid:1 ~lba:0L ~buffer:Ans.read_buffer in
  Printf.printf "ANS %s %s role %s\n" Ans.node Ans.compatible Ans.role;
  Printf.printf "NVMe bar %#Lx reg %d, ASC %#Lx\n" Ans.nvme_base Ans.nvme_index Ans.cpu_base;
  Printf.printf "RTKit version %d\n" booted.version;
  Printf.printf "endpoints debug %b crashlog %b syslog %b ioreport %b oslog %b\n"
    booted.endpoints.debug booted.endpoints.crashlog booted.endpoints.syslog
    booted.endpoints.ioreport booted.endpoints.oslog;
  Printf.printf "boot status %#Lx, CC %#Lx, admin TCBs %#Lx\n" Ans.boot_status_ok
    (ans.read32 (Int64.add Ans.nvme_base (Int64.of_int Ans.cc)))
    queues.admin_tcbs;
  Printf.printf "admin CQ id 1 SQ id 1 head %d, IOQ cmds %#Lx cqes %#Lx\n" admin.head queues.io_cmds
    queues.io_cqes;
  Printf.printf "NVMe read nsid 1 lba 0, %d bytes at %#Lx marker %S\n" (String.length block)
    Ans.read_buffer (String.sub block 0 8);
  Printf.printf "RTKit buffers from %#Lx\n" Ans.buffer_base;
  let handoff = Payload.scan (Payload.pack ()) in
  Printf.printf "payload kernel image %d bytes, fdt %s, memory %b, initrd %d bytes\n"
    handoff.kernel_image_size Payload.expect_compatible handoff.has_memory handoff.initrd_bytes;
  Printf.printf "kboot entry is that kernel and x0 is the fdt\n";
  report_image ();
  Printf.printf "Live proxy is %s at %d baud, from a second machine.\n" (Wire.device ()) Wire.baud
