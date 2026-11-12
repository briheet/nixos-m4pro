# PCIe worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

PCIe is the sixth boot driver, after the UART, the watchdog, the AIC, the power manager, and the DART. This log is the host-side work: an OCaml client that repeats the `apcie,t6040` MMIO from `pcie_init_controller` in unmodified m1n1.

The Mac was running macOS the whole time. Nothing here poked the live root complex.

## Hardware

The controller m1n1 initializes on this machine is `/arm-io/apcie0`, compatible `apcie,t6040`. There is no `/arm-io/apcie`. `pcie_init` also looks for `/arm-io/apcie-ge0` and `/arm-io/apcie-ge1`, and those nodes are absent. The USB4 controllers `apciec0`, `apciec1`, and `apciec2` are a different compatible and this init does not touch them.

`apcie,t6040` selects `regs_t8132`. That description has type `APCIE_T8132` and compat `APCIE_T8122`, and it has no fuse table. The T8122 path takes PHY and PHY-common from register index 2, then adds `0x8000` and `0x4000`.

`#ports` is 4. The dump has 35 `IODeviceMemory` ranges. Seven are shared and each port has seven more. The addresses are the CPU physical addresses `adt_get_reg` returns.

| Index | Role | Address | Length |
|---|---|---|---|
| 0 | ECAM | `0x1cb0000000` | `0x10000000` |
| 1 | Root complex | `0x414000000` | `0x4000` |
| 2 | PHY window | `0x417000000` | `0x40000` |
| 3 | PHY IP | `0x417040000` | `0x28000` |
| 4 | AXI | `0x416000000` | `0x1000000` |
| 5 | Fuses | `0x415046200` | `0x4000` |
| 6 | Shared, unused by this register map | `0x415044000` | `0x4000` |

After the T8122 adjustment the PHY control block is `0x417008000` and the PHY common block is `0x417004000`.

| Port | Bridge | Port base | Port PHY | Link speed m1n1 programs |
|---|---|---|---|---|
| 0 | `pci-bridge0`, Wi-Fi and Bluetooth | `0x410028000` | `0x417020000` | 2, from `maximum-link-speed` |
| 1 | `pci-bridge1`, SD card reader | `0x411028000` | `0x417024000` | 2, from the child's `expected-link-speed` |
| 2 | no bridge node | `0x412028000` | `0x417028000` | skipped |
| 3 | no bridge node | `0x413028000` | `0x41702c000` | skipped |

Wi-Fi's `iommu-parent` is `mapper-apcie0-wlan`. Bluetooth's is `mapper-apcie0-bt`. The SD reader's is `mapper-apcie1` on `dart-apcie1`. The internal SSD is not on this bus. It is `/arm-io/ans`, and its `iommu-parent` is `sart-ans`.

`clock-gates` decodes to eight power-manager device ids: `0xf0`, `0xa2`, `0xf4`, `0xa3`, `0xf2`, `0xa4`, `0xf3`, `0xf5`. Turning those on needs the `devices` blob, which the dump stores as a hash.

These tunables are also hashes, so the client leaves them unread: `apcie-axi2af-tunables`, `apcie-phy-tunables`, `apcie-phy-ip-pll-tunables`, `apcie-phy-ip-auspma-tunables`, `pcie-rc-tunables`, `pcie-rc-gen3-shadow-tunables`, and `pcie-rc-gen4-shadow-tunables`. There is no `apcie-common-tunables` property. `apcie-config-tunables` on both bridges is 24 cleartext bytes: offset `0x140`, size 4, mask 1, value 1. `apcie-pcieclkgen-tunables` is also cleartext, and `pcie_init` does not apply it.

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| PCIe | `lib/soc/pcie.ml` | The t6040 register map and `init` |
| Loopback | `lib/boot/loopback.ml` | Answers the clock, PHY, root-complex, and port-RUN polls |
| Client | `lib/boot/client.ml` | Runs `init` after the DART |
| Tests | `test/test_nixos_m4pro.ml` | The two live ports, a skipped port, and a poll that times out |

`init` follows `pcie_init_controller` for `/arm-io/apcie0` where the step does not need a hashed blob:

1. Store 0 at root-complex offset `0x4`.
2. Request PHY CLK0 and CLK1 and poll for the ack bits. Clear the t8132 PHY reset, bit 4. Store 1 and then `0x10` at PHY offset `0x4`.
3. Set PHY-common clock mode to 1 and poll PHY offset `0x8` for bit 0. Store `0x200` in PHY control.
4. Store `0x140` at root-complex `0x54` and 1 at `0x50`. Poll `0x58` for bit 0.
5. For each port that has a `pci-bridge` node, write the T8122 port block, including 16 words at `0x3000` and 512 MSI-map words at `0x3800`. Apply the config tunable. Enable the port application clock. Bring up that port's PHY clocks, clear bit 4, and set bits `0x200` and `0x400`. Set port reset-disable at `0x82c`. Poll port status for RUN, then poll link status until busy is clear.
6. Open the DesignWare read-only latch, program link speed 2 and one lane, and close the latch. The next function's ECAM window is 32 KiB higher, including the two ports that were skipped.

The loopback sets a clock ack when the matching request bit is stored, sets PHY offset `0x8` once both shared-PHY clocks have acked, sets root-complex `0x58` when `0x50` holds bit 0, and sets port status RUN when reset-disable is stored. Link status stays 0, so the busy poll sees an idle port. That is the stand-in for silicon finishing the polls. It is not a trained link.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. After `init`, the shared PHY control reads `0x20f` and PHY offset `0x8` reads 1. PHY common reads 1. Root complex `0x54` is `0x140`, `0x50` is 1, and `0x58` is 1. Port 0's config word `0x104` is `0xfffffff0`, the tunable leaves `0x140` at `0x11`, the application clock is `0x100101`, reset-disable is 1, and the port PHY reads `0x60f`. A seeded MSI-map word and a seeded `0x3000` word are cleared. Port 2 keeps a seeded `0x104`. Both ECAM link-capability words read `0x12`. A poll of an address the loopback never completes raises `pcie: Timeout enabling PHY`.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
PCIe /arm-io/apcie0 apcie,t6040
ECAM 0x1cb0000000, RC 0x414000000, PHY 0x417008000
brought up 2, skipped 2
```

## Still open

A live init has the same requirement as the earlier drivers. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

The hashed tunables and the eight power domains are still open. So is a NixOS driver for `apcie,t6040`. The SSD path continues at `sart-ans`, then the ANS coprocessor.
