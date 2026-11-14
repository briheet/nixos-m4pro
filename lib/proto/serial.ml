(* A live m1n1 UART proxy peer over a host tty.

   On this pair of Macs the tty is channel 0 of the target's debug USB
   (/dev/cu.kis-100000-ch-0) after `macvdmtool debugusb` on the host. The
   framing is Wire's. The read side follows UartInterface.reply in
   upstream/m1n1/proxyclient/m1n1/proxy.py: m1n1 console text shares the
   line with replies, so the reader scans for the ff 55 aa prefix every
   reply and event starts with, hands everything else to [console], skips
   events, and skips boot announcements that arrive while waiting for a
   different reply. *)

exception Timeout of string

type t = {
  fd : Unix.file_descr;
  path : string;
  timeout : float;
  console : string -> unit;
  buf : Bytes.t;
  mutable pos : int;
  mutable len : int;
  mutable deadline : float;
}

let event_header_len = 8

let raw_mode fd baud =
  let tio = Unix.tcgetattr fd in
  let tio =
    {
      tio with
      Unix.c_ignbrk = false;
      c_brkint = false;
      c_ignpar = true;
      c_parmrk = false;
      c_inpck = false;
      c_istrip = false;
      c_inlcr = false;
      c_igncr = false;
      c_icrnl = false;
      c_ixon = false;
      c_ixoff = false;
      c_opost = false;
      c_obaud = baud;
      c_ibaud = baud;
      c_csize = 8;
      c_cstopb = 1;
      c_cread = true;
      c_parenb = false;
      c_hupcl = false;
      c_clocal = true;
      c_isig = false;
      c_icanon = false;
      c_noflsh = false;
      c_echo = false;
      c_echoe = false;
      c_echok = false;
      c_echonl = false;
      c_vmin = 1;
      c_vtime = 0;
    }
  in
  Unix.tcsetattr fd Unix.TCSANOW tio

(* Any connected descriptor works. Tests use one end of a socketpair. *)
let of_fd ?(path = "fd") ?(timeout = 3.0) ?(console = fun _ -> ()) fd =
  { fd; path; timeout; console; buf = Bytes.create 4096; pos = 0; len = 0; deadline = infinity }

let open_device ?(baud = Wire.baud) ?(timeout = 3.0) ?(console = fun _ -> ()) path =
  let fd =
    try Unix.openfile path [ Unix.O_RDWR; Unix.O_NOCTTY; Unix.O_NONBLOCK ] 0
    with Unix.Unix_error (err, _, _) ->
      failwith (Printf.sprintf "cannot open %s: %s" path (Unix.error_message err))
  in
  (try
     Unix.clear_nonblock fd;
     raw_mode fd baud;
     (* proxy.py flushes both directions on open. Anything queued from
        before this session is console text or a stale reply. *)
     Unix.tcflush fd Unix.TCIOFLUSH
   with e ->
     Unix.close fd;
     raise e);
  of_fd ~path ~timeout ~console fd

let close t = Unix.close t.fd

let rec write_all t bytes off len =
  if len > 0 then
    let n = Unix.write t.fd bytes off len in
    write_all t bytes (off + n) (len - n)

(* [timeout] bounds the whole wait for one reply, not only silence on the
   line. A wedged m1n1 that keeps printing an exception dump would
   otherwise hold the reader forever. *)
let rec fill t =
  let now = Unix.gettimeofday () in
  if now >= t.deadline then
    raise (Timeout (Printf.sprintf "no reply from %s within %.1fs" t.path t.timeout));
  match Unix.select [ t.fd ] [] [] (Float.min t.timeout (t.deadline -. now)) with
  | [], _, _ ->
      raise (Timeout (Printf.sprintf "no data from %s within %.1fs" t.path t.timeout))
  | _ -> (
      match Unix.read t.fd t.buf 0 (Bytes.length t.buf) with
      | 0 -> raise (Timeout (Printf.sprintf "%s closed" t.path))
      | n ->
          t.pos <- 0;
          t.len <- n
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EINTR), _, _) -> fill t)

let read_byte t =
  if t.pos >= t.len then fill t;
  let c = Bytes.get t.buf t.pos in
  t.pos <- t.pos + 1;
  Char.code c

let read_exact t n =
  let out = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set out i (Char.chr (read_byte t))
  done;
  out

let console_bytes t bytes = if bytes <> [] then t.console (String.of_seq (List.to_seq (List.map Char.chr bytes)))

(* The reply header is the u32 command, little-endian, so every reply and
   event starts ff 55 aa followed by the command number. *)
let rec next_header t =
  match read_byte t with
  | 0xff -> after_ff t
  | b ->
      console_bytes t [ b ];
      next_header t

and after_ff t =
  match read_byte t with
  | 0x55 -> after_55 t
  | 0xff ->
      console_bytes t [ 0xff ];
      after_ff t
  | b ->
      console_bytes t [ 0xff; b ];
      next_header t

and after_55 t =
  match read_byte t with
  | 0xaa -> 0x00aa55ff lor (read_byte t lsl 24)
  | 0xff ->
      console_bytes t [ 0xff; 0x55 ];
      after_ff t
  | b ->
      console_bytes t [ 0xff; 0x55; b ];
      next_header t

let rec receive t ~cmd =
  let got = next_header t in
  if got = Wire.req_event then begin
    let header = read_exact t (event_header_len - 4) in
    let data_len = Char.code (Bytes.get header 0) lor (Char.code (Bytes.get header 1) lsl 8) in
    ignore (read_exact t (data_len + 4));
    receive t ~cmd
  end
  else begin
    let frame = Bytes.create Wire.reply_len in
    Wire.put_u32 frame 0 got;
    Bytes.blit (read_exact t (Wire.reply_len - 4)) 0 frame 4 (Wire.reply_len - 4);
    let reply = Wire.decode_reply frame in
    if got <> cmd && got = Wire.req_boot && reply.status = Wire.st_ok then receive t ~cmd
    else frame
  end

let peer t : Wire.peer =
 fun frame ->
  write_all t frame 0 (Bytes.length frame);
  t.deadline <- Unix.gettimeofday () +. t.timeout;
  Fun.protect
    ~finally:(fun () -> t.deadline <- infinity)
    (fun () -> receive t ~cmd:(Wire.get_u32 frame 0))

(* REQ_NOP with no feature bits. m1n1 answers with the features it enabled,
   which is none when none are asked for. *)
let nop t =
  let reply = Wire.decode_reply (peer t (Wire.encode_command Wire.req_nop (Bytes.make 8 '\000'))) in
  if reply.cmd <> Wire.req_nop then
    failwith (Printf.sprintf "m1n1 nop: got command %#x" reply.cmd);
  if reply.status <> Wire.st_ok then failwith (Printf.sprintf "m1n1 nop status %d" reply.status)

let transport t = Wire.proxy_transport (peer t)

(* REQ_MEMREAD: u64 address and u64 size in the payload; the reply carries
   the data checksum (same mix as the frames, over the data alone), then the
   raw bytes follow. Read in chunks so a lost byte costs one chunk. Without
   features negotiated (see [nop]) data checksums are on and there is no
   end sentinel. *)
let memread ?(chunk = 0x10000) t ~addr ~size =
  let out = Bytes.create size in
  let rec go off =
    if off < size then begin
      let n = min chunk (size - off) in
      let payload = Bytes.make 16 '\000' in
      Bytes.set_int64_le payload 0 (Int64.of_int (addr + off));
      Bytes.set_int64_le payload 8 (Int64.of_int n);
      let reply = Wire.decode_reply (peer t (Wire.encode_command Wire.req_memread payload)) in
      if reply.cmd <> Wire.req_memread then
        failwith (Printf.sprintf "m1n1 memread: got command %#x" reply.cmd);
      if reply.status <> Wire.st_ok then
        failwith (Printf.sprintf "m1n1 memread %#x+%#x: status %d" (addr + off) n reply.status);
      let expected = Wire.get_u32 reply.data 0 in
      let data = read_exact t n in
      let got = Wire.checksum data 0 n in
      if got <> expected then raise (Wire.Checksum_error { expected; got });
      Bytes.blit data 0 out off n;
      go (off + n)
    end
  in
  go 0;
  out
