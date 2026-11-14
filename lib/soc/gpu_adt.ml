(* The GPU (AGX) of this Mac, from its own Apple device tree.

   /arm-io/sgx describes the GPU, /arm-io/gfx-asc the coprocessor that runs
   its firmware. iBoot has already loaded that firmware (segments __TEXT,
   __DATA, __DATA_SHARED_RO at the physical addresses in segment-ranges) and
   set up the memory regions below; a Linux GPU driver adopts both, as
   Asahi's does on M1/M2. What m1n1's kboot_gpu.c fills into the OS device
   tree for those chips (operating points, leakage and power coefficients,
   the reserved regions) starts from the same properties, so this decoder is
   the base for the J614s GPU node.

   Layouts follow m1n1 (proxyclient/m1n1/adt.py, src/kboot_gpu.c):
     perf-states, perf-states-sram   perf-state-table-count tables of
                                     perf-state-count (u32 Hz, u32 mV)
     afr-perf-states, cs-perf-states u64 dies, u64 count, then per die
                                     count (u64 uV, u64 Hz), then u64
                                     min SRAM uV per die (microvolts here,
                                     unlike the u32 tables)
     *-base, *-size                  u64
     segment-ranges                  per segment u64 phys, u64 iova,
                                     u64 remap, u32 size, u32 flags
                                     (layout as observed, not documented) *)

type perf_state = { hz : int; mv : int }

(* [mv] holds microvolts in the 64-bit tables; see [aux]. *)
type aux_perf = { dies : int; states : perf_state list list; min_sram_mv : int list }

type region = { name : string; base : int; size : int }

type segment = { seg : string; phys : int; iova : int; size : int }

type t = {
  compatible : string list;
  reg : (int * int) list;  (** CPU physical base, size *)
  num_perf_states : int option;
  perf_tables : perf_state list list;
  sram_tables : perf_state list list;
  afr : aux_perf option;
  cs : aux_perf option;
  regions : region list;
  asc_reg : (int * int) list;
  segments : segment list;
}

let u64_at s off = Int64.to_int (String.get_int64_le s off)

let u32 n name = Adt.prop_u32 n name

let pairs32 s =
  List.init (String.length s / 8) (fun i ->
      { hz = Adt.u32_at s (8 * i); mv = Adt.u32_at s ((8 * i) + 4) })

let rec chunks k = function
  | [] -> []
  | l ->
      let rec take i acc = function
        | x :: r when i > 0 -> take (i - 1) (x :: acc) r
        | r -> (List.rev acc, r)
      in
      let c, r = take k [] l in
      c :: chunks k r

let tables n name ~count =
  match Adt.prop n name with
  | None -> []
  | Some s -> chunks count (pairs32 s)

let aux n name =
  match Adt.prop n name with
  | None -> None
  | Some s when String.length s < 16 -> None
  | Some s ->
      let dies = u64_at s 0 and count = u64_at s 8 in
      if dies <= 0 || count <= 0 || String.length s < 16 + (dies * count * 16) + (dies * 8) then None
      else
        let state d i =
          let off = 16 + (((d * count) + i) * 16) in
          { mv = u64_at s off; hz = u64_at s (off + 8) }
        in
        let states = List.init dies (fun d -> List.init count (state d)) in
        let min_sram_mv = List.init dies (fun d -> u64_at s (16 + (dies * count * 16) + (8 * d))) in
        Some { dies; states; min_sram_mv }

(* The base/size property pairs of the sgx node, in ADT order. *)
let regions n =
  List.filter_map
    (fun (k, v) ->
      match String.length k > 5 && String.sub k (String.length k - 5) 5 = "-base" with
      | false -> None
      | true -> (
          let stem = String.sub k 0 (String.length k - 5) in
          match Adt.prop n (stem ^ "-size") with
          | Some sz when String.length v = 8 && String.length sz = 8 ->
              Some { name = stem; base = u64_at v 0; size = u64_at sz 0 }
          | _ -> None))
    n.Adt.props

let segments n =
  match (Adt.prop n "segment-names", Adt.prop n "segment-ranges") with
  | Some names, Some ranges ->
      let names = String.split_on_char ';' (Adt.cstring names) in
      List.mapi
        (fun i seg ->
          let off = 32 * i in
          if off + 32 > String.length ranges then None
          else
            Some
              {
                seg;
                phys = u64_at ranges off;
                iova = u64_at ranges (off + 8);
                size = Adt.u32_at ranges (off + 24);
              })
        names
      |> List.filter_map Fun.id
  | _ -> []

let regs root path =
  List.init (Adt.reg_count root path) (fun i -> Adt.reg root path i)

let of_adt root =
  let sgx = Adt.node_at root "/arm-io/sgx" in
  let asc = Adt.node_at root "/arm-io/gfx-asc" in
  let count = Option.value (u32 sgx "perf-state-count") ~default:0 in
  {
    compatible = Adt.compatible sgx;
    reg = regs root "/arm-io/sgx";
    num_perf_states = u32 sgx "gpu-num-perf-states";
    perf_tables = (if count > 0 then tables sgx "perf-states" ~count else []);
    sram_tables = (if count > 0 then tables sgx "perf-states-sram" ~count else []);
    afr = aux sgx "afr-perf-states";
    cs = aux sgx "cs-perf-states";
    regions = regions sgx;
    asc_reg = regs root "/arm-io/gfx-asc";
    segments = segments asc;
  }

let summary g =
  let b = Buffer.create 4096 in
  let pr fmt = Printf.bprintf b fmt in
  pr "compatible: %s\n" (String.concat " " g.compatible);
  List.iteri (fun i (base, size) -> pr "sgx reg %d: %#x + %#x\n" i base size) g.reg;
  List.iteri (fun i (base, size) -> pr "gfx-asc reg %d: %#x + %#x\n" i base size) g.asc_reg;
  Option.iter (pr "gpu-num-perf-states: %d\n") g.num_perf_states;
  let table title t =
    List.iteri
      (fun i states ->
        pr "%s %d:" title i;
        List.iter (fun s -> pr " %d/%d" (s.hz / 1_000_000) s.mv) states;
        pr "  (MHz/mV)\n")
      t
  in
  table "perf table" g.perf_tables;
  table "sram table" g.sram_tables;
  let aux title = function
    | None -> ()
    | Some a ->
        List.iteri
          (fun d states ->
            pr "%s die %d:" title d;
            List.iter (fun s -> pr " %d/%d" (s.hz / 1_000_000) (s.mv / 1000)) states;
            pr "  (MHz/mV), min SRAM %d mV\n" (List.nth a.min_sram_mv d / 1000))
          a.states
  in
  aux "afr" g.afr;
  aux "cs" g.cs;
  List.iter (fun r -> pr "region %-24s %#x + %#x\n" r.name r.base r.size) g.regions;
  List.iter
    (fun s -> pr "firmware %-18s phys %#x iova %#x size %#x\n" s.seg s.phys s.iova s.size)
    g.segments;
  Buffer.contents b
