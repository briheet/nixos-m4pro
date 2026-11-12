(* PCIe root complex for this Mac.
   The live node is /arm-io/apcie0, compatible apcie,t6040. m1n1's
   pcie_init_controller selects regs_t8132 for that compatible: type
   APCIE_T8132, compat APCIE_T8122, no fuse table. The T8122 path adds
   0x8000 to the PHY base and 0x4000 to the PHY common base, both taken
   from register index 2.
   The steps below are the MMIO that path performs. Hashed tunables
   (axi2af, PHY, PHY IP, DesignWare RC) are not in the dump, so they
   are not applied. clock-gates are device ids, and the pmgr devices
   blob is hashed, so the power-on is not repeated here either.
   Ports 2 and 3 have ranges and no pci-bridge node. m1n1 skips a
   missing bridge and still advances the ECAM window by 32 KiB. *)

module Proxy = Proto.Proxy

let node = "/arm-io/apcie0"
let compatible = "apcie,t6040"
let port_count = 4
let shared_regs = 7
let reg_count = 35
let regs_per_port = (reg_count - shared_regs) / port_count

let ecam = 0x1cb0000000L
let rc = 0x414000000L
let phy_window = 0x417000000L
let phy = 0x417008000L
let phy_common = 0x417004000L
let phy_ip = 0x417040000L
let axi = 0x416000000L
let fuse = 0x415046200L

let ecam_port_stride = 0x8000

let phy_ctrl = 0
let clk0_req = 1
let clk1_req = 2
let clk0_ack = 4
let clk1_ack = 8
let phy_reset = 0x10
let phycmn_clk = 0
let phycmn_mode = 3
let phycmn_mode_on = 1

let port_appclk = 0x800
let port_appclk_en = 1
let port_status = 0x804
let port_status_run = 1
let port_linksts = 0x208
let port_linksts_busy = 4
let port_reset = 0x82c
let port_reset_dis = 1
let port_msimap = 0x3800

let dbi_ro_wr = 0x8bc
let dbi_port_link = 0x710
let dbi_link_width = 0x80c
let lnkcap = 0x7c
let lnkcap2 = 0x9c
let lnkctl2 = 0xa0

let lane_mode = 0x10000
let lane_mode_mask = 0x3f0000
let link_width = 0x100
let link_width_mask = 0x1f00
let lnkcap_mlw = 0x10
let lnkcap_mlw_mask = 0x3f0
let speed_change = 0x20000
let sls_mask = 0xf
let lnkcap2_sls_mask = 0x7e

let clk_timeout = 50000
let long_timeout = 250000

(* Decoded from clock-gates. pmgr_adt_power_enable looks these ids up in
   the devices blob, which the dump only has as a hash. *)
let clock_gate_ids = [| 0xf0; 0xa2; 0xf4; 0xa3; 0xf2; 0xa4; 0xf3; 0xf5 |]

type port = {
  index : int;
  present : bool;
  base : int64;
  phy : int64;
  maximum_link_speed : int;
  expected_link_speed : int option;
}

let ports =
  [|
    {
      index = 0;
      present = true;
      base = 0x410028000L;
      phy = 0x417020000L;
      maximum_link_speed = 2;
      expected_link_speed = None;
    };
    {
      index = 1;
      present = true;
      base = 0x411028000L;
      phy = 0x417024000L;
      maximum_link_speed = 1;
      expected_link_speed = Some 2;
    };
    {
      index = 2;
      present = false;
      base = 0x412028000L;
      phy = 0x417028000L;
      maximum_link_speed = 0;
      expected_link_speed = None;
    };
    {
      index = 3;
      present = false;
      base = 0x413028000L;
      phy = 0x41702c000L;
      maximum_link_speed = 0;
      expected_link_speed = None;
    };
  |]

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
  mask32 : int64 -> int64 -> int64 -> unit;
}

let of_transport transport =
  {
    read32 = Proxy.read32 transport;
    write32 = Proxy.write32 transport;
    mask32 = (fun addr clear set -> ignore (Proxy.mask32 transport addr clear set));
  }

let reg base offset = Int64.add base (Int64.of_int offset)

let poll t addr mask target ~timeout message =
  let rec loop left =
    if left = 0 then failwith message
    else if Int64.logand (t.read32 addr) mask = target then ()
    else loop (left - 1)
  in
  loop timeout

(* maximum-link-speed 1 is replaced by the first child's expected speed.
   The SD reader publishes expected-link-speed 2. The Wi-Fi bridge is
   already 2, so its child is not consulted. *)
let link_speed port =
  let speed =
    match port.expected_link_speed with
    | Some override when port.maximum_link_speed = 1 && override > 0 -> override
    | _ -> port.maximum_link_speed
  in
  if speed <= 0 then failwith "pcie: Invalid max-speed";
  speed

let enable_clocks t base =
  let ctrl = reg base phy_ctrl in
  t.mask32 ctrl 0L (Int64.of_int clk0_req);
  poll t ctrl (Int64.of_int clk0_ack) (Int64.of_int clk0_ack) ~timeout:clk_timeout
    "pcie: Timeout enabling PHY CLK0";
  t.mask32 ctrl 0L (Int64.of_int clk1_req);
  poll t ctrl (Int64.of_int clk1_ack) (Int64.of_int clk1_ack) ~timeout:clk_timeout
    "pcie: Timeout enabling PHY CLK1"

let write_port t port =
  let w off value = t.write32 (reg port.base off) value in
  w 0x88 0x110L;
  w 0x100 0xffffffffL;
  w 0x148 0xffffffffL;
  w 0x210 0xffffffffL;
  w 0x80 0L;
  w 0x84 0L;
  w 0x104 0xfffffff0L;
  w 0x124 0x100L;
  w 0x16c 0L;
  w 0x13c 0x10L;
  w 0x800 0x100100L;
  w 0x808 0x1000ffL;
  w 0x82c 0L;
  for i = 0 to 15 do
    w (0x3000 + (4 * i)) 0L
  done;
  for i = 0 to 511 do
    w (port_msimap + (4 * i)) 0L
  done;
  w 0x130 0x3000000L;
  w 0x140 0x10L;
  w 0x144 0x253770L;
  w 0x21c 0L;
  w 0x834 0L;
  w 0x83c 0L;
  (* apcie-config-tunables on both bridges: offset 0x140, size 4, mask 1, value 1. *)
  t.mask32 (reg port.base 0x140) 1L 1L;
  t.mask32 (reg port.base port_appclk) 0L (Int64.of_int port_appclk_en);
  let ctrl = reg port.phy phy_ctrl in
  t.mask32 ctrl (Int64.of_int (clk0_req lor clk1_req)) 0L;
  enable_clocks t port.phy;
  t.mask32 ctrl (Int64.of_int phy_reset) 0L;
  t.mask32 ctrl 0L 0x200L;
  t.mask32 ctrl 0L 0x400L;
  t.mask32 (reg port.base port_reset) 0L (Int64.of_int port_reset_dis);
  poll t (reg port.base port_status) (Int64.of_int port_status_run) (Int64.of_int port_status_run)
    ~timeout:long_timeout "pcie: Port failed to come up";
  poll t (reg port.base port_linksts) (Int64.of_int port_linksts_busy) 0L ~timeout:long_timeout
    "pcie: Port failed to become idle"

let program_link t config port =
  let speed = link_speed port in
  t.mask32 (reg config dbi_ro_wr) 0L 1L;
  t.mask32 (reg config lnkcap) (Int64.of_int sls_mask) (Int64.of_int speed);
  let cap2 = ((1 lsl speed) - 1) lsl 1 in
  t.mask32 (reg config lnkcap2) (Int64.of_int lnkcap2_sls_mask) (Int64.of_int cap2);
  (* m1n1 uses mask16 here. The register is 4-byte aligned and the field is bits 3:0. *)
  t.mask32 (reg config lnkctl2) (Int64.of_int sls_mask) (Int64.of_int speed);
  t.mask32 (reg config dbi_link_width) 0L (Int64.of_int speed_change);
  t.mask32 (reg config dbi_port_link) (Int64.of_int lane_mode_mask) (Int64.of_int lane_mode);
  t.mask32 (reg config dbi_link_width) (Int64.of_int link_width_mask) (Int64.of_int link_width);
  t.mask32 (reg config lnkcap) (Int64.of_int lnkcap_mlw_mask) (Int64.of_int lnkcap_mlw);
  t.mask32 (reg config dbi_ro_wr) 1L 0L;
  ignore (t.read32 (reg port.base port_linksts))

type status = {
  brought_up : int;
  skipped : int;
}

let init t =
  if regs_per_port * port_count <> reg_count - shared_regs then
    failwith "pcie: port registers do not divide evenly";
  t.write32 (reg rc 4) 0L;
  enable_clocks t phy;
  t.mask32 (reg phy phy_ctrl) (Int64.of_int phy_reset) 0L;
  t.mask32 (reg phy 4) 0L 1L;
  t.mask32 (reg phy 4) 0L 0x10L;
  t.mask32 (reg phy_common phycmn_clk) (Int64.of_int phycmn_mode) (Int64.of_int phycmn_mode_on);
  poll t (reg phy 8) 1L 1L ~timeout:long_timeout "pcie: PHY clock enable timed out";
  t.mask32 (reg phy phy_ctrl) 0L 0x200L;
  t.write32 (reg rc 0x54) 0x140L;
  t.write32 (reg rc 0x50) 1L;
  poll t (reg rc 0x58) 1L 1L ~timeout:long_timeout "pcie: Failed to initialize RC thing";
  let brought_up = ref 0 in
  let skipped = ref 0 in
  for i = 0 to port_count - 1 do
    let port = ports.(i) in
    let config = Int64.add ecam (Int64.of_int (i * ecam_port_stride)) in
    if port.present then (
      write_port t port;
      program_link t config port;
      incr brought_up)
    else incr skipped
  done;
  { brought_up = !brought_up; skipped = !skipped }
