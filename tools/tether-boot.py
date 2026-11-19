#!/usr/bin/env python3
"""Boot a kernel on the M4 Pro from the host, through m1n1's proxy.

docs/boot_linux/checklist.md, items 6-8. Runs upstream m1n1's
proxyclient/tools/linux.py unchanged, with two substitutions for the
debug USB link:

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

Every run is recorded under build/runs/<YYYYmmdd-HHMMSS>/ and build/current
points at the latest one:
  argv.txt          the command line of this script, including -b
  files.txt         size and sha256 of the kernel, DTB and initramfs
  host.log          everything this script and m1n1 printed, timestamped
  console.log       raw target console after the jump (what m4sh reads)
  console.ts.log    the same, one host timestamp per line
  commands.log      every tools/m4sh command and its output
  result.txt        how the run ended and the last kernel time seen
build/runs/index.md gets one line per run.
"""
import atexit
import datetime
import hashlib
import os
import pathlib
import re
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

# --- per-run record --------------------------------------------------------

RUNS = REPO / "build/runs"
STARTED = datetime.datetime.now()
RUN = RUNS / STARTED.strftime("%Y%m%d-%H%M%S")
RUN.mkdir(parents=True, exist_ok=True)
CURRENT = REPO / "build/current"
if CURRENT.is_symlink() or CURRENT.exists():
    CURRENT.unlink()
CURRENT.symlink_to(RUN.relative_to(CURRENT.parent))


def stamp():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]


class Tee:
    """Copy a stream to host.log with a timestamp at the start of each line."""

    def __init__(self, stream, path):
        self.stream = stream
        self.log = open(path, "a", buffering=1)
        self.at_start = True

    def write(self, text):
        self.stream.write(text)
        out = []
        for chunk in text.splitlines(keepends=True):
            if self.at_start:
                out.append(f"{stamp()} ")
            out.append(chunk)
            self.at_start = chunk.endswith("\n")
        self.log.write("".join(out))
        return len(text)

    def flush(self):
        self.stream.flush()
        self.log.flush()

    def __getattr__(self, name):
        return getattr(self.stream, name)


sys.stdout = Tee(sys.stdout, RUN / "host.log")
sys.stderr = Tee(sys.stderr, RUN / "host.log")

(RUN / "argv.txt").write_text(" ".join(sys.argv[1:]) + "\n")
with open(RUN / "files.txt", "w") as f:
    for arg in sys.argv[1:4]:
        path = pathlib.Path(arg)
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            f.write(f"{path}  {path.stat().st_size} bytes  sha256 {digest}\n")

RESULT = {"how": "ended before the console relay started"}
KTIME = re.compile(rb"^\[\s*(\d+\.\d+)\]")
MONTIME = re.compile(rb"^MON up=(\d+\.\d+)")  # tools/m4sh-started uptime monitor
LAST = {"ktime": None, "line": b""}


def finish():
    ended = datetime.datetime.now()
    seconds = (ended - STARTED).total_seconds()
    lines = [
        f"started   {STARTED:%Y-%m-%d %H:%M:%S}",
        f"ended     {ended:%Y-%m-%d %H:%M:%S} ({seconds:.0f} s later)",
        f"how       {RESULT['how']}",
        f"last kernel time  {LAST['ktime'] or '-'}",
        f"last line  {LAST['line'].decode(errors='replace').strip()}",
    ]
    (RUN / "result.txt").write_text("\n".join(lines) + "\n")
    bootargs = ""
    if "-b" in sys.argv:
        bootargs = sys.argv[sys.argv.index("-b") + 1]
    index = RUNS / "index.md"
    if not index.exists():
        index.write_text("| run | how it ended | last kernel time | boot args |\n|---|---|---|---|\n")
    with open(index, "a") as f:
        f.write(f"| {RUN.name} | {RESULT['how']} | {LAST['ktime'] or '-'} | `{bootargs}` |\n")


atexit.register(finish)

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
    print(f"--- console relay: log {LOG}, input {INPUT}, run {RUN} ---", flush=True)
    RESULT["how"] = "relay running (still up, or the relay was killed)"
    # build/console.log is truncated per run; it is what tools/m4sh reads.
    with open(LOG, "wb", buffering=0) as log, \
         open(RUN / "console.log", "wb", buffering=0) as raw, \
         open(RUN / "console.ts.log", "wb", buffering=0) as ts:
        pending = b""
        try:
            while True:
                ready, _, _ = select.select([dev.fileno(), fifo], [], [], 1.0)
                if dev.fileno() in ready:
                    data = dev.read(4096)
                    if data:
                        log.write(data)
                        raw.write(data)
                        sys.stdout.stream.buffer.write(data)
                        sys.stdout.stream.flush()
                        pending += data
                        *lines, pending = pending.split(b"\n")
                        for line in lines:
                            line = line.rstrip(b"\r")
                            ts.write(f"{stamp()} ".encode() + line + b"\n")
                            m = KTIME.match(line) or MONTIME.match(line)
                            if m:
                                LAST["ktime"] = m.group(1).decode()
                            if line.strip():
                                LAST["line"] = line
                if fifo in ready:
                    data = pad_input(os.read(fifo, 4096))
                    for off in range(0, len(data), 64):
                        dev.write(data[off:off + 64])
                        time.sleep(0.01)
        except (OSError, proxy.serial.SerialException) as e:
            RESULT["how"] = f"target went away at {stamp()} ({e})"
            print(f"--- {RESULT['how']} ---", flush=True)
        except KeyboardInterrupt:
            RESULT["how"] = f"stopped from the host at {stamp()}"


proxy.UartInterface.writemem = chunked_writemem
proxy.UartInterface.ttymode = relay


# Everything m1n1 needs on T6040 lives in m1n1 itself (m1n1/patches): the
# DAPF reg from the ADT, both CTRR ranges reserved, the firmware MCC state
# kept. This script only adapts the host side of the debug USB link. The
# proxy runs on the dockchannel UART, so m1n1.setup's bootstrap_port does
# not change the baud rate, and its PMU panic-counter reset keeps iBoot
# from falling back to recoveryOS after failed boots.

# M1N1_TOOL picks another proxyclient tool instead of linux.py. (chainload.py
# does not work on this Mac: iBoot locks RVBAR, and its RVBAR writes fault.)
tool = PROXYCLIENT / "tools" / os.environ.get("M1N1_TOOL", "linux.py")
sys.argv = [str(tool)] + sys.argv[1:]
runpy.run_path(str(tool), run_name="__main__")
