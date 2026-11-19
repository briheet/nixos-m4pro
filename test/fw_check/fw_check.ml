(* Compare Fw.A64 with llvm-objdump on the fully decoded classes. *)
let () =
  let img = Fw.Image.load Sys.argv.(1) Fw.Image.fw_27_2 in
  let text = Fw.Image.text img in
  let ref_ = Hashtbl.create 100000 in
  In_channel.with_open_text Sys.argv.(2) (fun ic ->
    In_channel.input_lines ic |> List.iter (fun l ->
      match String.index_opt l '\t' with
      | Some t when t > 1 && String.contains (String.sub l 0 t) ':' ->
          let addr = String.trim (String.sub l 0 t) in
          let addr = String.sub addr 0 (String.length addr - 1) in
          let a = try int_of_string ("0x" ^ addr) with _ -> -1 in
          let s = String.sub l (t + 1) (String.length l - t - 1) in
          let s = match String.index_opt s '<' with Some i when i > 0 && s.[i-1] = ' ' -> String.sub s 0 (i-1) | _ -> s in
          let s = match String.index_opt s '/' with Some i when i > 0 -> String.trim (String.sub s 0 i) | _ -> String.trim s in
          Hashtbl.replace ref_ a s
      | _ -> ()));
  let total = ref 0 and bad = ref 0 and by = Hashtbl.create 16 in
  for i = 0 to String.length text.data / 4 - 1 do
    let pc = i * 4 in
    let w = Int32.to_int (String.get_int32_le text.data pc) land 0xffffffff in
    let d = Fw.A64.decode pc w in
    let full = match d with
      | Fw.A64.B _ | Bl _ | Bcond _ | Cb _ | Tb _ | Adr _ | Mem _ | Movr _ | Br _ | Ret _ -> true | _ -> false in
    let full = full && (match d with Mem { m_mnem = "atomic" | "ld1-4" | "st1-4" | "stxr" | "ldxr" | "stxp" | "ldxp" | "cas" | "stlr" | "ldar"; _ } -> false | _ -> true) in
    match Hashtbl.find_opt ref_ pc with
    | Some r when full ->
        incr total;
        let mine = Fw.A64.to_string d in
        if mine <> r then begin
          incr bad;
          let k = match d with Mem m -> m.m_mnem | _ -> List.hd (String.split_on_char '\t' mine) in
          let n = try Hashtbl.find by k with Not_found -> 0 in
          Hashtbl.replace by k (n + 1);
          if n < 3 then Printf.printf "%x: mine %S  llvm %S\n" pc mine r
        end
    | Some r when (d = Fw.A64.Unknown) <> (r = "<unknown>") && not (String.length r > 3 && String.sub r 0 3 = "udf") ->
        if !bad < 400 then Printf.printf "%x: unknown mismatch mine %S llvm %S\n" pc (Fw.A64.to_string d) r; incr bad
    | _ -> ()
  done;
  Printf.printf "checked %d, mismatches %d\n" !total !bad;
  Hashtbl.iter (fun k n -> Printf.printf "  %s: %d\n" k n) by
