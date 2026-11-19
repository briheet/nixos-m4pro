# make-stage1 M1N1_BIN ESP_PARTUUID OUT
#
# m1n1 stage 1 for the macostest volume: the release m1n1 with the config
# lines the Asahi installer appends (asahi-installer src/m1n1.py), which
# chainload stage 2 from the ESP. Used by the flake package m1n1-stage1 and
# by nixos/m1n1-boot.nix, which puts it on the ESP for recoveryOS.
set -eu
m1n1=$1 partuuid=$2 out=$3

cat "$m1n1" > "$out"
printf 'chainload=%s;m1n1/boot.bin\nchosen.asahi,efi-system-partition=%s\n' \
  "$partuuid" "$partuuid" >> "$out"
# Four NUL bytes end m1n1's payload list.
printf '\0\0\0\0' >> "$out"
# iBoot on T6040 panics (3bdace14b1a9a68:2081) on a boot object that is not
# a whole number of 16 KiB pages; m1n1 alone is, the config lines are not.
# Zero-pad; m1n1 stops at the terminator above.
size=$(stat -c %s "$out")
truncate -s $(( (size + 16383) / 16384 * 16384 )) "$out"
