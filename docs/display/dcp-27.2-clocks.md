# DCP on the 27.2 firmware: the provider clock (`updateFrequencies`)

Static RE of `build/dcp27/dcp-text.bin` (offsets are into TEXT, as in
`dcp-27.2-rpc.md`), the 27.2 ADT (`build/adt.bin`), appledrm's firmware-27
interface (`iomfb_v27.c`, `dcp.c`) and the live j614s kernel log. Companion
docs: `dcp-27.2-rpc.md`, `dcp-27.2-kernel.md`, `dcp-27.2-aura.md`.

## 1. The symptom

Every modeset:

```
IOMFB updateFrequencies: minimum-frequency property not found, using getClockFrequency(0) instead.
apple-dcp: DCP requested undeclared provider clock index 0
IOMFB updateFrequencies getClockFrequency returned pixelClock = 0
IOMFB updateFrequencies EDT ERROR: getClockFrequency(0) (0) < videoClock 402278400! Giving up on frequencies.
set_disp_perf_state: video_clock = 402280000, disp_clock = 522963968
set_disp_perf_state: Call config_disp_perf_state :: Disp_Index = 0: perf_state = 3, disp_clock = 522963968, Flags = 0
IOMFB: videoClock is zero, defaulting to 402280000
program_frame_size: pixel_clock 804560000, vid0 402280000, ...
```

## 2. What the firmware asks for

The function is `UPPipeDCP_H16GSC::setup_video_limits` (text `0x2ad854`; its
error path names `setup_video_limits`, log tag `updateFrequencies`). It runs
on every modeset. The pipe object's fields: `+0x338` PixelClock, `+0x340`
VideoClock, `+0x348` DisplayClock, `+0x350` DispPerfState, `+0x368`
MaxVideoSrcDownscalingWidth.

1. VideoClock (`+0x340`) = the current timing's video clock (402278400 Hz for
   3024x1964@120).
2. `provider->vfunc[0x60]("minimum-frequency", &u64)` (`0x2ad9c8`). That
   vfunc is the **D401** wrapper (`0x21b77c`: `{obj[4] = this+0x10, key[0x40],
   u64 value, u8 value_null}` in 0x50, `{u64 value, u8 ret}` out 0xc), i.e.
   `get_uint_prop(obj, "minimum-frequency")`. The obj FourCC is the provider's
   (the same object as D400's, which appledrm answers for `"PROV"`; the exact
   FourCC for this call is inferred, not traced). appledrm's D401 handler
   (`dcpep_cb_get_uint_prop`) only knows `PMUS`/`Temperature`, so it answers
   `ret = 0` -> "property not found".
3. Fallback: `provider->vfunc[0x90](0)` = **D408** `getClockFrequency`
   (`0x21b500`, in 8 = `{u32 service, u32 clock_id = 0}`, out 8 = `u64 Hz`).
   The driver logs the index it got: 0.
4. If PixelClock < VideoClock: log "EDT ERROR ... Giving up", zero PixelClock
   and VideoClock and skip the rest. If minimum-frequency existed but was
   below VideoClock, it retries with getClockFrequency(0) first.
5. On success: DisplayClock = `0x237234(VideoClock)`, DispPerfState =
   `0x2de304(DisplayClock, ...)` (a nonzero return there panics with
   `IOMFB: failed to get disp perf state`, but this is the same pair of
   functions `set_disp_perf_state` already calls successfully with the same
   video clock: disp_clock 522963968, perf state 3).
6. Then (both paths) the downscale ratio `r = (PixelClock << 16) / VideoClock`
   (after stripping common factors of 2) is written as pipe parameter 0x39
   (`0x18ba24(..., 0x39, r, 1)`) and `MaxVideoSrcDownscalingWidth = r * 2 *
   width >> 16`; with a zero clock it falls back to 5120 or 6720. The values
   are published as `VideoClock`, `PixelClock`, `DisplayClock`,
   `DispPerfState`, `MaxVideoSrcDownscalingWidth`.

**Value needed:** any rate >= VideoClock (402278400 Hz at 120 Hz; lower at
lower refresh). The meaning is the display pipe ("pixel") clock.

The only other reader of PixelClock is `verify_bandwidth` (`0x2b0c74`), per
layer on each swap: it rejects a swap when `PixelClock * 2 * dispW < VideoClock
* srcW` ("pixel clock is too slow for swap"), and **skips the check when
PixelClock is 0**. So today the firmware is more permissive, not less.

## 3. Where T6050 gets it, why T6041 has none

- T6050 (j716c): ADT `/arm-io/dcp clock-ids = <361 458>`. The DT copies them
  to `apple,clock-ids` with `clocks = <&dcp_fw_clk361>, <&dcp_fw_clk458>` and
  `clock-names = "firmware-0", "firmware-1"` (fixed clocks the loader fills
  from `/arm-io clock-frequencies[id - 256]`). `dcp_firmware_metadata_v27()`
  binds them; D408 index N returns `clk_get_rate(firmware_clocks[N])`.
- T6041 (this Mac, 27.2 ADT): `/arm-io/dcp clock-ids` is **empty** (only
  `clock-gates` = 430, DISP-CPU-V). The live DT node has `apple,clock-ids`,
  `clocks` and `clock-names` all present and empty, so
  `num_firmware_clocks = 0` and `dcp->clk = NULL`; every D408 answers 0.
- The display clocks live on `/arm-io/disp0`: `clock-ids = <376 460>`;
  `clock-frequencies[376 - 256] = 712000000`, `[460 - 256] = 0`. Clock 263 is
  402280000, the firmware's own default video clock.
- Earlier appledrm firmware paths answered D408 with `clk_get_rate(dcp->clk)`
  (`iomfb_template.c` `dcpep_cb_get_frequency`), and the T6041 j614c DT gives
  the dcp `clocks = <&clk_disp0>` with `clk_disp0` = 712000000. Same SoC, same
  callback, same answer: **712 MHz**.

## 4. The fix (out-of-tree driver patch)

Answer D408 index 0 with disp0's clock when no provider clocks are declared:
`dcp->clk` if a DT ever gives one, else 712 MHz on `apple,t6041-dcp`.
Applies on top of display-patches/0001 (which does not touch
`iomfb_v27.c`); T6050 (declared clocks) and its dcpext instances (no clocks,
not t6041) are unchanged. Suggested name:
`display-patches/0002-t6041-dcp-27.2-provider-clock-0.patch`.

```diff
--- a/drivers/gpu/drm/apple/iomfb_v27.c
+++ b/drivers/gpu/drm/apple/iomfb_v27.c
@@ -138,6 +138,30 @@
 	return true;
 }
 
+/*
+ * T6041 (macOS 27.2): ADT /arm-io/dcp has an empty clock-ids, so the device
+ * tree declares no provider clocks. The firmware's setup_video_limits
+ * ("updateFrequencies") asks D401 for the provider's "minimum-frequency" and,
+ * without it, D408 for clock 0: the display pipe clock, which must be at least
+ * the mode's video clock (402278400 Hz at 3024x1964@120), else it gives up and
+ * leaves PixelClock, VideoClock, DisplayClock and DispPerfState at 0. Answer
+ * with disp0's clock: ADT /arm-io/disp0 clock-ids[0] = 376, /arm-io
+ * clock-frequencies[376 - 256] = 712 MHz, the rate the earlier T6041
+ * firmware got from clk_disp0 for the same callback.
+ */
+#define DCP_T6041_DISP0_CLOCK_HZ 712000000ULL
+
+static u64 dcp_v27_undeclared_clock(struct apple_dcp *dcp, u32 index)
+{
+	if (index || dcp->num_firmware_clocks)
+		return 0;
+	if (dcp->clk)
+		return clk_get_rate(dcp->clk);
+	if (of_device_is_compatible(dcp->dev->of_node, "apple,t6041-dcp"))
+		return DCP_T6041_DISP0_CLOCK_HZ;
+	return 0;
+}
+
 static bool trampoline_get_frequency_v27(struct apple_dcp *dcp, int tag,
 					void *out, void *in)
 {
@@ -148,6 +172,8 @@
 	if (index < dcp->num_firmware_clocks)
 		rate = clk_get_rate(dcp->firmware_clocks[index].clk);
 	else
+		rate = dcp_v27_undeclared_clock(dcp, index);
+	if (!rate && index >= dcp->num_firmware_clocks)
 		dev_err(dcp->dev, "DCP requested undeclared provider clock index %u\n",
 			index);
 	*(__le64 *)out = cpu_to_le64(rate);
```

Expected log after the fix: no "undeclared provider clock" line,
`getClockFrequency returned pixelClock = 712000000`, no "Giving up". The
"minimum-frequency property not found" line stays (harmless: it is the normal
fallback). With 712 MHz at 120 Hz: r = 1.770 (115993 / 65536),
MaxVideoSrcDownscalingWidth = 10704 for 3024 wide, and verify_bandwidth
starts rejecting layers downscaled by more than 3.54x (srcW/dispW).

Alternatives, not needed:
- Answer D401 `minimum-frequency` (provider obj) in `dcpep_cb_get_uint_prop`
  with the same 712 MHz. The firmware still uses it only for PixelClock.
- DT/aura: publish a fixed clock and `clocks = <&clk_disp0>` on the dcp. Today
  aura writes `clocks` empty for T6041, and a non-empty `clocks` with no
  `firmware-0` name trips `devm_clk_bulk_get_all() != clocks (0)` -> -EINVAL
  in `dcp_firmware_metadata_v27()`, so it needs a driver change anyway.

Verify after boot: `journalctl -k | grep -E 'updateFrequencies|undeclared'`.

## 5. Does it explain the ~44 fps dips?

Almost certainly not. The display power/perf state is set by a separate path,
`set_disp_perf_state` (text `~0x2c5d30`), which computes disp_clock from the
timing's video clock and does not read PixelClock; it already requests perf
state 3 (disp_clock 522963968), the same state `setup_video_limits` would
compute. The failed `updateFrequencies` only:

- leaves the published VideoClock/PixelClock/DisplayClock/DispPerfState
  properties at 0 and MaxVideoSrcDownscalingWidth at its 5120/6720 default;
- skips pipe parameter 0x39 (the downscale ratio);
- disables the `verify_bandwidth` per-layer downscale check (more permissive).

None of these affect swap timing at 1:1 scanout. The fix removes the error
spam and makes the firmware state match macOS's, but look for the frame drops
on the GPU/compositor/swap-completion side (e.g. swap_complete timestamps vs
vblank, GPU submission under new-window load).
