(* GPU ground truth from the live machine, through m1n1's proxy (docs/gpu/plan.md,
   phase 0). Read-only except for one power domain:

   - the ADT as iBoot passed it (boot args: devtree at +96, size at +104,
     virtual like the kernel sees it, so phys = devtree - virt_base + phys_base);
   - the GPU firmware iBoot loaded, each gfx-asc segment, saved and hashed
     (it is Apple's: the dumps stay in build/, never in git);
   - the leakage efuse words of the GPU (page 0x508374000, 0xc10..0xc2b);
   - the core mask (SGX +0xe01500, 3 words) and the A/B perf maps (SGX
     +0xe01400 and +0xe01480, 8 words each, two 4-bit indices per word),
     which need the gfx domain powered: it is raised to active only if it is
     not, and put back to the state it had.

   Field layouts and the leakage formulas follow aurora-silicon's aura
   (src/kboot_gpu.c, dt_set_gpu_t6040); they are what we check against, not
   something this file trusts. *)

module Proxy = Proto.Proxy
module Serial = Proto.Serial
module Pmgr = Soc.Pmgr
module Pmgr_adt = Soc.Pmgr_adt
module Gpu_adt = Soc.Gpu_adt

let efuse_page = 0x508374000
let efuse_offsets = [ 0xc10; 0xc1c; 0xc20; 0xc24; 0xc28 ]
let core_mask_off = 0xe01500
let perf_map_a_off = 0xe01400
let perf_map_b_off = 0xe01480
let cores_per_cluster_bits = 10

let u64 b off = Int64.to_int (Bytes.get_int64_le b off)
let u32b b off = Int32.to_int (Bytes.get_int32_le b off) land 0xffffffff

let read32 transport addr =
  match Probe.read transport (Int64.of_int addr) with
  | Some v -> Int64.to_int v land 0xffffffff
  | None -> failwith (Printf.sprintf "read of %#x faulted" addr)

let live_adt serial transport =
  let ba = Int64.to_int (Proxy.call transport Proxy.p_get_bootargs []) in
  let hdr = Serial.memread serial ~addr:ba ~size:112 in
  let virt_base = u64 hdr 8 and phys_base = u64 hdr 16 in
  let devtree = u64 hdr 96 and size = u32b hdr 104 in
  let phys = devtree - virt_base + phys_base in
  let data = Serial.memread serial ~addr:phys ~size in
  (Adt.parse (Bytes.to_string data), phys, size)

(* Printable runs of at least [min] bytes that look like version or build
   identifiers. *)
let interesting_strings ?(min = 6) s =
  let out = ref [] and start = ref (-1) in
  let keep str =
    let has sub =
      let ls = String.length sub and l = String.length str in
      let rec at i = i + ls <= l && (String.sub str i ls = sub || at (i + 1)) in
      at 0
    in
    List.exists has [ "AGX"; "RTKit"; "Build"; "build"; "version"; "Version"; "RELEASE"; "iBoot"; "gfx" ]
  in
  String.iteri
    (fun i c ->
      let printable = c >= ' ' && c <= '~' in
      if printable && !start < 0 then start := i
      else if (not printable) && !start >= 0 then begin
        let str = String.sub s !start (i - !start) in
        if String.length str >= min && keep str then out := str :: !out;
        start := -1
      end)
    s;
  List.rev !out

let leak_values ef =
  let e i = List.nth ef i in
  let sram_word = (e 3 lsl 32) lor e 2 in
  let raw0 = (e 0 lsr 1) land 0x3fff and raw1 = (e 0 lsr 15) land 0x3fff in
  let raw2 = (sram_word lsr 24) land 0x3ff in
  let raw3 = (e 1 lsr 9) land 0x1fff and raw4 = (e 4 lsr 4) land 0xfff in
  [
    ("core_leak[0]", float (raw0 + 1) *. 1.5, raw0, 0x3fff);
    ("core_leak[1]", float (raw1 + 1) *. 1.5, raw1, 0x3fff);
    ("sram_leak", float (raw2 + 1) *. 3.0, raw2, 0x3ff);
    ("cs_leak", float (raw3 + 1), raw3, 0x1fff);
    ("afr_leak", float (raw4 + 1) *. 1.5, raw4, 0xfff);
  ]

let perf_map transport base =
  let idx = Array.make 16 0 in
  for k = 0 to 7 do
    let w = read32 transport (base + (4 * k)) in
    idx.(2 * k) <- w land 0xf;
    idx.((2 * k) + 1) <- (w lsr 16) land 0xf
  done;
  Array.to_list idx

let popcount x =
  let rec go x n = if x = 0 then n else go (x land (x - 1)) (n + 1) in
  go x 0

(* Raise every domain of [chain] (parents first) to active if it is not,
   run [f], then put back what was changed, children first. Powering gfx
   without afr hangs the bus on the first SGX read: afr was power-gated
   here although the ADT flags it always-on. *)
let with_chain_active transport (chain : Pmgr_adt.domain list) f =
  let t = { Pmgr.read32 = Probe.read_or_raise transport; mask32 = Live.mask_checked transport } in
  let raised = ref [] in
  let restore () =
    List.iter
      (fun ((d : Pmgr_adt.domain), target) ->
        Pmgr.set_mode t (Int64.of_int (d.base + d.offset)) target)
      !raised
  in
  Fun.protect ~finally:restore (fun () ->
      List.iter
        (fun (d : Pmgr_adt.domain) ->
          let before = read32 transport (d.base + d.offset) in
          if (before land Pmgr.ps_actual) lsr 4 <> Pmgr.ps_active then begin
            Pmgr.set_mode t (Int64.of_int (d.base + d.offset)) Pmgr.ps_active;
            raised := (d, before land Pmgr.ps_target) :: !raised
          end)
        chain;
      f (List.map (fun ((d : Pmgr_adt.domain), _) -> d.name) !raised))

let run ?device ~out_dir () =
  let device = match device with Some d -> d | None -> Proto.Wire.device () in
  let serial = Serial.open_device ~timeout:10.0 ~console:(Probe.console_printer ()) device in
  Fun.protect
    ~finally:(fun () -> Serial.close serial)
    (fun () ->
      Serial.nop serial;
      let transport = Serial.transport serial in
      let report = Buffer.create 8192 in
      let pr fmt = Printf.ksprintf (fun s -> print_string s; Buffer.add_string report s) fmt in
      (* One directory per run: __TEXT differs between boots, and comparing
         dumps is how we find out where. *)
      let mkdir d = try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> () in
      mkdir out_dir;
      let tm = Unix.localtime (Unix.time ()) in
      let out_dir =
        Filename.concat out_dir
          (Printf.sprintf "%04d%02d%02d-%02d%02d%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
             tm.tm_hour tm.tm_min tm.tm_sec)
      in
      mkdir out_dir;
      let adt, adt_phys, adt_size = live_adt serial transport in
      pr "live ADT: %#x + %#x\n" adt_phys adt_size;
      let g = Gpu_adt.of_adt adt in
      print_string (Gpu_adt.summary g);
      (* Firmware segments as iBoot loaded them. *)
      List.iter
        (fun (s : Gpu_adt.segment) ->
          let data = Bytes.to_string (Serial.memread serial ~addr:s.phys ~size:s.size) in
          let file = Filename.concat out_dir ("gfx-asc" ^ s.seg ^ ".bin") in
          Out_channel.with_open_bin file (fun oc -> output_string oc data);
          pr "firmware %-18s %#x bytes md5 %s -> %s\n" s.seg s.size (Digest.to_hex (Digest.string data)) file;
          List.iter (pr "  string: %s\n") (interesting_strings data))
        g.segments;
      (* Leakage efuses (always readable). *)
      let ef = List.map (fun o -> read32 transport (efuse_page + o)) efuse_offsets in
      List.iter2 (fun o v -> pr "efuse %#x+%#x = %#010x\n" efuse_page o v) efuse_offsets ef;
      List.iter
        (fun (name, v, raw, mx) ->
          pr "  %-13s %8.1f (raw %#x%s)\n" name v raw (if raw = 0 || raw = mx then ", INVALID" else ""))
        (leak_values ef);
      (* Core mask and perf maps, with gfx powered. *)
      let sgx = fst (List.hd g.reg) in
      let chain =
        Pmgr_adt.power_chain adt
          (match Adt.prop (Adt.node_at adt "/arm-io/sgx") "clock-gates" with
          | Some v -> List.init (String.length v / 4) (fun i -> Adt.u32_at v (4 * i))
          | None -> [])
      in
      List.iter
        (fun (d : Pmgr_adt.domain) ->
          pr "pmgr %-6s %#x = %#010x\n" d.name (d.base + d.offset) (read32 transport (d.base + d.offset)))
        chain;
      with_chain_active transport chain (fun raised ->
          pr "raised to active for the reads: %s\n" (String.concat " " raised);
          List.iter
            (fun (d : Pmgr_adt.domain) ->
              pr "pmgr %-6s now %#010x\n" d.name (read32 transport (d.base + d.offset)))
            chain;
          let masks = List.init 3 (fun i -> read32 transport (sgx + core_mask_off + (4 * i))) in
          List.iteri (fun i m -> pr "core mask word %d = %#010x\n" i m) masks;
          let m0 = List.hd masks in
          List.iter
            (fun c ->
              let bits = (m0 lsr (cores_per_cluster_bits * c)) land ((1 lsl cores_per_cluster_bits) - 1) in
              pr "  cluster %d: cores %#x (%d active)\n" c bits (popcount bits))
            [ 0; 1 ];
          let show name l = pr "perf map %s: %s\n" name (String.concat " " (List.map string_of_int l)) in
          show "A" (perf_map transport (sgx + perf_map_a_off));
          show "B" (perf_map transport (sgx + perf_map_b_off)));
      List.iter
        (fun (d : Pmgr_adt.domain) ->
          pr "pmgr %-6s after %#010x\n" d.name (read32 transport (d.base + d.offset)))
        chain;
      Out_channel.with_open_bin (Filename.concat out_dir "probe.txt") (fun oc ->
          output_string oc (Buffer.contents report)))
