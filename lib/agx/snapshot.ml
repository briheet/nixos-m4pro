(* A snapshot taken by tools/hv/trace_agx_raw.py, read offline.

   The directory holds:
     shared.tsv       "root <phys>" and "entry <table> <depth> <index> <value>"
                      for the page tables in gfx-shared-region (the kernel
                      half macOS allocates GPU objects in)
     phys-<a>.bin     16 KiB RAM pages those tables map
     pages.tsv        "page <va> <size> <phys>" for context 0's low half
     va-<a>.bin       those pages
     region-*.bin     the regions iBoot set up

   Addresses: the kernel half is sign-extended from bit [half_bits] (42 on
   this firmware) and is walked from the shared root with the level shifts
   the init data itself declares (36/25/14, 64/2048/2048 entries). *)

type level = { shift : int; entries : int }

type t = {
  dir : string;
  root : int;
  entries : (int * int, int) Hashtbl.t;  (** (table, index) -> raw entry *)
  low : (int * int * string) list;  (** va, size, file *)
  levels : level list;
  half_bits : int;
  pages : (int, string) Hashtbl.t;  (** cache of phys page contents *)
}

let page_size = 0x4000
let oa_mask = 0xffffffffc000

(* This firmware's layout (docs/gpu/facts.md); [with_levels] replaces it
   with what a decoded init data declares. *)
let default_levels = [ { shift = 36; entries = 64 }; { shift = 25; entries = 2048 }; { shift = 14; entries = 2048 } ]

(* Kernel-half addresses need all 64 bits; OCaml ints have 63. Parse as
   Int64 and narrow: their top bits are all ones, so they stay correct (as
   negative numbers) for shifts and masks below bit 62. *)
let int_of_hex s = Int64.to_int (Int64.of_string (String.trim s))

let contains s sub =
  let ls = String.length sub and l = String.length s in
  let rec at i = i + ls <= l && (String.sub s i ls = sub || at (i + 1)) in
  at 0

let lines file = In_channel.with_open_text file In_channel.input_all |> String.split_on_char '\n'

let load dir =
  let entries = Hashtbl.create 4096 and root = ref 0 in
  List.iter
    (fun l ->
      match String.split_on_char '\t' l with
      | [ "root"; r ] -> root := int_of_hex r
      | [ "entry"; tbl; _depth; idx; v ] -> Hashtbl.replace entries (int_of_hex tbl, int_of_string idx) (int_of_hex v)
      | _ -> ())
    (lines (Filename.concat dir "shared.tsv"));
  let low =
    let f = Filename.concat dir "pages.tsv" in
    if not (Sys.file_exists f) then []
    else
      List.filter_map
        (fun l ->
          match String.split_on_char '\t' l with
          | [ "page"; va; size; _phys ] ->
              let va = int_of_hex va in
              Some (va, int_of_hex size, Filename.concat dir (Printf.sprintf "va-%016x.bin" va))
          | _ -> None)
        (lines f)
  in
  { dir; root = !root; entries; low; levels = default_levels; half_bits = 42; pages = Hashtbl.create 64 }

let with_levels t levels = { t with levels }

(* Kernel-half address: the top bits above [half_bits] all set. *)
let is_kernel t va = va lsr t.half_bits = (-1) lsr t.half_bits

let read_file f = In_channel.with_open_bin f In_channel.input_all

let page_at t phys =
  match Hashtbl.find_opt t.pages phys with
  | Some p -> Some p
  | None ->
      let f = Filename.concat t.dir (Printf.sprintf "phys-%#x.bin" phys) in
      if Sys.file_exists f then begin
        let p = read_file f in
        Hashtbl.replace t.pages phys p;
        Some p
      end
      else None

(* The physical page behind a kernel-half address, through the shared tables. *)
let translate t va =
  let rec walk table = function
    | [] -> None
    | lv :: rest -> (
        let idx = (va lsr lv.shift) land (lv.entries - 1) in
        match Hashtbl.find_opt t.entries (table, idx) with
        | None -> None
        | Some e when e land 1 = 0 -> None
        | Some e -> if rest = [] then Some (e land oa_mask) else walk (e land oa_mask) rest)
  in
  if is_kernel t va then walk t.root t.levels else None

(* [len] bytes at [va], or None if any page is not in the snapshot. *)
let read t va len =
  let buf = Buffer.create len in
  let rec go va left =
    if left = 0 then true
    else
      let off = va land (page_size - 1) in
      let n = min left (page_size - off) in
      let page =
        if is_kernel t va then Option.bind (translate t va) (page_at t)
        else
          List.find_map
            (fun (base, size, file) ->
              if va >= base && va < base + size then
                Some (String.sub (read_file file) (va - base - off) (min size page_size))
              else None)
            t.low
      in
      match page with
      | Some p when String.length p >= off + n ->
          Buffer.add_string buf (String.sub p off n);
          go (va + n) (left - n)
      | _ -> false
  in
  if go va len then Some (Buffer.contents buf) else None

(* The init-data address from the trace's events: the first host->firmware
   message on endpoint 0x20 of type 0x81 carries it in bits 47:0. *)
let init_va ~trace_dir =
  let f = Filename.concat trace_dir "events.jsonl" in
  let value_of l key =
    match String.split_on_char '"' l with
    | parts ->
        let rec find = function
          | k :: _ :: v :: _ when k = key -> Some v
          | _ :: r -> find r
          | [] -> None
        in
        find parts
  in
  List.find_map
    (fun l ->
      if contains l "\"ep\": 32," && contains l "\"dir\": \"tx\"" then
        match value_of l "msg" with
        | Some m ->
            let v = int_of_hex m in
            if (v lsr 48) land 0xff = 0x81 then
              let a = v land 0xffffffffffff in
              (* Sign-extend from bit 43 of the 44-bit message field. *)
              Some (if a land (1 lsl 43) <> 0 then a lor (-1 lsl 44) else a)
            else None
        | None -> None
      else None)
    (lines f)
