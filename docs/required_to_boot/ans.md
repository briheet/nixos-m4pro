# ANS worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

ANS is the NVMe coprocessor for the internal SSD. It comes after SART because `/arm-io/ans` names `/arm-io/sart-ans` as its `iommu-parent`. This log is the host-side work: an OCaml client that repeats the ASC wakeup, the RTKit handshake, the buffer replies, the controller register setup, the admin queue commands, and one 4 KiB read from unmodified m1n1.

The Mac was running macOS the whole time. Nothing here poked the live coprocessor.

## Hardware

The node is `/arm-io/ans`, compatible `iop,ascwrap-v6`, `device_type` `ans`, role `ANS2`. The phandle is `0x121`. `nvme-secure-bar` is present, so `nvme_init` selects `NVME_T8132` and uses register 9 as the controller base. Register 0 is the ASC CPU window. The mailbox is `0x8000` bytes into that window.

The raw `reg` property is a hash. The addresses are the `IODeviceMemory` ranges, which are the CPU physical addresses `adt_get_reg` returns.

| Index | Address | Length | Use |
|---|---|---|---|
| 0 | `0x409600000` | `0x88000` | ASC CPU. Mailbox at `0x409608000` |
| 1 | `0x409050000` | `0x4000` | |
| 2 | `0x200000000` | 0 | |
| 3 | `0x40dcc0000` | `0x60010` | Older NVMe window. Overlaps SART range 2 |
| 4 | `0x40b000000` | `0x18000` | |
| 5 | `0x40db90000` | `0xc000` | |
| 6 | `0x40dd47c00` | `0x4000` | |
| 7 | `0x200000000` | 0 | |
| 8 | `0x200000000` | 0 | |
| 9 | `0x44dcc0000` | `0x10000` | Controller base on this Mac |

`clock-gates` is an empty string, so the `u32` read in `nvme_init` fails and the die comes from the base: `(0x44dcc0000 >> 37) & 3` is 0. `clock-ids` is three little-endian words, `0x163`, `0x161`, `0x164`. m1n1 does not program them on that path, and this client does not either.

`nvme-linear-sq` is present. `nvme-queue-entries` is `0xfd`. m1n1 hardcodes `NVME_QUEUE_SIZE` 64, and the client follows that. The admin queue attribute word is `((64 - 1) << 16) | (64 - 1)`, which is `0x003f003f`. `nvme-interrupt-idx` is `0x4`. `iop-version` is `0x1`.

Register 9 is `0x10000` bytes. `CC`, `CSTS`, `AQA`, `ASQ`, `ACQ`, the admin completion doorbell `0x1004`, `0x1200`, `0x1208`, `0x1210`, and `0x1300` sit inside it. `NVME_LINEAR_SQ_CTRL` at `0x24908`, the linear admin doorbell `0x2490c`, `NVMMU_NUM` at `0x28100`, `NVMMU_TCB_INVAL` at `0x28118`, and `NVMMU_TCB_STAT` at `0x29120` sit past the end. Register 3 is `0x60010` bytes and covers those high offsets. m1n1 still uses register 9 as the single base, and the client does the same. The loopback is a flat address space, so the high stores land.

The child `iop-ans-nub` is compatible `iop-nub,rtbuddy-v2`. Under macOS the dump says that nub is running and pre-loaded. That is the live OS, and it is not a substitute for m1n1's boot. The controller class is `AppleANS3CGv2Controller`, model `APPLE SSD AP0512Z`, firmware `241.40.4`, NVMe revision 1.10.

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| ANS | `lib/nvme/ans.ml` | Wake, RTKit handshake, buffer replies, controller setup, admin queues, one read |
| RTKit words | `lib/nvme/rtkit.ml` | Message layout from `rtkit.c`, included by `Ans` |
| Loopback | `lib/boot/loopback.ml` | `P_READ64` / `P_WRITE64`, CSTS.RDY, scripted mailbox, scripted completions, stand-in page |
| Client | `lib/boot/client.ml` | SART DMA pages, wake, handshake, seed boot status, setup, admin queues, one read |
| Tests | `test/test_nixos_m4pro.ml` | Map, handshake, buffers, controller, admin commands, the read, and the failure strings |

`wake` is the opening of `rtkit_boot`. It sets the CPU control START bit `0x10` at `0x409600044`, waits until A2I control `0x110` has FULL (`bit 16`) clear, then writes the power-init message with `P_WRITE64`. Word 0 is `(6 << 52) | 0x220`, which is `0x60000000000220`. Word 1 is the management endpoint, 0. m1n1's `asc_send` uses `write64`, so this is not the lo/hi pair used for the NVMe queue addresses.

`handshake` is the rest of `rtkit_boot`.

1. Receive HELLO on the management endpoint. The version range has to overlap 11..12. The chosen version is `min(12, their max)`, which is what m1n1 computes. HELLO_ACK sends that version in both the min and max fields.
2. Receive endpoint-map chunks until the DONE bit (bit 51) is set. Each chunk is answered. A chunk without DONE gets MORE (bit 0). The last chunk gets DONE.
3. `START_EP` for each system endpoint the map named, in m1n1's order: debug, crashlog, syslog, ioreport, oslog. The message is type 5, flag bit 1, and the endpoint in bits 39:32.
4. Wait until a management message of type 7 carries IOP power `0x20`.
5. Send AP power ON, type `0xb`, state `0x20`. m1n1 returns after that send. It does not wait for the AP ack.

m1n1's power wait has no timeout. The host bounds it with the same countdown as the other receives, so a missing ack fails with `rtkit(nvme): timed out waiting for IOP power on` instead of spinning. During that wait, and again inside `nvme_poll_syslog`, a buffer request is answered. A syslog line and the ioreport types `0x8` and `0xc` are acked with the same words the coprocessor sent.

The mailbox receive follows `asc_recv`. I2A control is `0x114` and EMPTY is bit 17. The two receive registers are `0x830` and `0x838`. `asc_recv` writes no ack, so the loopback retires the message when RECV1 is read.

The loopback scripts the coprocessor side. Power-init is answered with one HELLO, min 11 and max 12 (`0x100000000c000b`). HELLO_ACK is answered with two map chunks, so both reply forms are exercised. Chunk 0 is bitmap `0x1f` (`0x8000000000001f`): management, crashlog, syslog, debug, ioreport. Chunk 1 is bitmap `0x100` plus DONE (`0x88000000000100`): oslog. The DONE reply is answered with IOP power ON (`0x70000000000020`). The default script does not send a buffer request. A live ANS sends its own HELLO and its own bitmap, and syslog, crashlog, and ioreport then ask for buffers. This bitmap is a stand-in so the state machine can run. The message shapes come from `rtkit.c`.

A buffer request is type 1. The page count sits in bits 51:44 and the IOVA sits in bits 41:0. The endpoint is message word 1. ANS is booted with a SART and no DART. A request whose IOVA is 0 is allocated, allowed through the SART, and answered with type 1, the same page count, and that physical address. `rtkit_map` rounds the size up to 16 KiB. The allocator starts at `0x82000000`. The dump has no `asc-dram-mask`, so `dva_base` stays 0 and the reply IOVA is the physical address. A request that already carries an IOVA is the `dart_translate` path, and the host fails it with `rtkit(nvme): failed to translate pre-allocated buffer`. A request with no SART bound fails with `rtkit(nvme): unable to allocate buffer`. A second crashlog request, once a crashlog buffer exists, fails with `rtkit(nvme): IOP crashed!`.

`setup` runs once `NVME_BOOT_STATUS` at `0x1300` reads `0xde71ce55`. It enables the linear submission queue, writes `0x003f003f` to `NVME_MAX_PEND_CMDS_CTRL` and to `AQA`, writes `NVMMU_NUM` 63, stores the admin and IO TCB pointers, clears `CC.EN`, waits for `CSTS.RDY` to clear, stores `ASQ` and `ACQ`, sets `CC.EN`, and waits for `CSTS.RDY`. Those 64-bit NVMe addresses are two `P_WRITE32`s, low then high, matching `write64_lo_hi`. The loopback copies `CC.EN` into `CSTS.RDY` on the write. `setup` leaves the I/O queue pointers at `0x1200` and `0x1208` alone.

`create_io_queues` is the admin half of `nvme_init`. m1n1 hardcodes the command tag at 0, so both commands land in slot 0 of the admin command queue and the admin TCB queue. Each command is 64 bytes and each TCB is 128 bytes. The client writes those bytes through the proxy at the caller-supplied physical addresses, the same stores m1n1 does into memory it allocated.

`CREATE_CQ` is opcode `0x05`. PRP1 is the I/O completion queue. CDW10 is queue id 1 in the low half and depth 63 in the high half, `0x003f0001`. CDW11 is the contiguous bit. `CREATE_SQ` is opcode `0x01`, PRP1 is the I/O command queue, and CDW11 is the contiguous bit plus completion queue id 1 at bit 16, `0x00010001`. Both opcodes are odd, so the TCB DMA flags are `NVMMU_TCB_DMA_TO_DEVICE` (bit 1). The first TCB word is `0x200`.

The submit follows `nvme_exec_command`. It drains the I2A mailbox the way `nvme_poll_syslog` does, rings the linear admin doorbell `0x2490c` with tag 0, and polls the completion at `ACQ + head * 16`. The phase bit is bit 0 of the status field and starts at 1. A matching completion invalidates that tag at `0x28118`, reads `0x29120`, advances the head, and rings the admin completion doorbell `0x1004` with the new head. Status is then shifted down by one. A nonzero code fails the command. A tag other than 0 fails it. A phase that never matches fails with `nvme: could not find command completion in CQ`. m1n1 also prints `nvme: create cq command failed` or `nvme: create sq command failed` around that, and on failure it shuts the controller down and resets ANS. This client stops at the command error and does not reset ANS.

The completion entry is 16 bytes: a 64-bit result, then a 32-bit reserved field, a 16-bit tag, and a 16-bit status. ANS DMA-writes it. The loopback plants a stand-in when the doorbell is written, at the ACQ address `setup` stored, with result 0, the doorbell tag, and status equal to the phase bit. That is a successful completion, not a completion captured from this SSD. After `CREATE_CQ` the head is 1. After `CREATE_SQ` the head is 2. Both commands succeeded, so the client stores the I/O completion pointer at `0x1208` and the I/O command pointer at `0x1200`.

The queue pages come from the caller. The demo uses `0x81000000` through `0x81050000`, stepping `0x10000`. `nvme.c` allocates each queue with `memalign(16 KiB)` and does not add a SART entry for it. This loopback SART starts empty, so the client allows each of those six ranges at 16 KiB plus the read page at `0x81060000` size `0x1000`. That is seven entries. iBoot's protected windows are runtime state and are not filled in.

`read` is `nvme_read`. The namespace is an argument. m1n1's APFS reader passes namespace 1, and the client demo does the same. The opcode is `0x02`. CDW10 and CDW11 are the LBA. CDW12 is 0, which is one 4 KiB page. The opcode is even and PRP1 is set, so the TCB DMA flags are `NVMMU_TCB_DMA_FROM_DEVICE` and the first TCB word is `0x100`. The I/O queue has its own head and phase, both starting at 0 and 1. The linear I/O doorbell is `0x24910`. The I/O completion doorbell is `0x100c`. The loopback plants the completion at the I/O completion queue and copies a stand-in page to PRP1. The page begins with the bytes `loopback`. An unaligned buffer fails with `nvme: read buffer is not 4K aligned` before the doorbell.

`BOOT_STATUS` is firmware state. `main` plants `0xde71ce55` after the handshake, the same kind of seed as the AIC counts. The handshake does not make the controller write that word.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. With the scripted mailbox, the ten A2I sends are the wakeup, HELLO_ACK `0x200000000c000c`, map reply MORE `0x80000000000001`, map reply DONE `0x88000000000000`, then `START_EP` for debug, crashlog, syslog, ioreport, and oslog (`0x50000300000002`, `0x50000100000002`, `0x50000200000002`, `0x50000400000002`, `0x50000800000002`), then AP power `0xb0000000000020`. The negotiated version is 12 and all five system endpoints are set. A HELLO whose max is 11 negotiates 11 and starts only the endpoint the map named. A missing HELLO, a bad endpoint, a bad type, versions 13..14, a missing map, a map for another endpoint, a non-map message, a missing IOP ack, and a full A2I mailbox each fail with the m1n1 string for that case. The IOP-ack timeout uses the host's bound.

After `setup`, `CC` is 1, `CSTS` is 1, `AQA` is `0x003f003f`, the linear queue bit is 1, `NVMMU_NUM` is 63, and the low halves of `ASQ` and `NVMMU_ASQ` are the demo addresses. The I/O queue pointers are still 0. After `create_io_queues` the head is 2, the admin completion doorbell is 2, the linear doorbell is 0, and the command slot holds `CREATE_SQ`: opcode `0x01`, PRP1 `0x81040000`, CDW10 `0x003f0001`, CDW11 `0x00010001`. The TCB word is `0x200` and its PRP1 is the same command queue. Both completion entries read `0x1000000000000`, which is phase 1, tag 0, and a zero status code. A `CREATE_CQ` checked on its own leaves opcode `0x05`, PRP1 `0x81050000`, CDW11 1, head 1, and the I/O pointers at 0. A missing completion, a status code of 1, and a completion tag of 9 each fail with the m1n1 string for that case, and the I/O pointers stay 0. The status failure still rings the completion doorbell with head 1.

The seven SART entries start at the admin TCBs, `0x81000000`, with a 16 KiB size, and the last is the read page at `0x81060000` size `0x1000`. A syslog buffer request for one 4 KiB page is allowed at `0x82000000` with a 16 KiB map, and the reply IOVA is that address. A second crashlog request, a pre-assigned IOVA, and a request with no SART each fail with the string above. The read of namespace 1, LBA 0 returns 4096 bytes beginning `loopback`. The I/O head is 1, the admin head stays 2, the command opcode is `0x02`, the namespace is 1, and the TCB word is `0x100`. A missing I/O completion leaves the page at 0. LBA `0x100000000` lands in CDW11.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
ANS /arm-io/ans iop,ascwrap-v6 role ANS2
NVMe bar 0x44dcc0000 reg 9, ASC 0x409600000
RTKit version 12
endpoints debug true crashlog true syslog true ioreport true oslog true
boot status 0xde71ce55, CC 0x1, admin TCBs 0x81000000
admin CQ id 1 SQ id 1 head 2, IOQ cmds 0x81040000 cqes 0x81050000
NVMe read nsid 1 lba 0, 4096 bytes at 0x81060000 marker "loopback"
RTKit buffers from 0x82000000
```

## Still open

A live init has the same requirement as the earlier drivers. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

The boot-status word is still a seed. The completion entries and the 4096-byte page are stand-ins planted by the loopback. The default mailbox script does not ask for a buffer; the client answers a request when one is posted. `nvme_shutdown` deletes the queues and then resets ANS through `pmgr_reset`. The PMGR device blob is a hash, so those reset offsets stay unread, and this client leaves the controller enabled.
