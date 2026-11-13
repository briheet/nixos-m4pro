# The installer on the RAM image (nixos/ram.nix): puts NixOS on the J614s's
# internal SSD, in the free space macOS leaves after its APFS container is
# shrunk (`diskutil apfs resizeContainer disk0s2 <size>` in macOS).
#
#   m4pro-install partition   create p4 nixos-boot (512 MiB, ESP type) and
#                             p5 nixos (the rest) in the largest free block
#   m4pro-install format      FAT32 on nixos-boot, ext4 on nixos
#   m4pro-install system      nixos-install the system built into this image
#
# Each step checks what it expects and stops otherwise; nothing is guessed
# or repaired. `partition` and `format` refuse to touch a disk that already
# has the NixOS partitions or filesystems; `system` installs a new
# generation and is also how the installed system is updated.
{ writeShellApplication, gptfdisk, e2fsprogs, dosfstools, util-linux, coreutils, gnugrep, systemd, nixos-install, diskSystem }:

writeShellApplication {
  name = "m4pro-install";
  runtimeInputs = [ gptfdisk e2fsprogs dosfstools util-linux coreutils gnugrep systemd nixos-install ];
  text = ''
    disk=/dev/nvme0n1
    boot=/dev/disk/by-partlabel/nixos-boot
    root=/dev/disk/by-partlabel/nixos
    system=${diskSystem}

    die() { echo "m4pro-install: $*" >&2; exit 1; }

    # The macOS layout: iBoot system container, the APFS container, and
    # recoveryOS, by GPT type code.
    check_apple_layout() {
      local table
      table=$(sgdisk -p "$disk")
      for want in "1 AF0B" "2 AF0A" "3 AF0C"; do
        echo "$table" | grep -Eq "^ +''${want% *} .* ''${want#* } " ||
          die "partition ''${want% *} is not type ''${want#* }; this is not the expected macOS layout"
      done
    }

    partition() {
      [ -b "$disk" ] || die "$disk not found"
      check_apple_layout
      [ ! -e "$boot" ] && [ ! -e "$root" ] || die "nixos partitions already exist; not repartitioning"
      sgdisk -p "$disk" | grep -Eq '^ +[4-9] ' && die "partitions beyond 3 exist; expected only the macOS ones"

      local ss first last sectors
      ss=$(blockdev --getss "$disk")
      first=$(sgdisk -a $((1048576 / ss)) -F "$disk")
      last=$(sgdisk -E "$disk")
      sectors=$((last - first + 1))
      [ $((sectors * ss)) -ge $((32 * 1024 * 1024 * 1024)) ] ||
        die "largest free block is $((sectors * ss / 1048576)) MiB; shrink the macOS container first"
      local p2end p3start
      p2end=$(sgdisk -i 2 "$disk" | grep '^Last sector' | grep -Eo '[0-9]+' | head -n 1)
      p3start=$(sgdisk -i 3 "$disk" | grep '^First sector' | grep -Eo '[0-9]+' | head -n 1)
      [ "$first" -gt "$p2end" ] && [ "$last" -lt "$p3start" ] ||
        die "the free block ($first-$last) is not between the macOS container and recoveryOS"

      sgdisk -b /root/gpt-before.bin "$disk" >/dev/null
      echo "GPT saved to /root/gpt-before.bin: $(sha256sum /root/gpt-before.bin | cut -d' ' -f1)"

      local bootend=$((first + 536870912 / ss - 1))
      sgdisk -n "4:$first:$bootend" -t 4:ef00 -c 4:nixos-boot \
             -n "5:$((bootend + 1)):$last" -t 5:8300 -c 5:nixos "$disk"
      sgdisk -v "$disk" | grep -q "No problems found" || die "sgdisk -v reports problems"
      blockdev --rereadpt "$disk"
      udevadm settle
      [ -e "$boot" ] && [ -e "$root" ] || die "new partitions did not appear"
      sgdisk -p "$disk"
    }

    format() {
      [ -e "$boot" ] && [ -e "$root" ] || die "no nixos partitions; run partition first"
      for p in "$boot" "$root"; do
        [ -z "$(blkid -o value -s TYPE "$p" || true)" ] || die "$p already has a filesystem; not formatting"
      done
      mkfs.vfat -F 32 -n NIXBOOT "$boot"
      mkfs.ext4 -q -L nixos "$root"
      blkid "$boot" "$root"
    }

    system() {
      [ "$(blkid -o value -s TYPE "$boot")" = vfat ] || die "$boot is not FAT"
      [ "$(blkid -o value -s TYPE "$root")" = ext4 ] || die "$root is not ext4"
      mountpoint -q /mnt && die "/mnt is already mounted"
      mkdir -p /mnt
      mount "$root" /mnt
      mkdir -p /mnt/boot
      mount -o fmask=0077,dmask=0077 "$boot" /mnt/boot
      trap 'umount -R /mnt' EXIT
      nixos-install --system "$system" --no-root-passwd --no-channel-copy
      echo "installed $system"
    }

    case "''${1:-}" in
      partition) partition ;;
      format) format ;;
      system) system ;;
      *) echo "usage: m4pro-install partition|format|system" >&2; exit 2 ;;
    esac
  '';
}
