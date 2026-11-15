# DCP on the 27.2 firmware: the IOMFB RPC selectors (static RE)

Static reverse engineering of the running T6041 DCP firmware dumped on 27.2
(`build/dcp27/dcp-text.bin`, `dcp-data.bin`; RTKit banner in DATA:
`RTKit_armv8_chinook_Oz_flto_pac-3514.41.1`, `AppleDCP-1317.40.16~1318-t604xdcp.RELEASE`),
against appledrm's firmware-27 interface (`iomfb_v27.c`, written for T6050 27.0).
Companion docs: `dcp-27.2-kernel.md`, `dcp-27.2-aura.md`.

All firmware addresses below are **offsets into `dcp-text.bin`** (TEXT). The
code addresses TEXT and DATA PC-relatively; DATA sits right after TEXT
(DATA offset = VA offset - 0x6fc000; e.g. the IOMFB instance table `text+0x9b5400`
is `dcp-data.bin+0x2b9400`). The absolute VA is not needed for anything here.

## 0. The answer in one paragraph

**A427 is not a callback. It is a method the AP called.** The firmware's
`rpc_callee_gated` (text `0x187aa8`) is the DCP-side dispatcher for AP->DCP
calls; Apple's log calls every incoming handler a "callback". Right after
"DCP booted" appledrm sends `A427` = `get_color_remap_mode` (`dcp_started()`,
`iomfb_template.c:4620`). **27.2 renumbered the IOMobileFramebuffer methods:
every 27.0 selector A400..A499 is A450..A549 on 27.2 (+50)** (see §8: this
includes `start_signal` A401 -> A451; 27.2's own A400/A401 are unrelated
UnifiedPipeline getters), and A402..A449 do not exist at all on 27.2, so `A427` fails the
lookup and the firmware panics. `get_color_remap_mode` is **A477** on 27.2
(stub `0x1d5f94`; proven by the vtable PAC discriminator `0x8273` =
SipHash of `_ZNK19IOMobileFramebuffer20get_color_remap_modeEP21DisplayColorRemapMode`).
Its wire layout is unchanged: in 8 bytes `{u32 mode; u8 mode_null; u8 pad[3]}`,
out 8 bytes `{u32 mode; u32 status}`; status 0 is success. The driver's
request (`.mode = 6`) and structs are right; **only the tag must change**.
The callback side (D###, DCP->AP) is **not** renumbered: every callback the
driver handles has the same number and the same sizes on 27.2. Besides the
+50 block, two UnifiedPipeline methods moved by +1: `set_create_dfb`
A389->**A390** and `vi_set_temperature_hint` A390->**A391** (27.2's A389 is
a 0x34/0x34 method; sending A389 with 0/0 makes the stub fail its size check
and the firmware panic with `ap_link: callback failed with: 0x5`).

## 1. How 27.2 encodes and dispatches selectors

### Wire format (unchanged)

Each record in the shared buffer is `{u32 tag; u32 in_len; u32 out_len}`
followed by `in_len` bytes of input and `out_len` bytes of output. The tag is
a FourCC read as a little-endian u32 whose **big-endian** reading is the ASCII
name: `'A427'` = `0x41343237`, which is the bytes `37 32 34 41` ("724A") on
the wire. appledrm already does this (`iomfb.c:972`, `.tag[0] = call->tag[3]`,
...; `dcp_parse_tag()` reads `"D123"` from `tag[3..0]`). The firmware prints
the tag by shifting `>>24, >>16, >>8, >>0` (text `0x188a6c`).

Prefixes seen in the firmware:

| prefix | direction | where |
|---|---|---|
| `A###` | AP -> DCP methods (the DCP serves them) | compiled `switch` in `rpc_callee_gated` + `0x1d0a30` |
| `D###` | DCP -> AP callbacks (the AP serves them) | 148 call sites of `rpc_call` `0x18a458` |
| `B444`, `A446xx`, `D600` in strings | not selectors (YCbCr444, DPCD 0x600, Baobab IDs) | - |

There are no selector strings or `{tag, handler}` tables in the image: both
directions use FourCC constants built in code (`mov wN,#lo; movk wN,#hi,lsl#16`).
The `Axxx_callback__` strings (`A119/A120/A122` UPPipe_RemoteCalls.cpp,
`A355/A374/A375` UnifiedPipeline_RemoteCalls.cpp, `A491/A492/A494/A500`
IOMobileFramebuffer_RemoteCalls.cpp) are `__func__` names of the array-argument
checkers inside those stubs, and they are already in 27.2 numbering.

### `rpc_callee_gated` (AP -> DCP)

- text `0x187aa8`: reads the record header from the shared buffer, checks
  `in_len + out_len + 12` against the message length
  (`ap_link: %s: payload size mismatch`, `payload too big`, ...), then
  `ldr w23, [record]` = tag.
- text `0x187b80`..`0x1885e4`: a compiled binary-search `switch (tag)` with
  jump tables; for `'A45x'..'A54x'` it calls a second compiled switch at
  text **`0x1d0a30`** (the IOMobileFramebuffer method lookup); `'A200'..'A206'`
  use a 7-slot pointer table in DATA (`text+0x7211f0`).
- text `0x1885e8`: `cbz handler, 0x188a6c` -> **`ap_link: %s: link_rpc_lookup
  callback not found: '%s'`** + panic (`0x1997c`). This is the A427 crash.
- text `0x188648`: `blraaz handler(ctx, msg, in, in_len, out, out_len)`.
- text `0x1889d0`: any nonzero return panics with **`ap_link: callback failed
  with: 0x%x`**, the code mapped from the handler's IOMFBStatus:
  `0x80000001`->**5** (a stub's "in_len/out_len too small" return),
  `0x8000000c`->1, `0x80000007`->2, `0x8000000b`->4, `0x8000000e`->6,
  `0x8000000f`->7, `0x80020011`->8, anything else -> 3. (The T8142 `0x5`
  panic in `dcp.c:5233` is this size check.)

Every generated stub starts with `cmp w3, #min_in` / `cmp w5, #min_out`
(`>=` checks, `mov w0,#0x80000001` on failure), so the firmware accepts
larger buffers but panics on smaller ones. It then looks up the IOMFB
instance (`[ctx+0x38]` into the 0x30-byte table at `text+0x9b5400`) and calls
the C++ method through the vtable with a PAC discriminator
(`movk x16, #disc, lsl #48; blraa`). The discriminator is clang's
`ptrauth_string_discriminator` of the method's mangled name
(SipHash-2-4, key `b5 d4 c9 eb 79 10 4a 79 6f ec 8b 1b 42 87 81 d4`,
`hash % 0xffff + 1`), so method names can be **verified** by hashing candidate
mangled names (`build/dcp27/re/siphash.py`). Hash-confirmed on 27.2:

| 27.2 | discriminator | mangled name | 27.0 |
|---|---|---|---|
| A352 | 0x79ab | `_ZN19IOMobileFramebuffer13applyPropertyEjj` | A352 |
| A461 | 0xa299 | `_ZN19IOMobileFramebuffer18set_display_deviceEj` | A411 |
| A463 | 0x6110 | `_ZN19IOMobileFramebuffer20set_digital_out_modeEjj` | A413 |
| A477 | 0x8273 | `_ZNK19IOMobileFramebuffer20get_color_remap_modeEP21DisplayColorRemapMode` | A427 |
| A478 | 0x15d0 | `_ZN19IOMobileFramebuffer23setBrightnessCorrectionEj` | A428 |
| A500 | 0x7076 | `_ZN19IOMobileFramebuffer17set_parameter_dcpE18IOMFBParameterNamePKyj` | A450 |
| A508 | 0xfd4f | `_ZN19IOMobileFramebuffer34enable_disable_video_power_savingsEj` | A458 |
| A516 | 0xbeb7 | `_ZN19IOMobileFramebuffer17first_client_openEv` | A466 |
| A517 | 0xb08b | `_ZN19IOMobileFramebuffer21last_client_close_dcpEPj` | A467 |

Every one of these lands exactly at 27.0 + 50; together with the size match of
all 26 other driver methods in the block (section 3) the +50 renumbering is
certain. Probable but weaker (16-bit hash, dictionary search):
A464 `get_digital_out_state(uint*)` (= the driver's unnamed `pipe_cfg_414`),
A474 `set_contrast(float*)`, A506 `enable_disable_dithering(uint)`.

### `rpc_call` (DCP -> AP)

text **`0x18a458`** `rpc_call(u32 tag, void *in, u32 in_len, void *out, u32 out_len)`;
every callback wrapper calls (or tail-calls) it with constant sizes, which
gives the exact sizes the firmware sends (section 4). The wrappers only go to
the AP when the AP link is up (`[text+0x9b5734] & 1`), otherwise they run a
local implementation.

## 2. Reproducing

```
L=/nix/store/0jqhv6bkz6inag7sgzzy0289sy6fvjr4-llvm-21.1.8/bin
$L/llvm-objcopy -I binary -O elf64-littleaarch64 \
  --rename-section .data=.text,alloc,load,code,contents dcp-text.bin text.elf
$L/llvm-objdump -d --no-show-raw-insn --triple=aarch64 --mattr=+v8.5a,+pauth text.elf \
  | sed 's/<_binary_[^>]*>//; s/ <T+0x[0-9a-f]*>//' > text.dis
```

Scripts and outputs (run from the directory holding `text.dis`) are in the
gitignored `build/dcp27/re/`: `emu.py` (tiny AArch64 emulator for the
dispatcher), `scan.py` (all `A###`/`B###`.../`Z###` through
`rpc_callee_gated` -> `scanAll.txt`), `stubs.py` (min sizes + PAC
discriminators per stub -> `stubs.txt`), `calls2.py` (tag/in/out at every
`rpc_call` site -> `dcalls2.txt`), `siphash.py` (discriminator), `cbdiff.txt`,
`methods_table.txt`. Only `'A'` selectors exist (the other 25 letters all miss).

## 3. Methods the 27.2 firmware serves (230 + 4)

A000-A044, A100-A137, A200/A203/A204/A205, A350-A401, A450-A542, A550, A551.
**No A402-A449.** Sizes are the stub minimums (`in>=` / `out>=`); names are
from the hash table above, from the +50 mapping of the driver's 27.0 table, or
from matching sizes against the 26.6 desktop peer calls (A360-A373 are
identical to 26.6, so nothing moved below A374).

```
A000 0x2ddf34  in>=0x4    out>=0x4    late_init_signal (27.0 A000)
A001 0x2ddec8  in>=0x0    out>=0x4    
A002 0x2dde84  in>=0x0    out>=0x0    
A003 0x2dddd0  in>=0x4    out>=0x0    
A004 0x2ddd1c  in>=0x4    out>=0x0    
A005 0x2ddc6c  in>=0x4    out>=0x0    
A006 0x2ddbbc  in>=0x4    out>=0x0    
A007 0x2ddb0c  in>=0x4    out>=0x0    
A008 0x2dda5c  in>=0x4    out>=0x0    
A009 0x2dd9a8  in>=0x4    out>=0x0    
A010 0x2dd8f4  in>=0x4    out>=0x0    
A011 0x2dd840  in>=0x8    out>=0x0    
A012 0x2dd78c  in>=0x8    out>=0x0    
A013 0x2dd6d8  in>=0x4    out>=0x0    
A014 0x2dd66c  in>=0x0    out>=0x4    
A015 0x2dd5cc  in>=0x0    out>=0x4    
A016 0x2dd518  in>=0x4    out>=0x0    
A017 0x2dd49c  in>=0x0    out>=0x0    
A018 0x2dd3fc  in>=0x0    out>=0x4    
A019 0x2dd38c  in>=0x0    out>=0x4    
A020 0x2dd25c  in>=0xc    out>=0x4    
A021 0x2dd138  in>=0x8    out>=0x4    
A022 0x2dd0cc  in>=0x0    out>=0x4    
A023 0x2dd05c  in>=0x0    out>=0x4    
A024 0x2dcfe0  in>=0x0    out>=0x0    
A025 0x2dced8  in>=0xc    out>=0x8    
A026 0x2dce3c  in>=0x0    out>=0x4    
A027 0x2dcdf8  in>=0x0    out>=0x0    setup_video_limits (27.0 A027)
A028 0x2dcd8c  in>=0x0    out>=0x4    
A029 0x2dcd20  in>=0x0    out>=0x4    
A030 0x2dccb4  in>=0x0    out>=0x4    
A031 0x2dcc38  in>=0x0    out>=0x0    
A032 0x2dcb74  in>=0x8    out>=0x4    
A033 0x2dcac0  in>=0x6c   out>=0x0    update_notify_clients_dcp / drv pipe_cfg_031 (27.0 A033)
A034 0x2dca54  in>=0x0    out>=0x4    
A035 0x2dc9e8  in>=0x0    out>=0x4    drv dfb_query (27.0 A035)
A036 0x2dc8a0  in>=0x2c   out>=0x2c   get_dfb_info (27.0 A036)
A037 0x2dc7a8  in>=0x8    out>=0x8    get_dfb_compression_info (27.0 A037)
A038 0x2dc780  in>=0x0    out>=0x8    
A039 0x2dc758  in>=0x0    out>=0x4    
A040 0x2dc720  in>=0x0    out>=0x4    
A041 0x2dc6b4  in>=0x0    out>=0x4    
A042 0x2dc648  in>=0x0    out>=0x4    
A043 0x2dc604  in>=0x0    out>=0x0    
A044 0x2dc528  in>=0x8    out>=0x4    
A100 0x23ad0c  in>=0x4    out>=0xc10  
A101 0x23abfc  in>=0xc10  out>=0x0    
A102 0x23ab0c  in>=0x8    out>=0x4    
A103 0x23a9d8  in>=0xc    out>=0x8    get_dfb_layout (27.0 A103)
A104 0x23a8f0  in>=0x8    out>=0x0    set_dfb_dimensions (27.0 A104)
A105 0x23a874  in>=0x0    out>=0x0    commit_dfb_info (27.0 A105)
A106 0x23a7d4  in>=0x0    out>=0x4    read_blend_crc (drv iomfb.c)
A107 0x23a734  in>=0x0    out>=0x4    
A108 0x23a624  in>=0x4    out>=0x4    
A109 0x23a554  in>=0x0    out>=0x4    
A110 0x23a430  in>=0x4    out>=0x0    
A111 0x23a338  in>=0xc    out>=0x0    
A112 0x23a1dc  in>=0x4    out>=0x4    
A113 0x23a0cc  in>=0x10   out>=0x4    
A114 0x23a070  in>=0x0    out>=0x0    
A115 0x239fe0  in>=0x0    out>=0x4    
A116 0x239f80  in>=0x0    out>=0x4    
A117 0x239e38  in>=0x4    out>=0x4    
A118 0x239cb4  in>=0xc    out>=0xc    
A119 0x239acc  in>=0x0    out>=0x0    
A120 0x2398fc  in>=0x5c   out>=0x0    
A121 0x2397f0  in>=0xc    out>=0x4    
A122 0x239608  in>=0x0    out>=0x0    
A123 0x239500  in>=0x18   out>=0x4    
A124 0x239404  in>=0xc    out>=0x4    
A125 0x239308  in>=0xc    out>=0x4    
A126 0x2391ec  in>=0x14   out>=0x8    
A127 0x23907c  in>=0x80   out>=0x7c   
A128 0x238f44  in>=0x80   out>=0x4    
A129 0x238e08  in>=0x34   out>=0x34   
A130 0x238d20  in>=0x4    out>=0x0    
A131 0x238c38  in>=0x4    out>=0x0    
A132 0x238b48  in>=0x20   out>=0x4    
A133 0x238aa8  in>=0x0    out>=0x4    
A134 0x2389d4  in>=0x0    out>=0x0    
A135 0x238930  in>=0x0    out>=0x4    
A136 0x2387e4  in>=0x0    out>=0x4    pmu_service_matched (27.0 A136)
A137 0x238698  in>=0x0    out>=0x4    backlight_service_matched (27.0 A137)
A350 0x262cc8  in>='?'    out>=0x4    
A351 0x262c2c  in>=0x0    out>=0x4    
A352 0x262b20  in>=0x8    out>=0x4    IOMobileFramebuffer::applyProperty(uint,uint) [hash]
A353 0x262a54  in>=0x0    out>=0x8    drv pipe_query_353 (unused)
A354 0x262894  in>=0x10   out>=0xc    
A355 0x2625f8  in>=0x5dc  out>=0x0    
A356 0x26255c  in>=0x0    out>=0x4    
A357 0x2623fc  in>=0x70   out>=0x68   
A358 0x262360  in>=0x0    out>=0x4    
A359 0x26222c  in>=0x14   out>=0x8    
A360 0x2621c8  in>=0x0    out>=0x4    peer: get id (26.6 A360)
A361 0x2620c0  in>=0x4    out>=0x0    peer: set master (26.6 A361)
A362 0x261fdc  in>=0x4    out>=0x0    peer: manage (26.6 A362)
A363 0x261ef8  in>=0x4    out>=0x0    
A364 0x261d60  in>=0x7c   out>=0x74   get_mode_info (26.6 A364, 0x7c/0x74)
A365 0x261be8  in>=0x7c   out>=0x74   peer: insert (26.6 A365)
A366 0x261b04  in>=0x4    out>=0x0    setup_peer_dcp (26.6 A366)
A367 0x2619ec  in>=0x24   out>=0x20   peer caps (26.6 A367)
A368 0x2618d4  in>=0x24   out>=0x20   peer caps (26.6 A368)
A369 0x261838  in>=0x0    out>=0x4    peer required (26.6 A369)
A370 0x261718  in>=0x4    out>=0x8    peer bpp (26.6)
A371 0x2615f8  in>=0x4    out>=0x8    peer bpp (26.6)
A372 0x2614d0  in>=0xc    out>=0xc    peer hints (26.6)
A373 0x2613a8  in>=0xc    out>=0xc    peer hints (26.6)
A374 0x26110c  in>=0x5dc  out>=0x0    
A375 0x260f44  in>=0x18   out>=0x14   
A376 0x260e20  in>=0x8    out>=0xc    
A377 0x260ca8  in>=0x14   out>=0x14   
A378 0x260af8  in>=0x2c   out>=0x28   
A379 0x260a5c  in>=0x0    out>=0x4    
A380 0x26093c  in>=0x4    out>=0x4    
A381 0x2608d0  in>=0x0    out>=0x4    
A382 0x26085c  in>=0x0    out>=0x14   
A383 0x260804  in>=0x0    out>=0x0    
A384 0x260768  in>=0x0    out>=0x4    drv dfb_ready_query? (27.0 A384; or A385)
A385 0x2606cc  in>=0x0    out>=0x4    drv dfb_ready_query? (alt)
A386 0x260630  in>=0x0    out>=0x4    
A387 0x260594  in>=0x0    out>=0x4    
A388 0x26049c  in>=0x4    out>=0x0    
A389 0x260360  in>=0x34   out>=0x34   NEW in 27.2 (52/52), was set_create_dfb slot in 27.0
A390 0x260304  in>=0x0    out>=0x0    set_create_DFB (27.0 A389)
A391 0x260284  in>=0x0    out>=0x4    vi_set_temperature_hint (27.0 A390)
A392 0x2601bc  in>=0x4    out>=0x4    
A393 0x260104  in>=0x0    out>=0x4    
A394 0x2600a8  in>=0x0    out>=0x0    
A395 0x26003c  in>=0x0    out>=0x4    
A396 0x25feec  in>=0x4    out>=0x0    
A397 0x25fe90  in>=0x0    out>=0x0    
A398 0x25fe24  in>=0x0    out>=0x4    
A399 0x25fdc8  in>=0x0    out>=0x0    
A400 0x25fd2c  in>=0x0    out>=0x4    
A401 0x25fcc0  in>=0x0    out>=0x4    UnifiedPipeline byte getter (inst+0x6754); NOT start_signal (see §8)
A450 0x1d8084  in>=0x0    out>=0x0    
A451 0x1d7f44  in>=0x0    out>=0x4    start_signal = gated IOMobileFramebuffer::start_ios_gated (27.0 A401)
A452 0x1d7ed4  in>=0x0    out>=0x0    
A453 0x1d7e5c  in>=0x0    out>=0x0    
A454 0x1d7d40  in>=0xc    out>=0x4    
A455 0x1d7ca4  in>=0x0    out>=0x4    
A456 0x1d7b7c  in>=0x10   out>=0x8    swap_start (27.0 A406)
A457 0x1d77c4  in>=0x0    out>=0x0    
A458 0x1d752c  in>=0xff4  out>=0x0    swap_submit_dcp (27.0 A408)
A459 0x1d72fc  in>=0xd48  out>=0x0    
A460 0x1d71f0  in>=0x8    out>=0x4    
A461 0x1d70e4  in>=0x4    out>=0x4    set_display_device(uint) [hash] (27.0 A411)
A462 0x1d7078  in>=0x0    out>=0x4    is_main_display (27.0 A412)
A463 0x1d6f6c  in>=0x8    out>=0x4    set_digital_out_mode(uint,uint) [hash] (27.0 A413)
A464 0x1d6e48  in>=0x8    out>=0x8    get_digital_out_state(uint*) [hash?] / drv pipe_cfg_414 (27.0 A414)
A465 0x1d6d1c  in>=0xc    out>=0xc    drv pipe_cfg_415 (27.0 A415)
A466 0x1d6c10  in>=0x4    out>=0x4    
A467 0x1d6b04  in>=0x4    out>=0x4    
A468 0x1d69f8  in>=0x8    out>=0x4    
A469 0x1d6914  in>=0x4    out>=0x0    
A470 0x1d67c4  in>=0xc10  out>=0x0    get_gamma_table (27.0 A420)
A471 0x1d6674  in>=0xc10  out>=0x0    set_gamma_table (27.0 A421)
A472 0x1d6520  in>=0x50   out>=0x4c   
A473 0x1d63f4  in>=0x50   out>=0x4    set_matrix (27.0 A423)
A474 0x1d62d0  in>=0x8    out>=0x8    set_contrast(float*) [hash?]
A475 0x1d61c4  in>=0x4    out>=0x4    
A476 0x1d60b8  in>=0x4    out>=0x4    
A477 0x1d5f94  in>=0x8    out>=0x8    get_color_remap_mode(DisplayColorRemapMode*) const [hash] (27.0 A427)
A478 0x1d5e88  in>=0x4    out>=0x4    setBrightnessCorrection(uint) [hash] (27.0 A428)
A479 0x1d5ca0  in>=0x70   out>=0x10   
A480 0x1d5af4  in>=0x34   out>=0xc    
A481 0x1d59e8  in>=0x4    out>=0x4    
A482 0x1d5808  in>=0x38   out>=0x10   
A483 0x1d56fc  in>=0x4    out>=0x4    
A484 0x1d55f0  in>=0x4    out>=0x4    
A485 0x1d54e4  in>=0x4    out>=0x4    
A486 0x1d53d8  in>=0x8    out>=0x4    
A487 0x1d52b0  in>=0x8    out>=0x8    
A488 0x1d5144  in>=0xa0   out>=0xa0   
A489 0x1d5038  in>=0x4    out>=0x4    
A490 0x1d4f14  in>=0x8    out>=0x8    
A491 0x1d4d10  in>=0x0    out>=0x0    
A492 0x1d4b24  in>=0x5c   out>=0x0    
A493 0x1d4a0c  in>=0xc    out>=0x4    
A494 0x1d4808  in>=0x0    out>=0x0    
A495 0x1d46e4  in>=0x18   out>=0x4    
A496 0x1d45cc  in>=0xc    out>=0x4    
A497 0x1d44b4  in>=0xc    out>=0x4    
A498 0x1d4398  in>=0x10   out>=0x8    
A499 0x1d4224  in>=0x84   out>=0x7c   (27.0 A449, peer runtime)
A500 0x1d40ac  in>=0x28   out>=0x4    set_parameter_dcp [hash] (27.0 A450)
A501 0x1d4048  in>=0x0    out>=0x4    
A502 0x1d3fe4  in>=0x0    out>=0x4    
A503 0x1d3f04  in>=0x4    out>=0x8    get_dfb_state (27.0 A453)
A504 0x1d3e98  in>=0x0    out>=0x4    create_default_fb (27.0 A454)
A505 0x1d3d80  in>=0x0    out>=0x0    
A506 0x1d3c74  in>=0x4    out>=0x4    enable_disable_dithering(uint) [hash?]
A507 0x1d3b68  in>=0x4    out>=0x4    
A508 0x1d3a5c  in>=0x4    out>=0x4    enable_disable_video_power_savings(uint) [hash] (27.0 A458)
A509 0x1d3950  in>=0x4    out>=0x4    
A510 0x1d3844  in>=0x4    out>=0x4    
A511 0x1d3738  in>=0x4    out>=0x4    
A512 0x1d3604  in>=0x18   out>=0x18   
A513 0x1d34e0  in>=0x8    out>=0x8    
A514 0x1d33b4  in>=0x14   out>=0x14   
A515 0x1d32d0  in>=0x8    out>=0x0    
A516 0x1d3258  in>=0x0    out>=0x0    first_client_open() [hash] (27.0 A466)
A517 0x1d3158  in>=0x4    out>=0x4    last_client_close_dcp(uint*) [hash] (27.0 A467)
A518 0x1d3038  in>=0x4    out>=0xc    
A519 0x1d2f4c  in>=0x4    out>=0x0    
A520 0x1d2d44  in>=0x14   out>=0x4    
A521 0x1d2c28  in>=0x10   out>=0x4    
A522 0x1d2b8c  in>=0x0    out>=0x4    
A523 0x1d2a80  in>=0x8    out>=0x4    
A524 0x1d299c  in>=0x10   out>=0x0    
A525 0x1d2728  in>=0x0    out>=0x4    setDisplayRefreshProperties (27.0 A475)
A526 0x1d2644  in>=0x8    out>=0x0    
A527 0x1d2538  in>=0x8    out>=0x4    
A528 0x1d2450  in>=0x4    out>=0x0    flush_supportsPower (27.0 A478)
A529 0x1d2348  in>=0x8    out>=0x4    abort_swaps_dcp (27.0 A479)
A530 0x1d21c0  in>=0xc    out>=0xc    
A531 0x1d2038  in>=0xc    out>=0xc    
A532 0x1d1dc8  in>=0x240  out>=0x0    
A533 0x1d1b70  in>=0x230  out>=0x0    register_dfb_surface (27.0 A483)
A534 0x1d1a60  in>=0x10   out>=0x8    setPowerState (27.0 A484)
A535 0x1d1928  in>=0x0    out>=0x4    drv pipe_query_474 (27.0 A485)
A536 0x1d18d8  in>=0x0    out>=0x0    
A537 0x1d17e0  in>=0x4    out>=0x0    drv pipe_set_476 (27.0 A487)
A538 0x1d1748  in>=0x0    out>=0x4    
A539 0x1d16ac  in>=0x0    out>=0x4    drv pipe_query_478 (27.0 A489)
A540 0x1d15c4  in>=0x4    out>=0x0    
A541 0x1d1500  in>=0x4    out>=0x8    
A542 0x1d13c8  in>=0x34   out>=0x4    
A550 0x193c54  in>=0x4    out>=0x0    
A551 0x1940ac  in>=0x10   out>=0x4    
A200/A203/A204/A205: dispatched through a 7-slot pointer table in DATA (VA text+0x7211f0); not IOMFB, not used by the driver
```

## 4. Diff: the driver's firmware-27 method table against 27.2

`iomfb_v27.c:72-114` (`dcp_methods[]`), in the order the boot/modeset path
hits them. "sent" is what appledrm puts in `in_len/out_len`
(`iomfb_template.c` thunks); "27.2 min" is the stub's check.

| driver entry | 27.0 tag | **27.2 tag** | sent in/out | 27.2 min in/out | note |
|---|---|---|---|---|---|
| `dcpep_start_signal` | A401 | **A451** | 0/4 | 0/4 | **corrected in §8**: 27.2 A401 is a different method that only returns a byte; A451 runs `start_ios_gated` |
| `iomfbep_get_color_remap_mode` | A427 | **A477** | 8/8 | 8/8 | **the crash**; hash-confirmed |
| `dcpep_get_dfb_state` | A453 | **A503** | 4/8 | 4/8 | client-open step "A445" |
| `dcpep_set_display_device` | A411 | **A461** | 4/4 | 4/4 | hash-confirmed |
| `dcpep_pipe_cfg_415` | A415 | **A465** | 0xc/0xc | 0xc/0xc | |
| `dcpep_enable_disable_video_power_savings` | A458 | **A508** | 4/4 | 4/4 | hash-confirmed |
| `dcpep_pipe_cfg_031` (update_notify_clients_dcp) | A033 | A033 | 0x6c/0 | 0x6c/0 | unchanged |
| `dcpep_pipe_cfg_414` (get_digital_out_state?) | A414 | **A464** | 8/8 | 8/8 | |
| `dcpep_pipe_query_478` | A489 | **A539** | 0/4 | 0/4 | |
| `dcpep_first_client_open` | A466 | **A516** | 0/0 | 0/0 | hash-confirmed |
| `dcpep_pipe_query_474` | A485 | **A535** | 0/4 | 0/4 | |
| `dcpep_pipe_set_476` | A487 | **A537** | 4/0 | 4/0 | |
| `dcpep_is_main_display` | A412 | **A462** | 0/4 | 0/4 | |
| `dcpep_set_digital_out_mode` | A413 | **A463** | 8/4 | 8/4 | hash-confirmed; first modeset |
| `dcpep_set_display_refresh_properties` | A475 | **A525** | 0/4 | 0/4 | |
| `dcpep_swap_start` | A406 | **A456** | 0x10/8 | 0x10/8 | |
| `dcpep_swap_submit` | A408 | **A458** | 0xff4/0xc | 0xff4/0xc | `dcp_swap_submit_req_v27` size is exactly right |
| `iomfbep_set_matrix` | A423 | **A473** | 0x50/4 | 0x50/4 | |
| `iomfbep_set_brightness_correction` | A428 | **A478** | 4/4 | 4/4 | hash-confirmed |
| `dcpep_set_parameter_dcp` | A450 | **A500** | 0x28/4 | 0x28/4 | hash-confirmed |
| `dcpep_set_power_state` | A484 | **A534** | 0x10/8 | 0x10/8 | |
| `dcpep_flush_supports_power` | A478 | **A528** | 4/0 | 4/0 | |
| `dcpep_create_default_fb` | A454 | **A504** | 0/4 | 0/4 | (D120 boot chain) |
| `dcpep_register_dfb_surface` | A483 | **A533** | 0x230/4 | 0x230/- | (D586 nested) |
| `iomfbep_last_client_close` | A467 | **A517** | 4/4 | 4/4 | hash-confirmed; teardown |
| `iomfbep_abort_swaps_dcp` | A479 | **A529** | 0x14/0x14 | 8/4 | accepted (>=), but 27.2 is the 26.6-desktop layout: in `u64 client`, out `u32 status` at **offset 0**; the v27 resp struct reads `ret` at +0x10 (always 0). Use the `_v26_6` structs on 27.2. |
| `dcpep_set_create_dfb` | A389 | **A390** | 0/0 | 0/0 | 27.2 A389 is 0x34/0x34: sending A389 0/0 -> `callback failed with: 0x5` |
| `iomfbep_a358_vi_set_temperature_hint` | A390 | **A391** | 0/4 | 0/4 | 27.2 A391 reads "Temperature" (`0x240fc8`); 27.2 A390 is now set_create_DFB, so sending A390 would silently create the DFB instead |
| `dcpep_dfb_ready_query` | A384 | A384 *or* A385 | 0/4 | 0/4 | both are no-side-effect bool getters (vtable 0xa00 / 0xa08) of identical shape; one UnifiedPipeline method was inserted in A374..A389 and its exact position is not recoverable statically. A384 is safe to keep; it only matters in the D120 boot chain. |
| `dcpep_late_init_signal` | A000 | A000 | 4/4 | 4/4 | unchanged |
| `dcpep_setup_video_limits` | A027 | A027 | 0/0 | 0/0 | unchanged |
| `dcpep_dfb_query` | A035 | A035 | 0/4 | 0/4 | unchanged |
| `dcpep_get_dfb_info` | A036 | A036 | 0x2c/0x2c | 0x2c/0x2c | unchanged |
| `dcpep_get_dfb_compression_info` | A037 | A037 | 8/8 | 8/8 | unchanged |
| `dcpep_get_dfb_layout` / `set_dfb_dimensions` / `commit_dfb_info` | A103/A104/A105 | same | 0xc/8, 8/0, 0/0 | same | unchanged |
| `iomfbep_a131/a132_*_service_matched` | A136/A137 | same | 0/4 | 0/4 | unchanged |
| `dcpep_pipe_set_352` / `pipe_query_353` | A352/A353 | same | - | 8/4, 0/8 | unused by the driver; A352 = applyProperty (hash) |

Hard-coded tags outside `dcp_methods[]`, also +50 on 27.2 if ever sent:
`iomfb_template.c:271-287` (A420/A421 gamma -> A470/A471, both 0xc10 = 3088;
desktop-only path; A364 get_mode_info unchanged; A128 desktop-only),
`iomfb.c:850` (A106 CRC, unchanged), and the T6050 peer/tiling files
`dcp-peer-runtime-v27.inc` (A411, A423, A428, A449, A450, A453),
`dcp-peer-swap-probe-v27.inc` (A406, A408), `dcp-peer-modeset-probe-v27.inc`
and `dcp-peer-video-probe-v27.inc` (A413, A484; their A360-A373 are unchanged).
The peer paths are not reached on the T6041 internal panel.

27.0 selectors that become A452..A549 but the driver never sends are listed
in the full table above (the `(27.0 Annn)` annotations).

## 5. Callbacks the 27.2 firmware calls on the AP (D###)

Exact sizes from all 148 `rpc_call` (`0x18a458`) call sites (`dcalls2.txt`),
diffed against `cb_handlers[]`/`callback_sizes[]` (`iomfb_v27.c:405-572`):


Corrections to the generated table: **D120** (`0x25b068`) and **D122**
(`0x25b2f0`) *are* called, 0/4 each, from the D100-based dispatcher where the
tag is `w21 + 0x200/0x202` with `w21 = 'D100'`; they match the driver
(`dcpep_cb_boot_1`, `trampoline_false`). `0x21a504` is D454 (`w21 = 'D451'`, +3).
D129 and D131 are never called by this firmware (harmless).

Summary:

- **No renumbering on the callback side.** All 78 callbacks the driver
  handles and 27.2 calls have the same number and exactly the driver's
  minimum sizes. Nothing on the D side explains or follows from the crash.
- 27.2 calls 128 distinct callbacks; 50 of them have no driver handler. They fill the gaps
  of the same numbering, so they are most likely 27.0 callbacks the T6050
  bring-up never needed (no 27.0 image to prove it), and appledrm already
  answers an unknown callback with a zeroed reply plus an ACK
  (`iomfb.c:1788-1817`, warning "received unknown callback") without
  setting `crashed`. A zero reply is a `false`/0 return, which is what the
  driver's explicit `trampoline_false/zero/nop` stubs would give anyway, so
  no callback stub is *required* to get past boot. Groups, by size/context:
  - UPPipe: D004, D005 (8/0), D007 (8/4); D103 (0/0) is
    `trigger_user_cal_loader` (calibration code around it); D125 (0x48/0x48,
    array getter `vals/val/len`).
  - UPPipe2: D200 (0/4; caller logs "Failed to register crashlog %x"),
    D205 (0xc/0x1004).
  - ServiceRelay (D4xx): D402 (0x4c/0), D405 (0x4c/8), D407 (0x48/0),
    D409 (0xc/4), D410 (0x14/8), D412 (0x448/4), D416 (0x84/4), then
    D417-D421 repeat the D412-D416 shapes (0x448, 0x1048, 0x50, 0x4c, 0x84 in;
    4 out) for a second object, D422 (0x48/4), D423/D424 (0x44/0).
  - IOMFB setProperty families: D550 (0x444/4), D551/D553 (0x1044/4), D554/D555
    (0x4c/4), D556 (0x48/4), D557/D558 (0x80/4), D559 (0x444/4), D560/D562
    (0x1044/4), D564 (0x4c/4), D566/D568 (0x80/4) -- the siblings of the
    D552/D561/D563/D565/D567 the driver answers `true`. If one of them turns
    out to gate something, `trampoline_true` with these sizes is the obvious
    stub.
  - D570 (0x1004/4), D571 (8/4), D573 (4/8), D577 (8/0), D578/D580/D581/D584
    (0/0, tail calls at `0x1d0778/0x1d07d4/0x1d07f0/0x1d080c`), D579 (4/4),
    D582 (0xc/0; "Unknown state transition", auto_mode_change), D590 (0x14/0;
    "clamshell value is %d"), D593 (8/0), D595 (0x2708/0x400; swap IDs),
    D600 (4/0).

Full table:

```
tag   27.2 (in/out)       driver 27.0 min (in/out)  driver handler   verdict
D000 0x0/0x4 0x0/0x4 dcpep_cb_d000_h17p ok
D001 0x0/0x4 0x0/0x4 trampoline_true ok
D002 0x0/0x0 0x0/0x0 trampoline_nop ok
D003 0x4/0x14 0x4/0x14 trampoline_rt_bandwidth_h17p ok
D004 0x8/0x0 - - MISSING in driver
D005 0x8/0x0 - - MISSING in driver
D006 0x54/0x50 0x54/0x50 trampoline_set_frame_sync_props_h17p ok
D007 0x8/0x4 - - MISSING in driver
D100 0x0/0x0 0x0/0x0 iomfbep_cb_match_pmu_service ok
D101 0x0/0x4 0x0/0x4 trampoline_zero ok
D102 0x44/0x0 0x44/0x0 trampoline_nop ok
D103 0x0/0x0 - - MISSING in driver
D104 0x44/0x0 0x44/0x0 trampoline_nop ok
D106 0x40/0x0 0x40/0x0 trampoline_nop ok
D107 0x0/0x4 0x0/0x4 trampoline_true ok
D108 0x0/0x4 0x0/0x4 trampoline_true ok
D109 0x0/0x4 0x0/0x4 trampoline_true ok
D110 0x0/0x4 0x0/0x4 trampoline_true ok
D111 0x0/0x4 0x0/0x4 trampoline_create_backlight_service ok
D112 0x0/0x4 0x0/0x4 trampoline_true ok
D113 0x1044/0x1004 0x1044/0x1004 dcpep_cb_core_analytics_v27 ok
D114 0x10/0x8 0x10/0x8 trampoline_tiling_state_v27 ok
D115 0x10/0x4 0x10/0x4 trampoline_set_tiling_state_v27 ok
D116 0xc/0x0 0xc/0x0 trampoline_nop ok
D117 0x14/0x4 0x14/0x4 trampoline_zero ok
D118 0x3e88/0x4 0x3e88/0x4 trampoline_zero ok
D119 0x4/0x4 0x4/0x4 trampoline_zero ok
D120 - 0x0/0x4 dcpep_cb_boot_1 driver only (27.2 never calls)
D121 0x0/0x4 0x0/0x4 trampoline_false ok
D122 - 0x0/0x4 trampoline_false driver only (27.2 never calls)
D123 0x0/0x4 0x0/0x4 trampoline_zero ok
D124 0x64/0x24 0x64/0x24 trampoline_read_edt_data ok
D125 0x48/0x48 - - MISSING in driver
D126 0x4/0x4 0x4/0x4 trampoline_prop_start ok
D127 0x1008/0x4 0x1008/0x4 trampoline_prop_chunk ok
D128 0x40/0x4 0x40/0x4 trampoline_prop_end ok
D129 - 0x1c/0x14 trampoline_allocate_bandwidth driver only (27.2 never calls)
D130 0x8/0x0 0x8/0x0 trampoline_update_external_counts_v27 ok
D131 - 0x10/0xc trampoline_get_external_counts_v27 driver only (27.2 never calls)
D132 0x4/0x0 0x4/0x0 trampoline_apply_suppression_v27 ok
D133 0x0/0x4 0x0/0x4 trampoline_display_identity_v27 ok
D200 0x0/0x4 - - MISSING in driver
D201 0xc/0x10 0xc/0x10 trampoline_map_piodma ok
D202 0x18/0x0 0x18/0x0 trampoline_unmap_piodma ok
D204 0x0/0x4 0x0/0x4 trampoline_ideal_screen_space_v27 ok
D205 0xc/0x1004 - - MISSING in driver
D206 0x0/0x4 0x0/0x4 iomfbep_cb_match_pmu_service_2 ok
D207 0x0/0x4 0x0/0x4 iomfbep_cb_match_backlight_service ok
D208 0x4/0x0 0x4/0x0 trampoline_nop ok
D209 0x0/0x8 0x0/0x8 trampoline_get_time ok
D300 0x10/0x0 0x10/0x0 trampoline_pr_publish ok
D400 0x4c/0xc04 0x4c/0xc04 trampoline_get_data_prop_v27 ok
D401 0x50/0xc 0x50/0xc trampoline_get_uint_prop ok
D402 0x4c/0x0 - - MISSING in driver
D404 0x48/0x0 0x48/0x0 trampoline_nop ok
D405 0x4c/0x8 - - MISSING in driver
D406 0x48/0x0 0x48/0x0 trampoline_set_fx_prop ok
D407 0x48/0x0 - - MISSING in driver
D408 0x8/0x8 0x8/0x8 trampoline_get_frequency_v27 ok
D409 0xc/0x4 - - MISSING in driver
D410 0x14/0x8 - - MISSING in driver
D411 0x10/0x1c 0x10/0x1c trampoline_map_reg ok
D412 0x448/0x4 - - MISSING in driver
D413 0x1048/0x4 0x1048/0x4 trampoline_true ok
D414 0x50/0x4 0x50/0x4 trampoline_sr_set_property_int ok
D415 0x4c/0x4 0x4c/0x4 trampoline_true ok
D416 0x84/0x4 - - MISSING in driver
D417 0x448/0x4 - - MISSING in driver
D418 0x1048/0x4 - - MISSING in driver
D419 0x50/0x4 - - MISSING in driver
D420 0x4c/0x4 - - MISSING in driver
D421 0x84/0x4 - - MISSING in driver
D422 0x48/0x4 - - MISSING in driver
D423 0x44/0x0 - - MISSING in driver
D424 0x44/0x0 - - MISSING in driver
D451 0x14/0x14 0x14/0x14 trampoline_allocate_buffer_v27 ok
D452 0x8/0x4 0x8/0x4 trampoline_buffer_lifecycle_v27 ok
D453 0x8/0x4 0x8/0x4 trampoline_buffer_lifecycle_v27 ok
D454 0x4/0x4 0x4/0x4 trampoline_release_mem_desc ok
D550 0x444/0x4 - - MISSING in driver
D551 0x1044/0x4 - - MISSING in driver
D552 0x1044/0x4 0x1044/0x4 trampoline_true ok
D553 0x1044/0x4 - - MISSING in driver
D554 0x4c/0x4 - - MISSING in driver
D555 0x4c/0x4 - - MISSING in driver
D556 0x48/0x4 - - MISSING in driver
D557 0x80/0x4 - - MISSING in driver
D558 0x80/0x4 - - MISSING in driver
D559 0x444/0x4 - - MISSING in driver
D560 0x1044/0x4 - - MISSING in driver
D561 0x1044/0x4 0x1044/0x4 trampoline_true ok
D562 0x1044/0x4 - - MISSING in driver
D563 0x4c/0x4 0x4c/0x4 trampoline_true ok
D564 0x4c/0x4 - - MISSING in driver
D565 0x48/0x4 0x48/0x4 trampoline_true ok
D566 0x80/0x4 - - MISSING in driver
D567 0x80/0x4 0x80/0x4 trampoline_true ok
D568 0x80/0x4 - - MISSING in driver
D569 0x44/0x4 0x44/0x4 trampoline_set_boolean_property_v27 ok
D570 0x1004/0x4 - - MISSING in driver
D571 0x8/0x4 - - MISSING in driver
D572 0x4/0x4 0x4/0x4 trampoline_zero ok
D573 0x4/0x8 - - MISSING in driver
D574 0x4/0x8 0x4/0x8 iomfbep_cb_video_range_h17p ok
D575 0x58/0x4c 0x58/0x4c trampoline_hotplug_h17p ok
D576 0x4/0x0 0x4/0x0 trampoline_nop ok
D577 0x8/0x0 - - MISSING in driver
D578 0x0/0x0 - - MISSING in driver
D579 0x4/0x4 - - MISSING in driver
D580 0x0/0x0 - - MISSING in driver
D581 0x0/0x0 - - MISSING in driver
D582 0xc/0x0 - - MISSING in driver
D584 0x0/0x0 - - MISSING in driver
D586 0x8/0x4 0x8/0x4 iomfbep_cb_create_dfb_surface ok
D587 0x0/0x0 0x0/0x0 trampoline_nop ok
D588 0x18/0x0 0x18/0x0 trampoline_nop ok
D589 0xe4/0xe0 0xe4/0xe0 trampoline_swap_info_h17p ok
D590 0x14/0x0 - - MISSING in driver
D592 0x0/0x0 0x0/0x0 trampoline_nop ok
D593 0x8/0x0 - - MISSING in driver
D594 0x730/0x0 0x730/0x0 trampoline_swap_complete ok
D595 0x2708/0x400 - - MISSING in driver
D596 0x14/0x0 0x14/0x0 trampoline_swap_complete_intent_gated ok
D597 0x4/0x0 0x4/0x0 trampoline_abort_swap_ap_gated ok
D598 0x4/0x0 0x4/0x0 trampoline_enable_backlight_message_ap_gated ok
D599 0x4/0x0 0x4/0x0 trampoline_nop ok
D600 0x4/0x0 - - MISSING in driver
D601 0x0/0x4 0x0/0x4 trampoline_false ok
D602 0x0/0x4 0x0/0x4 trampoline_false ok
D603 0x0/0x0 0x0/0x0 trampoline_nop ok
```

## 6. A427 in detail (and what to send instead)

- What the firmware said: `rpc_callee_gated` (`0x187aa8`) found no handler for
  the incoming tag `0x41343237` and took the not-found path at `0x1885e8` ->
  `0x188a6c` -> panic. The DCP served A401 just before (that is why "DCP
  booted" printed, though on 27.2 that A401 is not start_signal; see §8); the next record, A427, is the first selector of the
  vanished A402-A449 range.
- It is the AP's `iomfb_get_color_remap_mode()` call from `dcp_started()`.
  On 27.2 the method is **A477**, stub `0x1d5f94`:
  - `cmp w3, #8` -> in_len >= 8; `cmp w5, #8` -> out_len >= 8 (both
    `0x80000001` / panic code 5 if short);
  - in: `u32 mode` at +0, `u8 mode_null` at +4 (bit 0 set = pass NULL);
    `mode` is copied to out+0 (in/out pointer);
  - calls `IOMobileFramebuffer::get_color_remap_mode(DisplayColorRemapMode *) const`
    (vtable +0x2c0, discriminator 0x8273), converts its IOMFBStatus with
    `0x1bde80` and stores it at **out+4**; returns 0 to the dispatcher.
  - So: send `A477` with the existing `struct iomfb_get_color_remap_mode_req`
    (8 bytes, `.mode = 6`, `.mode_null = 0`) and
    `struct iomfb_get_color_remap_mode_resp` (8 bytes: `mode`, `ret`);
    `ret == 0` is success. `init_1` ignores the reply, which stays correct.
- No stub on the AP side is needed for "A427": it is not a callback, and
  answering it is the firmware's job.

## 7. Patch plan (appledrm, in the order the calls are hit)

Do not edit the 27.0 table in place: T6050 on 27.0 still needs it. Make the
renumbering a property of the 27.2 firmware.

### 7.1 Know that the firmware is 27.2 (dcp.c / dcp-internal.h)

The T6041 27.2 branch of `dcp_check_firmware_version()` (kernel doc 3.1)
already returns `DCP_FIRMWARE_V_27_0`. Next to it, record the minor:

```c
/* dcp-internal.h, struct apple_dcp, next to fw_compat */
	/* macOS 27.2+ firmware on the firmware-27 interface: renumbered methods. */
	bool fw_v27_2;
```

and in probe where `dcp->fw_compat` is set (`dcp.c:6355`), set
`dcp->fw_v27_2 = true` when the compat/version string is `27.2.x` (the same
parse as the 3.1 branch; T6050 on `27.0.0` keeps it false).

### 7.2 Retag methods at push time (iomfb_v27.c + iomfb.c)

One function covers the shared table, the hard-coded tags in
`iomfb_template.c`, and anything sent through `dcp_push_context()`:

```c
/* iomfb_v27.c (prototype in iomfb_v27.h) */
/*
 * macOS 27.2 renumbered the AP->DCP methods relative to 27.0: the
 * IOMobileFramebuffer block A402..A499 moved to A452..A549 (27.2 has no
 * A402..A449), and one UnifiedPipeline method was inserted below A390, so
 * set_create_DFB A389 -> A390 and vi_set_temperature_hint A390 -> A391.
 * Callbacks (D###) did not move.
 */
void iomfb_v27_2_retag(char tag[4])
{
	unsigned int n;

	if (tag[0] != 'A' || !isdigit(tag[1]) || !isdigit(tag[2]) ||
	    !isdigit(tag[3]))
		return;
	n = (tag[1] - '0') * 100 + (tag[2] - '0') * 10 + (tag[3] - '0');
	if (n >= 400 && n <= 499)	/* see §8: includes start_signal */
		n += 50;
	else if (n == 389 || n == 390)
		n += 1;
	else
		return;
	tag[1] = '0' + n / 100;
	tag[2] = '0' + n / 10 % 10;
	tag[3] = '0' + n % 10;
}
```

```c
/* iomfb.c, dcp_push_context(), right after the H17G alias (line ~962) */
	if (dcp->fw_compat == DCP_FIRMWARE_V_27_0 && dcp->fw_v27_2)
		iomfb_v27_2_retag(resolved.tag);
```

(`#include <linux/ctype.h>` for `isdigit`.) The trace/log helpers that print
`call->tag` then print the 27.2 number, which is what the firmware logs use.
If the peer paths (`dcp_peer_call*`, `dcp_peer_video_call*`) build records
without `dcp_push_context()`, apply the same function there; they are T6050
tiling paths and are not reached on the T6041 internal panel.

Resulting tags, in hit order:

1. right after "DCP booted": `get_color_remap_mode` **A427 -> A477**.
2. client-open sequence (`dcp_client_open_seq`): `get_dfb_state` A453 -> A503,
   `set_display_device` A411 -> A461, A503 again, `pipe_cfg_415` A415 -> A465,
   `enable_disable_video_power_savings` A458 -> A508, `pipe_cfg_031` A033 x9
   (unchanged), `pipe_cfg_414` A414 -> A464, `pipe_query_478` A489 -> A539,
   `first_client_open` A466 -> A516, `pipe_query_474` A485 -> A535, A539,
   `pipe_set_476` A487 -> A537, A539.
3. `init_3`: `is_main_display` A412 -> A462.
4. first modeset / swap: `set_digital_out_mode` A413 -> A463,
   `set_display_refresh_properties` A475 -> A525, `swap_start` A406 -> A456,
   `swap_submit` A408 -> A458, `set_matrix` A423 -> A473,
   `setBrightnessCorrection` A428 -> A478, `set_parameter_dcp` A450 -> A500,
   `set_power_state` A484 -> A534, `flush_supports_power` A478 -> A528.
5. D120 boot chain, only if the firmware runs it (it did not on the
   adopted-DCP run): `set_create_dfb` **A389 -> A390** (A389 would panic with
   code 5), `create_default_fb` A454 -> A504, DFB block A035/A036/A037/A103/A104/
   A105 unchanged, `setup_video_limits` A027 unchanged,
   `dfb_ready_query` A384 (keep; see section 4), `late_init_signal` A000
   unchanged; D100 nested `vi_set_temperature_hint` **A390 -> A391**;
   D586 nested `register_dfb_surface` A483 -> A533.
6. teardown: `last_client_close` A467 -> A517, `abort_swaps_dcp` A479 -> A529.

All sizes the driver already sends satisfy the 27.2 minimums (section 4), so
no request/response struct has to change for boot and the first modeset.

### 7.3 Follow-ups (not blocking)

- `abort_swaps_dcp` on 27.2 (A529): send/parse the 26.6-desktop layout
  (in `u64 client` = 8 bytes, out `u32 status` at offset 0). The v27 structs
  are accepted but read the status from +0x10, so a failure would be missed.
- `dfb_ready_query`: if the D120 chain ever runs and the firmware behaves
  differently, try A385; both A384 and A385 are side-effect-free bool getters.
- Callbacks: optionally add `cb_handlers`/`callback_sizes` entries for the
  unknown ones that actually show up in dmesg, with the exact sizes in
  section 5, to silence "received unknown callback" (functionally identical to
  today's zero reply).
- `iomfb_v27_callback_size_valid()` and the callback tables need no change.

## 8. Second crash: `NO LINK CALLS ALLOWED IN IBOOT-- id D574`

### 8.1 Where and what it checks

The string (`text 0x6d9bed`) has one xref, `0x18a620`, inside **`rpc_call`
(`0x18a458`)**, the function every DCP->AP callback goes through:

```
18a474  adrp x8, text+0x9b5000
18a478  ldrb w8, [x8, #0x734]      ; global "AP link up" byte (dcp-data.bin+0x2b9734)
18a480  tbz  w8, #0, 0x18a604      ; clear -> "NO LINK CALLS ALLOWED IN IBOOT-- id D%s" + panic
```

It is **not** a context id or a message field: it is one global byte for the
whole IOMFB AP link. It is written in two places only:

- `0x25a760` `strb #1` at the very start of **`UnifiedPipeline::start_ios_gated()`**
  (`0x25a72c`; strings "Created AP Services", "start_hardware_boot failed",
  "DRIVER DIDN'T LOAD"). This function then creates the AP services (D107-D112),
  calls D100/D120 (`start_hardware_boot`)/D122, sets `[+0x735]` and flushes RTPs.
  It is the macOS bring-up path.
- `0x244d54` in `UnifiedPipeline::start_hardware_root_iboot()` (the iBoot
  path), from a power-gates EDT check. In the dump (iBoot-started DCP) the byte is 0.

Many callback wrappers test the byte and fall back to a local implementation
when it is clear (e.g. D121 at `0x25f88c`); the ones that do not (D574 at
`0x1d04fc` among them) go straight to `rpc_call` and hit the panic.

### 8.2 Why we are still "in iBoot": start_signal is A451 on 27.2

The +50 renumbering starts at **A400**, not A402. On 27.2:

- **A451** (`0x1d7f44`, in 0, out >= 4) takes the IOMFB workloop gate and
  calls `0x1cd984`, which calls `IOMobileFramebuffer::start_ios_gated()`
  through the vtable (`+0x38`, discriminator **0x50ca** = SipHash of
  `_ZN19IOMobileFramebuffer15start_ios_gatedEv`, verified) and that reaches
  `UnifiedPipeline::start_ios_gated()`. The reply is `strb (status == 0)` at
  out+0. This is 27.0's **A401 `start_signal`** (+50).
- **A401** on 27.2 (`0x25fcc0`, out >= 4) is the last UnifiedPipeline method
  (A350..A401): it only copies the byte at `instance+0x6754` to out+0 and
  returns 0. No side effects.

So the driver's `dcp_start_signal()` (A401, not retagged) succeeded
without starting anything, the driver printed "DCP booted", the AP link
byte stayed 0, and the first callback that does not check it (D574) panicked.
A477 itself is not the trigger: `IOMobileFramebuffer::get_color_remap_mode`
(`0x1c6fc8`) just stores 6 and returns. D574 comes from one of the next
client-open methods (A503/A461/A465/A508 ...). Which one could not be pinned
statically, because the AP-proxy vtables are not in the TEXT/DATA dumps. It
does not matter, because every non-checking callback would panic the same way
until `start_ios_gated` has run.

### 8.3 D574

Wrapper `0x1d04fc`: `IOMFBStatus f(this, float *out)`. It sends in = 4 bytes
`{u8 out_is_null; pad[3]}` and out = 8 bytes `{float value; u32 status}`
(`rpc_call('D574', &in, 4, &out, 8)`), copies `value` to `*out` when non-NULL,
and maps `status` (1..0x12 table) to an IOMFBStatus. Sizes 4/8 match the
driver's `callback_sizes[574]`, and its handler `iomfbep_cb_video_range_h17p`
answers `{0x435b0000 (219.0f), 0}`, which is the right shape. Nothing to change
here: once the link byte is set, D574 is delivered to the AP normally.

### 8.4 The mailbox words

ep **0x23 is not IOMFB**. It is `DISP0_ENDPOINT` (`dcp-internal.h:92`),
which appledrm drives with `ibootep.c` (the DCP iBoot display service) over AFK.
IOMFB is ep **0x37**. On ep 0x23 the high 16 bits are the AFK ring-buffer
type (`afk.c:37`, `RBEP_TYPE GENMASK(63,48)`):

- `0x0085_0380_03c0_0380` = `RBEP_RECV` (0x85) "ring has data", in the compact
  doorbell form `afk.c:667` builds: rptr = 0x0380 (bits 47:32), new wptr =
  0x03c0 (31:16), old wptr = 0x0380 (15:0), so one 0x40-byte entry. The next one
  (`03c0/0440/03c0`) is one 0x80-byte entry.
- `0x00a2_0000_0000_0000` = `RBEP_SEND` (0xa2) with `SEND_WPTR` (31:0) = 0
  (`afk.c:2836`).

This is iBoot-service EPIC traffic (`ibootep_init()` runs on V_27_0 when
`hw.num_dptx_ports != 0`, `dcp.c:4196-4202`). It is not the IOMFB transport, and
it is not what made the firmware think it is "in iBoot".

IOMFB messages on ep 0x37 keep the driver's encoding (`iomfb.h`: type 3:0 = 2
MSG, ACK bit 6, CONTEXT 11:8, OFFSET 31:16, LENGTH 63:32). The 27.2 firmware
parses them correctly: it decoded our A427/A477 records, tag and sizes. Its
`ap_link` runs four caller and four callee contexts (thread names
`iomfb_ap_caller_0..3` / `iomfb_ap_callee_0..3` in DATA), the same layout as
the driver's CB/ASYNC_CB/OOBCB/OOBASYNC_CB and CMD/ASYNC/OOBCMD/OOBASYNC (ids 0-7).
The context and shared-memory layout need no change.

### 8.5 Patch

1. **Retag A400..A499 by +50** (not A402..A499). In `iomfb_v27_2_retag()`:

   ```c
   	if (n >= 400 && n <= 499)	/* start_signal A401 -> A451 included */
   		n += 50;
   	else if (n == 389 || n == 390)
   		n += 1;
   ```

   `dcp_start_signal()` then sends **A451** (0/4, unchanged sizes). The firmware
   sets the AP-link byte, creates the AP services and calls back D107-D112,
   D100, **D120 (start_hardware_boot)** and D122 *inside* A451, as on 27.0/T6050.
   That is the boot chain the first two runs never reached. In it, the retags
   that now matter are `set_create_dfb` A389->A390, `create_default_fb`
   A454->A504, `flush_supports_power` A478->A528,
   `set_display_refresh_properties` A475->A525, the unchanged A0xx/A1xx DFB
   calls, and `dfb_ready_query` A384 (if anything misbehaves right after
   `late_init_signal`, try A385, see section 4), plus `vi_set_temperature_hint`
   A390->A391 nested in D100.
2. No "leave iBoot" method beyond that is needed: `start_signal` (A451) *is*
   the take-over call, and macOS sends it first. Do not send any other IOMFB
   method before it. The driver already sends nothing else (`iomfb_start_v27()`
   -> `dcp_start_signal()`).
3. No context-id or channel-offset change.
4. Optional, independent: if the iBoot EPIC service on ep 0x23 is not wanted for
   the internal panel, give T6041-on-27 `num_dptx_ports = 0` (kernel doc
   section 2). That traffic is not the cause of this panic.

## 9. After start_signal: failed swaps, default FB surface, backlight

### 9.1 `swap failed! status 4294967295` is the driver's own drop

Status `~0U` is what `dcp_swapped()` (`iomfb_template.c:3297`) reports
when it is called with `data == NULL`. Only one caller does that before the
firmware is involved: `dcp_swap_submit()` (`iomfb_template.c:382-394`):

```c
if (!iomfb_apply_backlight_h17p(dcp, request, &dcp->present_h17p)) {
        if (cb)
                cb(dcp, NULL, cookie);      /* -> "swap failed! status 4294967295" */
        return;                             /* A458 is never sent */
}
```

and `iomfb_apply_backlight_h17p()` (`iomfb.c:~3355`) returns false for a
panel without an active backlight and with `dcp->brightness.maximum == 0`:

```c
if (!dcp_backlight_active(dcp)) {
        if (!dcp_has_panel(dcp)) return true;
        if (!dcp->brightness.maximum) return false;   /* <- every swap */
```

`brightness.maximum` comes only from the panel node's `apple,max-brightness`
(`dcp.c:5786`; "Missing property 'apple,max-brightness'"), except on desktop
26.x, which falls back to `DCP_DESKTOP_MAX_NITS` 600. Without it,
`dcp_work_backlight_fallback()` calls `dcp_backlight_configure()` ->
`dcp_bl_init(maximum = 0)` -> `-EINVAL`, which is the
**`backlight registration failed: -22`**. Symptoms (b) and (c) have one cause:
**no swap ever reaches the firmware**. A456 swap_start is sent and accepted
(otherwise the log would say "swap_start was rejected"). Then A458 is
dropped on the AP, so the panel keeps the iBoot image.

### 9.2 27.2 swap layouts: the driver's v27 structs are exact

**A456 swap_start** (stub `0x1d7b7c`; `IOMobileFramebuffer::swap_start`, vtable
+0x1f0, discriminator 0x5ed5):

| off | in (0x10) | driver `dcp_swap_start_req_h17p` |
|---|---|---|
| 0x0 | u32 swap_id (in/out, copied to out+0) | `swap_id` |
| 0x4 | u64 client (passed as the 2nd argument) | `client` |
| 0xc | u8 bit0 = swap_id pointer is NULL | `client_null` (name is wrong, keep it 0) |

out (8): `u32 swap_id`, `u32 status` at +4 (IOMFBStatus via `0x1bde80`) =
`dcp_swap_start_resp_h17p {swap_id, ret}`.

**A458 swap_submit** (stub `0x1d752c`; `IOMobileFramebuffer::swap_submit_dcp`,
vtable +0x210, discriminator 0x7317). The firmware copies 0xff4 bytes, builds
up to 4 `IOMFB::Surface` objects from the 0x22c-byte descriptors and calls
`swap_submit_dcp(swap, surfaces, dva[4], dva[4], bool, double, dva, bool, u32, bool*, const u32*, u32*)`:

| off | field (27.2) | driver `dcp_swap_submit_req_v27` |
|---|---|---|
| 0x000 | IOMFBSwap record, 0x6e0 (NULL if [0xfea]) | `swap` (0x6e0) |
| 0x6e0 | 4 x surface descriptor, 0x22c each; descriptor i skipped if [0xfeb+i] | `surf[4]` (0x22c) |
| 0xf90 | dva_t[4] (3rd argument) | `surf_iova[4]` |
| 0xfb0 | dva_t[4] (4th argument) | `unk_u64_a[4]` |
| 0xfd0 | bool | `unkbool` |
| 0xfd1 | double (unaligned) | `unkdouble` |
| 0xfd9 | dva_t | `unkU64` |
| 0xfe1 | bool | `unkbool2` |
| 0xfe2 | u32 | `clear` |
| 0xfe6 | const u32 (pointer is NULL if [0xff0]) | `unkU32Ptr` |
| 0xfea | swap_null | `swap_null` |
| 0xfeb | surf_null[4] | `surf_null[4]` |
| 0xfef | null flag for bool* out | `unkoutbool_null` |
| 0xff0 | null flag for the const u32* | `unknown_pointer_null` |
| 0xff1 | null flag for u32* out | `unknown_output_null` |

out (0xc): `u8 bool` at +0, `u32` at +1, **`u32 status` at +5** (`stur w0, [out,#5]`)
= `dcp_swap_submit_resp_{h17p,v27} {unkoutbool; unkU32out; ret; pad[3]}`.
Every offset matches the `static_assert`s in `iomfb_v27.h`. The stub has no
check that fails a swap: the only stub-level failure is a short buffer
(0x80000001, which panics). A refusal from `swap_submit_dcp` comes back as a
nonzero `ret`. So once swaps are sent, a failure prints a real IOMFBStatus
(e.g. 0xe000xxxx), never 0xffffffff. Swap completion still uses
D589/D594/D596/D597 (section 5: unchanged numbers and sizes).

### 9.3 `Creating default FB surface failed - width = 3024, height = 1964`

`IOMobileFramebufferDCP.cpp:3293` is in the function at `0x1c419c` (run on a
mode change). When the default FB is wanted (`[this+0x42fb] == 1`) and the
mode size is nonzero, it calls the AP-proxy `create_default_fb_surface(w, h)`
(vtable +0x5e8, disc 0x1780). That is the wrapper `0x1d0810`, which sends
**D586** with in = `{u32 width; u32 height}` (8) and out = `u8 ok` (4). A false
reply logs this line and **continues** (`0x1c4264` -> log at level
0x40000001 -> `0x1c42bc`). It is not fatal, and the firmware just keeps no
default surface.

The false comes from the driver's `iomfbep_cb_create_dfb_surface()`
(`iomfb_template.c:859`). It answers false when:

1. `apple_dcp_dfb_allocation()` fails. This logs **"unsupported DFB layout
   WxH format=… compression=… (err)"**:
   - `-EINVAL`: `dcp->dfb_region_size == 0`, because the DCP node has no
     `memory-region-names = "framebuffer"` (`dcp.c:5512`, "no boot
     framebuffer" at probe);
   - `-ENOSPC`: the region is smaller than 3024x1964 at the firmware's format
     (about 23.7 MB at 4 bytes per pixel);
   - `-EOPNOTSUPP`: compression is not 0, 2 or 3;
   - `dfb_format_valid` / `dfb_compression_valid` are false. That happens when
     the D120 chain skipped A037/A036: `boot_1_6()` skips them when bit 0 of the
     **A504** reply is 0. On 27.2, A504 (`0x1d3e98`) only returns the byte at
     `instance+0x42eb`; it does not create anything.
2. the nested A533 `register_dfb_surface` (0x230 in) returns a nonzero
   status (`complete_dfb_surface()`). In that case nothing is logged by the driver.

The A037/A036 reply layouts match the driver (A037 out: `u32 compression`, `u8 ok` at
+4; A036: 0x2c with the ok byte at +0x28). `dfb_ready_query` (A384/A385),
`set_create_dfb` (A390) and A504 are not inputs to this check. Swaps do not
need the default surface (each swap carries its own descriptors), so this is
second priority. The H17P note in the driver (a null base and a piodma DART
fault without it) applies only if the firmware scans out before the first swap.

### 9.4 Fixes, in order

1. **Make swaps reach the firmware: give the panel a brightness ceiling.**
   - DT (aura / nix-config DT for J614s): add `apple,max-brightness = <N>;` to
     the `apple,panel` (or `apple,panel-mini-led`) child of the DCP node. N is the
     panel's SDR user-accessible maximum in nits, from the ADT
     (`user-accessible-max-nits`, 16.16; 600 on the J616s per `dcp.c:444`; read the
     J614s value from its ADT and put it in `local/`).
   - or, in the driver (`dcp.c:5785`), extend the desktop fallback to T6041 on
     27.2 so a missing property is not fatal:
     ```c
     } else if (of_device_is_available(panel_np)) {
             ret = of_property_read_u32(panel_np, "apple,max-brightness",
                                        &dcp->brightness.maximum);
             if (ret && dcp->fw_v27_2) {
                     dcp->brightness.maximum = DCP_DESKTOP_MAX_NITS;
                     dev_warn(dev, "no apple,max-brightness: using %u nits\n",
                              DCP_DESKTOP_MAX_NITS);
             } else if (ret)
                     dev_err(dev, "Missing property 'apple,max-brightness'\n");
     }
     ```
   With `maximum != 0`, `dcp_work_backlight_fallback()` registers the
   backlight (half of maximum, no panel change), `iomfb_apply_backlight_h17p()`
   encodes the level into `swap.brightness_nits` (+0x35e) and A458 is sent.
   Also consider logging the drop in `dcp_swap_submit()` (one
   `dev_warn_ratelimited`), so a refusal on the AP side cannot look like a firmware
   status again.
2. **Re-run and read A458's real `ret`.** If a swap is refused now, it is
   `resp->ret` at out+5 from `swap_submit_dcp`. Report the value: it says
   which firmware check failed. The wire layouts are already right (9.2).
3. **Default FB surface** (if wanted): check dmesg for "unsupported DFB layout"
   and for "no boot framebuffer". Then do one of:
   - give the DCP node the boot framebuffer `memory-region` /
     `memory-region-names = "framebuffer"` (from the ADT/iBoot framebuffer, at
     least 3024x1964x4 rounded to 16K);
   - if the log shows `format=0 compression=0` with the valid flags clear, make
     `boot_1_6()` on 27.2 not depend on A504 bit 0 (always query A037 then
     A036);
   - if no line is logged, print `get_unaligned_le32(out)` in
     `complete_dfb_surface()` to see A533's status.
4. Unchanged and already correct: the A456/A458 request/response structs, and the
   swap-complete callbacks D589/D594/D596/D597.
