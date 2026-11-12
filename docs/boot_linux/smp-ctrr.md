# SMP oops: memory locked on the secondary cores

Date: 2026-11-13. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`. Checklist item 12.

## Symptom

With `maxcpus=1` the kernel reached the shell. With all 12 cores it stopped before `Run /init`. The console showed an oops in the async initramfs unpack on a secondary core:

```
Unpacking initramfs...
Unable to handle kernel write to read-only memory at virtual address ffff800004df0000
  FSC = 0x0f: level 3 permission fault
pte=00e8010004df0707
CPU: 6 UID: 0 PID: 97 Comm: kworker/u49:1
 __pi_memcpy_generic <- generic_perform_write <- shmem_file_write_iter <- ... <- unpack_to_rootfs
```

`kernel_init` then waits for the initramfs forever. The PTE is writable (AP[2] clear), yet the write faulted. With `rodata=off` the same unpack failed with a level 2 address size fault instead. With m1n1's MCC cache enable skipped it failed the same way on CPU 5. `nohz=off`, `initramfs_async=0`, and an RCU stall timeout of 3 s did not change it.

## Cause

The faulting physical pages were next to m1n1's image every time (`0x100057a0000` with m1n1 at `0x100057b0000`). On M4-class chips iBoot leaves Apple's CTRR read-only ranges enabled and locked on every core except the boot core. Read through m1n1's proxy, with the secondaries started by `smp_start_secondaries`:

| Core | `CTRR_C` bounds | `CTRR_D` bounds | `C_CTL` / `D_CTL` |
|---|---|---|---|
| boot | `0x1000645c000`..`0x10006467000` | `0x100057d8000`..`0x100058df000` | `0` / `0` |
| CPU 0, 5, 10 | same | same | `0x8000000000000001` / `0x8000000000000001` |

Bit 0 is enable and bit 63 is lock. m1n1 `cf37927d` reserves the C range from Linux (`fdt_add_mem_rsv` in `kboot_prepare_dt`, comment "On M4* / A18 Pro / M5*, there is a CTRR instance left enabled only on the secondary (non-boot) cores"). It does not reserve the D range, about 1 MiB just below m1n1. Those pages went to Linux's allocator. The first secondary core that wrote to one took the fault. The boot core alone never trips it, which is why `maxcpus=1` worked.

## Fix

First a workaround in `tools/tether-boot.py` added the D range to the DTB before `kboot_prepare_dt`. It is replaced by `m1n1/patches/0002-kboot-Reserve-both-CTRR-ranges-left-locked-on-second.patch`: m1n1 reserves every CTRR range itself, treating the upper bound as the last protected page. Installed on `macostest` on 2026-11-13; m1n1 now logs

```
FDT: reserving CTRR C [0x10006a3c000, 0x10006a48000), locked on secondary cores
FDT: reserving CTRR D [0x10005db8000, 0x10005ec0000), locked on secondary cores
```

and every core writes 200 MB with no oops.

The earlier log below is from the workaround.

```
tether-boot: reserving CTRR C 0x1000595c000..0x10005968000 (locked on secondary cores)
tether-boot: reserving CTRR D 0x10004cd8000..0x10004de0000 (locked on secondary cores)
[    0.004221] smp: Brought up 1 node, 12 CPUs
[    0.805777] Freeing unused kernel memory: 4800K
[    0.805878] Run /init as init process
```

## Checked

- `nproc` is 12. `/proc/cpuinfo` has 4 × part `0x054` and 8 × part `0x055`.
- `taskset -c N dd if=/dev/zero of=/tmp/tN bs=1M count=256` for every core: 5.2 to 6.1 GB/s, no fault.
- 12 parallel `dd` writers filled the 11.6 GB tmpfs. No oops in `dmesg`. Rescheduling and function-call IPIs count on all 12 cores.

The same m1n1 build carries `0001` (DAPF reg from the ADT instance list, so `dart-pmp` is skipped) and `0003` (keep the firmware's MCC cache state on T6040). An m1n1 fork for the M4 Pro (aurora-silicon/m1n1 PR #39) fixes the DAPF index the same way. `chainload.py` cannot be used to try a new m1n1 on this Mac: iBoot locks RVBAR and its RVBAR writes take an SError.
