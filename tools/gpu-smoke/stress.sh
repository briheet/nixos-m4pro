#!/usr/bin/env bash
# GPU stress test on the M4 Pro, run there after a fresh boot (aurora.ko is
# blacklisted at boot) and while nobody is logged in to the desktop: load the
# driver, run the phases below, summarize the driver's kernel log, unload.
#
#   1. one client, 2000 iterations of render + compute back to back
#   2. four clients in parallel, 500 iterations each
#   3. one client, 50 iterations 200 ms apart: the GPU idles off and wakes
#   4. vkmark headless on Aurora's Vulkan driver (when VKMARK and MESA are set)
#
#   SUDO_PASS=... [MESA=/nix/store/...-mesa] [VKMARK=/nix/store/...-vkmark] ./stress.sh
set -u
S() { echo "$SUDO_PASS" | sudo -S -p '' "$@"; }
dir=$(dirname "$0")
smoke="$dir/result/bin/gpu-smoke"
fail=0

timeout 90 bash -c "echo \"\$SUDO_PASS\" | sudo -S -p '' modprobe -d /run/current-system/kernel-modules aurora"
echo "modprobe=$?"
sleep 3

echo "== phase 1: one client, 2000 iterations"
start=$(date +%s%N)
timeout 600 "$smoke" 2000 2>&1 | grep -v VM_BIND | tail -6 || fail=1
echo "phase 1: $(( ($(date +%s%N) - start) / 1000000 )) ms"

echo "== phase 2: four clients, 500 iterations each"
start=$(date +%s%N)
for c in 1 2 3 4; do
	timeout 600 "$smoke" 500 > "/tmp/gpu-stress-$c.out" 2>&1 &
done
wait
for c in 1 2 3 4; do echo "client $c: $(grep -v VM_BIND "/tmp/gpu-stress-$c.out" | tail -1)"; done
echo "phase 2: $(( ($(date +%s%N) - start) / 1000000 )) ms"

echo "== phase 3: 50 iterations 200 ms apart (idle power-off and wake)"
timeout 120 "$smoke" 50 200 2>&1 | grep -v VM_BIND | tail -3

if [ -n "${VKMARK:-}" ] && [ -n "${MESA:-}" ]; then
	echo "== phase 4: vkmark headless"
	icd=$(ls "$MESA"/share/vulkan/icd.d/*.json | head -1)
	VK_ICD_FILENAMES=$icd timeout 300 "$VKMARK"/bin/vkmark --winsys headless 2>&1 | tail -25
fi

echo "== kernel log"
S journalctl -k -b --no-pager -o cat | grep aurora > /tmp/gpu-stress-kernel.log
grep -ciE "timeout|fault|recover|crash|lost|error" /tmp/gpu-stress-kernel.log | sed 's/^/problem lines: /'
grep -iE "timeout|fault|recover|crash|lost|error" /tmp/gpu-stress-kernel.log | head -20

for i in $(seq 1 60); do
	S rmmod aurora 2>/dev/null
	[ -e /dev/dri/renderD128 ] || { echo "unloaded after $i tries"; exit $fail; }
	sleep 1
done
echo "WARNING: aurora.ko still loaded; do not log in to the desktop"
exit 1
