# UART worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

UART is the first of the seven boot drivers. It is the serial console. A display driver is not required to reach a shell. This log is the host-side work: an OCaml client that speaks m1n1's proxy, and an unmodified m1n1 image whose early console points at this Mac's UART.

The Mac was running macOS the whole time. Nothing here poked the live UART.

## Hardware

| Fact | Value |
|---|---|
| Node | `/arm-io/uart0` |
| Compatible | `uart-1,samsung` |
| CPU physical base | `0x429200000` |
| Window size | `0x4000` |
| Bus address in the raw ADT `reg` cell | `0x229200000` |
| Clock | 24 MHz |
| 115200 baud divisor | 12 |

`0x429200000` is the `IODeviceMemory` address from the dumped device tree, and it is `EARLY_UART_BASE` for `T6040` and `T6041` in `upstream/m1n1/src/soc.h`. The raw ADT cell is the address on the `arm-io` bus. m1n1 translates that before it touches the device, so the client uses the CPU physical address.

Register offsets match `upstream/m1n1/src/uart_regs.h`:

| Register | Offset |
|---|---|
| `ULCON` | `0x000` |
| `UCON` | `0x004` |
| `UFCON` | `0x008` |
| `UTRSTAT` | `0x010` |
| `UFSTAT` | `0x018` |
| `UTXH` | `0x020` |
| `URXH` | `0x024` |
| `UBRDIV` | `0x028` |
| `UFRACVAL` | `0x02c` |

`UTRSTAT` bits used by the transmitter: `TXE` is bit 2 (`0x4`), `TXBE` is bit 1 (`0x2`). `start.S` waits on bit 1 before it stores a byte to `UTXH`. The baud divisor is `((clock / baud) + 7) / 16 - 1`. At 24 MHz and 115200 that is 12.

## What was built

m1n1 stays a submodule and its sources were not edited. `upstream/m1n1` is still `v2.0.0-105-gcf37927d`, and that worktree is clean. The host program loads and drives that code. An upstream bump stays a submodule update.

| Piece | Path | Role |
|---|---|---|
| Inner proxy | `lib/proto/proxy.ml` | 56-byte request, 24-byte reply. Opcodes include `P_READ32` (`0x105`) and `P_WRITE32` (`0x101`) |
| UART driver | `lib/soc/uart.ml` | Polls `UTRSTAT`, writes `UTXH`, turns `\n` into `\r\n` |
| Outer framing | `lib/proto/wire.ml` | UART proxy commands and replies, including the checksum |
| Loopback | `lib/boot/loopback.ml` | In-process stand-in for `uartproxy_run` |
| Image search | `lib/boot/m1n1_image.ml` | Finds `0x429200000` in a built `m1n1.bin` |
| Client | `lib/boot/client.ml` | Runs one string through the stack and reports the image |
| Build image | `docker/m1n1.Dockerfile` | Toolchain for the unmodified submodule |
| Tests | `test/test_nixos_m4pro.ml` | Framing, checksum, loopback, and the string round trip |

## How the client talks to m1n1

There are two layers, both copied from upstream behavior.

The inner layer is `ProxyRequest` / `ProxyReply` in `src/proxy.h`. A request is 7 little-endian u64s: opcode plus 6 arguments. A reply is opcode, signed status, and value (24 bytes). `S_OK` is 0. `S_BADCMD` is -1.

The outer layer is `UartRequest` / `UartReply` in `src/uartproxy.c`, and `UartInterface` in `proxyclient/m1n1/proxy.py`.

- A command is 64 bytes: u32 command, 56-byte payload, u32 checksum.
- A reply is 36 bytes: u32 command, i32 status, 24-byte data, u32 checksum.
- `REQ_PROXY` is `0x01AA55FF`. Its payload is the 56-byte inner request. The 24-byte data field of the reply is the inner reply.
- The checksum starts at `0xDEADBEEF`. For each byte, `sum = sum * 31337 + (byte xor 0x5A)`, modulo 2^32, then xor `0xADDEDBAD`. It covers every byte except its own field.
- A bad checksum comes back as status `ST_CSUMERR` (`-4`), little-endian `fc ff ff ff`.

`put_string` does what `uart_putchar` does. For each byte it issues `P_READ32` of `0x429200010` until `TXBE` is set, then `P_WRITE32` of the byte to `0x429200020`. A newline is sent as `\r` then `\n`.

The loopback checks that checksum, answers `P_GET_CHIPID` with `0x6040`, and models the UART window. `UTRSTAT` always reports the transmitter empty, which is the Samsung UART once the FIFO has drained. Bytes stored to `UTXH` are kept so the host can see what would have left the port. On a UART, m1n1 refuses the only optional feature bit, so `REQ_NOP` enables nothing.

## How the m1n1 image was built

`debug_putc` in `src/start.S` loads `EARLY_UART_BASE` only when `TARGET` is defined at compile time. `config.h` leaves `TARGET` commented out. Passing the macro on the make command line bakes `0x429200000` into the image without a patch:

```sh
make EXTRA_CFLAGS=-DTARGET=0x6040
```

`EXTRA_CFLAGS` is part of `BASE_CFLAGS`, and the assembler uses `BASE_CFLAGS`, so the flag reaches `start.S`. `ldr x1, =EARLY_UART_BASE` emits the constant in the literal pool. The little-endian bytes are `00 00 20 29 04 00 00 00`.

The image is `nixos-m4pro-m1n1`, built from `docker/m1n1.Dockerfile`. The recipe matches `upstream/m1n1/Dockerfile` except for the base image.

Docker Hub rejected the saved login token (`401`, personal access token expired). The base is the public ECR copy of Debian, `public.ecr.aws/debian/debian:trixie-slim`. Bookworm was tried first. Its binutils 2.40 rejects `.arch armv9.4-a`, which `src/utils.h` emits for some system registers. Trixie has binutils 2.44 and gcc 14.2.0, and that assembler accepts the directive. Rust is installed in the image because m1n1 links `librust.a`.

On this arm64 Mac the container is native `aarch64`, so the Makefile leaves `ARCH` empty and uses system `gcc`. The build tag was passed in because the container cannot see the parent `.git` and `version.sh` would otherwise write an empty tag:

```sh
docker build -f docker/m1n1.Dockerfile -t nixos-m4pro-m1n1 upstream/m1n1

docker run --rm \
  -e M1N1_VERSION_TAG="$(git -C upstream/m1n1 describe --tags --always --dirty)" \
  -v "$PWD/upstream/m1n1:/m1n1" -w /m1n1 \
  nixos-m4pro-m1n1 make EXTRA_CFLAGS=-DTARGET=0x6040
```

`build/` is gitignored inside the submodule. The products are owned by the host user after a `chown` in the same image.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. The tests pin the checksum against the Python implementation in `proxy.py` (empty buffer `0x73736542`, a single zero byte `0x8f9fedcc`, a NOP command `0x4b973968`, a `P_READ32` of `UTRSTAT` `0x6281318c`). They also reject a broken reply checksum, reject a broken command checksum with status `-4`, read back a written `UBRDIV` of 12, and round-trip `nixos-m4pro\n` to `nixos-m4pro\r\n`.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
nixos-m4pro host client for Mac16,8 / J614s / T6040
UART /arm-io/uart0 uart-1,samsung
physical base 0x429200000, size 0x4000, clock 24000000
115200 baud divisor 12
loopback chip id 0x6040
UART TX "nixos-m4pro\r\n"
m1n1 image upstream/m1n1/build/m1n1.bin contains early UART 0x429200000 at offset 0xa00
Live UART is /dev/cu.usbmodemP_01 at 115200 baud, from a second machine.
```

`upstream/m1n1/build/m1n1.bin` is 5,046,272 bytes. The same constant is in `build/m1n1.macho` at offset `0x10a00`. `build/build_tag.h` is `#define BUILD_TAG "v2.0.0-105-gcf37927d"`, and those bytes are inside `m1n1.bin`.

## Still open

The live port is `/dev/cu.usbmodemP_01` at 115200, which is the Darwin default in `proxy.py`. It shows up when this Mac is booted into m1n1 and the client runs on a second machine. This session did not boot the hardware.

`uart_init` in current m1n1 only locates `/arm-io/uart0`. Baud setup is `uart_setbaud`, which writes `UBRDIV` with the same divisor formula. The loopback does not claim to be the silicon FIFO timing. It answers `TXBE` immediately so the poll in `put_byte` can finish.
