# Kernel patches (aurora base)

Applied in name order on top of the `linux` flake input
(aurora-silicon/linux, branch integration/aurora), which already supports
the J614s. Only what aurora lacks is here:

- 0001: stop an MTP session adopted from U-Boot at shutdown (else iBoot
  panics on some reboots).

The Asahi-era patch set (34 patches, Linux 7.2.15) and its config are kept
in kernel/asahi/ for reference.
