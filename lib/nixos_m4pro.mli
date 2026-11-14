(** Host-side drivers for a Mac16,8 (J614s, T6040).

    [Proto] speaks the m1n1 UART proxy, over the loopback or a live tty ([Serial]). [Soc] is the UART, the watchdog,
    the AIC, PMGR, DART, PCIe, and SART. [Nvme] is the ANS coprocessor.
    [Boot] is the loopback peer, the payload scanner, [Client.run], and the read-only live [Probe].
    Each module below is the one from that layer. *)

module Proxy = Proto.Proxy
module Wire = Proto.Wire
module Serial = Proto.Serial
module Uart = Soc.Uart
module Wdt = Soc.Wdt
module Aic = Soc.Aic
module Pmgr = Soc.Pmgr
module Pmgr_adt = Soc.Pmgr_adt
module Gpu_adt = Soc.Gpu_adt
module Adt = Adt
module Dart = Soc.Dart
module Pcie = Soc.Pcie
module Sart = Soc.Sart
module Ans = Nvme.Ans
module Loopback = Boot.Loopback
module M1n1_image = Boot.M1n1_image
module Payload = Boot.Payload
module Client = Boot.Client
module Probe = Boot.Probe
module Live = Boot.Live
module Gpu_probe = Boot.Gpu_probe
module Agx = Agx
module Fw = Fw

val machine : string
