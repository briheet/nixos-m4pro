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
                data = os.read(fifo, 4096)
                for off in range(0, len(data), 64):
                    dev.write(data[off:off + 64])
                    time.sleep(0.01)


proxy.UartInterface.writemem = chunked_writemem
proxy.UartInterface.ttymode = relay

# m1n1.setup runs these on import. On this link the proxy is the dockchannel
# UART and needs no baud change, and resetting the PMU panic counter is an
# SPMI write to the PMIC that the boot does not need. With both in place the
# first proxy write after setup took longer than the 3 s timeout.
from m1n1 import proxyutils  # noqa: E402
from m1n1.hw import pmu  # noqa: E402

proxyutils.bootstrap_port = lambda iface, p: iface.nop()
pmu.PMU.reset_panic_counter = lambda self: None

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
    return _kboot_boot(self, kernel)


proxy.M1N1Proxy.kboot_boot = kboot_boot

# Keep the boot args where kboot_boot can reach them.
_utils_init = proxyutils.ProxyUtils.__init__


def utils_init(self, p, *args, **kwargs):
    _utils_init(self, p, *args, **kwargs)
    p._tether_ba = self.ba


proxyutils.ProxyUtils.__init__ = utils_init

linux_py = PROXYCLIENT / "tools/linux.py"
sys.argv = [str(linux_py)] + sys.argv[1:]
runpy.run_path(str(linux_py), run_name="__main__")
