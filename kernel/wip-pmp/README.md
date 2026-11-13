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

Status (2026-11-13): PMP starts (CPU_CONTROL 0x10), does the RTKit hello,
endpoint map, crashlog, ioreport and endpoint-7 buffers, then never
acknowledges its IOP power state, so the driver's probe times out (-ETIME).
Also tried, without change: boot() instead of wake(), starting endpoint 0x20
before the ack, AP power ON before the ack (as proxyclient fw/pmp.py does),
IOP power INIT after the hello. No DART errors, no crash report.

Next: trace how macOS boots PMP (m1n1 hypervisor with ASC tracing) to see
the message order and what PMP waits for after the endpoint-7 buffer.
