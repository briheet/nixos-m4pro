(* An AArch64 decoder for firmware analysis.

   Every instruction class the analyses need is decoded into its operands:
   branches and their targets, PC-relative addresses, immediate arithmetic,
   moves, loads and stores with every addressing mode, and the registers an
   instruction writes. Everything else keeps a mnemonic and the general
   registers it writes, which is all data flow needs to stay sound.

   Register numbers: 0-30 are x0-x30; 31 is SP wherever the encoding means
   the stack pointer (load/store bases, ADD/SUB immediate). Where 31 means
   the zero register the decoder says so ([Zr]) or leaves it out of [defs].

   Encodings follow the Arm ARM (DDI 0487), section C4 "A64 Instruction Set
   Encoding". Code offsets are ints (offsets from the image base). *)

let bits w hi lo = (w lsr lo) land ((1 lsl (hi - lo + 1)) - 1)
let bit w n = (w lsr n) land 1

let sext v width = if v land (1 lsl (width - 1)) <> 0 then v - (1 lsl width) else v

type addressing =
  | Off of int  (** [rn, #imm] *)
  | Pre of int  (** [rn, #imm]! *)
  | Post of int  (** [rn], #imm *)
  | Reg of { rm : int; ext : string; amount : int; shown : bool }  (** [rn, rm, ext #amount] *)
  | Lit of int  (** PC-relative: the target's offset *)

type mem = {
  m_mnem : string;
  load : bool;
  size : int;  (** bytes per register; 0 when not modelled (vector structures) *)
  signed : bool;
  fp : bool;  (** rt (and rt2) are SIMD/FP registers *)
  wide : bool;  (** general rt is an X register *)
  rt : int;
  rt2 : int option;
  rn : int;
  addr : addressing;
  defs_extra : int list;  (** other general registers written (exclusive-store status) *)
}

type movw = N | Z | K

type t =
  | B of int
  | Bl of int
  | Bcond of int * int  (** condition, target *)
  | Cb of { nz : bool; sf : bool; rt : int; target : int }
  | Tb of { nz : bool; rt : int; bitno : int; target : int }
  | Br of { link : bool; rn : int; rm : int option; mnem : string }
  | Ret of string
  | Adr of { page : bool; rd : int; target : int }  (** target offset (page-aligned for ADRP) *)
  | Addi of { sub : bool; s : bool; sf : bool; rd : int; rn : int; imm : int }
  | Movw of { op : movw; sf : bool; rd : int; imm : int; shift : int }
  | Logi of { op : int; sf : bool; rd : int; rn : int; imm : int64 }  (** and orr eor ands *)
  | Movr of { sf : bool; rd : int; rm : int }  (** orr rd, zr, rm *)
  | Pacd of { mnem : string; rd : int }  (** pointer authentication on data: value kept *)
  | Mem of mem
  | Exc of { mnem : string; imm : int }  (** svc, hvc, smc, brk, hlt *)
  | Other of { mnem : string; defs : int list }
  | Udf of int
  | Unknown

let conds = [| "eq"; "ne"; "hs"; "lo"; "mi"; "pl"; "vs"; "vc"; "hi"; "ls"; "ge"; "lt"; "gt"; "le"; "al"; "nv" |]

(* DecodeBitMasks for logical immediates (Arm ARM shared pseudocode). *)
let decode_bit_masks ~sf ~n ~imms ~immr =
  let x = (n lsl 6) lor (lnot imms land 0x3f) in
  let rec hsb v i = if i < 0 then -1 else if v land (1 lsl i) <> 0 then i else hsb v (i - 1) in
  let len = hsb x 6 in
  if len < 1 || ((not sf) && n = 1) then None
  else
    let levels = (1 lsl len) - 1 in
    let s = imms land levels and r = immr land levels in
    if s = levels then None
    else
      let esize = 1 lsl len in
      let ones = Int64.(sub (shift_left 1L (s + 1)) 1L) in
      let emask = if esize = 64 then -1L else Int64.(sub (shift_left 1L esize) 1L) in
      let rot =
        if r = 0 then ones
        else Int64.(logand emask (logor (shift_right_logical ones r) (shift_left ones (esize - r))))
      in
      let datasize = if sf then 64 else 32 in
      let rec rep acc k = if k >= datasize then acc else rep (Int64.logor acc (Int64.shift_left rot k)) (k + esize) in
      let v = rep 0L 0 in
      Some (if sf then v else Int64.logand v 0xffffffffL)

let defs_rd rd = if rd = 31 then [] else [ rd ]

(* ---- data processing, immediate ---- *)
let dp_imm pc w =
  let rd = bits w 4 0 and rn = bits w 9 5 and sf = bit w 31 = 1 in
  match bits w 25 23 with
  | 0 | 1 ->
      let imm = sext ((bits w 23 5 lsl 2) lor bits w 30 29) 21 in
      if bit w 31 = 1 then Adr { page = true; rd; target = (pc land lnot 0xfff) + (imm lsl 12) }
      else Adr { page = false; rd; target = pc + imm }
  | 2 ->
      let imm = bits w 21 10 lsl (if bit w 22 = 1 then 12 else 0) in
      let s = bit w 29 = 1 in
      Addi { sub = bit w 30 = 1; s; sf; rd; rn; imm }
  | 3 -> Other { mnem = "addg/subg"; defs = [ rd ] }
  | 4 -> (
      match decode_bit_masks ~sf ~n:(bit w 22) ~imms:(bits w 15 10) ~immr:(bits w 21 16) with
      | None -> Unknown
      | Some imm -> Logi { op = bits w 30 29; sf; rd; rn; imm })
  | 5 -> (
      let imm = bits w 20 5 and shift = bits w 22 21 * 16 in
      match bits w 30 29 with
      | 0 -> Movw { op = N; sf; rd; imm; shift }
      | 2 -> Movw { op = Z; sf; rd; imm; shift }
      | 3 -> Movw { op = K; sf; rd; imm; shift }
      | _ -> Unknown)
  | 6 when bits w 30 29 = 3 -> Unknown
  | 6 -> Other { mnem = [| "sbfm"; "bfm"; "ubfm" |].(bits w 30 29); defs = defs_rd rd }
  | _ -> Other { mnem = "extr"; defs = defs_rd rd }

(* ---- branches, exceptions, system ---- *)
let hint_name crm op2 =
  match (crm, op2) with
  | 0, 0 -> "nop" | 0, 1 -> "yield" | 0, 2 -> "wfe" | 0, 3 -> "wfi" | 0, 4 -> "sev" | 0, 5 -> "sevl"
  | 0, 7 -> "xpaclri" | 1, 0 -> "pacia1716" | 1, 2 -> "pacib1716" | 1, 4 -> "autia1716" | 1, 6 -> "autib1716"
  | 3, 0 -> "paciaz" | 3, 1 -> "paciasp" | 3, 2 -> "pacibz" | 3, 3 -> "pacibsp" | 3, 4 -> "autiaz"
  | 3, 5 -> "autiasp" | 3, 6 -> "autibz" | 3, 7 -> "autibsp" | 2, 0 -> "esb" | 2, 1 -> "psb" | 2, 2 -> "tsb"
  | 2, 4 -> "csdb" | 4, _ -> "bti"
  | _ -> Printf.sprintf "hint#%d" ((crm lsl 3) lor op2)

let branch_sys pc w =
  if bits w 30 26 = 0b00101 then
    let target = pc + (sext (bits w 25 0) 26 lsl 2) in
    if bit w 31 = 1 then Bl target else B target
  else if bits w 31 24 = 0b01010100 && bit w 4 = 0 then Bcond (bits w 3 0, pc + (sext (bits w 23 5) 19 lsl 2))
  else if bits w 30 25 = 0b011010 then
    Cb { nz = bit w 24 = 1; sf = bit w 31 = 1; rt = bits w 4 0; target = pc + (sext (bits w 23 5) 19 lsl 2) }
  else if bits w 30 25 = 0b011011 then
    Tb
      {
        nz = bit w 24 = 1;
        rt = bits w 4 0;
        bitno = (bit w 31 lsl 5) lor bits w 23 19;
        target = pc + (sext (bits w 18 5) 14 lsl 2);
      }
  else if bits w 31 25 = 0b1101011 then begin
    let opc = bits w 24 21 and op3 = bits w 15 10 and rn = bits w 9 5 and op4 = bits w 4 0 in
    let key = if bit w 10 = 1 then "b" else "a" in
    match opc with
    | 0 when op3 = 0 && op4 = 0 -> Br { link = false; rn; rm = None; mnem = "br" }
    | 0 when op3 lsr 1 = 1 && op4 = 31 -> Br { link = false; rn; rm = None; mnem = "bra" ^ key ^ "z" }
    | 1 when op3 = 0 && op4 = 0 -> Br { link = true; rn; rm = None; mnem = "blr" }
    | 1 when op3 lsr 1 = 1 && op4 = 31 -> Br { link = true; rn; rm = None; mnem = "blra" ^ key ^ "z" }
    | 2 when op3 = 0 && op4 = 0 -> Ret (if rn = 30 then "ret" else Printf.sprintf "ret x%d" rn)
    | 2 when op3 lsr 1 = 1 && rn = 31 && op4 = 31 -> Ret ("reta" ^ key)
    | 4 -> Ret "eret"
    | 8 when op3 lsr 1 = 1 -> Br { link = false; rn; rm = Some op4; mnem = "bra" ^ key }
    | 9 when op3 lsr 1 = 1 -> Br { link = true; rn; rm = Some op4; mnem = "blra" ^ key }
    | _ -> Unknown
  end
  else if bits w 31 24 = 0b11010100 then
    let imm = bits w 20 5 in
    match (bits w 23 21, bits w 1 0) with
    | 0, 1 -> Exc { mnem = "svc"; imm }
    | 0, 2 -> Exc { mnem = "hvc"; imm }
    | 0, 3 -> Exc { mnem = "smc"; imm }
    | 1, 0 -> Exc { mnem = "brk"; imm }
    | 2, 0 -> Exc { mnem = "hlt"; imm }
    | _ -> Unknown
  else if bits w 31 22 = 0b1101010100 then begin
    let l = bit w 21 and op0 = bits w 20 19 and crn = bits w 15 12 and crm = bits w 11 8 and op2 = bits w 7 5 in
    let rt = bits w 4 0 in
    let sysreg () = Printf.sprintf "s%d_%d_c%d_c%d_%d" op0 (bits w 18 16) crn crm op2 in
    if l = 1 && op0 >= 2 then Other { mnem = "mrs " ^ sysreg (); defs = defs_rd rt }
    else if l = 0 && op0 >= 2 then Other { mnem = "msr " ^ sysreg (); defs = [] }
    else if op0 = 1 then Other { mnem = (if l = 1 then "sysl" else "sys"); defs = (if l = 1 then defs_rd rt else []) }
    else if crn = 2 then Other { mnem = hint_name crm op2; defs = [] }
    else if crn = 3 then
      Other { mnem = (match op2 with 2 -> "clrex" | 4 -> "dsb" | 5 -> "dmb" | 6 -> "isb" | _ -> "barrier"); defs = [] }
    else if crn = 4 then Other { mnem = "msr-imm"; defs = [] }
    else Unknown
  end
  else Unknown

(* ---- loads and stores ---- *)
let reg_name ~fp ~wide ~size r =
  if fp then Printf.sprintf "%c%d" (match size with 1 -> 'b' | 2 -> 'h' | 4 -> 's' | 8 -> 'd' | _ -> 'q') r
  else if r = 31 then if wide then "xzr" else "wzr"
  else Printf.sprintf "%c%d" (if wide then 'x' else 'w') r

let log2 n = match n with 1 -> 0 | 2 -> 1 | 4 -> 2 | 8 -> 3 | 16 -> 4 | _ -> 0

let mem ?(rt2 = None) ?(signed = false) ?(fp = false) ?(defs_extra = []) m_mnem ~load ~size ~wide ~rt ~rn addr =
  Mem { m_mnem; load; size; signed; fp; wide; rt; rt2; rn; addr; defs_extra }

let ldst pc w =
  let rt = bits w 4 0 and rn = bits w 9 5 and v = bit w 26 = 1 in
  if bits w 29 27 = 0b011 && bit w 24 = 0 then begin
    (* load register (literal) *)
    let target = pc + (sext (bits w 23 5) 19 lsl 2) in
    match (bits w 31 30, v) with
    | 0, false -> mem "ldr" ~load:true ~size:4 ~wide:false ~rt ~rn:(-1) (Lit target)
    | 1, false -> mem "ldr" ~load:true ~size:8 ~wide:true ~rt ~rn:(-1) (Lit target)
    | 2, false -> mem "ldrsw" ~signed:true ~load:true ~size:4 ~wide:true ~rt ~rn:(-1) (Lit target)
    | _, false -> Other { mnem = "prfm"; defs = [] }
    | o, true -> mem "ldr" ~fp:true ~load:true ~size:(4 lsl o) ~wide:false ~rt ~rn:(-1) (Lit target)
  end
  else if bits w 29 27 = 0b101 then begin
    (* load/store pair *)
    let opc = bits w 31 30 and l = bit w 22 = 1 and rt2 = bits w 14 10 in
    let size, signed, wide =
      if v then (4 lsl opc, false, false) else match opc with 0 -> (4, false, false) | 1 -> (4, true, true) | _ -> (8, false, true)
    in
    let imm = sext (bits w 21 15) 7 * size in
    let addr = match bits w 24 23 with 1 -> Post imm | 3 -> Pre imm | _ -> Off imm in
    let base = if bits w 24 23 = 0 then "np" else "p" in
    let m = (if l then "ld" else "st") ^ base ^ if signed && l then "sw" else "" in
    if (not v) && opc = 1 && not l then Other { mnem = "stgp"; defs = [] }
    else if (v && opc = 3) || ((not v) && opc = 3) || ((not v) && opc = 1 && bits w 24 23 = 0) then Unknown
    else mem m ~rt2:(Some rt2) ~signed ~fp:v ~load:l ~size ~wide ~rt ~rn addr
  end
  else if bits w 29 27 = 0b111 then begin
    let size = bits w 31 30 and opc = bits w 23 22 in
    let bytes = if v && size = 0 && opc >= 2 then 16 else 1 lsl size in
    (* what the general-register forms load: store, load zero-extended,
       load sign-extended to X, to W *)
    let gen () =
      let suffix = match size with 0 -> "b" | 1 -> "h" | _ -> "" in
      match opc with
      | 0 -> Some ("st", suffix, false, false, size = 3)
      | 1 -> Some ("ld", suffix, true, false, size = 3)
      | 2 when size = 3 -> None (* prfm *)
      | 2 -> Some ("ld", "s" ^ (match size with 0 -> "b" | 1 -> "h" | _ -> "w"), true, true, true)
      | _ when size <= 1 -> Some ("ld", "s" ^ suffix, true, true, false)
      | _ -> None
    in
    let shape () = if v then Some ((if opc land 1 = 1 then "ld" else "st"), "", opc land 1 = 1, false, false) else gen () in
    let build kind addr =
      match shape () with
      | None -> Other { mnem = "prfm"; defs = [] }
      | Some (dir, suffix, load, signed, wide) ->
          let m = match kind with `R -> dir ^ "r" ^ suffix | `U -> dir ^ "ur" ^ suffix | `T -> dir ^ "tr" ^ suffix in
          mem m ~signed ~fp:v ~load ~size:bytes ~wide ~rt ~rn addr
    in
    if bit w 24 = 1 then build `R (Off (bits w 21 10 lsl log2 bytes))
    else if bit w 21 = 0 then
      let imm = sext (bits w 20 12) 9 in
      match bits w 11 10 with
      | 0 -> build `U (Off imm)
      | 1 -> build `R (Post imm)
      | 2 -> build `T (Off imm)
      | _ -> build `R (Pre imm)
    else
      match bits w 11 10 with
      | 2 ->
          let option = bits w 15 13 and s = bit w 12 in
          let ext = match option with 2 -> "uxtw" | 3 -> "lsl" | 6 -> "sxtw" | 7 -> "sxtx" | _ -> "?" in
          if ext = "?" then Unknown else
          build `R (Reg { rm = bits w 20 16; ext; amount = (if s = 1 then log2 bytes else 0); shown = s = 1 })
      | 0 ->
          (* atomic memory operations (ldadd, swp, ldapr, ...) *)
          if v then Unknown
          else
            mem "atomic" ~load:true ~size:(1 lsl size) ~wide:(size = 3) ~rt ~rn (Off 0)
              ~defs_extra:[]
      | _ when size = 3 && not v ->
          (* ldraa / ldrab: offset S:imm9 scaled by 8 *)
          let imm = sext ((bit w 22 lsl 9) lor bits w 20 12) 10 lsl 3 in
          let m = if bit w 23 = 1 then "ldrab" else "ldraa" in
          mem m ~load:true ~size:8 ~wide:true ~rt ~rn (if bit w 11 = 1 then Pre imm else Off imm)
      | _ -> Unknown
  end
  else if bits w 29 24 = 0b001000 && not v then begin
    (* exclusive and ordered loads/stores, compare-and-swap *)
    let size = 1 lsl bits w 31 30 and l = bit w 22 = 1 and o2 = bit w 23 and o1 = bit w 21 in
    let rs = bits w 20 16 in
    let m = match (o2, l, o1) with
      | 0, false, 0 -> "stxr" | 0, true, 0 -> "ldxr" | 0, false, 1 -> "stxp" | 0, true, 1 -> "ldxp"
      | 1, false, 0 -> "stlr" | 1, true, 0 -> "ldar" | _ -> "cas" in
    let extra = if m = "stxr" || m = "stxp" || m = "cas" then defs_rd rs else [] in
    mem m ~load:l ~size ~wide:(size = 8) ~rt ~rn (Off 0) ~defs_extra:extra
  end
  else if bits w 29 24 = 0b011001 && bit w 21 = 0 && bits w 11 10 = 0 && not v then begin
    (* stlur / ldapur *)
    let size = bits w 31 30 and opc = bits w 23 22 in
    let imm = sext (bits w 20 12) 9 in
    match opc with
    | 0 -> mem "stlur" ~load:false ~size:(1 lsl size) ~wide:(size = 3) ~rt ~rn (Off imm)
    | 1 -> mem "ldapur" ~load:true ~size:(1 lsl size) ~wide:(size = 3) ~rt ~rn (Off imm)
    | o -> mem "ldapurs" ~signed:true ~load:true ~size:(1 lsl size) ~wide:(o = 2) ~rt ~rn (Off imm)
  end
  else if bit w 31 = 0 && bits w 29 25 = 0b00110 && v then
    (* SIMD load/store multiple or single structures; post-index writes rn *)
    let l = bit w 22 = 1 in
    mem (if l then "ld1-4" else "st1-4") ~fp:true ~load:l ~size:0 ~wide:false ~rt ~rn
      (if bit w 23 = 1 then Post 0 else Off 0)
  else Unknown

(* ---- data processing, register ---- *)
let dp_reg w =
  let rd = bits w 4 0 and rn = bits w 9 5 and rm = bits w 20 16 and sf = bit w 31 = 1 in
  if bit w 28 = 0 then
    if bit w 24 = 0 then begin
      let opc = bits w 30 29 and n = bit w 21 in
      if opc = 1 && n = 0 && bits w 15 10 = 0 && rn = 31 && bits w 23 22 = 0 then Movr { sf; rd; rm }
      else
        let names = [| [| "and"; "orr"; "eor"; "ands" |]; [| "bic"; "orn"; "eon"; "bics" |] |] in
        Other { mnem = names.(n).(opc); defs = defs_rd rd }
    end
    else if bit w 21 = 0 then
      Other { mnem = [| "add"; "adds"; "sub"; "subs" |].(bits w 30 29); defs = defs_rd rd }
    else
      (* extended register: rd is SP unless flags are set *)
      let s = bit w 29 = 1 in
      Other { mnem = [| "add"; "adds"; "sub"; "subs" |].(bits w 30 29) ^ "x"; defs = (if s && rd = 31 then [] else [ rd ]) }
  else
    match bits w 24 21 with
    | 0 -> Other { mnem = "adc/sbc"; defs = defs_rd rd }
    | 2 -> Other { mnem = "ccmp"; defs = [] }
    | 4 -> Other { mnem = [| "csel"; "csinc"; "csinv"; "csneg" |].((bit w 30 lsl 1) lor bit w 10); defs = defs_rd rd }
    | 6 when bit w 30 = 1 ->
        let op = bits w 15 10 in
        if bits w 20 16 = 1 then
          let names = [| "pacia"; "pacib"; "pacda"; "pacdb"; "autia"; "autib"; "autda"; "autdb" |] in
          if op < 8 then Pacd { mnem = names.(op); rd }
          else if op >= 8 && op < 16 then Pacd { mnem = names.(op - 8) ^ "z"; rd }
          else if op = 16 || op = 17 then Pacd { mnem = (if op = 16 then "xpaci" else "xpacd"); rd }
          else Unknown
        else Other { mnem = [| "rbit"; "rev16"; "rev32"; "rev"; "clz"; "cls" |].(min op 5); defs = defs_rd rd }
    | 6 -> Other { mnem = "dp2"; defs = defs_rd rd }
    | x when x >= 8 -> Other { mnem = "madd"; defs = defs_rd rd }
    | _ -> Other { mnem = "dp"; defs = [] }

(* ---- SIMD and floating point: only general-register results matter ---- *)
let simd w =
  let rd = bits w 4 0 in
  let to_gpr_conv = bit w 30 = 0 && bits w 28 24 = 0b11110 && bit w 21 = 1 && bits w 15 10 = 0 in
  if to_gpr_conv && List.mem (bits w 18 16) [ 0; 1; 4; 5; 6 ] then Other { mnem = "fcvt/fmov->gpr"; defs = defs_rd rd }
  else if w land 0xbfe0fc00 = 0x0e002c00 || w land 0xbfe0fc00 = 0x0e003c00 then Other { mnem = "smov/umov"; defs = defs_rd rd }
  else Other { mnem = "simd"; defs = [] }

let decode pc w =
  if w lsr 16 = 0 then Udf (w land 0xffff)
  else
    let op0 = bits w 28 25 in
    if op0 land 0b1110 = 0b1000 then dp_imm pc w
    else if op0 land 0b1110 = 0b1010 then branch_sys pc w
    else if op0 land 0b0101 = 0b0100 then ldst pc w
    else if op0 land 0b0111 = 0b0101 then dp_reg w
    else if op0 land 0b0111 = 0b0111 then simd w
    else Unknown

(* General registers an instruction writes (31 = SP where it means SP). *)
let defs = function
  | Bl _ -> [ 30 ]
  | Br { link = true; _ } -> [ 30 ]
  | Adr { rd; _ } -> [ rd ]
  | Addi { s; rd; _ } -> if s && rd = 31 then [] else [ rd ]
  | Movw { rd; _ } | Movr { rd; _ } -> defs_rd rd
  | Logi { op; rd; _ } -> if op = 3 && rd = 31 then [] else [ rd ] (* ands rd=31 is tst; others may write SP *)
  | Pacd _ -> []
  | Mem m ->
      let wb = match m.addr with Pre _ | Post _ -> if m.rn >= 0 then [ m.rn ] else [] | _ -> [] in
      let rts = if m.load && not m.fp then defs_rd m.rt @ (match m.rt2 with Some r -> defs_rd r | None -> []) else [] in
      wb @ rts @ m.defs_extra
  | Other { defs; _ } -> defs
  | _ -> []

(* How control leaves an instruction. *)
type flow = Next | Jump of int | Branch of int (* conditional *) | Call of int | Stop | Indirect

let flow = function
  | B t -> Jump t
  | Bcond (14, t) -> Jump t
  | Bcond (_, t) | Cb { target = t; _ } | Tb { target = t; _ } -> Branch t
  | Bl t -> Call t
  | Br { link = false; _ } -> Indirect
  | Ret _ | Udf _ | Unknown -> Stop
  | Exc { mnem = "brk" | "hlt"; _ } -> Stop
  | _ -> Next

(* ---- printing, in llvm-objdump's syntax for the classes decoded fully ---- *)
let hex v = if v < 0 then Printf.sprintf "#-0x%x" (-v) else Printf.sprintf "#0x%x" v
let xr ?(sp = false) sf r = if r = 31 then (if sp then (if sf then "sp" else "wsp") else if sf then "xzr" else "wzr") else Printf.sprintf "%c%d" (if sf then 'x' else 'w') r
let base r = if r = 31 then "sp" else Printf.sprintf "x%d" r

let to_string = function
  | B t -> Printf.sprintf "b\t0x%x" t
  | Bl t -> Printf.sprintf "bl\t0x%x" t
  | Bcond (c, t) -> Printf.sprintf "b.%s\t0x%x" conds.(c) t
  | Cb { nz; sf; rt; target } -> Printf.sprintf "%s\t%s, 0x%x" (if nz then "cbnz" else "cbz") (xr sf rt) target
  | Tb { nz; rt; bitno; target } ->
      Printf.sprintf "%s\t%s, %s, 0x%x" (if nz then "tbnz" else "tbz") (xr (bitno >= 32) rt) (hex bitno) target
  | Br { mnem; rn; rm = None; _ } -> Printf.sprintf "%s\tx%d" mnem rn
  | Br { mnem; rn; rm = Some m; _ } -> Printf.sprintf "%s\tx%d, %s" mnem rn (base m)
  | Ret m -> m
  | Adr { page; rd; target } -> Printf.sprintf "%s\tx%d, 0x%x" (if page then "adrp" else "adr") rd target
  | Addi { sub; s; sf; rd; rn; imm } ->
      if (not sub) && (not s) && imm = 0 && (rd = 31 || rn = 31) then Printf.sprintf "mov\t%s, %s" (xr ~sp:true sf rd) (xr ~sp:true sf rn)
      else if s && rd = 31 then Printf.sprintf "%s\t%s, %s" (if sub then "cmp" else "cmn") (xr ~sp:true sf rn) (hex imm)
      else
        Printf.sprintf "%s%s\t%s, %s, %s" (if sub then "sub" else "add") (if s then "s" else "")
          (if s then xr sf rd else xr ~sp:true sf rd) (xr ~sp:true sf rn) (hex imm)
  | Movw { op; sf; rd; imm; shift } ->
      let m = match op with N -> "movn" | Z -> "movz" | K -> "movk" in
      Printf.sprintf "%s\t%s, %s%s" m (xr sf rd) (hex imm) (if shift > 0 then Printf.sprintf ", lsl #%d" shift else "")
  | Logi { op; sf; rd; rn; imm } ->
      Printf.sprintf "%s\t%s, %s, #0x%Lx" [| "and"; "orr"; "eor"; "ands" |].(op) (xr ~sp:(op <> 3) sf rd) (xr sf rn) imm
  | Movr { sf; rd; rm } -> Printf.sprintf "mov\t%s, %s" (xr sf rd) (xr sf rm)
  | Pacd { mnem; rd } -> Printf.sprintf "%s\tx%d" mnem rd
  | Exc { mnem; imm } -> Printf.sprintf "%s\t%s" mnem (hex imm)
  | Udf i -> Printf.sprintf "udf\t#%d" i
  | Unknown -> "<unknown>"
  | Other { mnem; _ } -> mnem
  | Mem m ->
      let r x = reg_name ~fp:m.fp ~wide:m.wide ~size:m.size x in
      let regs = match m.rt2 with Some r2 -> r m.rt ^ ", " ^ r r2 | None -> r m.rt in
      let a =
        match m.addr with
        | Off 0 -> Printf.sprintf "[%s]" (base m.rn)
        | Off i -> Printf.sprintf "[%s, %s]" (base m.rn) (hex i)
        | Pre i -> Printf.sprintf "[%s, %s]!" (base m.rn) (hex i)
        | Post i -> Printf.sprintf "[%s], %s" (base m.rn) (hex i)
        | Lit t -> Printf.sprintf "0x%x" t
        | Reg { rm; ext; amount; shown } ->
            let rmn = if ext = "lsl" || ext = "sxtx" then xr true rm else xr false rm in
            if ext = "lsl" && not shown then Printf.sprintf "[%s, %s]" (base m.rn) rmn
            else if shown then Printf.sprintf "[%s, %s, %s #%d]" (base m.rn) rmn ext amount
            else Printf.sprintf "[%s, %s, %s]" (base m.rn) rmn ext
      in
      Printf.sprintf "%s\t%s, %s" m.m_mnem regs a
