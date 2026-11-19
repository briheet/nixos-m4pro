#!/usr/bin/env python3
# The guest's serial console under m1n1's hypervisor (the second USB port of
# m1n1, e.g. /dev/cu.usbmodem…3): log everything to FILE and type what is
# written to the named pipe IN, one line at a time.
#   guest-console.py PORT LOG IN
# Used to drive a macOS guest booted in single-user mode (boot-arg -s), whose
# root shell is on this console, from the host.
import os
import sys
import threading
import time

import serial

port, log, fifo = sys.argv[1:4]
s = serial.Serial(port, 115200, timeout=0.2)
out = open(log, "ab", buffering=0)


def reader():
    while True:
        d = s.read(4096)
        if d:
            out.write(d)


threading.Thread(target=reader, daemon=True).start()
if not os.path.exists(fifo):
    os.mkfifo(fifo)
while True:
    with open(fifo, "rb") as f:
        for line in f:
            # Slowly: the virtual UART has a small buffer.
            for i in range(0, len(line), 32):
                s.write(line[i:i + 32])
                s.flush()
                time.sleep(0.05)
            time.sleep(0.2)
