(* Looking at firmware memory without knowing its layout yet.

   [hexdump] prints 8-byte words, marking those that are kernel-half
   addresses the snapshot can resolve. [graph] starts at an address and
   follows every such pointer breadth-first: the shape it prints (which
   offsets of which structure point where, and how far apart the targets
   are) is what a layout schema is fitted to, and it does not depend on any
   firmware version. *)

let u64 s off = Int64.to_int (String.get_int64_le s off)

let hex64 v = Printf.sprintf "%016Lx" (Int64.of_int v)

let resolvable snap v = Snapshot.is_kernel snap v && Snapshot.translate snap v <> None

let hexdump ?(out = print_string) snap va len =
  match Snapshot.read snap va len with
  | None -> out (Printf.sprintf "%s: not in the snapshot\n" (hex64 va))
  | Some s ->
      let b = Buffer.create (len * 4) in
      let words = String.length s / 8 in
      for w = 0 to words - 1 do
        if w mod 4 = 0 then Printf.bprintf b "%s +%04x:" (hex64 (va + (8 * w))) (8 * w);
        let v = u64 s (8 * w) in
        Printf.bprintf b " %s%s" (hex64 v) (if resolvable snap v then "*" else " ");
        if w mod 4 = 3 || w = words - 1 then Buffer.add_char b '\n'
      done;
      out (Buffer.contents b)

type edge = { from_va : int; offset : int; target : int }

(* Breadth-first from [root], reading [span] bytes of each node, up to
   [depth] levels and [limit] nodes. Returns the nodes in visiting order with
   their depth, and every pointer edge found. *)
let graph ?(span = 0x400) ?(depth = 3) ?(limit = 200) snap root =
  let seen = Hashtbl.create 256 and nodes = ref [] and edges = ref [] in
  let q = Queue.create () in
  Queue.add (root, 0) q;
  Hashtbl.add seen root ();
  while (not (Queue.is_empty q)) && List.length !nodes < limit do
    let va, d = Queue.pop q in
    nodes := (va, d) :: !nodes;
    match Snapshot.read snap va span with
    | None -> ()
    | Some s ->
        for w = 0 to (String.length s / 8) - 1 do
          let v = u64 s (8 * w) in
          if resolvable snap v then begin
            edges := { from_va = va; offset = 8 * w; target = v } :: !edges;
            if d < depth && not (Hashtbl.mem seen v) then begin
              Hashtbl.add seen v ();
              Queue.add (v, d + 1) q
            end
          end
        done
  done;
  (List.rev !nodes, List.rev !edges)

let print_graph ?(out = print_string) (nodes, edges) =
  let b = Buffer.create 4096 in
  List.iter
    (fun (va, d) ->
      Printf.bprintf b "%s%s\n" (String.make (2 * d) ' ') (hex64 va);
      List.iter
        (fun e ->
          if e.from_va = va then
            Printf.bprintf b "%s  +%04x -> %s\n" (String.make (2 * d) ' ') e.offset (hex64 e.target))
        edges)
    nodes;
  out (Buffer.contents b)
