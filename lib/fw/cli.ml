(* nixos-m4pro fw DIR COMMAND ...: the firmware dumped by gpu-probe in DIR. *)

let usage () =
  prerr_endline "nixos-m4pro fw DIR summary            code coverage, functions, names";
  prerr_endline "nixos-m4pro fw DIR funcs [SUBSTR]     functions: address, size, name";
  prerr_endline "nixos-m4pro fw DIR func NAME|HEX      one function, disassembled and annotated";
  prerr_endline "nixos-m4pro fw DIR strings [SUBSTR]   strings and the functions using them";
  prerr_endline "nixos-m4pro fw DIR xref HEX           what references an image offset";
  prerr_endline "nixos-m4pro fw DIR leftover           code-looking ranges no function reached";
  prerr_endline "nixos-m4pro fw DIR disasm              every function, annotated (for grep)"

let contains s sub =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

let users p a =
  List.sort_uniq compare
    (List.filter_map (fun (pc, _) -> let f = p.Prog.owner.(pc / 4) in if f >= 0 then Some f else None) (Prog.refs_to p a))

let run = function
  | dir :: cmd ->
      let img = Image.load dir Image.fw_27_2 in
      let p = Prog.analyse img in
      (match cmd with
      | [ "summary" ] ->
          let c = Prog.coverage p in
          List.iter (fun (s : Image.segment) -> Printf.printf "%-18s %s +%#x\n" s.name (Image.pp_addr img s.off) (String.length s.data)) img.segments;
          let named = Hashtbl.length p.names in
          let left = List.fold_left (fun a (_, k) -> a + k) 0 c.leftover_code in
          Printf.printf "TEXT words %d: in functions %d (%.1f%%), padding %d, code-looking but unreached %d in %d ranges, rest data\n"
            c.words c.owned (100. *. float c.owned /. float c.words) c.padding left (List.length c.leftover_code);
          Printf.printf "functions %d (named %d), jump tables %d, strings %d\n" (Hashtbl.length p.funcs) named
            (Hashtbl.length p.jump_tables) (Hashtbl.length p.strings)
      | "funcs" :: rest ->
          let pat = match rest with [ s ] -> s | _ -> "" in
          Hashtbl.fold (fun e f acc -> (e, f) :: acc) p.funcs []
          |> List.sort compare
          |> List.iter (fun (e, (f : Prog.func)) ->
                 let n = Prog.name p e in
                 if contains n pat then
                   Printf.printf "%6x %5d %s%s\n" e f.words n (if f.returns then "" else "  [no return]"))
      | [ "func"; s ] -> (
          match Prog.find_func p s with Some e -> Prog.disasm p e | None -> Printf.printf "no function %s\n" s)
      | "strings" :: rest ->
          let pat = match rest with [ s ] -> s | _ -> "" in
          Hashtbl.fold (fun o s acc -> (o, s) :: acc) p.strings []
          |> List.sort compare
          |> List.iter (fun (o, s) ->
                 if contains s pat then
                   Printf.printf "%6x %S  <- %s\n" o s (String.concat " " (List.map (Prog.name p) (users p o))))
      | [ "xref"; h ] ->
          let a = int_of_string ("0x" ^ h) in
          List.iter
            (fun (pc, k) ->
              let kind = match k with Prog.Code_addr -> "addr" | Data_addr -> "addr" | Load n -> Printf.sprintf "R%d" n | Store n -> Printf.sprintf "W%d" n in
              let f = p.owner.(pc / 4) in
              Printf.printf "%6x %-4s %s\n" pc kind (if f >= 0 then Prog.name p f else "?"))
            (List.sort compare (Prog.refs_to p a));
          List.iter (fun pc -> Printf.printf "%6x call %s\n" pc (Prog.name p p.owner.(pc / 4))) (Hashtbl.find_all p.callers a)
      | [ "disasm" ] ->
          Hashtbl.fold (fun e _ acc -> e :: acc) p.funcs []
          |> List.sort compare
          |> List.iter (fun e -> Prog.disasm p e)
      | [ "leftover" ] ->
          List.iter (fun (s, k) -> Printf.printf "%6x %d words: %s\n" s k (A64.to_string (Prog.insn p s))) (Prog.coverage p).leftover_code
      | _ -> usage ())
  | _ -> usage ()
