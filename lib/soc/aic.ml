(* AIC3 for this Mac.
   Init follows aic23_init in upstream/m1n1/src/aic.c for compatible aic,3.
   The base is the IODeviceMemory address of /arm-io/aic. The raw ADT reg
   cell is the arm-io bus address 0x302400000; m1n1 translates it first.
   Offsets and the external-IRQ blob come from that node's properties.
   nr_die and nr_irq are read from the capability registers. Those values
   are silicon state, so a loopback has to be seeded before init. *)

module Proxy = Proto.Proxy

let compatible = "aic,3"
let node = "/arm-io/aic"
let version = 3
let base = 0x502400000L
let size = 0x1cc000L

let iack_offset = 0x40000
let cap0_offset = 0x4
let maxnumirq_offset = 0xc
let extint_base = 0x10000
let extintrcfg_stride = 0x4a00
let intmaskset_stride = 0x4a00
let intmaskclear_stride = 0x4a00

let cap0_nr_irq = 0xffff
let cap0_last_die = 0x0f000000
let maxnumirq_max_irq = 0xffff
let maxnumirq_max_die = 0x0f000000
let irq_cfg_target = 0xf
let max_dies = 4
let max_hw_num = 0x80 * 32

(* Dump of aic-ext-intr-cfg, three bytes: irq low, die/irq high, target. *)
let ext_intr_cfg = [| 0xad; 0x01; 0x03 |]

type layout = {
  nr_die : int;
  nr_irq : int;
  max_die : int;
  max_irq : int;
  event : int64;
  config : int64;
  sw_set : int64;
  sw_clr : int64;
  mask_set : int64;
  mask_clr : int64;
  reg_size : int;
}

type t = {
  read32 : int64 -> int64;
  write32 : int64 -> int64 -> unit;
  mask32 : int64 -> int64 -> int64 -> int64;
}

let of_transport transport =
  {
    read32 = Proxy.read32 transport;
    write32 = Proxy.write32 transport;
    mask32 = Proxy.mask32 transport;
  }

let at offset = Int64.add base (Int64.of_int offset)

let field_lsb mask = mask land -mask

let field_get mask value = (value land mask) / field_lsb mask

let field_prep mask value = value * field_lsb mask land mask

let u32 value = Int64.to_int (Int64.logand value 0xffffffffL)

let computed_stride max_irq =
  let word_rows = max_irq lsr 5 in
  (4 * max_irq) + (5 * 4 * word_rows)

let decode_ext bytes =
  if Array.length bytes mod 3 <> 0 then invalid_arg "aic-ext-intr-cfg length is a multiple of 3";
  List.init (Array.length bytes / 3) (fun i ->
      let b0 = bytes.(3 * i) in
      let b1 = bytes.((3 * i) + 1) in
      let b2 = bytes.((3 * i) + 2) in
      let irq = b0 lor ((b1 land 0xf) lsl 8) in
      let die = b1 lsr 4 in
      (die, irq, b2))

let discover t =
  let cap0 = u32 (t.read32 (at cap0_offset)) in
  let info = u32 (t.read32 (at maxnumirq_offset)) in
  let nr_die = field_get cap0_last_die cap0 + 1 in
  let nr_irq = field_get cap0_nr_irq cap0 in
  let max_die = field_get maxnumirq_max_die info in
  let max_irq = field_get maxnumirq_max_irq info in
  if nr_die > max_dies then failwith (Printf.sprintf "aic: more dies than supported: %d" nr_die);
  if max_irq > max_hw_num then failwith (Printf.sprintf "aic: more IRQs than supported: %d" max_irq);
  let word n = 4 * n in
  let row = word (max_irq lsr 5) in
  let sw_set = extint_base + word max_irq in
  let sw_clr = sw_set + row in
  let mask_set = sw_clr + row in
  let mask_clr = mask_set + row in
  {
    nr_die;
    nr_irq;
    max_die;
    max_irq;
    event = at iack_offset;
    config = at extint_base;
    sw_set = at sw_set;
    sw_clr = at sw_clr;
    mask_set = at mask_set;
    mask_clr = at mask_clr;
    reg_size = iack_offset + 4;
  }

let config_addr layout die irq =
  Int64.add layout.config
    (Int64.add
       (Int64.mul (Int64.of_int die) (Int64.of_int extintrcfg_stride))
       (Int64.of_int (4 * irq)))

let configure t layout =
  List.iter
    (fun (die, irq, target) ->
      if die >= layout.nr_die || irq >= layout.nr_irq then
        failwith
          (Printf.sprintf "aic: external irq %#x die %d outside %d dies / %d irqs" irq die
             layout.nr_die layout.nr_irq);
      let set = Int64.of_int (field_prep irq_cfg_target target) in
      ignore (t.mask32 (config_addr layout die irq) (Int64.of_int irq_cfg_target) set))
    (decode_ext ext_intr_cfg)

let init t =
  let layout = discover t in
  configure t layout;
  layout

let ack t = t.read32 (at iack_offset)

let set_sw t layout irq active =
  if layout.max_irq <= 0 then invalid_arg "aic: max_irq is zero";
  let die = irq / layout.max_irq in
  let irq = irq mod layout.max_irq in
  let mask = Int64.shift_left 1L (irq land 31) in
  let slot = 4 * (irq lsr 5) in
  let stride = if active then intmaskset_stride else intmaskclear_stride in
  let bank = if active then layout.sw_set else layout.sw_clr in
  t.write32 (Int64.add bank (Int64.of_int ((die * stride) + slot))) mask
