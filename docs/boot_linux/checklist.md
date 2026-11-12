# Boot Linux to a shell

The first goal on this MacBook Pro (14-inch, M4 Pro, `Mac16,8`, `J614s`, `T6040`): a Linux kernel that boots and gives a shell where `ls`, `cat /proc/cpuinfo`, and the other basics work. Input is typed from the host over debug USB, and the system runs from RAM. The SSD, the internal keyboard, and networking come after this list (see `docs/required_for_daily_use/list.md`).

Each item has a check that marks it done. Items are ticked only after the check passed on this machine.

## A. Build setup (host)

- [x] **1. aarch64-linux builder.** Nix inside a Docker container with a persistent store volume, so nothing on the host system changes.
  Check: a package builds for `aarch64-linux`.
  Result: container `nixos-m4pro-builder` (nixos/nix 2.28.3), store on volume `nixos-m4pro-nix`, sources on the case-sensitive volume `nixos-m4pro-src` at `/src`. Static BusyBox 1.37.0 builds for aarch64-linux. `tools/kernel-env.sh` is `nix develop` on nixpkgs' `linux` at the `flake.lock` revision.
- [x] **2. Kernel source.** AsahiLinux/linux at `7b0c21fc` (*arm64: dts: apple: Add minimal t604x (M4 Pro/Max) device trees*), or a later commit carrying the same trees.
  Check: `t6040-j614s.dtb` compiles.
  Result: branch `asahi` at `6ba0637d1` (Linux 7.2.15) plus the t604x commit from `bits/000-devicetree` (`1763a2566d73`, applies as new files only). `t6040-j614s.dtb` compiles, compatible `apple,j614s`. Local changes are exported to `kernel/patches/`.
- [x] **3. Kernel config.** Built in, no modules: `ARCH_APPLE`, 16K pages, Apple AIC, Samsung UART and console, Apple watchdog, PMGR power domains, Apple pinctrl and I2C, earlycon, initramfs, procfs, sysfs, devtmpfs, framebuffer console.
  Check: `Image` builds.
  Result: `kernel/m4pro.config` on arm64 defconfig, plus `CONFIG_SERIAL_APPLE_DOCKCHANNEL` (item 8). `Image.gz` is 29.6 MB, `7.2.15-m4pro`.
- [x] **4. Device tree for this bin.** The tree lists 4E + 12P cores; this chip is 4E + 8P (CPU ids 8 and 9 absent). Keep only the cores the Apple device tree reports, by their `reg` (MPIDR) values. `stdout-path` points at `uart0`. Memory and framebuffer stay as placeholders for m1n1 to fill.
  Check: the dtb compiles, and its CPU nodes match the 12 cores in this Mac's ADT.
  Result: no edit needed. m1n1's `dt_set_cpus` matches DT CPU nodes by position against the cores it started and drops the rest. Live log: `CPU 8/9/14/15 is not alive, disabling`, the other 11 secondaries get release addresses, and 4 of 12 P-core PMU affinities are pruned.
- [x] **5. Initramfs.** Static BusyBox and an `/init` that mounts `/proc`, `/sys`, `/dev`, prints a banner, and runs a shell on the console.
  Check: a `.cpio.gz` of a few MB.
  Result: `initramfs/init` and `tools/build-initramfs.sh`, 851 KB.

## B. Getting the kernel onto the machine

- [x] **6. Upload speed.** Time a write and read-back of a few MiB through m1n1's proxy on `/dev/cu.kis-100000-ch-0`.
  Check: a measured rate, and a decision: upload every boot through the proxy, or embed the payload in the m1n1 image on `macostest` through recovery.
  Result: debug USB has no flow control. Proxy writes of 1-1.5 KiB sustain 410-544 KiB/s, verified; 2 KiB and up stall or lose bytes; a write whose length is not a multiple of 8 never completes. `tools/tether-boot.py` sends 1 KiB chunks with the tail merged into an aligned 8 bytes. The 29.6 MB kernel uploads in about 75 s, so every try is uploaded.
- [x] **7. Boot payload.** Kernel, device tree, and initramfs in the form m1n1 boots. m1n1 only takes a device tree whose root compatible contains `apple,j614s`.
  Check: m1n1 accepts the payload and reports the kernel, DT, and initrd.
  Result: m1n1 takes the payload: `FDT: initrd at 0x10031600000`, framebuffer 3024x1890 (notch hidden), DRAM 24 GB at `0x10000000000`, `FDT prepared`. `GPU: unsupported chip` is not fatal.

## C. First boot

- [x] **8. Kernel banner.** Command line: `earlycon console=ttyDC0 rdinit=/init maxcpus=1 cpuidle.off=1 clk_ignore_unused pd_ignore_unused`.
  Check: `Linux version` appears on the debug USB console.
  Result: `Linux version 7.2.15-m4pro`, `Machine model: Apple MacBook Pro (14-inch, M4 Pro, 2024)`, `earlycon: dockchannel0 at MMIO 0x50882c000`. Two things were in the way. uart0 is not routed to the host, so the console is a new polled driver for the dockchannel UART (`ttyDC0`). m1n1's `kboot_boot` programs the `dart-pmp` DAPF at `0x500578000`, which raises an SError on this chip; `tools/tether-boot.py` renames that node in m1n1's in-memory ADT so DAPF init skips it. Full log: `first-boot.log`.
- [x] **9. Interrupts and timer.** AIC v3 probes and the timer ticks.
  Check: `/proc/interrupts` counts rise, `sleep 1` returns after a second.
  Result: `irq_apple_aic: Initialized with 2720/4096 IRQs * 1/2 die(s), 7 FIQs, 32 vIPIs`; `arch_timer: cp15 timer running at 1000.00MHz`. `time sleep 1` is `real 0m 1.00s`, and the `arch_timer` count rose from 14362 to 14468 across it.
- [x] **10. Console input.** Characters typed on the host reach the shell.
  Check: a `#` prompt that runs what is typed.
  Result: `echo CLEAN-OK-$((6*7))` printed `CLEAN-OK-42`. Host-to-target bytes on debug USB arrive in whole blocks, so the relay pads each write to 64 bytes with spaces before the newline. `tools/m4sh "cmd"` runs a command and prints its output.
- [x] **11. Basic commands.** `uname -a`, `ls /`, `cat /proc/cpuinfo`, `cat /proc/meminfo` (about 24 GB), `cat /proc/interrupts`, `cat /proc/device-tree/model`, `dmesg`, `date`, `mount`, `df`, `ps`, `free`, `top`.
  Check: each runs and gives a sane answer; output recorded here.
  Result: all run. `uname -a`: `Linux (none) 7.2.15-m4pro ... aarch64`. `/proc/meminfo`: `MemTotal: 24226848 kB`. `/proc/cpuinfo`: implementer `0x61`, part `0x055`, SME and SME2 listed. `mount` and `df -h`: proc, sysfs, devtmpfs, devpts, tmpfs. `ps`/`top`: 83 tasks, 100% idle. `date` is 1970: no RTC driver yet (SMC/SPMI). Errors in the log are cpufreq without cluster info in the DT, the keyboard backlight PWM period, and drivers for other boards in defconfig.
- [ ] **12. All 12 cores.** Drop `maxcpus=1`.
  Check: `nproc` is 12 and `/proc/cpuinfo` shows both core types.
- [ ] **13. Stability.** The watchdog does not reset the machine, an hour idle with no hang, `reboot` restarts it.
  Check: uptime past an hour; `reboot` comes back to m1n1.
  So far: `watchdog0` registered and the machine stayed up 168 s with no reset; `reboot -f` printed `reboot: Restarting system` and the machine restarted. The hour is not done yet.
- [ ] **14. Screen console.** m1n1's framebuffer handed to Linux as `simple-framebuffer`, with the framebuffer console on it.
  Check: the boot log is on the internal panel.

## D. NixOS from RAM

- [ ] **15. NixOS initramfs.** A NixOS system built with nixos-apple-silicon's modules plus this kernel and device tree, packed as the initramfs.
  Check: a NixOS shell on the console where `systemctl status`, `nix --version`, and `ls /nix/store` work.
- [ ] **16. Boot without the host.** Kernel and NixOS embedded in the m1n1 image on `macostest`.
  Check: the M4 Pro boots to NixOS with the host cable unplugged. Changes do not survive a reboot.

## Needed from the owner along the way

- Reboots of the M4 Pro: `sudo /Users/briheet/code/macvdmtool/macvdmtool reboot debugusb`.
- ChatGPT and Chrome closed while debug USB reconnects; both claim the device and block the `kis` ports.
- If uploads are too slow (item 6), a recovery trip per kernel to install the payload.
