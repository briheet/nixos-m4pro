# ANS (the SSD coprocessor) mailbox only: its RTKit management and system
# endpoint messages, e.g. the power-state changes at shutdown. Unlike m1n1's
# hv/trace_nvme.py this does not trace the NVMe registers, so disk I/O does
# not trap to the host. Run with run_guest.py -m (with tools/hv/trace_pmp.py).
from m1n1.trace.asc import ASCTracer

ASCTracer = ASCTracer._reloadcls()
ans_tracer = ASCTracer(hv, "/arm-io/ans", verbose=1)
ans_tracer.start()
