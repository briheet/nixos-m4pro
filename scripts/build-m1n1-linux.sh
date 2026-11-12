#!/bin/bash
# Build j614s.dtb, Image.gz, a BusyBox initramfs, and m1n1-linux.bin.
# Run this inside the nixos-m4pro-m1n1 container. See README.md.
# Kernel objects go to OUT so the Linux source tree stays clean.
set -euo pipefail

SRC="${LINUX_SRC:-/src}"
OUT="${OUT:-/out}"
M1N1_BIN="${M1N1_BIN:-/m1n1/m1n1.bin}"
JOBS="$(nproc)"

apt-get update
apt-get install -y --no-install-recommends \
  bc bison flex libssl-dev libelf-dev cpio gzip busybox-static

test -f "$M1N1_BIN"
test -d "$SRC/arch/arm64/boot/dts/apple"

cd "$SRC"
make ARCH=arm64 O="$OUT" defconfig
make ARCH=arm64 O="$OUT" -j"$JOBS" Image.gz

DTS=arch/arm64/boot/dts/apple/t6040-j614s.dts
cpp -nostdinc -D__DTS__ -I include -I arch/arm64/boot/dts/apple \
  -undef -x assembler-with-cpp \
  "$DTS" | dtc -I dts -O dtb -o "$OUT/j614s.dtb" -

rm -rf "$OUT/initramfs"
mkdir -p "$OUT/initramfs/bin" "$OUT/initramfs/proc" "$OUT/initramfs/sys"
cat > "$OUT/initramfs/init" << 'EOF'
#!/bin/sh
export PATH=/bin
mkdir -p /proc /sys
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo
echo nixos-m4pro
printf 'model  '
cat /proc/device-tree/model
echo
printf 'kernel '
uname -a
echo
printf 'cpus   '
nproc
echo
grep MemTotal /proc/meminfo
echo
exec setsid cttyhack /bin/sh
EOF
chmod 755 "$OUT/initramfs/init"
cp /bin/busybox "$OUT/initramfs/bin/busybox"
for applet in sh mount mkdir cat uname nproc grep setsid cttyhack; do
  ln -s busybox "$OUT/initramfs/bin/$applet"
done
(
  cd "$OUT/initramfs"
  find . -print0 | cpio --null -ov --format=newc | gzip -n > "$OUT/initramfs.cpio.gz"
)

IMAGE="$OUT/arch/arm64/boot/Image.gz"
test -f "$IMAGE"
test -f "$OUT/j614s.dtb"
cp "$IMAGE" "$OUT/Image.gz"

{
  cat "$M1N1_BIN"
  printf 'chosen.bootargs=earlycon console=ttySAC0,115200 debug rw\n'
  cat "$OUT/j614s.dtb"
  cat "$OUT/initramfs.cpio.gz"
  cat "$OUT/Image.gz"
} > "$OUT/m1n1-linux.bin"

ls -lh "$OUT/j614s.dtb" "$OUT/Image.gz" "$OUT/initramfs.cpio.gz" "$OUT/m1n1-linux.bin"
echo BUILD_OK
