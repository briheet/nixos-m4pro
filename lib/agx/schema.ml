(* Firmware structure layouts as data, with version gates (docs/gpu/plan.md,
   "Layout schemas").

   A layout is a list of fields; each field has a type and an optional gate
   on the firmware version. [layout] keeps the fields present in one version
   and computes their offsets; [decode] reads a structure from a snapshot and
   returns a tree. A new firmware release is a gate added or changed here
   (or, later, in the .sexp files these are meant to move to), not new code.

   Versions are compared as lists of integers: "27.2" < "27.10". *)

type ty =
  | U8
  | U16
  | U32
  | U64
  | F32
  | Ptr of string  (** a kernel-half pointer, to the named struct (or "") *)
  | Bytes of int
  | Array of int * ty
  | Struct of string

type gate = Always | Since of string | Until of string  (** Until is exclusive *)

type field = { name : string; ty : ty; gate : gate }

let f ?(gate = Always) name ty = { name; ty; gate }

let version_of_string s = List.map int_of_string (String.split_on_char '.' s)
let present v = function Always -> true | Since s -> v >= version_of_string s | Until s -> v < version_of_string s

(* Named structures, filled by the schema files below. *)
let structs : (string, field list) Hashtbl.t = Hashtbl.create 64

let rec size v = function
  | U8 -> 1
  | U16 -> 2
  | U32 | F32 -> 4
  | U64 | Ptr _ -> 8
  | Bytes n -> n
  | Array (n, t) -> n * size v t
  | Struct name -> List.fold_left (fun acc fl -> acc + size v fl.ty) 0 (fields v name)

and fields v name =
  match Hashtbl.find_opt structs name with
  | Some l -> List.filter (fun fl -> present v fl.gate) l
  | None -> failwith ("schema: unknown struct " ^ name)

(* Offsets of each present field (packed: firmware structs are). *)
let layout v name =
  let _, l =
    List.fold_left (fun (off, acc) fl -> (off + size v fl.ty, (off, fl) :: acc)) (0, []) (fields v name)
  in
  List.rev l

type value =
  | Int of int
  | Float of float
  | Pointer of int
  | Raw of string
  | List of value list
  | Fields of (string * value) list

let rec decode_at v s off ty =
  match ty with
  | U8 -> Int (Char.code s.[off])
  | U16 -> Int (String.get_uint16_le s off)
  | U32 -> Int (Int32.to_int (String.get_int32_le s off) land 0xffffffff)
  | U64 -> Int (Int64.to_int (String.get_int64_le s off))
  | F32 -> Float (Int32.float_of_bits (String.get_int32_le s off))
  | Ptr _ -> Pointer (Int64.to_int (String.get_int64_le s off))
  | Bytes n -> Raw (String.sub s off n)
  | Array (n, t) -> List (List.init n (fun i -> decode_at v s (off + (i * size v t)) t))
  | Struct name -> Fields (List.map (fun (o, fl) -> (fl.name, decode_at v s (off + o) fl.ty)) (layout v name))

let decode snap ~version name va =
  let n = size version (Struct name) in
  Option.map (fun s -> decode_at version s 0 (Struct name)) (Snapshot.read snap va n)

let rec pp ?(indent = 0) b = function
  | Int i -> Printf.bprintf b "%#x" i
  | Float x -> Printf.bprintf b "%g" x
  | Pointer p -> Printf.bprintf b "-> %016Lx" (Int64.of_int p)
  | Raw r -> String.iter (fun c -> Printf.bprintf b "%02x" (Char.code c)) r
  | List l ->
      Buffer.add_char b '[';
      List.iteri
        (fun i x ->
          if i > 0 then Buffer.add_string b ", ";
          pp ~indent b x)
        l;
      Buffer.add_char b ']'
  | Fields fs ->
      List.iter
        (fun (k, x) ->
          Printf.bprintf b "\n%s%s: " (String.make (indent + 2) ' ') k;
          pp ~indent:(indent + 2) b x)
        fs

let to_string x =
  let b = Buffer.create 1024 in
  pp b x;
  Buffer.contents b
