(* Next-stage image for payload_run in upstream/m1n1/src/payload.c.
   The built m1n1.bin scans the bytes concatenated after itself. A gzip
   member is decompressed and then recognized. An uncompressed ARM64
   image stops that scan, so the devicetree has to follow the gzip, not
   sit behind a raw kernel. The devicetree has to match apple,<target>
   with the ADT target-type lowercased, which is apple,j614s on this
   Mac. kboot_prepare_dt requires a /memory node. kboot_boot then sets
   the entry to the kernel and x0 to the devicetree.
   The gzip writer emits one stored deflate block. tinf accepts that
   block. A distribution Image.gz uses Huffman blocks, which this host
   reader leaves untouched. *)

let expect_compatible = "apple,j614s"
let kernel_align = 2 * 1024 * 1024
let kernel_magic = 0x644d5241l
let initramfs_magic = "m1n1_initramfs"
let initrd_payload = "nixos-m4pro"

type handoff = {
  mutable has_kernel : bool;
  mutable kernel_image_size : int;
  mutable compatible : string list;
  mutable has_memory : bool;
  mutable initrd_bytes : int;
  mutable tso : bool;
  mutable chosen : (string * string) list;
}

let ready handoff = handoff.has_kernel && List.mem expect_compatible handoff.compatible

let empty () =
  {
    has_kernel = false;
    kernel_image_size = 0;
    compatible = [];
    has_memory = false;
    initrd_bytes = 0;
    tso = false;
    chosen = [];
  }

let crc_table =
  let table = Array.make 256 0l in
  for i = 0 to 255 do
    let c = ref (Int32.of_int i) in
    for _ = 0 to 7 do
      if Int32.logand !c 1l <> 0l then
        c := Int32.logxor (Int32.shift_right_logical !c 1) 0xedb88320l
      else c := Int32.shift_right_logical !c 1
    done;
    table.(i) <- !c
  done;
  table

let crc32 data =
  let c = ref 0xffffffffl in
  String.iter
    (fun ch ->
      let idx = Int32.to_int (Int32.logand (Int32.logxor !c (Int32.of_int (Char.code ch))) 0xffl) in
      c := Int32.logxor (Int32.shift_right_logical !c 8) crc_table.(idx))
    data;
  Int32.logxor !c 0xffffffffl

let gzip_store data =
  let len = String.length data in
  if len > 0xffff then failwith "payload: stored gzip block is limited to 65535 bytes";
  let out = Bytes.create (10 + 5 + len + 8) in
  Bytes.set out 0 '\x1f';
  Bytes.set out 1 '\x8b';
  Bytes.set out 2 '\x08';
  Bytes.set out 3 '\x00';
  Bytes.set out 8 '\x00';
  Bytes.set out 9 '\xff';
  Bytes.set out 10 '\x01';
  Bytes.set_uint16_le out 11 len;
  Bytes.set_uint16_le out 13 (len lxor 0xffff);
  Bytes.blit_string data 0 out 15 len;
  let foot = 15 + len in
  Bytes.set_int32_le out foot (crc32 data);
  Bytes.set_int32_le out (foot + 4) (Int32.of_int len);
  Bytes.to_string out

let le16 data i = Char.code data.[i] lor (Char.code data.[i + 1] lsl 8)

let le32 data i =
  Int32.logor (Int32.of_int (Char.code data.[i]))
    (Int32.logor
       (Int32.shift_left (Int32.of_int (Char.code data.[i + 1])) 8)
       (Int32.logor
          (Int32.shift_left (Int32.of_int (Char.code data.[i + 2])) 16)
          (Int32.shift_left (Int32.of_int (Char.code data.[i + 3])) 24)))

let le64 data i =
  let rec loop n acc =
    if n = 8 then acc
    else loop (n + 1) (Int64.logor acc (Int64.shift_left (Int64.of_int (Char.code data.[i + n])) (n * 8)))
  in
  loop 0 0L

let be32 data i =
  (Char.code data.[i] lsl 24)
  lor (Char.code data.[i + 1] lsl 16)
  lor (Char.code data.[i + 2] lsl 8)
  lor Char.code data.[i + 3]

let starts data pos magic =
  let n = String.length magic in
  pos + n <= String.length data && String.sub data pos n = magic

let gunzip_stored data pos =
  let len_all = String.length data in
  if pos + 18 > len_all || not (starts data pos "\x1f\x8b") then
    failwith "payload: gzip header is missing";
  if Char.code data.[pos + 2] <> 8 then failwith "payload: gzip method is not deflate";
  if Char.code data.[pos + 3] <> 0 then failwith "payload: gzip flag bits are not decoded by this host";
  if Char.code data.[pos + 10] <> 1 then failwith "payload: gzip uses a non-stored deflate block";
  let len = le16 data (pos + 11) in
  let nlen = le16 data (pos + 13) in
  if nlen <> (len lxor 0xffff) then failwith "payload: gzip stored length is corrupt";
  let payload_at = pos + 15 in
  let foot = payload_at + len in
  if foot + 8 > len_all then failwith "payload: gzip member is truncated";
  let plain = String.sub data payload_at len in
  if le32 data foot <> crc32 plain then failwith "payload: gzip crc mismatch";
  if le32 data (foot + 4) <> Int32.of_int len then failwith "payload: gzip isize mismatch";
  (plain, foot + 8 - pos)

let kernel_image =
  let image = Bytes.make 64 '\000' in
  Bytes.set_int32_le image 0 0x14000000l;
  Bytes.set_int64_le image 16 64L;
  Bytes.set_int32_le image 0x38 kernel_magic;
  Bytes.to_string image

let add_be32 buf n =
  let bytes = Bytes.create 4 in
  Bytes.set_int32_be bytes 0 (Int32.of_int n);
  Buffer.add_bytes buf bytes

let add_pad buf =
  while Buffer.length buf mod 4 <> 0 do
    Buffer.add_char buf '\000'
  done

let add_cstr buf text =
  Buffer.add_string buf text;
  Buffer.add_char buf '\000';
  add_pad buf

let add_prop buf ~nameoff ~value =
  add_be32 buf 3;
  add_be32 buf (String.length value);
  add_be32 buf nameoff;
  Buffer.add_string buf value;
  add_pad buf

let be32_string n =
  let bytes = Bytes.create 4 in
  Bytes.set_int32_be bytes 0 (Int32.of_int n);
  Bytes.to_string bytes

let device_tree ?(compatible = [ "apple,j614s"; "apple,t6040"; "apple,arm-platform" ]) () =
  let strings = Buffer.create 64 in
  let intern name =
    let offset = Buffer.length strings in
    Buffer.add_string strings name;
    Buffer.add_char strings '\000';
    offset
  in
  let compatible_off = intern "compatible" in
  let model_off = intern "model" in
  let device_type_off = intern "device_type" in
  let reg_off = intern "reg" in
  let addr_cells_off = intern "#address-cells" in
  let size_cells_off = intern "#size-cells" in
  let struct_buf = Buffer.create 256 in
  let node name =
    add_be32 struct_buf 1;
    add_cstr struct_buf name
  in
  node "";
  add_prop struct_buf ~nameoff:compatible_off ~value:(String.concat "\000" compatible ^ "\000");
  add_prop struct_buf ~nameoff:model_off
    ~value:"Apple MacBook Pro (14-inch, M4 Pro, 2024)\000";
  add_prop struct_buf ~nameoff:addr_cells_off ~value:(be32_string 2);
  add_prop struct_buf ~nameoff:size_cells_off ~value:(be32_string 2);
  node "memory";
  add_prop struct_buf ~nameoff:device_type_off ~value:"memory\000";
  (* Placeholder reg from configs/devicetree/upstream/t604x-j614-j616.dtsi.
     kboot_prepare_dt overwrites it from the live boot args. *)
  add_prop struct_buf ~nameoff:reg_off
    ~value:(be32_string 0x100 ^ be32_string 0 ^ be32_string 0x2 ^ be32_string 0);
  add_be32 struct_buf 2;
  add_be32 struct_buf 2;
  add_be32 struct_buf 9;
  let struct_bytes = Buffer.contents struct_buf in
  let string_bytes = Buffer.contents strings in
  let struct_off = 56 in
  let strings_off = struct_off + String.length struct_bytes in
  let total = strings_off + String.length string_bytes in
  let image = Bytes.make total '\000' in
  Bytes.set_int32_be image 0 0xd00dfeedl;
  Bytes.set_int32_be image 4 (Int32.of_int total);
  Bytes.set_int32_be image 8 (Int32.of_int struct_off);
  Bytes.set_int32_be image 12 (Int32.of_int strings_off);
  Bytes.set_int32_be image 16 40l;
  Bytes.set_int32_be image 20 17l;
  Bytes.set_int32_be image 24 16l;
  Bytes.set_int32_be image 32 (Int32.of_int (String.length string_bytes));
  Bytes.set_int32_be image 36 (Int32.of_int (String.length struct_bytes));
  Bytes.blit_string struct_bytes 0 image struct_off (String.length struct_bytes);
  Bytes.blit_string string_bytes 0 image strings_off (String.length string_bytes);
  Bytes.to_string image

let initramfs_wrap payload =
  let n = String.length payload in
  let out = Bytes.create (String.length initramfs_magic + 4 + n) in
  Bytes.blit_string initramfs_magic 0 out 0 (String.length initramfs_magic);
  Bytes.set_int32_le out (String.length initramfs_magic) (Int32.of_int n);
  Bytes.blit_string payload 0 out (String.length initramfs_magic + 4) n;
  Bytes.to_string out

let pack () =
  "tso=0\n" ^ "chosen.nixos-m4pro=handoff\n" ^ gzip_store kernel_image ^ device_tree ()
  ^ initramfs_wrap initrd_payload ^ "\000\000\000\000"

let align4 n = (n + 3) land lnot 3

let cstr_end data pos =
  let rec loop i =
    if pos + i >= String.length data then failwith "payload: devicetree string is unterminated"
    else if data.[pos + i] = '\000' then i
    else loop (i + 1)
  in
  loop 0

let split_strings data pos len =
  let rec loop i acc =
    if i >= len then List.rev acc
    else
      let rec stop j =
        if j >= len || data.[pos + j] = '\000' then j else stop (j + 1)
      in
      let j = stop i in
      let acc = if j > i then String.sub data (pos + i) (j - i) :: acc else acc in
      loop (j + 1) acc
  in
  loop 0 []

let note_fdt data pos state =
  if pos + 40 > String.length data || be32 data pos <> 0xd00dfeed then
    failwith "payload: fdt magic is missing";
  let total = be32 data (pos + 4) in
  if total < 40 || pos + total > String.length data then failwith "payload: fdt totalsize runs past the buffer";
  let struct_off = be32 data (pos + 8) in
  let strings_off = be32 data (pos + 12) in
  let struct_size = be32 data (pos + 36) in
  let struct_at = pos + struct_off in
  let limit = struct_at + struct_size in
  let rec walk p stack =
    if p + 4 > limit then ()
    else
      match be32 data p with
      | 1 ->
          let name_at = p + 4 in
          let name_len = cstr_end data name_at in
          let name = String.sub data name_at name_len in
          if name = "memory" then state.has_memory <- true;
          walk (name_at + align4 (name_len + 1)) (name :: stack)
      | 2 -> (match stack with _ :: rest -> walk (p + 4) rest | [] -> ())
      | 3 ->
          let len = be32 data (p + 4) in
          let nameoff = be32 data (p + 8) in
          let value = p + 12 in
          let pname_at = pos + strings_off + nameoff in
          let pname = String.sub data pname_at (cstr_end data pname_at) in
          (match stack with
          | "" :: _ when pname = "compatible" -> state.compatible <- split_strings data value len
          | "memory" :: _ when pname = "device_type" -> state.has_memory <- true
          | _ -> ());
          walk (value + align4 len) stack
      | 4 -> walk (p + 4) stack
      | 9 -> ()
      | _ -> ()
  in
  walk struct_at [];
  total

let take_var data pos =
  let eq_limit = pos + 65 in
  let rec find_eq i =
    if i >= String.length data || i >= eq_limit then None
    else if data.[i] = '=' then Some i
    else if data.[i] = '\000' then None
    else find_eq (i + 1)
  in
  match find_eq pos with
  | None -> None
  | Some eq ->
      let nl_limit = eq + 1 + 1025 in
      let rec find_nl i =
        if i >= String.length data || i >= nl_limit then None
        else if data.[i] = '\n' then Some i
        else find_nl (i + 1)
      in
      match find_nl (eq + 1) with
      | None -> None
      | Some nl ->
          Some
            ( String.sub data pos (eq - pos),
              String.sub data (eq + 1) (nl - eq - 1),
              nl + 1 )

let note_kernel data pos size state =
  if pos + 0x40 > String.length data then failwith "payload: kernel header is truncated";
  if not (starts data (pos + 0x38) "ARM\x64") then failwith "payload: kernel magic is missing";
  let image_size = le64 data (pos + 16) in
  if image_size <= 0L || image_size > Int64.of_int max_int then
    failwith "payload: kernel image_size is not usable";
  let image_size = Int64.to_int image_size in
  if size > image_size then failwith "payload: kernel image_size is smaller than the bytes around it";
  state.has_kernel <- true;
  state.kernel_image_size <- image_size;
  image_size

let rec load_one data pos ~size state =
  let len = String.length data in
  if pos >= len then `Stop
  else if starts data pos "\x1f\x8b" then (
    let plain, consumed = gunzip_stored data pos in
    ignore (load_one plain 0 ~size:(String.length plain) state);
    `Next (pos + consumed))
  else if starts data pos "\xfd7zXZ\x00" then failwith "payload: xz payloads are not decoded by this host"
  else if starts data pos "\xd0\x0d\xfe\xed" then `Next (pos + note_fdt data pos state)
  else if starts data pos "07070" then
    if size = 0 then failwith "Uncompressed cpio archives not supported"
    else (
      state.initrd_bytes <- size;
      `Next (pos + size))
  else if pos + 0x40 <= len && starts data (pos + 0x38) "ARM\x64" then
    let image_size = note_kernel data pos size state in
    if size = 0 then `Stop else `Next (pos + image_size)
  else if starts data pos "m1n1_sig" then
    if pos + 12 > len then `Stop
    else `Next (pos + Int32.to_int (le32 data (pos + 8)))
  else if starts data pos initramfs_magic then
    let header = String.length initramfs_magic in
    if pos + header + 4 > len then failwith "payload: initramfs header is truncated"
    else
      let bytes = Int32.to_int (le32 data (pos + header)) in
      let body = pos + header + 4 in
      if bytes < 0 || body + bytes > len then failwith "payload: initramfs size runs past the buffer"
      else (
        (* load_cpio records the range and does not scan those bytes. *)
        state.initrd_bytes <- bytes;
        `Next (body + bytes))
  else
    match take_var data pos with
    | Some (name, value, next) ->
        if name = "tso" then state.tso <- value <> "" && value.[0] = '1'
        else if String.starts_with ~prefix:"chosen." name then
          state.chosen <- state.chosen @ [ (String.sub name 7 (String.length name - 7), value) ];
        `Next next
    | None ->
        if pos + 4 <= len && String.sub data pos 4 = "\000\000\000\000" then `Stop
        else if
          pos + 11 <= len
          && String.sub data (pos + 5) 6 = "\x16\x04IMG4"
        then `Stop
        else `Stop

let scan data =
  let state = empty () in
  let rec outer pos =
    if pos >= String.length data then ()
    else
      match load_one data pos ~size:0 state with
      | `Stop -> ()
      | `Next next -> if next <= pos || next > String.length data then () else outer next
  in
  outer 0;
  {
    has_kernel = state.has_kernel;
    kernel_image_size = state.kernel_image_size;
    compatible = state.compatible;
    has_memory = state.has_memory;
    initrd_bytes = state.initrd_bytes;
    tso = state.tso;
    chosen = state.chosen;
  }

let entry_align = kernel_align
