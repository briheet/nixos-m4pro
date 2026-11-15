# DCP on the 27.2 firmware: the kernel side (appledrm + display gate)

Goal: drive the J614s internal panel (DCP `apple,t6041-dcp`, SoC T6040) on the
macOS 27.2 DCP firmware with Aurora's appledrm, by routing T6041 + 27.x to the
firmware-27 interface (`DCP_FIRMWARE_V_27_0`, written for T6050/M5 on 27.0)
instead of the 26.6 desktop interface (`DCP_FIRMWARE_V_26_6_DESKTOP`).

Source read: kernel-aurora `9219565939723cd5bc381941bc3978d52610d753`
(`drivers/gpu/drm/apple`, `drivers/soc/apple/display-gate.c`,
`drivers/iommu/apple-dart.c`, `arch/arm64/boot/dts/apple/t604x.dtsi`,
`t6050-*.dtsi`). Line numbers below are from that tree. The boot-loader side
(what aura has to put in the DT) is in `dcp-27.2-aura.md`.

State of the running system (2026-11-15, read-only): `/chosen/asahi,os-fw-version`
= `27.2`; `dcp@402e00000` is `disabled` and has **no** `apple,firmware-compat`
or `apple,firmware-version`; the display gate logged nothing for the internal
DCP (no `apple,t6041-handoff` marker, so it silently left simpledrm in place).
Kernel config: `CONFIG_DRM_APPLE=m`, but `CONFIG_APPLE_DISPLAY_GATE=y`,
`CONFIG_APPLE_DART=y`, `CONFIG_APPLE_RTKIT=y`, `CONFIG_APPLE_MAILBOX=y`.

## Summary

- Two firmware-version gates have to change, and one of them is built in.
  - `drivers/soc/apple/display-gate.c:2142-2146` only enables the T6041
    internal display nodes when `apple,firmware-compat` is exactly `26.6.2`.
    **It is built in (`CONFIG_APPLE_DISPLAY_GATE=y`), so changing it means a
    full kernel rebuild, not just a new appledrm.ko.** (This is a nix-config
    kernel patch anyway, so the cost is a kernel build.) The only way to avoid
    it is for the loader to enable the nodes itself and leave out the marker
    (see section 2), which skips the gate's safety checks.
  - `drm/apple/dcp.c:5265-5279` (`dcp_check_firmware_version`) accepts
    T6041 only on 26.5.2/26.6.2, and the V_27_0 branch at 5243-5248 accepts
    only the string `27.0.0`.
- The "peer" in the v27 code is **not** a T6041 concept. It is a second
  external display processor that the T6050's dcpext borrows to drive a mode
  too wide for one pipe (VFTG pair). It is gated on `apple,t6050-dcpext`
  and on a live DPTX port, so it never runs for an internal panel. Nothing
  to port for the first modeset.
- The V_27_0 path does make several T6050 assumptions that do hit a T6041
  internal panel. These ones are certain or near-certain:
  `num_dptx_ports = 2` in the T6041 hw data (it would start DPTX/iBoot
  endpoints on the panel DCP), and `apple,clock-ids` missing from the T6041
  DT (bind fails with -EINVAL). Several more are probable:
  firmware-owned shmem in RAM (memremap WC fails), no `framebuffer`
  memory-region (the firmware's default-framebuffer request is refused), and
  the IOMFB method and callback numbering of 27.2 vs 27.0.
- The patch below is about 40 lines across `dcp.c` and `display-gate.c`, plus
  a one-line DT addition. Everything ranked 3 and lower in section 4 can only
  be confirmed by running it, or by static RE of the 27.2 T6041 DCP firmware.

---

## 1. How V_27_0 is selected and used, against the T6041 26.6 desktop path

### 1.1 Selection

| Where | What |
|---|---|
| `dcp.c:5223` `dcp_check_firmware_version()` | The only selector. Its result goes into `dcp->fw_compat` (`dcp.c:6355`). |
| `dcp.c:5233-5241` | T8142 (J813) special case: `apple,t8142-dcp` with compat string `"27.0.0"` gives V_27_0, because its H17P interface panicked 27.0 (`ap_link: callback failed with: 0x5`). |
| `dcp.c:5243-5248` | Any hw entry with `.firmware_compat = V_27_0` (T6050 dcp/dcpext, `dcp.c:8785-8797`) gives V_27_0 **only if** compat is exactly `"27.0.0"`, otherwise UNKNOWN. |
| `dcp.c:5254-5255` | Other pinned hw entries (H17P, M4) return their pinned value. |
| `dcp.c:5257` | Reads `apple,firmware-version` (only used for the T6041 check). |
| `dcp.c:5265-5279` | T6041 dcp and dcpext: `firmware-version == firmware-compat` and in {26.5.2, 26.6.2} gives V_26_6_DESKTOP, else UNKNOWN plus the error "T6041 display not started ...". |
| `dcp.c:6315-6316` | UNKNOWN makes probe return -ENODEV. |
| `dcp.c:6410-6416` | After `dcp->hw` is copied from match data, T8142 on V_27_0 gets `iomfb_method_profile = DEFAULT` (H17G broke swaps). This is the precedent for per-SoC hw overrides on V_27_0. |

`apple,firmware-compat` is a u32 array (3 to 5 cells) that
`dcp_read_fw_version()` formats as a string (`dcp.c:5183-5221`).

### 1.2 hw data

`dcp.c:8776-8797`:

| field | T6041 dcp | T6050 dcp | effect in V_27_0 |
|---|---|---|---|
| `firmware_dma_bits` | 0 (42) | 41 | `dma_set_mask` at `dcp.c:5669-5670`. T6041's DARTs have `apple,dma-range = <0x100 0x0 0x10 0x0>` (`t604x.dtsi:643,653`), so either value works. Keep 42. |
| `num_dptx_ports` | **2** | 0 | `dcp_start()` at `dcp.c:4168-4170` starts the iBoot endpoint and `dptxep_init()` on any V_27_0 DCP with `num_dptx_ports != 0`, even without a PHY. For T6050 internal this is 0. **Must be 0 for the T6041 panel on 27.** |
| `adopt_live_session` | false | true | `dcp.c:5694-5700` checks CPU_CONTROL.RUN, `5864-5869` (if false) ORs RUN in, `110-120` `dcp_pin_live_session()` keeps DMA/domain alive past unbind, `7037-7051` shutdown keeps DMA, `7069` drain for sleep. 26.6 desktop gets the same effect differently (the gate checks RUN, and the RTKit wake is deferred to `dcp_start_desktop()`, `dcp.c:5895-5901`, `4039-4050`). Recommend true on 27, as T6050. |
| `firmware_compat` | UNKNOWN | V_27_0 | Pinning it for T6041 would also pin the dcpext. Use a runtime check instead (section 3). |
| `firmware_clock` | none | none | Both use `apple,bw-scratch`. |

### 1.3 Probe and bind differences (`dcp.c`)

| Line | 26.6 desktop (T6041 today) | V_27_0 (T6050) | T6041 on 27 |
|---|---|---|---|
| 6317-6321 | `dcp_validate_t6041_dt()` (`dcp.c:446-479`) pins the five reg windows to the **26.x ADT** (coproc + disp-0..3) | not called | Leave it uncalled until the 27.2 ADT `disp0` reg list is compared. If 27.2 adds a window (T6050 has a `disp-4` "PMC metadata" at `0x286700000`, `t6050-peripherals.dtsi:2622-2629`), it would wrongly refuse. |
| 6329-6333 | needs `apple,bw-scratch` | same | T6041 DT has it (`t604x.dtsi:670`, index 4). |
| 6356-6368 | allocates `dcp->desktop` | none | Every `dcp->desktop->` use is behind `fw_compat == DESKTOP`, or behind `dcp_desktop_external()` for the dcpext. Internal DCP on V_27_0 is NULL-safe. |
| 6551-6556 | surfaces from `apple,iomfb-surfaces = <1 1 0 0>` | same | Unchanged. |
| 5629-5636 | none | `iomfb_boolean_properties` list + cleanup | Generic. |
| 5683-5686 | logs CPU_CONTROL/STATUS at handoff | none | Cosmetic. Worth keeping for bring-up (patch item 6). |
| 5807-5811 → 5459-5530 `dcp_firmware_metadata_v27()` | not called | reads `memory-region-names = "framebuffer"` (DFB region size) and `apple,clock-ids` | **T6041 DT has neither.** A missing framebuffer is tolerated (`dfb_region_size = 0`, 5475-5479). A missing `apple,clock-ids` makes `of_property_count_u32_elems()` return -EINVAL, and 5497-5498 turns that into a bind failure (-EINVAL). |
| 5817-5820 | `devm_clk_get_optional` | same when `num_firmware_clocks == 0` | OK. |
| 5888-5901 | RTKit wake deferred to `dcp_start_desktop()` | `apple_rtkit_wake()` in bind | Generic. |
| 1640-1641 vs 1642-1678 | `dcp_desktop_shmem_setup()` (`dcp.c:551-584`): **vmap WC**, because "the buffers may lie in RAM or in carveouts without struct pages" (`dcp.c:481-487`) | `memremap(MEMREMAP_WC)`, and requires the PA in DRAM (`1656-1661`) | On arm64, `memremap(WC)` of linear-mapped RAM fails. If the 27.2 firmware puts its RTKit buffers in RAM, as 26.6 did, the IOMFB/system endpoint shmem setup fails. Pre-emptive patch item 5. |

### 1.4 Start and endpoints

- `dcp_start()` (`dcp.c:4108-4230`): DESKTOP returns early into
  `dcp_start_desktop()` (`4122-4125`, `4039-4100`). That function starts the
  whole aux endpoint graph: `dcp_desktop_panel_eps` at `3900-3911` (DPAVCTRL,
  EPIC25, DPSAC, DPDEV, DPAVSERV, AV, DPTX, HDCP, EPIC2C, REMOTEALLOC).
  V_27_0 starts only `systemep_init()` (4157), the iBoot/DPTX endpoints if
  `phy || num_dptx_ports` (4168), `iomfb_start_rtkit()` (4214), and AV if
  `hdmi_audio`. That matches what T6050's internal panel needs. Whether
  T6041 27.2 also wants DPAVCTRL/EPIC25 started before IOMFB is something
  only a run will show.
- AFK wire format (`afk.c:113`): `wire_v2 = fw_compat == V_27_0`. The 26.6
  desktop endpoints switch to "compact EPIC" on the first compact message
  (`afk.c:437-466`, `afk_compact_capable()` is DESKTOP-only). If the T6041
  27.2 system endpoint still speaks compact, `systemep_init` only warns
  (`dcp.c:4157-4159`). The loss is the mNits backlight takeover
  (`systemep.c:111-113`), not the modeset.
- `afk.c:1560-1561`: EPIC service-init parsing in H17P/v27 mode. `afk.c:1962-2051`:
  `afk_v27_access_remote()` resolves firmware-owned DVAs through
  `apple_dart_fw_remote()` (`apple-dart.c:2763-2794`). It works on any
  locked DART with 3- or 4-level tables.

### 1.5 IOMFB interface (the main 27.0-vs-T6041 risk)

`iomfb_v27.c` is the H17P template (`iomfb_template.c`) built with
`DCP_FW_VER = 27.0.0` (`iomfb_v27.c:116-126`):

- Method table `iomfb_v27.c:72-114`, for example A408 swap_submit, A484
  set_power_state, A450 set_parameter_dcp, A454 create_default_fb, A466/A467
  client open/close. Compare the 26.6 desktop table at
  `iomfb_v26_6_desktop.c:20-48` (A407, A473, A442, A446, A457/A458). Almost
  every number moved between 26.6 and 27.0. **27.0 to 27.2 may move again,
  and T6050's build may differ from T6041's.** Nothing in the driver checks
  this: a wrong selector is just a different call to the firmware.
- Callback table `iomfb_v27.c:405-487`, with exact minimum sizes at
  `489-572`. Validation happens in `iomfb.c:1769-1781`: an undersized known
  callback sets `dcp->crashed` ("unqualified IOMFB callback"). An unknown
  callback gets a zeroed reply and "received unknown callback"
  (`iomfb.c:1783-1825`). These two messages are the first things to grep
  for on the first run.
- Wire layouts: `dcp_swap_v27` 0x6e0 and swap_complete 0x730 (`iomfb_v27.c:66-70`,
  `iomfb_v27.h:10,45`), hotplug 0x58/0x4c (D575), D003 bandwidth reply in
  H17P form (`iomfb_v27.c:128-139`; 26.6 used `trampoline_rt_bandwidth`).
- D408 get_frequency (`iomfb_v27.c:141-155`) answers by **ADT clock-id
  index** into `apple,clock-ids`. T6050 lists `<361 458>` with real clocks
  (`t6050-j716c-gpu-panel.dtsi:390-394`). With none, every D408 logs
  "undeclared provider clock index" and answers 0 Hz. 26.6 desktop answered
  0 Hz too and worked (`dcp.c:5812-5816` comment), but 27 may compute
  bandwidth or clock settings from it.
- D400 get_data_prop (`iomfb_v27.c:221-239`) serves `VORP` keys straight
  from **DT properties of the dcp node**. The firmware can ask for ADT
  properties the T6041 DT does not carry, and gets nothing back.
- D411 map_reg (`iomfb_template.c:1415-1423`): V_27_0 replies with
  `disp_firmware_base[index]` (PA = DVA), for windows disp-0..3 + bw-scratch
  (index 4). The firmware indexes windows in ADT order, so a 27.2 ADT with a
  new disp0 window shifts the index.
- DFB (default framebuffer): D586 create_dfb_surface (`iomfb_template.c:849-910`)
  sizes the surface against `dfb_region_size`. With no `framebuffer` region
  (T6041 today) it logs "unsupported DFB layout" and replies false. On T6050
  the loader supplies that region for the internal DCP. The comment at
  `dcp.c:5468-5471` says only dcpext4 lacks it.
- Mode set: `DCP_INHERIT_BOOT_MODE` is false for 27.x
  (`iomfb_template.c:447-451`), so the driver sends A413
  set_digital_out_mode. `appledrm.fw27_panel_boot_mode` (`dcp.c:362-367`,
  `iomfb_template.c:453-470`) set to 1 keeps the iBoot mode and avoids A413.
  **Use `appledrm.fw27_panel_boot_mode=1` for the first run** (J815 rejects
  A413 with 0x8000000b).
- XRGB: `apple_drv.c:190-200` makes fbdev ARGB on every V_27_0 (fbcon stays
  correct). `apple_drv.c:1150-1158` marks XRGB's X byte as alpha only for
  T8142 on V_27_0. If a compositor shows wrong colours or black on T6041,
  add `apple,t6041-dcp` there.
- Other V_27_0-only behaviour, which is generic and applies to an eDP panel
  as it does on T6050: the queued transport (`iomfb.c:361-365`), no
  opaque-X workaround (`iomfb.c:399`), command-record check skipped
  (`iomfb.c:1880`), `pq_dsc` mode parsing (`iomfb.c:2096-2098`), soft DPMS
  and nits backlight (`dcp.c:4439-4446`, `4470-4521`; `dcp_backlight.c:97-101,
  277`), and the D113 analytics passthrough that stops the crash about an
  hour in (`iomfb_v27.c:366-403`).

### 1.6 Peer, dcpext, fabric, power: T6050-only, not on the internal path

- **Peer**: `dcp-peer-v27.inc:62-154` `dcp_peer_hints_v27()` returns early unless
  `apple,t6050-dcpext` and DPTX unit 0 (line 77). The candidate scan also
  requires `apple,t6050-dcpext` (line 124). The index rule
  `dcp_peer_index_allowed()` (`dcp-peer-v27.h:113-120`) is the T8132/T6050
  crossbar's. `dcp_peer_check_v27()` (`dcp-peer-runtime-v27.inc:138-148`)
  returns 0 when `dptxport[0].caps.total_rate == 0`, which is always true
  for a panel. The tiling D114/D115 getters (`iomfb_v27.c:328-360`) fall
  through to the non-tiled answer. T6041 has its own 26.6 pair
  (`dcp-peer-v26_6.*`), and its dcpext topology is different (dcpext0 is
  HDMI, dcpext1 is Type-C; J614s has no dcpext0 in the ADT,
  `display-gate.c:2297-2304`). No T6041
  equivalent is needed for the panel.
- **Fabric/crossbar**: `dcp-fabric.c:2410-2454` `dcp_direct_crossbar_link_t6050()`
  (V_27_0 and external only), `dcp-fabric.c:314,357,386` (T6050 DP-tunnel
  clock symbol), `dcp-fabric.c:2097,3008`, `dptxep.c:291,374,644,790,981-1000,
  1181,1387` are all external or DPTX only.
- **Clock/power**: `apple,display-power` is used only by the H17P
  suspend-to-RAM sequences (`dcp.c:7746-7986`, `dcp_s2r_capable()` =
  H17P && `hw.s2r`, `dcp.c:7308-7311`). Not V_27_0, not the first modeset.
- **dcpext**: the T6041 dcpext on 27.x should stay refused (UNKNOWN, after
  which the failsafe path marks it an unusable pipe, `dcp.c:6902-6960`). The
  gate also refuses it today ("no firmware memory"). Any 27.x dcpext work is
  a separate project.

### 1.7 DART (built in)

`apple-dart.c:5378-5384`: `fw_mirror` (locked roots that mirror Linux
mappings) already includes `apple,t6041-dart`. `apple-dart.c:5418-5419`:
`fw_tree`, which records and reserves the firmware's own subtrees in
**four-level** locked roots, is **t6050-only**. The comment at
`apple-dart.c:396-403` says explicitly that T6041 still has to be checked. If
the 27.2 iBoot leaves the T6041 DCP DART (`dcp_dart`, SID 23) on a
four-level root with firmware subtrees, Linux's DMA allocations can land on
firmware slots. **This would also need a kernel rebuild** (DART is built in).
It can only be learned by running: dump the DART's TTBR/level state at bind.

---

## 2. The display gate (`drivers/soc/apple/display-gate.c`, built in)

- Runs at `arch_initcall_sync` (`display-gate.c:3209,3241`), before platform
  devices exist. For `apple,t6040` it is `gate_t6041` (`328-336`), which runs
  `gate_t6041_run()` (`3031-3037`): `gate_t6041_internal()` (`2118-2192`),
  then the staged external chains. It does nothing when booted with
  `video=...` firmware-drivers-only.
- What it requires from the boot loader for the internal panel
  (`gate_t6041_internal`):
  1. A node at alias/path `dcp`, compatible `apple,t6041-dcp`, carrying
     `apple,t6041-handoff`. If the marker is absent, nothing happens and
     nothing is logged (this is today's 27.2 boot).
  2. `disp0` compatible `apple,display-subsystem`, plus the dcp's `piodma` and
     `panel` children. dcp, disp0 and piodma each need
     `apple,t6041-handoff = <1>` (`2132-2140`).
  3. **`apple,firmware-compat` on dcp: exactly 3 cells and exactly `26 6 2`
     (`2142-2146`).** The appledrm desktop path also accepts 26.5.2, but the
     gate does not.
  4. DART and mailbox topology (`2148-2159`): dcp `iommus` is a single
     `t8110-dart` entry with SID 23; disp0 has SID 0; piodma has SID 16 on
     **the same** DART as disp0, and dcp's DART must differ from it. One
     `asc-mailbox-v4`.
  5. All six nodes (dcp DART, disp DART, mailbox, disp0, dcp, panel) still
     `disabled` (`2161-2166`).
  6. The ASC is running: `coproc + 0x44` bit 4 (`2168-2176`).
  Then it sets them `okay` through an OF changeset (`2178-2188`).
- **Firmware-version constraint: yes.** Item 3 hard-codes 26.6.2, so with
  27.2 the internal display never gets enabled, whatever appledrm does.
  Changing that needs a **kernel rebuild** (built-in code, `__init`, runs
  before modules load). The gate does nothing else that depends on the
  firmware: no PMP and no piodma programming for the internal DCP. The
  staged dcpext chains only check firmware memory regions
  (`staged_firmware_memory()`).
- A workaround without a rebuild: aura sets `status = "okay"` on the six
  nodes itself and does **not** set `apple,t6041-handoff` on dcp. The gate
  then returns at its first check. appledrm's V_27_0 path does not look for
  the marker (only the 26.6 `dcp_validate_t6041_dt()` and the 14.7/26.6 J613
  paths do). The cost is that you lose the gate's DART/SID/running checks.
  Since the kernel is a nix-config build output, the gate patch (3.4) is the
  better route.

---

## 3. Minimal patch plan

Exact edits against the tree above. Items 1-4 are required. Item 5 is
strongly suggested. Items 6-7 are bring-up aids.

### 3.1 `drivers/gpu/drm/apple/dcp.c`: select V_27_0 for T6041 on 27.2

Add a kill switch next to `t6041_dcpext` (`dcp.c:378-381`):

```c
static bool t6041_fw27 = true;
module_param(t6041_fw27, bool, 0444);
MODULE_PARM_DESC(t6041_fw27,
		 "T6041 internal panel: drive macOS 27.2 DCP firmware through the firmware-27 interface (default 1)");

/* T6041 internal DCP on a 27.2.x firmware: the T6050 firmware-27 instance. */
static bool dcp_t6041_fw27(struct device *dev)
{
	u32 v[3];

	return t6041_fw27 &&
	       of_device_is_compatible(dev->of_node, "apple,t6041-dcp") &&
	       of_property_count_u32_elems(dev->of_node, "apple,firmware-compat") == 3 &&
	       !of_property_read_u32_array(dev->of_node, "apple,firmware-compat", v, 3) &&
	       v[0] == 27 && v[1] == 2;
}
```

In `dcp_check_firmware_version()`, at the top of the T6041 block
(`dcp.c:5265`, right after `compat_ret = ...`):

```c
		if (dcp_t6041_fw27(dev)) {
			dev_info(dev, "T6041 DCP firmware %s (compat %s): firmware-27 interface\n",
				 ret >= 0 ? fw_str : "missing", compat_str);
			return DCP_FIRMWARE_V_27_0;
		}
```

The dcpext (`apple,t6041-dcpext`) is deliberately not matched, so on 27.x it
falls through to the existing "not 26.5.2 or 26.6.2" refusal and becomes an
unusable failsafe pipe. Do not require `firmware-version == firmware-compat`
here: aura may report `27.2.1` as the version and `27.2.0` as the compat.
Adjust the `v[1] == 2` match to whatever aura emits (see `dcp-27.2-aura.md`).

### 3.2 `dcp.c`: T6041-on-27 hw overrides

In `dcp_platform_probe_pipe()`, next to the T8142 override (`dcp.c:6410-6416`):

```c
	/*
	 * T6041's internal DCP on firmware 27 runs like T6050's: adopted
	 * running, with no DPTX port services on the panel processor.
	 */
	if (fw_compat == DCP_FIRMWARE_V_27_0 &&
	    of_device_is_compatible(dev->of_node, "apple,t6041-dcp")) {
		dcp->hw.num_dptx_ports = 0;
		dcp->hw.adopt_live_session = true;
	}
```

`num_dptx_ports = 0` keeps `dcp_start()` (`4168-4170`) from opening iBoot and
DPTX on the panel DCP. `adopt_live_session` gives the T6050 handling for
bind, unbind and shutdown (1.2). If you would rather keep the 26.6 desktop
handling for the first try, leave `adopt_live_session` false. Bind then ORs
RUN in, which is a no-op on a running ASC.

### 3.3 `apple,clock-ids` (DT or code)

Do one of these:
- DT (preferred, mirrors `t6050-j714s-gpu-panel.dtsi:99-110`): in
  `arch/arm64/boot/dts/apple/t604x.dtsi` `dcp: dcp@402e00000`, add
  `apple,clock-ids;` (empty). Later, put the 27.2 ADT `/arm-io/dcp clock-ids`
  values there, with `clocks`/`clock-names = "firmware-N"`, if the firmware
  turns out to need real D408 rates. Aura could add it instead, but it
  belongs in the DT.
- Code: `dcp.c:5495-5497` currently treats only `-ENODATA` as "present, no
  values". Make an absent property count as zero clocks:
  ```c
  	if (clocks == -EINVAL &&
  	    !of_property_present(dev->of_node, "apple,clock-ids"))
  		clocks = 0;
  ```
  With zero clocks, `devm_clk_bulk_get_all()` returns 0 (no `clocks`
  property), which matches.

### 3.4 `drivers/soc/apple/display-gate.c`: accept 27.2 (kernel rebuild)

`display-gate.c:2142-2146`:

```c
	/* The desktop 26.6.2 instance, or the firmware-27 instance on 27.2.x. */
	if (of_property_count_u32_elems(nodes[T6041_DCP], "apple,firmware-compat") != 3 ||
	    of_property_read_u32_array(nodes[T6041_DCP], "apple,firmware-compat", version, 3) ||
	    !((version[0] == 26 && version[1] == 6 && version[2] == 2) ||
	      (version[0] == 27 && version[1] == 2)))
		goto out;
```

Also update the comments at `display-gate.c:72-73` and `2093-2099`. No other
gate change is needed, provided aura keeps emitting the markers and the SID
layout (23 / 0 / 16).

### 3.5 `dcp.c`: map firmware shmem the desktop way on T6041 (suggested)

`dcp.c:1640`:

```c
	if (bfr->iova && (dcp->fw_compat == DCP_FIRMWARE_V_26_6_DESKTOP ||
			  (dcp->fw_compat == DCP_FIRMWARE_V_27_0 &&
			   of_device_is_compatible(dcp->dev->of_node, "apple,t6041-dcp"))))
		return dcp_desktop_shmem_setup(dcp, bfr);
```

`dcp_rtk_shmem_destroy()` (`dcp.c:1696-1705`) already handles `bfr->private`
(vunmap). Without this change, a 27.2 RTKit buffer in linear-mapped RAM makes
`memremap(WC)` fail, and RTKit start fails ("shmem_setup").

### 3.6 Bring-up aids (optional)

- Extend the "coprocessor handoff" log (`dcp.c:5683-5686`) to the T6041 V_27_0
  case.
- Boot the first run with `appledrm.fw27_panel_boot_mode=1` (keeps the iBoot
  timing, no A413) and `appledrm.t6041_dcpext=0`.

### 3.7 Not needed for the first modeset

Peer code, fabric/crossbar, `apple,display-power`/s2r, dcpext, PMP. The
`apple_drv.c:1587-1589` 10 s start timeout keys on the compatible string, so
it still applies.

---

## 4. T6050 assumptions that need T6041 equivalents, ranked by how likely they break the first modeset

| # | Assumption | Symptom | How to learn | Fix |
|---|---|---|---|---|
| 0 | (Blockers, certain) Gate wants 26.6.2. appledrm wants 26.x for T6041 and `27.0.0` for V_27_0. | No dcp device / "T6041 display not started" | done | 3.1, 3.4 |
| 1 | `apple,clock-ids` present (certain) | bind -EINVAL | done | 3.3 |
| 2 | IOMFB **method numbers** of the 27.0 T6050 build (`iomfb_v27.c:72-114`) | firmware answers the wrong call, hangs or panics (cf. T8142 `0x5`), "start_done" timeout | static: selector strings in the 27.2 T6041 DCP firmware, against 27.0 T6050. run: syslog/crashlog | new `iomfb_v27_2.c` table, or per-SoC table selection if numbering differs |
| 3 | **Callback numbers and minimum sizes** (`iomfb_v27.c:405-572`) | "unqualified IOMFB callback N" (crash flag) or "received unknown callback" | run (first dmesg), or static RE | adjust table |
| 4 | Wire layouts: swap 0x6e0, swap_complete 0x730, hotplug 0x58 (`iomfb_v27.h`, `iomfb_v27.c:63-70`) | swaps rejected, no vblank | run (swap status), static RE | new structs |
| 5 | Loader-supplied `framebuffer` memory-region for the DFB (`dcp.c:5473-5491`, D586) | "unsupported DFB layout", start may stall in D121 | run | aura adds `memory-region`/`memory-region-names = "framebuffer"` (the boot fb at `0x105df78c000`) |
| 6 | RTKit shmem via memremap in DRAM (`dcp.c:1642-1678`) | "shmem_setup ... not physically contiguous / -ENOMEM", RTKit start fails | run | 3.5 |
| 7 | A413 set_digital_out_mode accepted on the panel | modeset fails `0x8000000b`, no swaps | run | `fw27_panel_boot_mode=1` |
| 8 | `num_dptx_ports = 0` on the panel DCP (`dcp.c:4168`) | iBoot/DPTX endpoint warnings, possible firmware confusion | done | 3.2 |
| 9 | D408 clock indices with real rates (`iomfb_v27.c:141-155`) | dev_err spam. Firmware may misconfigure bandwidth/clock (underflow, blank) | run + 27.2 ADT `clock-ids` | DT clocks |
| 10 | D411 window index = ADT disp0 order + bw-scratch | wrong register window, faults | 27.2 ADT `disp0 reg` count against the 26.x five | DT reg list / bw-scratch index |
| 11 | D400 `VORP` properties present in the dcp DT node | firmware falls back or fails for a property | run (log D400 keys) | add properties in DT/aura |
| 12 | DART four-level firmware subtrees reserved only for t6050 (`apple-dart.c:5418`) | DART faults or corruption after Linux maps buffers | run (DART state at bind) | add `apple,t6041-dart` to `fw_tree` (**kernel rebuild**) |
| 13 | AFK v2 wire on the system endpoint (`afk.c:113`) against 26.6's compact EPIC | "Failed to start system endpoint", no mNits backlight takeover | run | allow compact on T6041 v27 in `afk_compact_capable()` |
| 14 | No DPAVCTRL/EPIC25 started before IOMFB (26.6 desktop started them, `dcp.c:3900-3911`) | unknown; possibly the panel does not light | run | start them for T6041 v27 |
| 15 | XRGB X byte read as alpha (only T8142 flagged, `apple_drv.c:1150-1158`) | wrong colours / black under a compositor (fbcon OK) | run | add t6041 |

**Only learnable by running** (or by static RE of the 27.2 T6041 DCP
firmware image): items 2-4 numbering and layouts, 6, 7, 9 (whether 0 Hz
matters), 11, 12, 13, 14, 15. **Learnable from the 27.2 ADT** (aura agent):
items 5, 9 (clock-id values), 10 (disp0 reg count), and the value of
`firmware-compat` to match in 3.1/3.4.

First-run checklist (read-only observation is enough): grep dmesg for
`apple-t6041-display`, `T6041 DCP firmware`, `shmem_setup`,
`unqualified IOMFB callback`, `received unknown callback`,
`unsupported DFB layout`, `undeclared provider clock index`,
`DCP is_main_display`, `Failed to start system endpoint`, and RTKit crash
logs. Use `appledrm.fw27_panel_boot_mode=1 appledrm.t6041_dcpext=0`.
