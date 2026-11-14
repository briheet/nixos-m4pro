let fail msg =
  prerr_endline msg;
  exit 1

let check name cond = if not cond then fail ("FAIL " ^ name)

let byte_at bytes index = Char.code (Bytes.get bytes index)

let () =
  let open Nixos_m4pro in
  let nop = Proxy.encode_request Proxy.p_nop [] in
  check "nop length" (Bytes.length nop = Proxy.request_bytes);
  check "nop is zeros" (nop = Bytes.make Proxy.request_bytes '\000');

  let addr = Int64.add Uart.t6040_base (Int64.of_int Uart.utrstat) in
  let read = Proxy.encode_request Proxy.p_read32 [ addr ] in
  check "read32 opcode" (byte_at read 0 = 0x05 && byte_at read 1 = 0x01);
  check "read32 address"
    (byte_at read 8 = 0x10 && byte_at read 10 = 0x20 && byte_at read 11 = 0x29 && byte_at read 12 = 0x04);

  let reply = Bytes.make Proxy.reply_bytes '\000' in
  Proxy.put_u64 reply 0 Proxy.p_read32;
  Proxy.put_u64 reply 16 0x42L;
  let transport _request = reply in
  check "call read32" (Proxy.call transport Proxy.p_read32 [ addr ] = 0x42L);

  let bad = Bytes.make Proxy.reply_bytes '\000' in
  Proxy.put_u64 bad 0 Proxy.p_read32;
  Proxy.put_u64 bad 8 Proxy.s_badcmd;
  (try
     ignore (Proxy.call (fun _ -> bad) Proxy.p_read32 [ addr ]);
     fail "bad command was accepted"
   with Failure message -> check "bad command" (String.equal message "m1n1 proxy: bad command"));

  check "115200 divisor" (Uart.ubrdiv_of_baud 115200 = 12);
  check "offsets" (Uart.utxh = 0x20 && Uart.urxh = 0x24 && Uart.ubrdiv = 0x028);
  check "physical base" (Uart.t6040_base = 0x429200000L);

  let written = Buffer.create 8 in
  let ready = ref true in
  let uart =
    Uart.of_proxy
      ~read32:(fun address ->
        if address = Int64.add Uart.t6040_base (Int64.of_int Uart.utrstat) && !ready then 2L else 0L)
      ~write32:(fun address value ->
        if address = Int64.add Uart.t6040_base (Int64.of_int Uart.utxh) then
          Buffer.add_char written (Char.chr (Int64.to_int value)))
  in
  Uart.put_string uart "hi\n";
  check "put_string" (Buffer.contents written = "hi\r\n");

  (* Golden values come from the checksum in proxyclient/m1n1/proxy.py. *)
  let empty = Bytes.create 0 in
  check "checksum empty" (Wire.checksum empty 0 0 = 0x73736542);
  let zero = Bytes.make 1 '\000' in
  check "checksum one zero" (Wire.checksum zero 0 1 = 0x8f9fedcc);
  check "sentinels" (Wire.checksum_sentinel = 0xd0decade && Wire.data_end_sentinel = 0xb0cacc10);

  let nop_cmd = Wire.encode_command Wire.req_nop (Bytes.create 0) in
  check "nop command length" (Bytes.length nop_cmd = Wire.command_len);
  check "nop command bytes" (byte_at nop_cmd 0 = 0xff && byte_at nop_cmd 1 = 0x55 && byte_at nop_cmd 2 = 0xaa);
  check "nop command checksum" (Wire.get_u32 nop_cmd (Wire.command_len - 4) = 0x4b973968);
  let parsed = Wire.parse_command nop_cmd in
  check "nop command parses" (parsed.Wire.checksum_ok && parsed.Wire.cmd = Wire.req_nop);

  let read_cmd = Wire.encode_command Wire.req_proxy read in
  check "read32 frame checksum" (Wire.get_u32 read_cmd (Wire.command_len - 4) = 0x6281318c);

  let csum_reply = Wire.encode_reply Wire.req_proxy Wire.st_csumerr Bytes.empty in
  check "csumerr status bytes"
    (byte_at csum_reply 4 = 0xfc && byte_at csum_reply 5 = 0xff && byte_at csum_reply 6 = 0xff
   && byte_at csum_reply 7 = 0xff);
  let decoded = Wire.decode_reply csum_reply in
  check "csumerr status" (decoded.Wire.status = Wire.st_csumerr && decoded.Wire.cmd = Wire.req_proxy);

  let broken = Bytes.copy csum_reply in
  Bytes.set broken (Wire.reply_len - 1) '\000';
  (try
     ignore (Wire.decode_reply broken);
     fail "bad reply checksum was accepted"
   with Wire.Checksum_error _ -> ());

  let board = Loopback.create () in
  let peer = Loopback.handle board in
  let transport = Wire.proxy_transport peer in
  check "loopback chip" (Proxy.call transport Proxy.p_get_chipid [] = 0x6040L);
  let linked = Uart.of_transport transport in
  Uart.put_string linked "nixos-m4pro\n";
  check "loopback tx" (Loopback.tx board = "nixos-m4pro\r\n");
  ignore (Proxy.call transport Proxy.p_write32 [ Int64.add Uart.t6040_base (Int64.of_int Uart.ubrdiv); 12L ]);
  check "loopback divisor"
    (Proxy.call transport Proxy.p_read32 [ Int64.add Uart.t6040_base (Int64.of_int Uart.ubrdiv) ] = 12L);

  let corrupt = Bytes.copy read_cmd in
  Bytes.set corrupt 10 (Char.chr (byte_at corrupt 10 lxor 0xff));
  let rejected = Wire.decode_reply (peer corrupt) in
  check "loopback rejects checksum" (rejected.Wire.status = Wire.st_csumerr);

  (try
     ignore (Proxy.call transport 0x7fffL []);
     fail "unknown opcode was accepted"
   with Failure message -> check "unknown opcode" (String.equal message "m1n1 proxy: bad command"));

  let unknown = Wire.encode_command 0x06aa55ff (Bytes.create 0) in
  let unknown_reply = Wire.decode_reply (peer unknown) in
  check "unknown command" (unknown_reply.Wire.status = Wire.st_badcmd);

  check "wdt version" (Wdt.version = 2 && Wdt.clears_secondary);
  check "wdt primary" (Wdt.primary.address = 0x50836c000L && Wdt.primary.length = 0x4000);
  check "wdt secondary" (Wdt.secondary.index = 2 && Wdt.secondary.address = 0x508330008L);
  check "wdt ranges" (Array.length Wdt.ranges = 5);
  let wdt = Wdt.of_transport transport in
  let ctl = Wdt.reg Wdt.ctl in
  let untouched = Wdt.ranges.(4).address in
  ignore (Proxy.call transport Proxy.p_write32 [ ctl; 1L ]);
  ignore (Proxy.call transport Proxy.p_write32 [ Wdt.secondary.address; 1L ]);
  ignore (Proxy.call transport Proxy.p_write32 [ untouched; 7L ]);
  Wdt.disable wdt;
  check "wdt disabled" (wdt.read32 ctl = 0L && wdt.read32 Wdt.secondary.address = 0L);
  check "wdt leaves other range" (wdt.read32 untouched = 7L);
  Wdt.reboot wdt;
  check "wdt reboot sequence"
    (wdt.read32 (Wdt.reg Wdt.alarm) = Wdt.reboot_alarm
    && wdt.read32 (Wdt.reg Wdt.count) = 0L
    && wdt.read32 ctl = Wdt.reboot_ctl);

  check "aic base" (Aic.base = 0x502400000L && Aic.size = 0x1cc000L && Aic.version = 3);
  check "aic ext irq"
    (match Aic.decode_ext Aic.ext_intr_cfg with
    | [ (0, 0x1ad, 3) ] -> true
    | _ -> false);
  check "aic computed stride" (Aic.computed_stride 0x400 = 0x1280);
  check "aic field" (Aic.field_get Aic.cap0_nr_irq 0x400 = 0x400 && Aic.field_get Aic.maxnumirq_max_die 0x01000400 = 1);
  let seed addr value =
    ignore (Proxy.call transport Proxy.p_write32 [ Int64.add Aic.base (Int64.of_int addr); Int64.of_int value ])
  in
  seed Aic.cap0_offset 0x400;
  seed Aic.maxnumirq_offset 0x01000400;
  let config = Int64.add Aic.base 0x106b4L in
  seed 0x106b4 0xa0;
  let aic = Aic.of_transport transport in
  let layout = Aic.init aic in
  check "aic counts" (layout.Aic.nr_die = 1 && layout.Aic.nr_irq = 0x400 && layout.Aic.max_die = 1 && layout.Aic.max_irq = 0x400);
  check "aic banks" (layout.Aic.sw_set = Int64.add Aic.base 0x11000L && layout.Aic.reg_size = 0x40004);
  check "aic target" (aic.Aic.read32 config = 0xa3L);
  Aic.set_sw aic layout 0 true;
  check "aic sw set" (aic.Aic.read32 layout.Aic.sw_set = 1L);
  ignore (Proxy.call transport Proxy.p_write32 [ layout.Aic.event; 0x11L ]);
  check "aic ack" (Aic.ack aic = 0x11L);
  seed Aic.cap0_offset 0;
  (try
     ignore (Aic.discover aic);
     let tiny = Aic.discover aic in
     Aic.configure aic tiny;
     fail "aic accepted an irq past nr_irq"
   with Failure message ->
     check "aic irq range" (String.starts_with ~prefix:"aic: external irq" message));

  check "pmgr base" (Pmgr.base = 0x502800000L && Pmgr.compatible = "pmgr1,t6041" && Pmgr.dies = 1);
  check "pmgr domains" (Pmgr.ps_pms.offset = 0x100 && Pmgr.ps_aic.offset = 0x118);
  let pmgr = Pmgr.of_transport transport in
  Pmgr.power_aic pmgr;
  let state addr = pmgr.Pmgr.read32 addr in
  check "pmgr aic powered"
    (state (Pmgr.at Pmgr.ps_pms.offset) = 0xffL && state (Pmgr.at Pmgr.ps_aic.offset) = 0xffL);
  (try
     Pmgr.set_mode pmgr 0x1000L Pmgr.ps_active;
     fail "pmgr poll should time out off the pmgr window"
   with Failure message -> check "pmgr timeout" (String.starts_with ~prefix:"pmgr: timeout" message));

  check "dart count" (Dart.count = 30 && Dart.apcie0.base = 0x410000000L);
  check "dart ttbr" (Dart.encode_ttbr 0x80000000L = 0x80001L);
  let dart = Dart.of_transport transport in
  let status = Dart.init dart Dart.apcie0 ~stream:0 ~table:0x80000000L in
  let at off = Int64.add Dart.apcie0.base (Int64.of_int off) in
  check "dart unlocked" (status.Dart.locked = false);
  check "dart stream" (dart.Dart.read32 (at Dart.enable_streams) = 1L);
  check "dart ttbr reg" (dart.Dart.read32 (at Dart.ttbr) = 0x80001L);
  check "dart tcr" (dart.Dart.read32 (at Dart.tcr) = 1L);
  check "dart tlb" (dart.Dart.read32 (at Dart.tlb_cmd) = Int64.of_int Dart.tlb_flush_sid);
  (try
     ignore (Dart.init dart Dart.apcie0 ~stream:256 ~table:0x80000000L);
     fail "dart accepted stream 256"
   with Failure message -> check "dart stream range" (String.starts_with ~prefix:"dart: stream" message));
  ignore (Proxy.call transport Proxy.p_write32 [ at Dart.protect; 1L ]);
  ignore (Proxy.call transport Proxy.p_write32 [ at Dart.ttbr; 0x11L ]);
  ignore (Proxy.call transport Proxy.p_write32 [ at Dart.tcr; 0L ]);
  let held = Dart.init dart Dart.apcie0 ~stream:0 ~table:0x80000000L in
  check "dart locked keeps ttbr" (held.Dart.locked && dart.Dart.read32 (at Dart.ttbr) = 0x11L);
  check "dart locked skips tcr" (dart.Dart.read32 (at Dart.tcr) = 0L);

  check "pcie map"
    (Pcie.compatible = "apcie,t6040" && Pcie.reg_count = 35 && Pcie.regs_per_port = 7
    && Pcie.ecam = 0x1cb0000000L && Pcie.phy = Int64.add Pcie.phy_window 0x8000L
    && Pcie.phy_common = Int64.add Pcie.phy_window 0x4000L);
  check "pcie gates" (Array.length Pcie.clock_gate_ids = 8 && Pcie.clock_gate_ids.(0) = 0xf0);
  check "pcie speed" (Pcie.link_speed Pcie.ports.(0) = 2 && Pcie.link_speed Pcie.ports.(1) = 2);
  let at_pci base off = Int64.add base (Int64.of_int off) in
  let pcie = Pcie.of_transport transport in
  let port0 = Pcie.ports.(0) in
  let port1 = Pcie.ports.(1) in
  let seed addr value = ignore (Proxy.call transport Proxy.p_write32 [ addr; value ]) in
  seed (at_pci port0.base (Pcie.port_msimap + (4 * 511))) 0xdeadL;
  seed (at_pci port0.base 0x3000) 0xdeadL;
  seed (at_pci Pcie.ports.(2).base 0x104) 0x99L;
  seed (at_pci Pcie.ecam Pcie.lnkcap) 0xffL;
  seed (at_pci Pcie.ecam Pcie.dbi_ro_wr) 1L;
  let pcie_status = Pcie.init pcie in
  check "pcie ports" (pcie_status.brought_up = 2 && pcie_status.skipped = 2);
  check "pcie phy" (pcie.read32 Pcie.phy = 0x20fL && pcie.read32 (at_pci Pcie.phy 8) = 1L);
  check "pcie phy common" (pcie.read32 Pcie.phy_common = 1L);
  check "pcie rc"
    (pcie.read32 (at_pci Pcie.rc 4) = 0L
    && pcie.read32 (at_pci Pcie.rc 0x54) = 0x140L
    && pcie.read32 (at_pci Pcie.rc 0x50) = 1L
    && pcie.read32 (at_pci Pcie.rc 0x58) = 1L);
  check "pcie port0"
    (pcie.read32 (at_pci port0.base 0x104) = 0xfffffff0L
    && pcie.read32 (at_pci port0.base 0x140) = 0x11L
    && pcie.read32 (at_pci port0.base Pcie.port_appclk) = 0x100101L
    && pcie.read32 (at_pci port0.base Pcie.port_reset) = 1L
    && pcie.read32 (at_pci port0.base Pcie.port_status) = 1L
    && pcie.read32 (at_pci port0.base Pcie.port_linksts) = 0L
    && pcie.read32 port0.phy = 0x60fL);
  check "pcie msi cleared"
    (pcie.read32 (at_pci port0.base Pcie.port_msimap) = 0L
    && pcie.read32 (at_pci port0.base (Pcie.port_msimap + (4 * 511))) = 0L
    && pcie.read32 (at_pci port0.base 0x3000) = 0L);
  check "pcie skipped port" (pcie.read32 (at_pci Pcie.ports.(2).base 0x104) = 0x99L);
  let port1_cfg = Int64.add Pcie.ecam 0x8000L in
  check "pcie link"
    (pcie.read32 (at_pci Pcie.ecam Pcie.lnkcap) = 0x12L
    && pcie.read32 (at_pci Pcie.ecam Pcie.dbi_port_link) = Int64.of_int Pcie.lane_mode
    && pcie.read32 (at_pci Pcie.ecam Pcie.dbi_link_width) = 0x20100L
    && pcie.read32 (at_pci Pcie.ecam Pcie.dbi_ro_wr) = 0L
    && pcie.read32 (at_pci port1_cfg Pcie.lnkcap) = 0x12L
    && pcie.read32 port1.phy = 0x60fL);
  (try
     Pcie.poll pcie 0L 1L 1L ~timeout:2 "pcie: Timeout enabling PHY CLK0";
     fail "pcie poll should time out"
   with Failure message ->
     check "pcie timeout" (String.starts_with ~prefix:"pcie: Timeout enabling PHY" message));

  check "sart map"
    (Sart.compatible = "sart,coastguard" && Sart.version = 3 && Sart.base = 0x40dc50000L
    && Sart.entries = 16 && Sart.power_reg_offset = 0x13e8 && Sart.power_canary_offset = 0
    && Sart.window = 0xc000 && Sart.range_count = 3);
  let sart = Sart.of_transport transport in
  let sart_at off = Int64.add Sart.base (Int64.of_int off) in
  seed (sart_at (Sart.config_off 0)) 1L;
  seed (sart_at (Sart.config_off 15)) 0x100L;
  let sart_status = Sart.init sart in
  check "sart protected" (sart_status.Sart.protected = 1);
  let paddr = 0x80000000L in
  let region = 0x1000L in
  let index = Sart.allow sart sart_status ~paddr ~size:region in
  check "sart entry" (index = 1);
  check "sart regs"
    (sart.Sart.read32 (sart_at (Sart.paddr_off 1)) = 0x80000L
    && sart.Sart.read32 (sart_at (Sart.size_off 1)) = 1L
    && sart.Sart.read32 (sart_at (Sart.config_off 1)) = Int64.of_int Sart.flags_allow
    && sart.Sart.read32 (sart_at (Sart.config_off 0)) = 1L
    && sart.Sart.read32 (sart_at (Sart.config_off 15)) = 0x100L);
  Sart.remove sart sart_status ~paddr ~size:region;
  check "sart removed"
    (sart.Sart.read32 (sart_at (Sart.config_off 1)) = 0L
    && sart.Sart.read32 (sart_at (Sart.paddr_off 1)) = 0L
    && sart.Sart.read32 (sart_at (Sart.config_off 0)) = 1L);
  (try
     ignore (Sart.allow sart sart_status ~paddr:0x100L ~size:region);
     fail "sart accepted an unaligned region"
   with Invalid_argument message ->
     check "sart align" (String.starts_with ~prefix:"sart: region is not 4K aligned" message));
  (try
     let pages = Int64.add Sart.size_max 1L in
     ignore (Sart.allow sart sart_status ~paddr ~size:(Int64.shift_left pages Sart.shift));
     fail "sart accepted a huge region"
   with Failure message -> check "sart size" (String.starts_with ~prefix:"sart: region is too large" message));
  (try
     Sart.remove sart sart_status ~paddr ~size:region;
     fail "sart removed a missing region"
   with Failure message ->
     check "sart missing" (String.starts_with ~prefix:"sart: could not find entry" message));
  for i = 0 to Sart.entries - 1 do
    seed (sart_at (Sart.config_off i)) 1L
  done;
  let full = Sart.init sart in
  (try
     ignore (Sart.allow sart full ~paddr ~size:region);
     fail "sart accepted a region with no free entry"
   with Failure message ->
     check "sart full" (String.starts_with ~prefix:"sart: no more free entries" message));
  let dma_board = Loopback.create ~script:false () in
  let dma_sart = Sart.of_transport (Wire.proxy_transport (Loopback.handle dma_board)) in
  let dma_status = Sart.init dma_sart in
  let dma_at off = Int64.add Sart.base (Int64.of_int off) in
  let dma = Ans.allow_dma dma_sart dma_status Ans.demo_queues in
  check "ans dma"
    (List.length dma = 7 && List.hd dma = 0
    && dma_sart.Sart.read32 (dma_at (Sart.paddr_off 0))
       = Int64.shift_right_logical Ans.demo_queues.admin_tcbs Sart.shift
    && dma_sart.Sart.read32 (dma_at (Sart.size_off 0)) = Int64.shift_right_logical Ans.queue_span Sart.shift
    && dma_sart.Sart.read32 (dma_at (Sart.paddr_off 6))
       = Int64.shift_right_logical Ans.read_buffer Sart.shift
    && dma_sart.Sart.read32 (dma_at (Sart.size_off 6)) = 1L
    && dma_sart.Sart.read32 (dma_at (Sart.config_off 6)) = Int64.of_int Sart.flags_allow);

  check "ans map"
    (Ans.compatible = "iop,ascwrap-v6" && Ans.role = "ANS2" && Ans.secure_bar
    && Ans.nvme_base = 0x44dcc0000L && Ans.nvme_index = 9 && Ans.nvme_window = 0x10000
    && Ans.cpu_base = 0x409600000L && Ans.die = 0 && Ans.queue_size = 64 && Ans.aqa_value = 0x3f003f);
  let ans = Ans.of_transport transport in
  let at off = Int64.add Ans.nvme_base (Int64.of_int off) in
  let mbox off = Int64.add Ans.cpu_base (Int64.of_int (Ans.mbox_offset + off)) in
  (try
     Ans.setup ~boot_timeout:2 ans Ans.demo_queues;
     fail "ans setup should wait for boot status"
   with Failure message ->
     check "ans boot" (String.starts_with ~prefix:"nvme: ANS did not boot" message));
  seed (at Ans.csts) 1L;
  seed (at Ans.boot_status) Ans.boot_status_ok;
  Ans.wake ans;
  check "ans cpu"
    (ans.Ans.read32 (Int64.add Ans.cpu_base (Int64.of_int Ans.cpu_control)) = Int64.of_int Ans.cpu_start);
  check "ans wakeup"
    (ans.Ans.read64 (mbox Ans.mbox_a2i_send0) = Ans.wakeup_msg0
    && ans.Ans.read64 (mbox Ans.mbox_a2i_send1) = 0L);
  check "ans message words"
    (Ans.wakeup_msg0 = 0x60000000000220L && Ans.standin_hello = 0x100000000C000BL
    && Ans.standin_epmap_lo = 0x8000000000001FL && Ans.standin_epmap_hi = 0x88000000000100L
    && Ans.iop_power_ack = 0x70000000000020L);
  check "standin hello waiting"
    (ans.Ans.read64 (mbox Ans.mbox_i2a_recv0) = Ans.standin_hello
    && ans.Ans.read32 (mbox Ans.mbox_i2a_control) = 0L);
  let booted = Ans.handshake ans in
  check "rtkit version" (booted.version = Ans.max_version && booted.version = 12);
  check "rtkit endpoints"
    (booted.endpoints.debug && booted.endpoints.crashlog && booted.endpoints.syslog
    && booted.endpoints.ioreport && booted.endpoints.oslog);
  check "rtkit sent"
    (Loopback.sent board
    = [
        (Ans.wakeup_msg0, 0L);
        (0x200000000C000CL, 0L);
        (0x80000000000001L, 0L);
        (0x88000000000000L, 0L);
        (0x50000300000002L, 0L);
        (0x50000100000002L, 0L);
        (0x50000200000002L, 0L);
        (0x50000400000002L, 0L);
        (0x50000800000002L, 0L);
        (0xB0000000000020L, 0L);
      ]);
  check "rtkit inbox drained"
    (ans.Ans.read32 (mbox Ans.mbox_i2a_control) = Int64.of_int Ans.mbox_empty);
  Ans.setup ans Ans.demo_queues;
  let queues = Ans.demo_queues in
  check "ans ctrl"
    (ans.Ans.read32 (at Ans.cc) = 1L
    && ans.Ans.read32 (at Ans.csts) = 1L
    && ans.Ans.read32 (at Ans.aqa) = Int64.of_int Ans.aqa_value
    && ans.Ans.read32 (at Ans.linear_sq) = 1L
    && ans.Ans.read32 (at Ans.nvmmu_num) = 63L
    && ans.Ans.read32 (at Ans.asq) = queues.admin_cmds
    && ans.Ans.read32 (at Ans.nvmmu_asq) = queues.admin_tcbs
    && ans.Ans.read32 (at Ans.ioq_cmds) = 0L
    && ans.Ans.read32 (at Ans.ioq_cqes) = 0L
    && ans.Ans.read32 (Int64.add (at Ans.asq) 4L) = 0L);
  let admin = Ans.create_io_queues ans queues in
  let cmd addr off = ans.Ans.read32 (Int64.add addr (Int64.of_int off)) in
  check "admin queues"
    (admin.Ans.head = 2 && admin.Ans.phase = 1 && Ans.queue_id_word = 0x3f0001
    && ans.Ans.read32 (at Ans.db_acq) = 2L
    && ans.Ans.read32 (at Ans.db_linear_asq) = 0L
    && ans.Ans.read32 (at Ans.ioq_cmds) = queues.io_cmds
    && ans.Ans.read32 (at Ans.ioq_cqes) = queues.io_cqes
    && cmd queues.admin_cmds 0 = Int64.of_int Ans.admin_create_sq
    && cmd queues.admin_cmds 24 = queues.io_cmds
    && cmd queues.admin_cmds 40 = Int64.of_int Ans.queue_id_word
    && cmd queues.admin_cmds 44 = 0x10001L
    && cmd queues.admin_tcbs 0 = 0x200L
    && cmd queues.admin_tcbs 24 = queues.io_cmds
    && ans.Ans.read64 (Int64.add queues.admin_cqes 8L) = 0x1000000000000L
    && ans.Ans.read64 (Int64.add queues.admin_cqes 24L) = 0x1000000000000L);
  seed (mbox Ans.mbox_a2i_control) (Int64.of_int Ans.mbox_full);
  (try
     Ans.wake ~mbox_timeout:2 ans;
     fail "ans wake should time out on a full mailbox"
   with Failure message ->
     check "ans mailbox" (String.starts_with ~prefix:"asc: A2I mailbox full" message));

  let quiet = Loopback.create ~script:false () in
  let quiet_ans = Ans.of_transport (Wire.proxy_transport (Loopback.handle quiet)) in
  let post msg0 msg1 = Loopback.post quiet msg0 msg1 in
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should wait for HELLO"
   with Failure message ->
     check "rtkit hello" (String.starts_with ~prefix:"rtkit(nvme): did not receive HELLO" message));
  post Ans.standin_hello 5L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should reject a non-management HELLO"
   with Failure message ->
     check "rtkit hello ep" (String.starts_with ~prefix:"rtkit(nvme): expected HELLO but got message for EP" message));
  post 0L 0L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should reject a non-HELLO type"
   with Failure message ->
     check "rtkit hello type"
       (String.starts_with ~prefix:"rtkit(nvme): expected HELLO but got message with type" message));
  post (Ans.hello_msg0 ~min_ver:13 ~max_ver:14) 0L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should reject versions that do not overlap"
   with Failure message ->
     check "rtkit version overlap" (String.starts_with ~prefix:"rtkit(nvme): supported versions [11,12]" message));
  post Ans.standin_hello 0L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should wait for the endpoint map"
   with Failure message ->
     check "rtkit epmap"
       (String.starts_with ~prefix:"rtkit(nvme): couldn't receive message while waiting for endpoint map" message));
  post Ans.standin_hello 0L;
  post Ans.standin_epmap_lo 3L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should reject an endpoint map for another endpoint"
   with Failure message ->
     check "rtkit epmap ep"
       (String.starts_with ~prefix:"rtkit(nvme): expected management message while waiting for endpoint map" message));
  post Ans.standin_hello 0L;
  post Ans.standin_hello 0L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should reject a non-map message"
   with Failure message ->
     check "rtkit epmap type"
       (String.starts_with ~prefix:"rtkit(nvme): expected endpoint map message but got" message));
  post Ans.standin_hello 0L;
  post (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 0L;
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should time out without an IOP power ack"
   with Failure message ->
     check "rtkit power" (String.starts_with ~prefix:"rtkit(nvme): timed out waiting for IOP power" message));
  let mark = List.length (Loopback.sent quiet) in
  post (Ans.hello_msg0 ~min_ver:11 ~max_ver:11) 0L;
  post (Int64.logor (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 8L) 0L;
  post Ans.iop_power_ack 0L;
  let negotiated = Ans.handshake quiet_ans in
  check "rtkit negotiates 11"
    (negotiated.version = 11 && negotiated.endpoints.debug && not negotiated.endpoints.crashlog
    && not negotiated.endpoints.syslog && not negotiated.endpoints.ioreport
    && not negotiated.endpoints.oslog);
  let rec drop n xs = if n = 0 then xs else drop (n - 1) (List.tl xs) in
  check "rtkit debug only"
    (drop mark (Loopback.sent quiet)
    = [
        (0x200000000B000BL, 0L);
        (Ans.epmap_reply_msg0 ~base:0 ~done_:true, 0L);
        (0x50000300000002L, 0L);
        (0xB0000000000020L, 0L);
      ]);
  post Ans.standin_hello 0L;
  ignore (Proxy.call (Wire.proxy_transport (Loopback.handle quiet)) Proxy.p_write32
    [ Int64.add Ans.cpu_base (Int64.of_int (Ans.mbox_offset + Ans.mbox_a2i_control)); Int64.of_int Ans.mbox_full ]);
  (try
     ignore (Ans.handshake ~recv_timeout:2 quiet_ans);
     fail "handshake should stop when the mailbox is full"
   with Failure message ->
     check "rtkit send full" (String.starts_with ~prefix:"asc: A2I mailbox full" message));

  let buffer_board () =
    let board = Loopback.create ~script:false () in
    let transport = Wire.proxy_transport (Loopback.handle board) in
    let sart = Sart.of_transport transport in
    let status = Sart.init sart in
    let ans = Ans.of_transport transport in
    (board, sart, status, ans)
  in
  let buf_board, buf_sart, buf_status, buf_ans = buffer_board () in
  Ans.bind_map buf_ans buf_sart buf_status;
  let post_buf msg0 msg1 = Loopback.post buf_board msg0 msg1 in
  post_buf (Ans.hello_msg0 ~min_ver:12 ~max_ver:12) 0L;
  post_buf (Int64.logor (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 4L) 0L;
  post_buf (Ans.buffer_msg0 ~pages:1 ~iova:0L) (Int64.of_int Ans.ep_syslog);
  post_buf Ans.iop_power_ack 0L;
  let buffered = Ans.handshake buf_ans in
  let reply = Ans.buffer_msg0 ~pages:1 ~iova:Ans.buffer_base in
  let buf_at off = Int64.add Sart.base (Int64.of_int off) in
  check "rtkit buffer"
    (buffered.endpoints.syslog && not buffered.endpoints.debug
    && Ans.pages_of reply = 1 && Ans.iova_of reply = Ans.buffer_base
    && (match Ans.buffers buf_ans with
       | Some buffers ->
           buffers.syslog_buf = Some Ans.buffer_base && buffers.next = Int64.add Ans.buffer_base 0x4000L
       | None -> false)
    && buf_sart.Sart.read32 (buf_at (Sart.paddr_off 0)) = Int64.shift_right_logical Ans.buffer_base Sart.shift
    && buf_sart.Sart.read32 (buf_at (Sart.size_off 0)) = 4L
    && List.exists (fun (msg0, msg1) -> msg0 = reply && msg1 = Int64.of_int Ans.ep_syslog) (Loopback.sent buf_board));
  let crash_board, crash_sart, crash_status, crash_ans = buffer_board () in
  Ans.bind_map crash_ans crash_sart crash_status;
  Loopback.post crash_board (Ans.hello_msg0 ~min_ver:12 ~max_ver:12) 0L;
  Loopback.post crash_board (Int64.logor (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 2L) 0L;
  Loopback.post crash_board (Ans.buffer_msg0 ~pages:1 ~iova:0L) (Int64.of_int Ans.ep_crashlog);
  Loopback.post crash_board (Ans.buffer_msg0 ~pages:1 ~iova:0L) (Int64.of_int Ans.ep_crashlog);
  Loopback.post crash_board Ans.iop_power_ack 0L;
  (try
     ignore (Ans.handshake crash_ans);
     fail "a second crashlog buffer should report a crash"
   with Failure message -> check "rtkit crash" (String.starts_with ~prefix:"rtkit(nvme): IOP crashed" message));
  let pre_board, pre_sart, pre_status, pre_ans = buffer_board () in
  Ans.bind_map pre_ans pre_sart pre_status;
  Loopback.post pre_board (Ans.hello_msg0 ~min_ver:12 ~max_ver:12) 0L;
  Loopback.post pre_board (Int64.logor (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 4L) 0L;
  Loopback.post pre_board (Ans.buffer_msg0 ~pages:1 ~iova:0x1000L) (Int64.of_int Ans.ep_syslog);
  Loopback.post pre_board Ans.iop_power_ack 0L;
  (try
     ignore (Ans.handshake pre_ans);
     fail "a preallocated buffer should fail without a DART"
   with Failure message ->
     check "rtkit translate"
       (String.starts_with ~prefix:"rtkit(nvme): failed to translate pre-allocated buffer" message));
  let bare_board = Loopback.create ~script:false () in
  let bare_ans = Ans.of_transport (Wire.proxy_transport (Loopback.handle bare_board)) in
  Loopback.post bare_board (Ans.hello_msg0 ~min_ver:12 ~max_ver:12) 0L;
  Loopback.post bare_board (Int64.logor (Ans.epmap_reply_msg0 ~base:0 ~done_:true) 4L) 0L;
  Loopback.post bare_board (Ans.buffer_msg0 ~pages:1 ~iova:0L) (Int64.of_int Ans.ep_syslog);
  (try
     ignore (Ans.handshake ~recv_timeout:2 bare_ans);
     fail "a buffer request without a SART map should fail"
   with Failure message ->
     check "rtkit alloc" (String.starts_with ~prefix:"rtkit(nvme): unable to allocate buffer" message));

  let bringup ?(complete_cq = true) () =
    let board = Loopback.create ~complete_cq () in
    let transport = Wire.proxy_transport (Loopback.handle board) in
    let ans = Ans.of_transport transport in
    let at off = Int64.add Ans.nvme_base (Int64.of_int off) in
    ignore (Proxy.call transport Proxy.p_write32 [ at Ans.csts; 1L ]);
    ignore (Proxy.call transport Proxy.p_write32 [ at Ans.boot_status; Ans.boot_status_ok ]);
    Ans.setup ans Ans.demo_queues;
    (board, ans, at)
  in
  let cq_board, cq_ans, cq_at = bringup () in
  let staged = { Ans.queues = Ans.demo_queues; head = 0; phase = 1 } in
  Ans.create_cq cq_ans staged;
  check "admin create cq"
    (staged.Ans.head = 1
    && cq_ans.Ans.read32 (Int64.add Ans.demo_queues.admin_cmds 0L) = Int64.of_int Ans.admin_create_cq
    && cq_ans.Ans.read32 (Int64.add Ans.demo_queues.admin_cmds 24L) = Ans.demo_queues.io_cqes
    && cq_ans.Ans.read32 (Int64.add Ans.demo_queues.admin_cmds 44L) = 1L
    && cq_ans.Ans.read32 (cq_at Ans.ioq_cmds) = 0L
    && cq_ans.Ans.read32 (cq_at Ans.ioq_cqes) = 0L);
  ignore cq_board;
  let silent, silent_ans, _silent_at = bringup ~complete_cq:false () in
  (try
     ignore (Ans.create_io_queues ~timeout:2 silent_ans Ans.demo_queues);
     fail "admin command should wait for a completion"
   with Failure message ->
     check "admin timeout" (String.starts_with ~prefix:"nvme: could not find command completion" message));
  check "admin timeout leaves ioq" (silent_ans.Ans.read32 (Int64.add Ans.nvme_base (Int64.of_int Ans.ioq_cmds)) = 0L);
  ignore silent;
  let bad, bad_ans, bad_at = bringup () in
  Loopback.set_cqe_code bad 1;
  (try
     ignore (Ans.create_io_queues bad_ans Ans.demo_queues);
     fail "admin command should reject a failed status"
   with Failure message ->
     check "admin status" (String.starts_with ~prefix:"nvme: command failed with status 1" message));
  check "admin status doorbell" (bad_ans.Ans.read32 (bad_at Ans.db_acq) = 1L);
  check "admin status leaves ioq" (bad_ans.Ans.read32 (bad_at Ans.ioq_cmds) = 0L);
  let mismatched, mismatched_ans, _ = bringup () in
  Loopback.set_cqe_tag mismatched 9;
  (try
     ignore (Ans.create_io_queues ~timeout:2 mismatched_ans Ans.demo_queues);
     fail "admin command should reject a mismatched tag"
   with Failure message ->
     check "admin tag" (String.starts_with ~prefix:"nvme: invalid tag in CQ: expected 0 but got 9" message));

  let read_board, read_ans, read_at = bringup () in
  let read_admin = Ans.create_io_queues read_ans Ans.demo_queues in
  let io = Ans.io_queue Ans.demo_queues in
  let page = Ans.read read_ans io ~nsid:1 ~lba:0L ~buffer:Ans.read_buffer in
  let read_cmd off = read_ans.Ans.read32 (Int64.add Ans.demo_queues.io_cmds (Int64.of_int off)) in
  check "nvme read"
    (String.length page = Ans.read_page && String.sub page 0 8 = "loopback" && page.[8] = '\000'
    && io.Ans.head = 1 && io.Ans.phase = 1 && read_admin.Ans.head = 2
    && read_ans.Ans.read32 (read_at Ans.db_iocq) = 1L
    && read_ans.Ans.read32 (read_at Ans.db_linear_iosq) = 0L
    && read_cmd 0 = Int64.of_int Ans.cmd_read && read_cmd 4 = 1L && read_cmd 24 = Ans.read_buffer
    && read_cmd 40 = 0L && read_cmd 48 = 0L
    && read_ans.Ans.read32 Ans.demo_queues.io_tcbs = 0x100L
    && read_ans.Ans.read64 (Int64.add Ans.demo_queues.io_cqes 8L) = 0x1000000000000L);
  ignore read_board;
  (try
     ignore (Ans.read read_ans io ~nsid:1 ~lba:0L ~buffer:1L);
     fail "nvme read should reject an unaligned buffer"
   with Failure message ->
     check "nvme align" (String.starts_with ~prefix:"nvme: read buffer is not 4K aligned" message));
  let quiet_board, quiet_read, _ = bringup () in
  ignore (Ans.create_io_queues quiet_read Ans.demo_queues);
  Loopback.set_complete_cq quiet_board false;
  (try
     ignore (Ans.read ~timeout:2 quiet_read (Ans.io_queue Ans.demo_queues) ~nsid:1 ~lba:0L ~buffer:Ans.read_buffer);
     fail "nvme read should wait for an I/O completion"
   with Failure message ->
     check "nvme read timeout" (String.starts_with ~prefix:"nvme: could not find command completion" message));
  check "nvme read timeout leaves the page" (quiet_read.Ans.read64 Ans.read_buffer = 0L);
  let marked_board, marked_ans, _ = bringup () in
  ignore (Ans.create_io_queues marked_ans Ans.demo_queues);
  Loopback.set_block marked_board (String.make Ans.read_page 'A');
  let marked = Ans.read marked_ans (Ans.io_queue Ans.demo_queues) ~nsid:1 ~lba:0x100000000L ~buffer:Ans.read_buffer in
  check "nvme read block"
    (marked.[0] = 'A' && marked.[4095] = 'A'
    && marked_ans.Ans.read32 (Int64.add Ans.demo_queues.io_cmds 40L) = 0L
    && marked_ans.Ans.read32 (Int64.add Ans.demo_queues.io_cmds 44L) = 1L);

  let packed = Payload.pack () in
  let handoff = Payload.scan packed in
  check "payload handoff"
    (Payload.ready handoff && handoff.kernel_image_size = 64 && handoff.has_memory
    && handoff.compatible = [ "apple,j614s"; "apple,t6040"; "apple,arm-platform" ]
    && handoff.initrd_bytes = String.length Payload.initrd_payload
    && (not handoff.tso)
    && handoff.chosen = [ ("nixos-m4pro", "handoff") ]
    && Payload.kernel_image.[0x38] = 'A'
    && Char.code (Payload.device_tree ()).[0] = 0xd0
    && Char.code (Payload.device_tree ()).[1] = 0x0d
    && Char.code (Payload.device_tree ()).[2] = 0xfe
    && Char.code (Payload.device_tree ()).[3] = 0xed);
  let raw = Payload.kernel_image ^ Payload.device_tree () in
  let stopped = Payload.scan raw in
  check "payload raw kernel stops"
    (stopped.has_kernel && stopped.compatible = [] && not (Payload.ready stopped));
  let other = Payload.scan (Payload.device_tree ~compatible:[ "apple,t6040" ] ()) in
  check "payload compatible" ((not (Payload.ready other)) && other.compatible = [ "apple,t6040" ] && other.has_memory);
  (try
     ignore (Payload.scan "070701");
     fail "an uncompressed cpio should be rejected"
   with Failure message ->
     check "payload cpio" (String.starts_with ~prefix:"Uncompressed cpio archives not supported" message));
  let plain, consumed = Payload.gunzip_stored (Payload.gzip_store Payload.kernel_image) 0 in
  check "payload gzip" (plain = Payload.kernel_image && consumed = String.length (Payload.gzip_store Payload.kernel_image));

  let image = Filename.temp_file "m1n1" ".bin" in
  Fun.protect ~finally:(fun () -> Sys.remove image) (fun () ->
      let oc = open_out_bin image in
      output_string oc "not-the-constant";
      output_string oc (M1n1_image.needle ());
      close_out oc;
      check "image offset" (M1n1_image.find_offset image = Some 16));

  (* Serial reader on a socketpair. The far end has already queued what a
     live m1n1 line can carry ahead of a reply: console text, a lone ff, an
     ff 55 that is not a header, an event, and a stale boot reply. *)
  let near, far = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let console = Buffer.create 32 in
  let serial = Serial.of_fd ~timeout:1.0 ~console:(Buffer.add_string console) near in
  let send s = ignore (Unix.write_substring far s 0 (String.length s)) in
  let reply_data = Bytes.make Wire.reply_data_len '\000' in
  Proxy.put_u64 reply_data 0 Proxy.p_get_chipid;
  Proxy.put_u64 reply_data 16 0x6040L;
  let event =
    let b = Bytes.make (8 + 3 + 4) '\000' in
    Wire.put_u32 b 0 Wire.req_event;
    Bytes.set b 4 '\003';
    Bytes.blit_string "evt" 0 b 8 3;
    Bytes.to_string b
  in
  send "hello\n\xffx\xff\x55y";
  send event;
  send (Bytes.to_string (Wire.encode_reply Wire.req_boot Wire.st_ok Bytes.empty));
  send (Bytes.to_string (Wire.encode_reply Wire.req_proxy Wire.st_ok reply_data));
  let chip = Proxy.call (Serial.transport serial) Proxy.p_get_chipid [] in
  check "serial chip id" (chip = 0x6040L);
  check "serial console" (Buffer.contents console = "hello\n\xffx\xff\x55y");
  let sent = Bytes.create Wire.command_len in
  ignore (Unix.read far sent 0 Wire.command_len);
  let command = Wire.parse_command sent in
  check "serial request framing"
    (command.cmd = Wire.req_proxy && command.checksum_ok
    && Proxy.get_u64 command.payload 0 = Proxy.p_get_chipid);
  (try
     ignore (Proxy.call (Serial.transport serial) Proxy.p_get_chipid []);
     fail "serial read without a reply should time out"
   with Serial.Timeout _ -> ());
  (* A line that never goes quiet but never carries a reply still times out. *)
  let chatter = Thread.create (fun () ->
      let stop = Unix.gettimeofday () +. 3.0 in
      try
        while Unix.gettimeofday () < stop do
          ignore (Unix.write_substring far "TTY spam\n" 0 9);
          Thread.delay 0.05
        done
      with Unix.Unix_error _ -> ()) ()
  in
  let started = Unix.gettimeofday () in
  (try
     ignore (Proxy.call (Serial.transport serial) Proxy.p_get_chipid []);
     fail "serial read with only console text should time out"
   with Serial.Timeout _ -> ());
  check "serial overall deadline" (Unix.gettimeofday () -. started < 2.0);
  Thread.join chatter;
  Unix.close far;
  Serial.close serial;

  (* Probe on the loopback. It must read, and nothing it does may write. *)
  let board = Loopback.create () in
  let transport = Wire.proxy_transport (Loopback.handle board) in
  Proxy.write32 transport (Int64.add Aic.base (Int64.of_int Aic.cap0_offset)) Loopback.aic_cap0;
  Proxy.write32 transport (Int64.add Aic.base (Int64.of_int Aic.maxnumirq_offset)) Loopback.aic_maxnumirq;
  let writes = ref 0 in
  let counting request =
    let opcode = Proxy.get_u64 request 0 in
    if opcode = Proxy.p_write32 || opcode = Proxy.p_write64 || opcode = Proxy.p_mask32 then incr writes;
    transport request
  in
  let report = Probe.probe counting ~device:"loopback" in
  check "probe chip id" (report.chip_id = 0x6040L);
  check "probe base" (report.base = Loopback.m1n1_base);
  check "probe no writes" (!writes = 0);
  check "probe all read" (List.for_all (fun (r : Probe.reading) -> r.value <> None) report.readings);
  (match report.aic with
  | Ok l -> check "probe aic" (l.nr_die = 1 && l.max_die = 2 && l.nr_irq = 2720 && l.max_irq = 4096)
  | Error msg -> fail ("probe aic: " ^ msg));

  (* Live.power_aic refuses a domain that is not already active, and on an
     active one it leaves the state as it was. *)
  let board = Loopback.create () in
  let transport = Wire.proxy_transport (Loopback.handle board) in
  (try
     ignore (Live.power_aic transport);
     fail "power_aic changed a domain that was not active"
   with Failure message -> check "live refuses" (String.ends_with ~suffix:"refusing to change it" message));
  List.iter
    (fun (d : Pmgr.domain) -> Proxy.write32 transport (Pmgr.at d.offset) 0x000000ffL)
    [ Pmgr.ps_pms; Pmgr.ps_aic ];
  let steps = Live.power_aic transport in
  check "live no-op" (List.for_all (fun (s : Live.step) -> s.before = s.after && s.after = 0xffL) steps);

  (* Live.disable_wdt refuses an armed watchdog and is a no-op on a
     disabled one. *)
  Proxy.write32 transport (Wdt.reg Wdt.ctl) Wdt.reboot_ctl;
  (try
     ignore (Live.disable_wdt transport);
     fail "disable_wdt changed an armed watchdog"
   with Failure message -> check "wdt refuses" (String.ends_with ~suffix:"refusing to change it" message));
  check "wdt left armed" (Proxy.read32 transport (Wdt.reg Wdt.ctl) = Wdt.reboot_ctl);
  Proxy.write32 transport (Wdt.reg Wdt.ctl) 0L;
  let steps = Live.disable_wdt transport in
  check "wdt no-op" (List.for_all (fun (s : Live.step) -> s.before = 0L && s.after = 0L) steps);

  (* Live.aic_init sets the target nibble and keeps the rest of the word. *)
  Proxy.write32 transport (Int64.add Aic.base (Int64.of_int Aic.cap0_offset)) Loopback.aic_cap0;
  Proxy.write32 transport (Int64.add Aic.base (Int64.of_int Aic.maxnumirq_offset)) Loopback.aic_maxnumirq;
  let cfg = Int64.add Aic.base (Int64.of_int (Aic.extint_base + (4 * 0x1ad))) in
  Proxy.write32 transport cfg 0xa0L;
  let _, cfg_steps = Live.aic_init transport in
  check "aic init changes target"
    (match cfg_steps with
    | [ s ] -> s.irq = 0x1ad && s.addr = 0x5024106b4L && s.cfg_before = 0xa0L && s.cfg_after = 0xa3L
    | _ -> false);
  (* Pmgr.apcie0_power is parents first, and Live.power_apcie0 powers only
     what is off. *)
  let position id =
    let rec go i = function
      | [] -> fail (Printf.sprintf "pmgr id %d missing" id)
      | (ps : Pmgr.ps) :: rest -> if ps.id = id then i else go (i + 1) rest
    in
    go 0 Pmgr.apcie0_power
  in
  check "apcie0 parents first"
    (List.for_all
       (fun (ps : Pmgr.ps) -> List.for_all (fun par -> position par < position ps.id) ps.parents)
       Pmgr.apcie0_power);
  check "apcie0 gates listed" (List.for_all (fun id -> position id >= 0) Pmgr.apcie0_clock_gates);
  Proxy.write32 transport 0x502280100L 0xffL;
  let masked = ref [] in
  let tracking request =
    if Proxy.get_u64 request 0 = Proxy.p_mask32 then masked := Proxy.get_u64 request 8 :: !masked;
    transport request
  in
  let ps_steps = Live.power_apcie0 tracking in
  check "apcie0 all active"
    (List.for_all (fun (s : Live.ps_step) -> Live.actual s.ps_after = Pmgr.ps_active) ps_steps);
  check "apcie0 skips active" (not (List.mem 0x502280100L !masked));
  check "apcie0 write order"
    (List.rev !masked
    = List.filter_map
        (fun (ps : Pmgr.ps) -> if ps.addr = 0x502280100L then None else Some ps.addr)
        Pmgr.apcie0_power);
  let _, again = Live.aic_init transport in
  check "aic init repeat is a no-op"
    (List.for_all (fun (s : Live.cfg_step) -> s.cfg_before = 0xa3L && s.cfg_after = 0xa3L) again);
  (* AGX schemas: InitData is 0xbc bytes on 13.x firmware (m1n1's
     initdata.py) and 0xc8 on 27.2 (traced 2026-11-14). *)
  let module S = Nixos_m4pro.Agx.Schema in
  ignore Nixos_m4pro.Agx.Initdata.levels;
  check "InitData 13.5 size" (S.size [ 13; 5 ] (S.Struct "InitData") = 0xbc);
  check "InitData 27.2 size" (S.size [ 27; 2 ] (S.Struct "InitData") = 0xc8);
  check "UatLevelInfo size" (S.size [ 27; 2 ] (S.Struct "UatLevelInfo") = 0x20);
  check "uat_page_size offset 27.2"
    (List.exists (fun (o, (fl : S.field)) -> fl.name = "uat_page_size" && o = 0x30) (S.layout [ 27; 2 ] "InitData"));
  ignore Nixos_m4pro.Agx.Regionb.queue_channels;
  ignore Nixos_m4pro.Agx.Cmdqueue.show;
  check "ChannelInfoSet 13.x" (S.size [ 13; 5 ] (S.Struct "ChannelInfoSet") = 0x110);
  check "ChannelState 13.x" (S.size [ 13; 5 ] (S.Struct "ChannelState") = 0x30);
  check "ChannelState 27.2" (S.size [ 27; 2 ] (S.Struct "ChannelState") = 0x30);
  check "RegionB 27.2 queues end at 0x1c0" (S.size [ 27; 2 ] (S.Struct "RegionB") = 0x1c0);
  check "RunCmdQueueMsg 27.2" (S.size [ 27; 2 ] (S.Struct "RunCmdQueueMsg27") = 0x18);
  check "CommandQueueInfo 27.2" (S.size [ 27; 2 ] (S.Struct "CommandQueueInfo27") = 0x80);
  check "JobList" (S.size [ 27; 2 ] (S.Struct "JobList") = 0x18);
  check "version gates" (S.present [ 27; 2 ] (S.Since "27") && not (S.present [ 13; 5 ] (S.Since "27")));
  print_endline "ok"
