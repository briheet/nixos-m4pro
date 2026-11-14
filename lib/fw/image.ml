(* A firmware image as the coprocessor sees it: segments at fixed offsets
   from one base address.

   The GPU firmware is loaded by iBoot from macOS's firmware bundle and
   relocated in RAM; gpu-probe dumps each segment the ADT names
   (gfx-asc segment-names / segment-ranges) as <dir>/gfx-asc<SEGMENT>.bin.
   The segments are laid out back to back from the firmware's base address
   (0x7ffffc0000000000 for 27.2: __TEXT +0, __DATA +0x64000,
   __DATA_SHARED_RO +0x128000).

   Addresses inside the image are kept as offsets from the base (OCaml's
   native int has 63 bits; the base itself does not fit). [__DATA] is a
   runtime copy, read after the firmware ran: its pointers are the
   firmware's own live values. *)

type segment = { name : string; off : int; data : string }

type t = { base : int64; segments : segment list; size : int }

let default_base = 0x7ffffc0000000000L

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* Segments in [dir] named gfx-asc<NAME>.bin, at [offsets] (name, offset). *)
let load ?(base = default_base) ?(prefix = "gfx-asc") dir offsets =
  let segments =
    List.filter_map
      (fun (name, off) ->
        let path = Filename.concat dir (prefix ^ name ^ ".bin") in
        if Sys.file_exists path then Some { name; off; data = read_file path } else None)
      offsets
  in
  let size = List.fold_left (fun m s -> max m (s.off + String.length s.data)) 0 segments in
  { base; segments; size }

(* 27.2's layout (ADT gfx-asc segment-ranges, 2026-11-14). *)
let fw_27_2 = [ ("__TEXT", 0); ("__DATA", 0x64000); ("__DATA_SHARED_RO", 0x128000) ]

let segment_of img off = List.find_opt (fun s -> off >= s.off && off < s.off + String.length s.data) img.segments

let text img = List.find (fun s -> s.name = "__TEXT") img.segments

let in_image img off = segment_of img off <> None

let u8 img off = match segment_of img off with Some s -> Some (Char.code s.data.[off - s.off]) | None -> None

let get f n img off =
  match segment_of img off with
  | Some s when off + n <= s.off + String.length s.data -> Some (f s.data (off - s.off))
  | _ -> None

let u16 = get String.get_uint16_le 2
let u32 = get (fun s o -> Int32.to_int (String.get_int32_le s o) land 0xffffffff) 4
let u64 = get String.get_int64_le 8

(* An absolute address (as a 64-bit value) of something in the image, or a
   value that looks like one with pointer-authentication bits on top: the
   low 40 bits are the offset (the base's low 40 bits are zero) and the top
   is not zero. *)
let offset_of_pointer img (v : int64) =
  let low = Int64.to_int (Int64.logand v 0xff_ffff_ffffL) in
  let top = Int64.shift_right_logical v 40 in
  if top <> 0L && low < img.size && in_image img low && Int64.logand img.base 0xff_ffff_ffffL = 0L then Some low
  else None

let address img off = Int64.add img.base (Int64.of_int off)

let pp_addr img off = Printf.sprintf "%016Lx" (address img off)

(* NUL-terminated printable strings of at least [min] characters. *)
let strings ?(min = 4) img =
  let out = ref [] in
  List.iter
    (fun s ->
      let n = String.length s.data in
      let start = ref (-1) in
      for i = 0 to n - 1 do
        let c = s.data.[i] in
        let printable = (c >= ' ' && c <= '~') || c = '\n' || c = '\t' in
        if printable then (if !start < 0 then start := i)
        else begin
          if c = '\000' && !start >= 0 && i - !start >= min then
            out := (s.off + !start, String.sub s.data !start (i - !start)) :: !out;
          start := -1
        end
      done)
    img.segments;
  List.rev !out
