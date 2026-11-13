# PMP on the M4 Pro (work in progress, not in the NixOS kernel)

Why: iBoot loads the PMP (power-management coprocessor) firmware but leaves
it stopped (`/arm-io/pmp/iop-pmp-nub` has `pre-loaded` but not `running`).
ANS is a `notify_pmp` device (PMP index 0x21). With PMP stopped, ANS crashes
(SError) whenever it sleeps, so Linux loses the SSD after any ANS sleep, and
m1n1 stage 1 cannot hand over (docs/boot_linux/boot-chain.md).

Patches here, on top of kernel/patches (apply after them):
- PMP, its mailbox and DART in t6041.dtsi, from the J614s ADT, and a `pmp`
  alias so m1n1 (kboot `dt_set_pmp`) fills in board/DRAM ids and enables it.
- pmp.rs maps 0xe0000 of PMP SRAM: T6040 keeps the bootargs at 0x87480.
- RTKit starts system endpoint 7 and serves its buffer request: the T6040
  PMP asks for a 2-page buffer there and waits for it.

Kernel config needed on top of m4pro-nixos.config: `CONFIG_RUST=y`,
`CONFIG_APPLE_PMP=y` (rustc 1.99.1 and bindgen from the pinned nixpkgs work).

Status (2026-11-13, after tracing macOS 27.2.1 under the m1n1 hypervisor,
trace in build/macos/hv-pmp-trace-macos27.2.1.txt, tools/hv/trace_pmp.py):

- macOS starts PMP without an IOP power request; PMP asks for a buffer on
  system endpoint 7 and takes the reply as message type 5. With those two
  changes PMP boots under Linux (syslog "io.cpp:61: PMP started") and runs
  the endpoint 0x20 protocol pmp.rs implements.
- macOS reports ANS power to PMP (DEV_STATUS_TGT_WR bit 33). pmp-report has
  the T6041 offsets (base 0x5003c0000, tgt_read 0x1e00, tgt_write 0x10f00,
  actual 0x1e80, status 0x10) and a fix for entries >= 32 (64-bit shift);
  ANS's power domain goes through pmp_report_ans.
- Still open: ANS crashes (SError, FAR 0x41f020000) when it enters IOP
  sleep after "NVMe shutdown ... saveCtx", even with PMP running and ANS
  reported. The boot trace has no ANS sleep. Next: trace macOS putting ANS to
  sleep (system sleep under the hypervisor, trace_nvme.py + trace_pmp.py).
- PMP sends one message the driver does not know: type 0x36, payload 0x178.
