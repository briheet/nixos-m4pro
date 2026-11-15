#!/usr/bin/env bash
# One GPU bring-up test on the M4 Pro, run there after a fresh boot (aurora.ko
# is blacklisted at boot): load the driver, run the smoke test, print the
# driver's kernel log, then unload it again.
#
# The unload is retried until the render node is gone: while aurora.ko is
# loaded, Hyprland picks its renderD128 and aborts in EGL at login.
#
#   SUDO_PASS=... ./test.sh        (from ~/gpu-smoke on the M4 Pro)
set -u
S() { echo "$SUDO_PASS" | sudo -S -p '' "$@"; }

timeout 90 bash -c "echo \"\$SUDO_PASS\" | sudo -S -p '' modprobe -d /run/current-system/kernel-modules aurora"
echo "modprobe=$?"
sleep 3
genpd() { S cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | sed "s/^/genpd-$1 /"; }
genpd idle
timeout 40 "$(dirname "$0")/result/bin/gpu-smoke" > /tmp/gpu-smoke.out 2>&1 &
smoke_pid=$!
# While the render is pending: are the GPU's power domains on?
sleep 1
genpd pending
wait $smoke_pid
echo "smoke=$?"
grep -v VM_BIND /tmp/gpu-smoke.out
sleep 2
S journalctl -k -b --no-pager -o cat | grep -E "aurora|j614s-fwlog|j614s-rec|j614s-live"
# Last, as it touches GPU registers directly: the KSM's view of the queues.
if [ -n "${KSM_QIDS:-}" ]; then
	sync
	S "$(command -v python3)" "$(dirname "$0")/ksm.py" $KSM_QIDS
fi

for i in $(seq 1 60); do
	S rmmod aurora 2>/dev/null
	[ -e /dev/dri/renderD128 ] || { echo "unloaded after $i tries"; exit 0; }
	sleep 1
done
echo "WARNING: aurora.ko still loaded; do not log in to the desktop"
exit 1
