#!/usr/bin/env python3
"""Boot a kernel on the M4 Pro from the host, through m1n1's proxy.

docs/boot_linux/checklist.md, items 6-8. Runs upstream m1n1's
proxyclient/tools/linux.py unchanged, with two substitutions:

- UartInterface.writemem sends at most CHUNK bytes per proxy write. Debug
  USB drops data on larger writes (2 KiB already stalls; 1 KiB sustains
  about 410 KiB/s with every byte verified).
- UartInterface.ttymode, which linux.py enters after kboot_boot, becomes a
  relay: everything from the target goes to stdout and to LOG, and bytes
  written to the FIFO at INPUT go to the target. That lets a non-interactive
  caller type into the kernel's console.

Usage (from the repo root, with .venv-m1n1):
  M1N1DEVICE=/dev/cu.kis-100000-ch-0 .venv-m1n1/bin/python tools/tether-boot.py \\
      build/Image.gz build/t6040-j614s.dtb build/initramfs.cpio.gz -b "..."
Environment: CONSOLE_LOG (default build/console.log),
             CONSOLE_IN (default build/console.in, created as a FIFO).
"""
import os
import pathlib
import runpy
import select
import stat
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
PROXYCLIENT = REPO / "upstream/m1n1/proxyclient"
sys.path.insert(0, str(PROXYCLIENT))

from m1n1 import proxy  # noqa: E402

CHUNK = 1024
LOG = pathlib.Path(os.environ.get("CONSOLE_LOG", REPO / "build/console.log"))
INPUT = pathlib.Path(os.environ.get("CONSOLE_IN", REPO / "build/console.in"))

_writemem = proxy.UartInterface.writemem


def aligned_writemem(self, addr, data):
    """A proxy write whose size is not a multiple of 8 never completes over
    debug USB (8, 16, 32 work; 9 hangs). Send the 8-byte multiple as is,
    and merge any 1-7 byte tail into the 8 bytes already in memory there."""
    whole = len(data) & ~7
    if whole:
        _writemem(self, addr, data[:whole])
    tail = data[whole:]
    if tail:
        cur = bytearray(self.readmem(addr + whole, 8))
        cur[:len(tail)] = tail
        _writemem(self, addr + whole, bytes(cur))


def chunked_writemem(self, addr, data, progress=False):
    total = len(data)
    start = time.time()
    last = 0.0
    for off in range(0, total, CHUNK):
        aligned_writemem(self, addr + off, data[off:off + CHUNK])
        now = time.time()
        if progress and (now - last > 2 or off + CHUNK >= total):
            done = min(off + CHUNK, total)
            rate = done / 1024 / max(now - start, 1e-6)
            print(f"  {done >> 10}/{total >> 10} KiB, {rate:.0f} KiB/s", flush=True)
            last = now


def pad_input(data):
    """Host-to-target bytes on debug USB arrive only in whole blocks: a short
    tail waits for the next write (a 23-byte line lost its last 3 bytes; a
    64-byte line arrives whole). Pad every write to a multiple of 64 with
    spaces placed before a trailing newline, which a shell ignores."""
    pad = -len(data) % 64
    if not pad:
        return data
    if data.endswith(b"\n"):
        return data[:-1] + b" " * pad + b"\n"
    return data + b" " * pad


def relay(self, dev=None):
    dev = dev or self.dev
    dev.timeout = 0
    LOG.parent.mkdir(parents=True, exist_ok=True)
    if INPUT.exists() and not stat.S_ISFIFO(INPUT.stat().st_mode):
        INPUT.unlink()
    if not INPUT.exists():
        os.mkfifo(INPUT)
    # O_RDWR keeps the FIFO open with no writer, so reads never see EOF.
    fifo = os.open(INPUT, os.O_RDWR | os.O_NONBLOCK)
    print(f"--- console relay: log {LOG}, input {INPUT} ---", flush=True)
    with open(LOG, "ab", buffering=0) as log:
        log.write(f"\n--- boot {time.ctime()} ---\n".encode())
        while True:
            ready, _, _ = select.select([dev.fileno(), fifo], [], [], 1.0)
            if dev.fileno() in ready:
                data = dev.read(4096)
                if data:
                    log.write(data)
                    sys.stdout.buffer.write(data)
                    sys.stdout.flush()
            if fifo in ready:
                data = pad_input(os.read(fifo, 4096))
                for off in range(0, len(data), 64):
                    dev.write(data[off:off + 64])
                    time.sleep(0.01)


proxy.UartInterface.writemem = chunked_writemem
proxy.UartInterface.ttymode = relay

# m1n1.setup runs bootstrap_port on import. On this link the proxy is the
# dockchannel UART and needs no baud change, so it is only a nop here.
#
# m1n1.setup also resets the PMU panic counter, and that has to stay: the
# counter rises with every crashed or forced boot, and once it runs out the
# Mac starts recoveryOS instead of m1n1. (It was disabled here once while
# chasing slow writes, whose real cause was unaligned write sizes, and the
# M4 Pro ended up in recovery after a run of failed boots on 2026-11-12.)
from m1n1 import proxyutils  # noqa: E402

proxyutils.bootstrap_port = lambda iface, p: iface.nop()

# kboot_boot runs dapf_init_all() just before the jump. On this Mac the
# DAPF window of dart-pmp is reg 1 at 0x500578000, the block that also holds
# dart-apcie0's PS_PROT range, and programming it raises an SError, which
# makes m1n1 reboot the machine. dapf_init_all skips any entry whose ADT
# node is missing, so rename the node in m1n1's in-memory ADT ("dart-pmp" ->
# "dart-pmX", same length) right before booting. Linux never sees the ADT.
HIDE_FROM_DAPF = [b"dart-pmp"]

_kboot_boot = proxy.M1N1Proxy.kboot_boot


def kboot_boot(self, kernel):
    iface = self.iface
    ba = self._tether_ba
    adt_base = (ba.devtree - ba.virt_base + ba.phys_base) & 0xFFFFFFFFFFFFFFFF
    adt = iface.readmem(adt_base, ba.devtree_size)
    for name in HIDE_FROM_DAPF:
        # An ADT property is a 32-byte name, a u32 length, then the value.
        needle = b"name".ljust(32, b"\0") + (len(name) + 1).to_bytes(4, "little") + name + b"\0"
        off = adt.find(needle)
        if off < 0:
            print(f"tether-boot: ADT node {name.decode()} not found, nothing to hide", flush=True)
            continue
        value = adt_base + off + 36
        iface.writemem(value, name[:-1] + b"X")
        print(f"tether-boot: renamed ADT node {name.decode()} at {value:#x} so DAPF init skips it", flush=True)
    skip_mcc_enable_cache(self)
    return _kboot_boot(self, kernel)


# kboot_boot also calls mcc_enable_cache(), which writes a cache-enable value
# into every memory-cache plane. On this chip every plane times out (status
# 0x10101) and, with the memory cache left in that state, a secondary core's
# page-table walker reads page tables that do not match memory: CPU 6 took a
# level 3 permission fault on a writable page, and with rodata=off a level 2
# address size fault, both while unpacking the initramfs. Keep the firmware's
# cache state by clearing m1n1's mcc_initialized flag, which makes
# mcc_enable_cache() return before writing anything. Offsets are from
# upstream/m1n1/build/m1n1-raw.elf (cf37927d, EXTRA_CFLAGS=-DTARGET=0x6040),
# the image installed on macostest; both values are checked before writing.
MCC_COUNT_OFF = 0x116AF8
MCC_INITIALIZED_OFF = 0x116B58


def skip_mcc_enable_cache(proxy_):
    iface = proxy_.iface
    base = proxy_.get_base()
    count = int.from_bytes(iface.readmem(base + MCC_COUNT_OFF, 4), "little")
    initialized = iface.readmem(base + MCC_INITIALIZED_OFF, 1)[0]
    if (count, initialized) != (4, 1):
        print(f"tether-boot: mcc_count={count} mcc_initialized={initialized}, not the expected "
              "m1n1 build; leaving MCC alone", flush=True)
        return
    iface.writemem(base + MCC_INITIALIZED_OFF, b"\0")
    print(f"tether-boot: cleared mcc_initialized at {base + MCC_INITIALIZED_OFF:#x}, "
          "so kboot keeps the firmware's memory cache state", flush=True)


proxy.M1N1Proxy.kboot_boot = kboot_boot

# Keep the boot args and the utils object where the wrappers can reach them.
_utils_init = proxyutils.ProxyUtils.__init__


def utils_init(self, p, *args, **kwargs):
    _utils_init(self, p, *args, **kwargs)
    p._tether_ba = self.ba
    p._tether_u = self


# On M4-class chips iBoot leaves two CTRR ranges enabled and locked on every
# core except the boot core. Measured on this Mac (2026-11-13): C_CTL and D_CTL
# read 0x8000000000000001 on CPUs 0, 5 and 10 and 0 on the boot core. A write
# from a secondary core into either range takes a permission fault whatever
# the page tables say. m1n1 cf37927d reserves only the C range (44 KiB, from
# the boot core's *_EL1 bounds). The D range, about 1 MiB just below m1n1,
# stayed in Linux's free memory, and the first secondary core that wrote to a
# page there (unpacking the initramfs) oopsed: "write to read-only memory" on
# a writable page. Read both ranges from the boot core and add them to the
# DTB's memreserve block, padded out to 16K pages, before m1n1 prepares it.
CTRR_REGS = {
    "C": ((3, 0, 11, 1, 0), (3, 0, 11, 1, 1)),
    "D": ((3, 0, 11, 1, 2), (3, 0, 11, 1, 3)),
}
PAGE = 0x4000


def fdt_add_memreserve(blob, ranges):
    """Insert (addr, size) entries into a flattened device tree's memreserve
    block. dtc places the block between the header and the structure block,
    so everything after it moves by 16 bytes per entry."""
    be = lambda b: int.from_bytes(b, "big")
    if be(blob[0:4]) != 0xD00DFEED:
        raise ValueError("not a flattened device tree")
    off_struct, off_strings, off_rsvmap = be(blob[8:12]), be(blob[12:16]), be(blob[16:20])
    if not off_rsvmap < off_struct < off_strings:
        raise ValueError("unexpected FDT block order")
    end = off_rsvmap
    while be(blob[end:end + 8]) or be(blob[end + 8:end + 16]):
        end += 16
    extra = b"".join(a.to_bytes(8, "big") + s.to_bytes(8, "big") for a, s in ranges)
    out = bytearray(blob[:end] + extra + blob[end:])
    shift = len(extra)
    for field, value in ((4, be(blob[4:8]) + shift), (8, off_struct + shift), (12, off_strings + shift)):
        out[field:field + 4] = value.to_bytes(4, "big")
    return bytes(out)


_kboot_prepare_dt = proxy.M1N1Proxy.kboot_prepare_dt


def kboot_prepare_dt(self, dt_addr):
    u = self._tether_u
    size = int.from_bytes(self.iface.readmem(dt_addr + 4, 4), "big")
    blob = self.iface.readmem(dt_addr, size)
    ranges = []
    for name, (lwr, upr) in CTRR_REGS.items():
        lo, hi = u.mrs(lwr), u.mrs(upr)
        if not lo or hi < lo:
            print(f"tether-boot: CTRR {name} bounds {lo:#x}..{hi:#x} look empty, skipping", flush=True)
            continue
        start = lo & ~(PAGE - 1)
        end = (hi + 0x1000 + PAGE - 1) & ~(PAGE - 1)
        ranges.append((start, end - start))
        print(f"tether-boot: reserving CTRR {name} {start:#x}..{end:#x} (locked on secondary cores)",
              flush=True)
    new = fdt_add_memreserve(blob, ranges)
    new_addr = u.malloc(len(new))
    self.iface.writemem(new_addr, new)
    return _kboot_prepare_dt(self, new_addr)


proxy.M1N1Proxy.kboot_prepare_dt = kboot_prepare_dt


proxyutils.ProxyUtils.__init__ = utils_init

linux_py = PROXYCLIENT / "tools/linux.py"
sys.argv = [str(linux_py)] + sys.argv[1:]
runpy.run_path(str(linux_py), run_name="__main__")
