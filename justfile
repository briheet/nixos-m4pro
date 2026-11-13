# NixOS on the 14-inch MacBook Pro M4 Pro (J614s): build, boot and install.
# README.md walks through a full install; `just --list` shows the recipes.
#
# Everything that runs on the Mac is built by Nix from this flake (pinned
# nixpkgs, pinned kernel and m1n1 sources, the patches in kernel/patches and
# m1n1/patches) inside an aarch64-linux builder container. The host only
# copies the results to build/out and talks to the target over debug USB.

set shell := ["bash", "-euo", "pipefail", "-c"]

builder := "nixos-m4pro-builder"
nix_image := "nixos/nix:2.28.3"
m1n1_repo := "https://github.com/AsahiLinux/m1n1"
m1n1_rev := "cf37927d6bf47c502136e7d2c9e61f946b0b8745"
vdm := env("MACVDMTOOL", home_directory() / "code/macvdmtool/macvdmtool")
port := "/dev/cu.kis-100000-ch-0"

default:
    @just --list

# --- host setup ------------------------------------------------------------

# Create the builder: Nix in an aarch64-linux container, with the store on a volume.
builder:
    if docker inspect {{builder}} >/dev/null 2>&1; then \
      docker start {{builder}} >/dev/null; \
    else \
      docker run -d --name {{builder}} -v nixos-m4pro-nix:/nix -v nixos-m4pro-src:/src \
        -v "$PWD":/work -w /work {{nix_image}} sleep infinity >/dev/null; \
      docker exec {{builder}} sh -c 'mkdir -p /etc/nix && printf "experimental-features = nix-command flakes\nsandbox = false\nmax-jobs = auto\ncores = 0\nfilter-syscalls = false\n" > /etc/nix/nix.conf'; \
    fi
    docker exec {{builder}} sh -c 'git config --global --add safe.directory /work; uname -m; nix --version'

# Host tools: m1n1 (pinned, with m1n1/patches) in upstream/m1n1, its Python deps, the OCaml tools.
setup:
    if [ ! -d upstream/m1n1 ]; then \
      git clone {{m1n1_repo}} upstream/m1n1; \
      git -C upstream/m1n1 checkout -q -b nixos-m4pro {{m1n1_rev}}; \
      git -C upstream/m1n1 am -q "$PWD"/m1n1/patches/*.patch; \
    fi
    test "$(git -C upstream/m1n1 rev-parse 'HEAD~{{num_m1n1_patches}}')" = {{m1n1_rev}}
    git -C upstream/m1n1 diff --quiet HEAD
    test -d .venv-m1n1 || python3 -m venv .venv-m1n1
    .venv-m1n1/bin/pip install -q -r tools/requirements-m1n1.txt
    dune build

num_m1n1_patches := `ls m1n1/patches/*.patch | wc -l | tr -d ' '`

# --- build -----------------------------------------------------------------

# Build the kernel, device tree, RAM installer and installed system into build/out.
build: builder
    docker exec -w /work {{builder}} sh -c '\
      out=$(nix build --no-link --print-out-paths .#boot-files) && \
      mkdir -p build/out && cp -fL $out/* build/out/ && \
      chmod 644 build/out/*'
    ls -l build/out

# Build m1n1 into build/out: `stage1` (release + chainload to the ESP) or `dev` (the bring-up proxy build).
m1n1 variant="stage1": builder
    docker exec -w /work {{builder}} sh -c '\
      out=$(nix build --no-link --print-out-paths .#m1n1-{{variant}}) && \
      mkdir -p build/out && cp -fL $( [ -f $out ] && echo $out || echo $out/lib/m1n1/m1n1.bin ) build/out/m1n1-{{variant}}.bin && \
      chmod 644 build/out/m1n1-{{variant}}.bin'
    shasum -a 256 build/out/m1n1-{{variant}}.bin

# --- the target ------------------------------------------------------------
#
# Development runs over m1n1's own USB device, as Asahi develops: m1n1's
# proxy on its first serial port, the hypervisor's virtual UART (the guest
# kernel's console) on its third. Debug USB (macvdmtool debugusb, the
# dockchannel) is the fallback for when m1n1's USB device is not there.

m1n1_usb := "/dev/cu.usbmodem*1"
m1n1_vuart := "/dev/cu.usbmodem*3"

# Restart the M4 Pro into m1n1 and wait for m1n1's USB device.
restart:
    pkill -f 'tools/tether-boot.py|tools/m4console|run_guest.py' || true
    sudo -n {{vdm}} reboot | tail -n 1
    for i in $(seq 60); do ls {{m1n1_usb}} >/dev/null 2>&1 && break; sleep 1; done
    ls {{m1n1_usb}} {{m1n1_vuart}}
    for i in 1 2 3 4 5; do \
      M1N1DEVICE=$(ls {{m1n1_usb}}) perl -e 'alarm 20; exec @ARGV' .venv-m1n1/bin/python -c \
        "import sys; sys.path.insert(0, 'upstream/m1n1/proxyclient'); from m1n1.setup import *" >/dev/null 2>&1 \
        && echo "m1n1 answers" && exit 0; sleep 2; done; echo "m1n1 is not answering" >&2; exit 1

# Boot `ram` (the installer) or `disk` (the SSD's system) on bare metal: m1n1's stock linux.py uploads over m1n1's USB device, then the console is relayed from the dockchannel over debug USB.
dev-boot system="disk":
    #!/usr/bin/env bash
    set -euo pipefail
    for f in Image.gz t6040-j614s.dtb {{system}}-initrd {{system}}-cmdline; do
      test -f build/out/$f || { echo "build/out/$f missing; run just build" >&2; exit 1; }
    done
    pkill -f 'tools/m4console|tools/linux.py' || true
    M1N1DEVICE=$(ls {{m1n1_usb}}) PYTHONUNBUFFERED=1 nohup .venv-m1n1/bin/python \
      upstream/m1n1/proxyclient/tools/linux.py build/out/Image.gz build/out/t6040-j614s.dtb \
      build/out/{{system}}-initrd -b "$(cat build/out/{{system}}-cmdline)" < /dev/null > build/linux-py.out 2>&1 &
    # Linux has started once m1n1's USB device goes away.
    for i in $(seq 120); do ls {{m1n1_usb}} >/dev/null 2>&1 || break; sleep 1; done
    ls {{m1n1_usb}} >/dev/null 2>&1 && { echo "m1n1 did not hand over:" >&2; tail -n 5 build/linux-py.out >&2; exit 1; }
    pkill -f tools/linux.py || true
    echo "kernel started after $i s; switching to debug USB for the console"
    just connect
    nohup .venv-m1n1/bin/python tools/m4console --pad64 {{port}} > build/m4console.out 2>&1 &
    for i in $(seq 90); do
      tools/m4sh "uname -r" 3 >/dev/null 2>&1 && { echo "{{system}}: shell answers"; tools/m4sh "uname -r; systemctl is-system-running" 10; exit 0; }
      sleep 2
    done
    echo "no shell on the console" >&2; exit 1

# --- fallback: bare metal over debug USB ------------------------------------

# Switch the M4 Pro's USB-C port to debug USB (after every target reboot).
connect:
    # The port controller can refuse while the target is still enumerating.
    for i in 1 2 3; do sudo -n {{vdm}} debugusb | tail -n 1 && break; sleep 3; done
    for i in $(seq 15); do [ -e {{port}} ] && break; sleep 1; done; test -e {{port}}

# Boot the RAM installer on bare metal over debug USB (about 8 minutes).
boot-ram: connect
    tools/m4boot ram

# Boot the SSD's NixOS on bare metal over debug USB, with the kernel from build/out.
boot-disk: connect
    tools/m4boot disk

# Run a command on the target's root shell.
sh command timeout="10":
    tools/m4sh {{quote(command)}} {{timeout}}

# --- install to the SSD (from the RAM installer: just boot-ram) ------------

# Create the NixOS partitions in the free space after the macOS container.
[confirm("Create partitions 4 and 5 in the free space on the M4 Pro's SSD?")]
flash-partition:
    tools/m4sh "m4pro-install partition" 60

# Create the filesystems on the new partitions (refuses if any exist).
[confirm("Format nixos-boot (FAT32) and nixos (ext4) on the M4 Pro?")]
flash-format:
    tools/m4sh "m4pro-install format" 120

# Install (or update to) the system in the RAM image; keeps older generations.
flash-system:
    tools/m4sh "m4pro-install system" 900

# A first install: partition, format and install.
flash: flash-partition flash-format flash-system

# --- m1n1 on the macostest volume (from 1TR recoveryOS) ----------------------

# Recovery path for a broken stage 2: serve m1n1-dev.bin (port 8001) to copy onto the ESP from recoveryOS.
stage2-serve: (m1n1 "dev")
    #!/usr/bin/env bash
    set -euo pipefail
    addr=$(ipconfig getifaddr en11)
    echo "in recoveryOS Terminal:"
    echo "  diskutil mount disk0s4 && mkdir -p /Volumes/NIXBOOT/m1n1"
    echo "  curl -o /Volumes/NIXBOOT/m1n1/boot.bin http://$addr:8001/m1n1-dev.bin"
    echo "  shasum -a 256 /Volumes/NIXBOOT/m1n1/boot.bin   # $(shasum -a 256 build/out/m1n1-dev.bin | cut -d' ' -f1)"
    echo "  diskutil unmount /Volumes/NIXBOOT"
    exec .venv-m1n1/bin/python -m http.server 8001 -b "$addr" -d build/out

# Stage 2 is not served: NixOS installs it on the ESP (nixos/m1n1-boot.nix).
# Serve the kmutil script that installs a m1n1 variant (default stage 1) on the USB link (en11).
m1n1-serve variant="stage1": (m1n1 variant)
    addr=$(ipconfig getifaddr en11) && echo "in recoveryOS Terminal: sh <(curl $addr:8000)" && \
      .venv-m1n1/bin/python upstream/m1n1/tools/kmutil.py -b "$addr" -p 8000 build/out/m1n1-{{variant}}.bin
