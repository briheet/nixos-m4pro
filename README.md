# nixos-m4pro

Host-side work toward NixOS on a 14-inch MacBook Pro with M4 Pro (`Mac16,8` / `J614s` / `T6040`). An OCaml client drives an unmodified [m1n1](https://github.com/AsahiLinux/m1n1). The boot image is m1n1 with a Linux kernel and a small initramfs concatenated after it.

This does not install NixOS, and it does not boot this Mac by itself. Two things can be reproduced from a fresh clone:

- The host client, on the in-process loopback. It prints the boot-path log. It does not touch hardware.
- `build/linux/m1n1-linux.bin`. m1n1's payload scanner can read it. Handing it to a machine needs a second computer, and the target Mac already running m1n1. That handoff has not been run for this tree.

The laptop screen stays dark. The shell, if the handoff reaches userspace, is on the debug serial port.

## Layout

| Path | What it is |
|---|---|
| `lib/` | UART, watchdog, AIC, PMGR, DART, PCIe, SART, NVMe, and the payload handoff |
| `bin/main.ml` | Runs the loopback boot path |
| `docs/required_to_boot/` | Notes for those drivers |
| `docker/m1n1.Dockerfile` | Debian trixie image used to cross-build |
| `scripts/build-m1n1-linux.sh` | Builds the concatenated image inside that container |
| `upstream/m1n1`, `upstream/linux` | Checkouts you clone yourself. They are not in this commit |
| `build/` | Build output. Git ignores it |
| `configs/` | Machine dumps from the original Mac. Git ignores them. Nothing here needs them |

`.gitmodules` names the two upstream repositories. This commit does not record submodule commits, so `git submodule update` will not fetch them.

## Sources

m1n1 `cf37927d6bf47c502136e7d2c9e61f946b0b8745` (`v2.0.0-105-gcf37927d`).

Asahi Linux `7b0c21fc289711e372fa3cd48a509f837cc9a4bf` (`arm64: dts: apple: Add minimal t604x (M4 Pro/Max) device trees`).

```bash
git clone https://github.com/briheet/nixos-m4pro
cd nixos-m4pro
git clone https://github.com/AsahiLinux/m1n1 upstream/m1n1
git -C upstream/m1n1 checkout cf37927d6bf47c502136e7d2c9e61f946b0b8745
git clone --filter=blob:none \
  https://github.com/AsahiLinux/linux upstream/linux
git -C upstream/linux checkout 7b0c21fc289711e372fa3cd48a509f837cc9a4bf
```

On a case-insensitive disk, the Linux checkout warns about colliding header names. The tree still builds. `uname` then ends in `-dirty`.

## Host client

The flake covers `aarch64-darwin`, `aarch64-linux`, `x86_64-darwin`, and `x86_64-linux`.

```bash
nix develop
dune test
dune exec nixos-m4pro
```

The program walks UART, the watchdog, AIC, PMGR, DART, PCIe, SART, and NVMe on a loopback peer, then records a kboot handoff. The last lines are the loopback's 64-byte stand-in kernel, not `m1n1-linux.bin`. The host gzip reader accepts stored deflate blocks only. The real `Image.gz` is Huffman, so this program does not scan the boot image. m1n1's own decompressor does.

`upstream/m1n1` is not modified. A newer m1n1 is a different checkout, not a patch in this repo.

## Boot image

The image is four pieces, in the order m1n1 scans them:

1. `upstream/m1n1/build/m1n1.bin`, built for `T6040`, with no chainloading support and no payload of its own.
2. One config line: `chosen.bootargs=earlycon console=ttySAC0,115200 debug rw`.
3. `build/linux/j614s.dtb`, from `t6040-j614s.dts`. Compatible strings are `apple,j614s`, `apple,t6040`, `apple,arm-platform`.
4. A gzip newc cpio, then `Image.gz`.

`/init` mounts `/proc` and `/sys`, prints the devicetree model, `uname`, the CPU count, and `MemTotal`, then runs `setsid cttyhack /bin/sh`. That is a BusyBox shell from Debian `busybox-static`. It is not a NixOS closure. The kernel is that Linux tree's `defconfig`. AIC, the Samsung UART, and the PMGR power-state driver are built in. NVMe, DART, the mailbox, RTKit, SART, and the watchdog are modules, and this initramfs contains no modules, so the shell has no disk and no display.

Build the toolchain image once. The Dockerfile context is the m1n1 tree.

```bash
docker build -f docker/m1n1.Dockerfile -t nixos-m4pro-m1n1 upstream/m1n1
```

Build m1n1. Leave `config.h` alone. `CHAINLOADING` stays unset, so a machine that boots this file with nothing concatenated waits on the proxy instead of jumping to Linux.

```bash
docker run --rm -v "$PWD/upstream/m1n1:/m1n1" -w /m1n1 nixos-m4pro-m1n1 \
  bash -lc 'make -j"$(nproc)" EXTRA_CFLAGS=-DTARGET=0x6040'
```

The raw image is `upstream/m1n1/build/m1n1.bin`.

Build the kernel, the devicetree, the initramfs, and the concatenation. This needs a few gigabytes under `build/linux/` and a while of compile time.

```bash
mkdir -p build/linux
docker run --rm \
  -v "$PWD/upstream/linux:/src:ro" \
  -v "$PWD/build/linux:/out" \
  -v "$PWD/upstream/m1n1/build/m1n1.bin:/m1n1/m1n1.bin:ro" \
  -v "$PWD/scripts/build-m1n1-linux.sh:/build.sh:ro" \
  nixos-m4pro-m1n1 bash /build.sh
```

The script prints `BUILD_OK`. The file to copy to the second machine is `build/linux/m1n1-linux.bin`.

## Trying the image

This needs the target Mac already sitting in m1n1, and a second computer. A charge-only USB-C cable will not carry the serial pins. Use a SuperSpeed cable, plugged into the DFU port on both machines. On a 14-inch MacBook Pro that port is the left USB-C port closest to the hinge. When the second computer is also Apple Silicon, [macvdmtool](https://github.com/AsahiLinux/macvdmtool) is what brings the debug UART up.

The m1n1 that iBoot starts is the `m1n1.bin` from the previous section, installed as the boot object of a second APFS volume from One True Recovery with `kmutil configure-boot`. Asahi's [m1n1 hypervisor preparation](https://asahilinux.org/docs/sw/m1n1-hypervisor/) is the write-up of that install. Point it at the second volume. The Asahi installer does not support this model, so it will not do this step.

On the second computer, from the m1n1 checkout:

```bash
pip install -r requirements.txt
export M1N1DEVICE=/dev/cu.usbmodemP_01   # Linux hosts usually use /dev/ttyACM0
python3 proxyclient/tools/shell.py
```

A proxy prompt means the cable and m1n1 are up. Leave that shell, then:

```bash
python3 proxyclient/tools/chainload.py -r /path/to/m1n1-linux.bin
```

`-r` is required because the file is a raw image. When that command returns, open the same serial device at 115200. The banner from `/init` is the sign that Linux reached the shell. Typing in that window is the keyboard for it. The keyboard on the target Mac is not.

`kboot_prepare_dt` still runs only on the machine that is in m1n1. It fills memory, the serial number, MAC addresses, and SEP from the live device tree. Those values are not in this repository.
