(** RTKit management messages from upstream/m1n1/src/rtkit.c.

    [Ans] includes this module. Callers keep using the [Ans] names.
    A live ANS sends its own bitmap. The stand-in words are for the loopback. *)

val mgmt_type_shift : int
val mgmt_iop_pwr : int
val power_init : int
val power_on : int
val ep_mgmt : int
val min_version : int
val max_version : int
val msg_hello : int
val msg_hello_ack : int
val msg_start_ep : int
val msg_iop_pwr_ack : int
val msg_epmap : int
val msg_ap_pwr : int
val ep_crashlog : int
val ep_syslog : int
val ep_debug : int
val ep_ioreport : int
val ep_oslog : int
val epmap_done : int64
val start_ep_flag : int64
val msg_buffer : int
val msg_syslog_log : int
val iova_mask : int64
val wakeup_msg0 : int64
val type_of : int64 -> int
val field : int64 -> int -> int64 -> int
val hello_msg0 : min_ver:int -> max_ver:int -> int64
val standin_hello : int64
val standin_epmap_lo : int64
val standin_epmap_hi : int64
val iop_power_ack : int64
val hello_ack_msg0 : int -> int64
val epmap_reply_msg0 : base:int -> done_:bool -> int64
val start_ep_msg0 : int -> int64
val ap_power_msg0 : int64
val pages_of : int64 -> int
val iova_of : int64 -> int64
val buffer_msg0 : pages:int -> iova:int64 -> int64
