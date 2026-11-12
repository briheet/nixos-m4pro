# Internal keyboard and a shell on the screen

Date: 2026-11-13. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The built-in keyboard and trackpad sit behind the MTP coprocessor. Key events reach the CPU over a dockchannel FIFO. Asahi's drivers for this path on t602x (M2 Pro/Max) work unchanged; the M4 Pro needed device tree nodes.

## Hardware (from this Mac's ADT)

| Node | ADT | Device tree |
|---|---|---|
| MTP (`iop,ascwrap-v6`) | `/arm-io/mtp` reg 0 `0x514600000`, IRQs 792-795 | `mtp@514600000` (asc), sram `0x514c00000` from `segment-ranges` |
| Mailbox | +`0x8000` in the ASC window | `mbox@514608000`, `apple,asc-mailbox-v4` |
| DART (`dart,t8110`) | `/arm-io/dart-mtp` reg 0 `0x514800000`, IRQ 775, 16 SIDs | `iommu@514800000` |
| Dockchannel | `/arm-io/dockchannel-mtp`, IRQ 776, FIFO 2048 | `fifo@514b14000`, ranges at `0x514b28000` |

The DART address was checked on the live machine: at `0x514800000`, PARAMS3 reads `0x2A2A0202` (42-bit PA/VA, v2.2) and PARAMS4 `0x00010010` (16 SIDs). At `+0x8000`, where the t602x tree puts its MTP DART, there is no DART. The ADT has no PMGR domain for MTP.

## Kernel

- Patch 0006 adds the nodes to `t6041.dtsi`, disabled. Patch 0007 enables them for J614/J616, with the `keyboard` alias m1n1 uses to fill in `apple,keyboard-layout-id` and `hid-country-code`, and `firmware-name = "apple/tpmtfw-j614s.bin"` for the trackpad.
- The SMC GPIOs for the trackpad AFE and STM resets, and the `stm` node, are left out until there is an SMC driver.
- `kernel/m4pro-min.config`: `APPLE_RTKIT_HELPER`, `APPLE_DOCKCHANNEL`, `HID_DOCKCHANNEL`, `HID_APPLE` (needs `LEDS_CLASS`), `HID_MULTITOUCH`, `INPUT_EVDEV`, `FW_LOADER`.
- `/init` runs a second shell on `tty1`, the internal screen.

## Result

```
apple-dart 514800000.iommu: DART [pagesize 4000, 16 streams, bypass support: 1, bypass forced: 0, locked: 0, AS 42 -> 42] initialized
rtkit-helper 514600000.mtp: RTKit: Initializing (protocol version 12)
dockchannel-hid 514b30000.input: Interface keyboard is now ready
input: Apple MTP keyboard Keyboard as /devices/platform/soc/514b14000.fifo/514b30000.input/0019:0000:0000.0002/input/input3
H: Handlers=sysrq kbd leds event1
```

`echo typed-on-the-mac > /tmp/kbd`, typed on the internal keyboard into the shell on the screen, produced that file. Interrupts after typing: `apple-dockchannel-rx` 105, `mbox-recv` 49, DART faults 0.

## Open

- Trackpad multitouch: needs `apple/tpmtfw-j614s.bin` extracted from macOS. It registers as a basic mouse without it.
- AFE/STM reset GPIOs: with the SMC driver.
