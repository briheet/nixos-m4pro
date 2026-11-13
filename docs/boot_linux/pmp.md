# PMP and the SSD controller (ANS) on the M4 Pro

Why booting through m1n1's boot chain lost the SSD, how macOS does it, and what the kernel series now does. Kernel patches 0012–0021, m1n1 patch 0005.

## The problem

m1n1 stage 1 reads stage 2 from the ESP, so it has to start ANS (the SSD coprocessor) and stop it again before Linux. After that, Linux's `nvme-apple` could not use the SSD. The same happened with Linux alone: unbinding and binding `nvme-apple` crashed ANS with an SError (FAR 0x41f020000, inside ANS's address space) right after `NVMe shutdown start … saveCtx`, while entering IOP sleep. Direct boots only worked because iBoot leaves ANS running and Linux wakes it rather than restarting it.

## How it was found

macOS 27.2.1 on `macOSTest`, run under the m1n1 hypervisor with the PMP and ANS mailbox tracers (`tools/hv/trace_pmp.py`, `tools/hv/trace_ans.py`), over m1n1's own USB device (9.5 MB/s, with macOS's console on the second port). The files come off the volume with `tools/macos-fetch.py` from recoveryOS; see "Running macOS under the hypervisor" below.

- **PMP is the OS's job.** iBoot loads PMP (the power-management coprocessor) but leaves it stopped (`pre-loaded` without `running` in `/arm-io/pmp/iop-pmp-nub`). macOS starts it: no IOP power request, the RTKit hello, endpoints 1–4 and 7, a buffer for endpoint 7 answered with message **type 5**, then PMP acknowledges power on and the PMP endpoint (0x20) protocol `pmp.rs` already implements follows. PMP also sends message 0x36 every few seconds; macOS answers 0x37 with 8.
- **macOS reports ANS to PMP.** ANS is a `notify_pmp` device, entry 0x21 (bit 33). macOS sets it in `DEV_STATUS_TGT_WR`. The report block is pmp reg 3 − 0x10000 = 0x5003c0000 (m1n1 `tools/pmp_assist.py`): target read 0x1e00, target write 0x10f00, actual 0x1e80, status 0x10.
- **macOS shuts ANS down through idle**, not sleep: AP 0x201, IOP 0x201, then clears the CPU run bit.

## What Linux does now

- `pmp.rs` boots PMP rather than waking it, maps the 0xe0000 SRAM window T6040 needs (bootargs at 0x87480), and answers 0x36. RTKit starts system endpoint 7 and answers its buffer request with type 5. PMP's log says `io.cpp:61: PMP started`.
- `pmp-report` has the T6041 offsets and a fix for entries 32 and up (`1 << id` was an int shift); the ANS mailbox, SART and NVMe take their power domain through `pmp_report_ans`.
- `apcie_phy_sw`, the storage PHY switch, is one of the NVMe power domains. Linux powered it off as unused; with it off ANS faulted going idle.
- `nvme-apple` stops T8132-generation ANS by **quiescing** it (0x10) and leaving its CPU running. Sleep crashes it; from idle it does not come back for a new RTKit instance (neither after a core reset nor woken with 0x220). Quiesced, it is in the state iBoot hands over, and the next start wakes it: hello, new buffer requests, power on.
- m1n1 (patch 0005) hands ANS over the same way after reading the ESP.

Verified on J614s: `nvme-apple` unbind and bind keeps the SSD; m1n1 stage 1 reading the ESP, chainloading stage 2, then Linux finds `nvme0n1` with p1–p5 and reads at 3.5 GB/s.

## Running macOS under the hypervisor

1. In recoveryOS: `tools/macos-fetch.py` serves a script that uploads macOSTest's kernelcache, SPTM and TXM; `bputil -nkcas` and `csrutil disable` for macOSTest only; reinstall m1n1 (`just m1n1-serve dev`) since the policy change removes it.
2. Extract with `ipsw` (nixpkgs): `ipsw img4 extract -p` (the Preboot kernelcache is IMG4), then `ipsw img4 im4p extract` for the kernelcache, SPTM and TXM.
3. Boot the Mac into m1n1 without switching to debug USB; m1n1's USB device gives `/dev/cu.usbmodem…1` (proxy) and `…3` (guest console).
4. `run_guest.py --sptm-mode=emulation --sptm sptm.macho --txm txm.macho -m tools/hv/trace_pmp.py -m tools/hv/trace_ans.py kernelcache.macho -- "debug=0x14e serial=3 wdt=-1 -v"`.

m1n1 patch 0004 lets the hypervisor run over the dockchannel debug UART too, but there the guest has no console, so m1n1's USB device is the better link.
