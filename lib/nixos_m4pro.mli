(** Host-side drivers for a Mac16,8 (J614s, T6040).

    [Proto] speaks the m1n1 UART proxy. [Soc] is the UART, the watchdog,
    the AIC, PMGR, DART, PCIe, and SART. [Nvme] is the ANS coprocessor.
    [Boot] is the loopback peer, the payload scanner, and [Client.run].
    Each module below is the one from that layer. *)

module Proxy = Proto.Proxy
module Wire = Proto.Wire
module Uart = Soc.Uart
module Wdt = Soc.Wdt
module Aic = Soc.Aic
module Pmgr = Soc.Pmgr
module Dart = Soc.Dart
module Pcie = Soc.Pcie
module Sart = Soc.Sart
module Ans = Nvme.Ans
module Loopback = Boot.Loopback
module M1n1_image = Boot.M1n1_image
module Payload = Boot.Payload
module Client = Boot.Client

val machine : string
