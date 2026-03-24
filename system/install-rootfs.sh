#!/usr/bin/env bash
# Usage: ./install-rootfs.sh <rootfs-archive> <disk>
set -e

[ $# -eq 2 ] || { echo "Usage: $0 <rootfs-archive> <disk>"; exit 1; }

rootfs="$1"
disk="$2"

echo "WARNING: Will wipe $disk. Continue? (y/N)"
read -r confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit

umount ${disk}* 2>/dev/null || true
parted -s "$disk" mklabel gpt \
  mkpart ESP fat32 1MiB 1025MiB set 1 esp on \
  mkpart root 1025MiB 100%

p=${disk}$([[ "$disk" =~ nvme ]] && echo p || echo "")
mkfs.vfat -F32 ${p}1
mkfs.xfs ${p}2

mount ${p}2 /mnt
mkdir -p /mnt/boot/efi
mount ${p}1 /mnt/boot/efi

zstd -dc "$rootfs" | tar -xpf - -C /mnt

# Write fstab with EFI partition
echo "${p}1 /boot/efi vfat defaults 0 0" > /mnt/etc/fstab

umount -R /mnt
echo "Rootfs installed to $disk"
