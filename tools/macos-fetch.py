#!/usr/bin/env python3
"""Fetch the macOS boot files of a volume on the M4 Pro, from 1TR recoveryOS.

Serves a shell script on the USB link (en11) that recoveryOS runs with
  sh <(curl HOST:8000)
It finds the volume's Preboot directory, uploads its kernelcache and the
SPTM and TXM images (restore/Firmware) here with HTTP PUT, and prints their
sha256 sums. Files land in build/macos/<volume>/.
  tools/macos-fetch.py [volume, default macostest]
Used to run that macOS under the m1n1 hypervisor (docs/boot_linux/pmp.md).
"""
import hashlib, os, pathlib, socket, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VOL = sys.argv[1] if len(sys.argv) > 1 else "macostest"
REPO = pathlib.Path(__file__).resolve().parents[1]
OUT = REPO / "build" / "macos" / VOL
ADDR = os.environ.get("BIND") or subprocess.run(["ipconfig", "getifaddr", "en11"], capture_output=True, text=True).stdout.strip()

SCRIPT = f"""#!/bin/sh
set -eu
H=http://{ADDR}:8000
VOL={VOL}
mnt=/Volumes/$VOL
[ -d "$mnt" ] || diskutil mount "$VOL" >/dev/null
vg=$(diskutil info "$mnt" | awk -F': *' '/APFS Volume Group/ {{print $2}}' | awk '{{print $1}}')
[ -n "$vg" ] || {{ echo "no APFS volume group for $mnt"; exit 1; }}
echo "volume group: $vg"
pb=""
for d in $(diskutil list | awk '/Preboot/ {{print $NF}}'); do
  m=$(diskutil info "$d" | awk -F': *' '/Mount Point/ {{print $2}}')
  [ -n "$m" ] && [ -d "$m" ] || {{ diskutil mount "$d" >/dev/null; m=$(diskutil info "$d" | awk -F': *' '/Mount Point/ {{print $2}}'); }}
  [ -d "$m/$vg" ] && pb="$m/$vg" && break
done
[ -n "$pb" ] || {{ echo "Preboot directory for $vg not found"; exit 1; }}
echo "preboot: $pb"
send() {{ echo "upload $(basename "$1")"; curl -sfT "$1" "$H/$(basename "$1")"; }}
for f in "$pb"/boot/*/System/Library/Caches/com.apple.kernelcaches/kernelcache; do send "$f"; done
for f in "$pb"/restore/Firmware/sptm.*.release.im4p "$pb"/restore/Firmware/txm.macosx.release.im4p; do send "$f"; done
curl -sf "$H/done" >/dev/null
echo "all uploaded"
"""

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/done":
            self.send_response(200); self.end_headers()
            print("recoveryOS reports all files uploaded", flush=True)
            return
        body = SCRIPT.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        name = os.path.basename(self.path)
        if not name or name.startswith("."):
            self.send_response(400); self.end_headers(); return
        n = int(self.headers["Content-Length"])
        OUT.mkdir(parents=True, exist_ok=True)
        h = hashlib.sha256()
        with open(OUT / name, "wb") as f:
            while n:
                chunk = self.rfile.read(min(n, 1 << 20))
                f.write(chunk); h.update(chunk); n -= len(chunk)
        print(f"received {name}: {(OUT / name).stat().st_size} bytes, sha256 {h.hexdigest()}", flush=True)
        self.send_response(201); self.end_headers()

    def log_message(self, *a):
        pass

if not ADDR:
    sys.exit("macos-fetch: en11 has no address; boot the M4 Pro into recoveryOS first")
print(f"in recoveryOS Terminal: sh <(curl {ADDR}:8000)", flush=True)
ThreadingHTTPServer((ADDR, 8000), H).serve_forever()
