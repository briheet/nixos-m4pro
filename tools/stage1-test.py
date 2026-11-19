#!/usr/bin/env python3
"""Run m1n1 stage 1's chainload in the memory layout iBoot left, from the host.

The m1n1 installed as the boot object (loaded by iBoot, so iBoot's blobs lie
right after it) is driven over its proxy: call its own chainload_load() with
a `chainload=` spec, then vector to the next_stage it set, through m1n1's
normal exit path. That is what stage 1 does with a `chainload=` line, without
a recoveryOS trip per attempt.

  M1N1DEVICE=/dev/cu.usbmodem...1 tools/stage1-test.py ELF [SPEC]

ELF is the installed m1n1's m1n1-raw.elf (for its symbol offsets). SPEC
defaults to the ESP's m1n1/boot.bin.
"""
import pathlib
import struct
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "upstream/m1n1/proxyclient"))

from m1n1.setup import *  # noqa: E402,F401,F403  (p, u, iface)

ESP_PARTUUID = "c1689edb-3947-4ed4-ba55-696ead4f2833"
elf = sys.argv[1]
spec = sys.argv[2] if len(sys.argv) > 2 else f"{ESP_PARTUUID};m1n1/boot.bin"

nm = subprocess.run([str(REPO / "build/toolchain/llvm-nm"), elf], capture_output=True, text=True, check=True).stdout
sym = {l.split()[2]: int(l.split()[0], 16) for l in nm.splitlines() if len(l.split()) == 3}
base = u.base
print(f"m1n1 base {base:#x}; chainload_load +{sym['chainload_load']:#x}, next_stage +{sym['next_stage']:#x}")

mm = u.adt["/chosen/memory-map"]
for name, value in sorted(mm._properties.items(), key=lambda kv: kv[1][0] if isinstance(kv[1], tuple) else 0):
    if isinstance(value, tuple) and value[1] and value[0] != 0xffffffffffffffff:
        print(f"  {name:28} base{value[0] - base:+#x} size {value[1]:#x}")

s = spec.encode() + b"\0"
addr = u.malloc(len(s))
iface.writemem(addr, s)
print(f"calling chainload_load({spec!r})")
ret = p.call(base + sym["chainload_load"], addr, 0, 0)
print(f"chainload_load returned {ret}")
if ret != 0:
    sys.exit(1)

ns = iface.readmem(base + sym["next_stage"], 6 * 8)
entry, *args = struct.unpack("<6Q", ns)
print(f"next_stage: entry {entry:#x} args {[hex(a) for a in args]}")
p.request(p.P_VECTOR, entry, *args, no_reply=True)
print("vectored to the next stage")
