(* The program in a firmware image: which words are code, how they split
   into functions, what references what, and what the functions are called.

   Functions are found from every place that names code: the reset vector,
   call targets, PAC prologues (pacibsp), code addresses built with
   ADR/ADRP (handler tables, exception vectors, callbacks) and code pointers
   stored in __DATA. Each is followed through its branches (jump tables
   included) until it returns, stops or tail-calls another function, so
   what is left over shows where the analysis has not reached yet.

   Names come from the firmware's own strings: assertion and log messages
   pass __func__, so a function that references an identifier-like string
   ("AGFAcceleratorDrainDeviceControlRing") is usually that function, or
   has it inlined. *)

type func = {
  entry : int;
  mutable blocks : int list;  (** block starts *)
  mutable words : int;  (** instructions owned *)
  mutable callees : int list;
  mutable returns : bool;
  mutable names : string list;  (** identifier strings it references *)
}

type ref_kind = Code_addr | Data_addr | Load of int | Store of int

type t = {
  img : Image.t;
  text : Image.segment;
  insns : A64.t array;  (** one per TEXT word *)
  owner : int array;  (** function entry owning each word, or -1 *)
  funcs : (int, func) Hashtbl.t;
  strings : (int, string) Hashtbl.t;
  refs : (int, int * ref_kind) Hashtbl.t;  (** target -> (pc, kind), many *)
  refs_from : (int, int * ref_kind) Hashtbl.t;  (** pc -> (target, kind), many *)
  callers : (int, int) Hashtbl.t;  (** callee -> call site, many *)
  jump_tables : (int, int list) Hashtbl.t;  (** br pc -> targets *)
  names : (int, string) Hashtbl.t;  (** entry -> chosen name *)
}

let word t pc = Int32.to_int (String.get_int32_le t.text.data pc) land 0xffffffff
let in_text t pc = pc >= 0 && pc < String.length t.text.data && pc land 3 = 0
let insn t pc = t.insns.(pc / 4)

(* Plausible start of code: decodes, and is not padding. *)
let codeish t pc =
  in_text t pc && match insn t pc with A64.Unknown | Udf _ -> false | _ -> true

(* ---- constants within a straight line of code ---- *)
module Consts = struct
  (* Register -> image offset (from ADR/ADRP/ADD) or plain integer. *)
  type v = Addr of int | Int of int64

  let step img (st : (int, v) Hashtbl.t) pc (i : A64.t) : (int * v) option =
    let result =
      match i with
      | A64.Adr { rd; target; _ } -> Some (rd, Addr target)
      | Addi { sub; s = false; rd; rn; imm; sf = true } -> (
          match Hashtbl.find_opt st rn with
          | Some (Addr a) -> Some (rd, Addr (if sub then a - imm else a + imm))
          | Some (Int v) -> Some (rd, Int (Int64.add v (Int64.of_int (if sub then -imm else imm))))
          | None -> None)
      | Movw { op = Z; rd; imm; shift; _ } -> Some (rd, Int (Int64.shift_left (Int64.of_int imm) shift))
      | Movw { op = N; rd; imm; shift; sf } ->
          let v = Int64.lognot (Int64.shift_left (Int64.of_int imm) shift) in
          Some (rd, Int (if sf then v else Int64.logand v 0xffffffffL))
      | Movw { op = K; rd; imm; shift; _ } -> (
          match Hashtbl.find_opt st rd with
          | Some (Int v) ->
              let mask = Int64.lognot (Int64.shift_left 0xffffL shift) in
              Some (rd, Int (Int64.logor (Int64.logand v mask) (Int64.shift_left (Int64.of_int imm) shift)))
          | _ -> None)
      | Logi { op = 1; rn = 31; rd; imm; _ } -> Some (rd, Int imm)
      | Movr { rd; rm; sf = true } -> (match Hashtbl.find_opt st rm with Some v -> Some (rd, v) | None -> None)
      | Mem { load = true; fp = false; rt; addr = Lit a; size = 8; _ } -> (
          match Image.u64 img a with Some v -> Some (rt, Int v) | None -> None)
      | _ -> None
    in
    ignore pc;
    List.iter (fun r -> Hashtbl.remove st r) (A64.defs i);
    (match result with Some (r, v) -> Hashtbl.replace st r v | None -> ());
    result
end

(* ---- jump tables ---- *)
(* clang's switch: adr xT, table; ldr{sw,h,b} xI, [xT, xIdx, lsl #n];
   add xD, xB, xI, lsl #m; br xD, bounded by an earlier cmp wIdx, #k.
   Entries are offsets from xB. *)
let jump_table t br_pc rd =
  let window = 16 in
  let start = max 0 (br_pc - (4 * window)) in
  let st = Hashtbl.create 8 in
  let load = ref None and add = ref None and bound = ref None in
  let pc = ref start in
  while !pc < br_pc do
    let i = insn t !pc in
    (match i with
    | A64.Mem { load = true; fp = false; rn; rt; size; signed; addr = Reg { rm; _ }; _ } -> (
        match Hashtbl.find_opt st rn with
        | Some (Consts.Addr tbl) -> load := Some (tbl, size, signed, rt, rm)
        | _ -> ())
    | Addi { sub = true; s = true; rd = 31; imm; _ } -> (
        match !load with None -> bound := Some (imm + 1) | Some _ -> ())
    | _ -> ());
    let w = word t !pc in
    (* add (shifted register), 64-bit *)
    if w land 0xff200000 = 0x8b000000 then begin
      let d = A64.bits w 4 0 and n = A64.bits w 9 5 and m = A64.bits w 20 16 and sh = A64.bits w 15 10 in
      match Hashtbl.find_opt st n with Some (Consts.Addr b) -> add := Some (d, b, m, sh) | _ -> ()
    end;
    ignore (Consts.step t.img st !pc i);
    pc := !pc + 4
  done;
  match (!load, !add) with
  | Some (tbl, size, signed, li, _), Some (d, b, m, sh) when d = rd && m = li ->
      let n = match !bound with Some k when k > 0 && k <= 1024 -> k | _ -> 64 in
      let rec go k acc =
        if k >= n then List.rev acc
        else
          let e =
            match size with
            | 4 -> Option.map (fun v -> if signed then A64.sext v 32 else v) (Image.u32 t.img (tbl + (4 * k)))
            | 2 -> Option.map (fun v -> if signed then A64.sext v 16 else v) (Image.u16 t.img (tbl + (2 * k)))
            | 1 -> Option.map (fun v -> if signed then A64.sext v 8 else v) (Image.u8 t.img (tbl + k))
            | _ -> None
          in
          match e with
          | Some e when codeish t (b + (e lsl sh)) -> go (k + 1) ((b + (e lsl sh)) :: acc)
          | _ -> List.rev acc
      in
      go 0 []
  | _ -> []

(* ---- traversal ---- *)
(* A block can be walked more than once (it is reached from several
   branches, and a later walk may re-enter an earlier one), so the same
   reference must not be recorded twice. *)
let add_multi tbl k v = if not (List.mem v (Hashtbl.find_all tbl k)) then Hashtbl.add tbl k v

let explore t entries =
  let pending = Queue.create () in
  let known = Hashtbl.create 1024 in
  let enqueue e = if codeish t e && not (Hashtbl.mem known e) then (Hashtbl.replace known e (); Queue.add e pending) in
  List.iter enqueue entries;
  (* Every entry is known before bodies are walked, so a branch into another
     entry is a tail call. New entries found while walking are walked later. *)
  while not (Queue.is_empty pending) do
    let entry = Queue.pop pending in
    if t.owner.(entry / 4) < 0 then begin
      let f = { entry; blocks = []; words = 0; callees = []; returns = false; names = [] } in
      Hashtbl.replace t.funcs entry f;
      let blocks = Queue.create () and seen = Hashtbl.create 64 in
      let add_block b = if in_text t b && not (Hashtbl.mem seen b) then (Hashtbl.replace seen b (); Queue.add b blocks) in
      add_block entry;
      while not (Queue.is_empty blocks) do
        let b = Queue.pop blocks in
        f.blocks <- b :: f.blocks;
        let consts = Hashtbl.create 8 in
        let pc = ref b and go = ref true in
        while !go do
          let p = !pc in
          if (not (in_text t p)) || (p <> entry && Hashtbl.mem known p && p <> b) then go := false
          else if t.owner.(p / 4) >= 0 && t.owner.(p / 4) <> entry then go := false
          else begin
            if t.owner.(p / 4) <> entry then (t.owner.(p / 4) <- entry; f.words <- f.words + 1);
            let i = insn t p in
            (match Consts.step t.img consts p i with
            | Some (_, Consts.Addr a) ->
                let kind = if in_text t a then Code_addr else Data_addr in
                add_multi t.refs a (p, kind);
                add_multi t.refs_from p (a, kind);
                if kind = Code_addr && codeish t a then enqueue a
            | _ -> ());
            (match i with
            | A64.Mem { rn; addr = Off o | Pre o; load; size; _ } when rn >= 0 -> (
                match Hashtbl.find_opt consts rn with
                | Some (Consts.Addr a) ->
                    let k = if load then Load size else Store size in
                    add_multi t.refs (a + o) (p, k);
                    add_multi t.refs_from p (a + o, k)
                | _ -> ())
            | A64.Mem { addr = Lit a; size; _ } ->
                add_multi t.refs a (p, Load size);
                add_multi t.refs_from p (a, Load size)
            | _ -> ());
            match A64.flow i with
            | Next -> pc := p + 4
            | Branch tgt ->
                add_block tgt;
                pc := p + 4
            | Jump tgt ->
                if Hashtbl.mem known tgt && tgt <> entry then f.callees <- tgt :: f.callees else add_block tgt;
                go := false
            | Call tgt ->
                enqueue tgt;
                add_multi t.callers tgt p;
                f.callees <- tgt :: f.callees;
                pc := p + 4
            | Indirect ->
                (match i with
                | Br { rn; _ } ->
                    let targets = jump_table t p rn in
                    if targets <> [] then begin
                      Hashtbl.replace t.jump_tables p targets;
                      List.iter add_block targets
                    end
                | _ -> ());
                go := false
            | Stop ->
                (match i with Ret _ -> f.returns <- true | _ -> ());
                go := false
          end
        done
      done
    end
  done

let identifier s =
  String.length s >= 6
  && (match s.[0] with 'A' .. 'Z' | 'a' .. 'z' | '_' -> true | _ -> false)
  && String.for_all (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) s
  && String.exists (function 'a' .. 'z' -> true | _ -> false) s

let analyse img =
  let text = Image.text img in
  let n = String.length text.data / 4 in
  let insns = Array.init n (fun i -> A64.decode (4 * i) (Int32.to_int (String.get_int32_le text.data (4 * i)) land 0xffffffff)) in
  let t =
    {
      img; text; insns; owner = Array.make n (-1);
      funcs = Hashtbl.create 1024; strings = Hashtbl.create 4096; refs = Hashtbl.create 8192;
      refs_from = Hashtbl.create 8192; callers = Hashtbl.create 8192; jump_tables = Hashtbl.create 64;
      names = Hashtbl.create 1024;
    }
  in
  List.iter (fun (o, s) -> Hashtbl.replace t.strings o s) (Image.strings img);
  (* seeds: reset, PAC prologues, call targets, code pointers in data *)
  let seeds = ref [ 0 ] in
  Array.iteri
    (fun i ins ->
      match ins with
      | A64.Other { mnem = "pacibsp"; _ } -> seeds := (4 * i) :: !seeds
      | Bl tgt when in_text t tgt -> seeds := tgt :: !seeds
      | _ -> ())
    insns;
  List.iter
    (fun (s : Image.segment) ->
      if s.name <> "__TEXT" then
        for k = 0 to (String.length s.data / 8) - 1 do
          match Image.offset_of_pointer img (String.get_int64_le s.data (8 * k)) with
          | Some o when in_text t o -> seeds := o :: !seeds
          | _ -> ()
        done)
    img.segments;
  explore t (List.sort_uniq compare !seeds);
  (* names *)
  let users = Hashtbl.create 1024 in
  Hashtbl.iter
    (fun target (pc, kind) ->
      match (kind, Hashtbl.find_opt t.strings target) with
      | Data_addr, Some s when identifier s ->
          let f = t.owner.(pc / 4) in
          if f >= 0 then begin
            let fn = Hashtbl.find t.funcs f in
            if not (List.mem s fn.names) then fn.names <- s :: fn.names;
            let l = try Hashtbl.find users s with Not_found -> [] in
            if not (List.mem f l) then Hashtbl.replace users s (f :: l)
          end
      | _ -> ())
    t.refs;
  Hashtbl.iter
    (fun _ f ->
      (* A name only this function uses wins. A name shared with others is
         an inlined __func__ string (its assert landed in several callers):
         still take it, marked shared. *)
      let own = List.filter (fun s -> Hashtbl.find users s = [ f.entry ]) f.names in
      match (own, f.names) with
      | [ s ], _ -> Hashtbl.replace t.names f.entry s
      | s :: _, _ -> Hashtbl.replace t.names f.entry (s ^ "~")
      | [], s :: _ -> Hashtbl.replace t.names f.entry (s ^ "~")
      | [], [] -> ())
    t.funcs;
  t

let name t entry =
  match Hashtbl.find_opt t.names entry with Some n -> n | None -> Printf.sprintf "fn_%x" entry

(* ---- reports ---- *)
type coverage = {
  words : int;
  owned : int;
  padding : int;  (** zero words and udf *)
  leftover_code : (int * int) list;  (** unowned ranges that decode as code: start, words *)
}

let coverage t =
  let n = Array.length t.insns in
  let owned = ref 0 and padding = ref 0 and ranges = ref [] and cur = ref None in
  let close () = match !cur with Some (s, k) when k >= 4 -> ranges := (s, k) :: !ranges; cur := None | _ -> cur := None in
  for i = 0 to n - 1 do
    if t.owner.(i) >= 0 then (incr owned; close ())
    else
      match t.insns.(i) with
      | A64.Udf _ -> incr padding; close ()
      | Unknown -> close ()
      | _ -> ( match !cur with Some (s, k) -> cur := Some (s, k + 1) | None -> cur := Some (4 * i, 1))
  done;
  close ();
  { words = n; owned = !owned; padding = !padding; leftover_code = List.rev !ranges }

let refs_to t target = Hashtbl.find_all t.refs target
let refs_from t pc = Hashtbl.find_all t.refs_from pc

(* The string at or around an address, for annotations. *)
let string_at t a = Hashtbl.find_opt t.strings a

let annotate t pc (i : A64.t) =
  let notes =
    List.filter_map
      (fun (a, kind) ->
        match (kind, string_at t a) with
        | _, Some s -> Some (Printf.sprintf "%S" (if String.length s > 70 then String.sub s 0 70 ^ "..." else s))
        | Code_addr, None -> Some ("&" ^ name t a)
        | Data_addr, None -> Some (Printf.sprintf "&%s" (Image.pp_addr t.img a))
        | Load n, None -> Some (Printf.sprintf "R%d %s" n (Image.pp_addr t.img a))
        | Store n, None -> Some (Printf.sprintf "W%d %s" n (Image.pp_addr t.img a)))
      (refs_from t pc)
  in
  let notes =
    match i with
    | A64.Bl tgt -> name t tgt :: notes
    | B tgt when Hashtbl.mem t.funcs tgt -> ("tail " ^ name t tgt) :: notes
    | Br _ -> (
        match Hashtbl.find_opt t.jump_tables pc with
        | Some l -> Printf.sprintf "jump table, %d cases" (List.length l) :: notes
        | None -> notes)
    | _ -> notes
  in
  match notes with [] -> "" | l -> "\t; " ^ String.concat " " l

let disasm ?(out = print_string) t entry =
  match Hashtbl.find_opt t.funcs entry with
  | None -> out (Printf.sprintf "no function at %x\n" entry)
  | Some f ->
      let b = Buffer.create 4096 in
      Printf.bprintf b "%s %s  (%d instructions, %d blocks%s)\n" (Image.pp_addr t.img entry) (name t entry) f.words
        (List.length f.blocks) (if f.returns then "" else ", never returns");
      if List.length f.names > 1 then Printf.bprintf b "  names referenced: %s\n" (String.concat " " f.names);
      let blocks = List.sort_uniq compare f.blocks in
      for i = 0 to Array.length t.insns - 1 do
        if t.owner.(i) = entry then begin
          let pc = 4 * i in
          if List.mem pc blocks && pc <> entry then Printf.bprintf b " %x:\n" pc;
          Printf.bprintf b "   %6x  %s%s\n" pc (A64.to_string t.insns.(i)) (annotate t pc t.insns.(i))
        end
      done;
      out (Buffer.contents b)

let find_func t s =
  match int_of_string_opt ("0x" ^ s) with
  | Some v when Hashtbl.mem t.funcs v -> Some v
  | _ ->
      Hashtbl.fold (fun e n acc -> if acc = None && (n = s || n = s ^ "~") then Some e else acc) t.names None
