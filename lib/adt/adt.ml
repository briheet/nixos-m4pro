(* Apple device tree (ADT), as iBoot hands it to m1n1.

   A node is a u32 property count, a u32 child count, the properties, then
   the children. A property is a 32-byte NUL-padded name, a u32 length
   whose top bit is a flag, and the value padded to 4 bytes. Integers are
   little-endian.

   Addresses follow the usual cell rules: a node's "reg" entries use its
   parent's #address-cells and #size-cells, and each ancestor with "ranges"
   maps child bus addresses to its own parent's space. Cells are u32, low
   cell first. This matches proxyclient/m1n1/adt.py in m1n1. *)

type node = {
  name : string;
  props : (string * string) list;
  children : node list;
}

let cstring s = match String.index_opt s '\000' with Some i -> String.sub s 0 i | None -> s

let u32_at s off = Int32.to_int (String.get_int32_le s off) land 0xffffffff

let parse data =
  let pos = ref 0 in
  let take n =
    if !pos + n > String.length data then failwith "adt: truncated";
    let v = String.sub data !pos n in
    pos := !pos + n;
    v
  in
  let u32 () = u32_at (take 4) 0 in
  let rec node () =
    let nprops = u32 () in
    let nchildren = u32 () in
    let props =
      List.init nprops (fun _ ->
          let name = cstring (take 32) in
          let size = u32 () land 0x7fffffff in
          let value = take size in
          ignore (take ((4 - (size land 3)) land 3));
          (name, value))
    in
    let children = List.init nchildren (fun _ -> node ()) in
    let name = match List.assoc_opt "name" props with Some v -> cstring v | None -> "" in
    { name; props; children }
  in
  node ()

let prop n name = List.assoc_opt name n.props

let prop_exn n name =
  match prop n name with Some v -> v | None -> failwith (Printf.sprintf "adt: %s has no %s" n.name name)

let prop_u32 n name = Option.map (fun v -> u32_at v 0) (prop n name)

let strings n name =
  match prop n name with
  | None -> []
  | Some v -> String.split_on_char '\000' v |> List.filter (( <> ) "")

let compatible n = strings n "compatible"

(* The nodes from the root down to [path], e.g. "/arm-io/pmgr". *)
let lookup root path =
  let parts = String.split_on_char '/' path |> List.filter (( <> ) "") in
  let rec go acc node = function
    | [] -> Some (List.rev (node :: acc))
    | p :: rest -> (
        match List.find_opt (fun c -> c.name = p) node.children with
        | Some c -> go (node :: acc) c rest
        | None -> None)
  in
  go [] root parts

let lookup_exn root path =
  match lookup root path with Some l -> l | None -> failwith ("adt: no node " ^ path)

let node_at root path = List.nth (lookup_exn root path) (List.length (lookup_exn root path) - 1)

(* [cells s off n] reads n u32 cells low-first as one integer. *)
let cells s off n =
  let rec go i acc = if i < 0 then acc else go (i - 1) ((acc lsl 32) lor u32_at s (off + (4 * i))) in
  if n > 2 then failwith "adt: more than 2 cells";
  go (n - 1) 0

let address_cells n = Option.value (prop_u32 n "#address-cells") ~default:2
let size_cells n = Option.value (prop_u32 n "#size-cells") ~default:2

(* Walk up from the parent through every ancestor that has "ranges". *)
let translate ancestors addr =
  let rec go addr = function
    | [] -> addr
    | [ _root ] -> addr
    | node :: (parent :: _ as rest) -> (
        match prop node "ranges" with
        | None -> addr
        | Some r ->
            let ac = address_cells node and sc = size_cells node and pac = address_cells parent in
            let entry = 4 * (ac + pac + sc) in
            let rec find i =
              if (i + 1) * entry > String.length r then addr
              else
                let bus = cells r (i * entry) ac in
                let par = cells r ((i * entry) + (4 * ac)) pac in
                let size = cells r ((i * entry) + (4 * (ac + pac))) sc in
                if bus <= addr && addr < bus + size then addr - bus + par else find (i + 1)
            in
            go (find 0) rest)
  in
  go addr (List.rev ancestors)

(* [reg root path i] is the CPU physical address and size of reg entry i. *)
let reg root path i =
  let chain = lookup_exn root path in
  let node = List.nth chain (List.length chain - 1) in
  let parent = List.nth chain (List.length chain - 2) in
  let ac = address_cells parent and sc = size_cells parent in
  let r = prop_exn node "reg" in
  let entry = 4 * (ac + sc) in
  if (i + 1) * entry > String.length r then
    failwith (Printf.sprintf "adt: %s has no reg %d" path i);
  let addr = cells r (i * entry) ac in
  let size = cells r ((i * entry) + (4 * ac)) sc in
  (translate (List.filteri (fun j _ -> j < List.length chain - 1) chain) addr, size)

let reg_count root path =
  let chain = lookup_exn root path in
  let node = List.nth chain (List.length chain - 1) in
  let parent = List.nth chain (List.length chain - 2) in
  match prop node "reg" with
  | None -> 0
  | Some r -> String.length r / (4 * (address_cells parent + size_cells parent))

let of_file path = parse (In_channel.with_open_bin path In_channel.input_all)
