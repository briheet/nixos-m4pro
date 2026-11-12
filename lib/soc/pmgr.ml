(* Power manager for this Mac.
   The live node is /arm-io/pmgr, compatible pmgr1,t6041. That is the
   stub tree's pmgr1 at 0x502800000. The register write is pmgr_set_mode
   in upstream/m1n1/src/pmgr.c: clear the auto and latched bits, store
   the target power state, then poll until the actual state matches.
   The devices and ps-groups blobs in the dump are hashes, so the full
   device walk in pmgr_init cannot be repeated from the dump. The AIC
   domain below is the one the stub attaches to this block. *)

module Proxy = Proto.Proxy

let compatible = "pmgr1,t6041"
let node = "/arm-io/pmgr"
let base = 0x502800000L
let size = 0x1e0000L
let ranges = 63
let dies = 1

let ps_active = 0xf
let ps_clkgate = 0x4
let ps_pwrgate = 0x0

let auto_enable = 1 lsl 28
let was_clkgated = 1 lsl 9
let was_pwrgated = 1 lsl 8
let ps_target = 0xf
let ps_actual = 0xf0
let mode_clear = auto_enable lor was_clkgated lor was_pwrgated lor ps_target
let poll_timeout = 10000

type domain = {
  name : string;
  offset : int;
  always_on : bool;
}

let ps_pms = { name = "pms"; offset = 0x100; always_on = true }
let ps_aic = { name = "aic"; offset = 0x118; always_on = true }

type t = {
  read32 : int64 -> int64;
  mask32 : int64 -> int64 -> int64 -> int64;
}

let of_transport transport =
  { read32 = Proxy.read32 transport; mask32 = Proxy.mask32 transport }

let at offset = Int64.add base (Int64.of_int offset)

let set_mode t addr mode =
  ignore (t.mask32 addr (Int64.of_int mode_clear) (Int64.of_int (mode land ps_target)));
  let want = Int64.shift_left (Int64.of_int (mode land ps_target)) 4 in
  let rec poll left =
    if left = 0 then
      failwith (Printf.sprintf "pmgr: timeout setting mode %#x at %#Lx" mode addr)
    else
      let actual = Int64.logand (t.read32 addr) (Int64.of_int ps_actual) in
      if actual = want then () else poll (left - 1)
  in
  poll poll_timeout

(* Enable walks the parent first, which is what pmgr_set_mode_recursive
   does for a non-zero target. The stub lists ps_pms as ps_aic's parent. *)
let power_aic t =
  set_mode t (at ps_pms.offset) ps_active;
  set_mode t (at ps_aic.offset) ps_active

(* Power for /arm-io/apcie0, read from this Mac's device tree through m1n1
   on 2026-11-12. apcie0's clock-gates are 240 162 244 163 242 164 243 245;
   with their parents that is the ten below. Addresses are absolute, since
   all but AFC sit in a second PMGR window at 0x502280000. The list is in
   dependency order, parents before children, which is the order
   pmgr_adt_power_enable("/arm-io/apcie0") in m1n1 turns them on.
   dart-apcie0 has no clock-gates of its own and is behind these. *)
type ps = {
  id : int;
  ps_name : string;
  addr : int64;
  parents : int list;
}

let apcie0_power =
  [
    { id = 35; ps_name = "AFC"; addr = 0x502800178L; parents = [] };
    { id = 165; ps_name = "FAB3_SOC"; addr = 0x502280118L; parents = [ 35 ] };
    { id = 162; ps_name = "APCIE_GP"; addr = 0x502280100L; parents = [] };
    { id = 163; ps_name = "APCIE_ST0"; addr = 0x502280108L; parents = [] };
    { id = 164; ps_name = "APCIE_ST1"; addr = 0x502280110L; parents = [] };
    { id = 240; ps_name = "ANS"; addr = 0x502280370L; parents = [ 165 ] };
    { id = 244; ps_name = "APCIE_SYS_GP"; addr = 0x502280390L; parents = [ 165; 162 ] };
    { id = 242; ps_name = "APCIE_SYS_ST0"; addr = 0x502280380L; parents = [ 240; 163 ] };
    { id = 243; ps_name = "APCIE_SYS_ST1"; addr = 0x502280388L; parents = [ 240; 164 ] };
    { id = 245; ps_name = "APCIE_PHY_SW"; addr = 0x502280398L; parents = [ 242; 243 ] };
  ]

let apcie0_clock_gates = [ 240; 162; 244; 163; 242; 164; 243; 245 ]
