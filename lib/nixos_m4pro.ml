(* Host tools for this M4 Pro. m1n1 stays in upstream/m1n1 and is driven
   from here, so an upstream update is a submodule bump rather than a rebase.

   proto is the UART proxy. soc is the blocks before the disk. nvme is ANS.
   boot is the loopback, the payload scanner, and the client sequence.
   The aliases below are the names bin/ and test/ already use. *)

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

let machine = Client.machine
