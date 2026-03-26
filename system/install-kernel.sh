#!/usr/bin/env bash
set -euo pipefail

[ $# -ge 1 ] || { echo "Usage: $0 <kernel-tarball> [disk]"; exit 1; }

kernel="$1"

# Find boot disk by root PARTUUID (stable across NVMe reordering)
ROOT_PARTUUID="204dd2f7-381a-47a8-bc8d-c2dff520e914"
root_part=$(blkid -t PARTUUID="$ROOT_PARTUUID" -o device 2>/dev/null) \
  || { echo "FATAL: cannot find root partition by PARTUUID=$ROOT_PARTUUID"; exit 1; }
disk=${root_part%p[0-9]*}  # strip partition suffix (e.g. /dev/nvme1n1p2 → /dev/nvme1n1)
p=${disk}$([[ "$disk" =~ nvme ]] && echo p || echo "")

echo "Root partition: $root_part (disk: $disk)"
mount ${p}2 /mnt
mkdir -p /mnt/boot/efi
mount ${p}1 /mnt/boot/efi

# Extract new kernel (do NOT delete old modules/kernels — keep for rollback)
zstd -dc "$kernel" | tar -xpf - -C /mnt

# Derive kernel filename from tarball (e.g., linux-6.19.6)
kname=$(basename "$kernel" .tar.zst)
kver=${kname#linux-}

# --- Verify bcachefs.ko exists ---
if ! ls /mnt/usr/lib/modules/"$kver"/kernel/fs/bcachefs/bcachefs.ko >/dev/null 2>&1; then
  echo "FATAL: bcachefs.ko missing from tarball for kernel $kver"
  umount -R /mnt
  exit 1
fi

# --- Run depmod as safety net ---
depmod -b /mnt/usr -a "$kver" 2>/dev/null || depmod -b /mnt -a "$kver" 2>/dev/null || true

# --- Copy kernel to EFI partition (keep old kernels for rollback) ---
cp /mnt/boot/"$kname" /mnt/boot/efi/

# --- EFI boot entry ---
efi_label="Linux $kver"

# Remove existing entry with same label if re-installing
existing=$(efibootmgr | awk -v label="$efi_label" '$0 ~ label {print substr($1,5,4);exit}')
[ -n "$existing" ] && efibootmgr -b "$existing" -B

efibootmgr -c -d "$disk" -p 1 -L "$efi_label" \
  -l "\\$kname" \
  --unicode "root=PARTUUID=204dd2f7-381a-47a8-bc8d-c2dff520e914 rw"

# Set new kernel as next boot (preserves existing boot order)
new=$(efibootmgr | awk -v label="$efi_label" '$0 ~ label {print substr($1,5,4);exit}')
if [ -n "$new" ]; then
  # Prepend new entry to existing boot order
  current=$(efibootmgr | awk -F: '/^BootOrder/{gsub(/ /,"",$2); print $2}')
  other=$(echo "$current" | sed "s/$new,//;s/,$new//;s/$new//")
  [ -n "$other" ] && efibootmgr -o "$new,$other" || efibootmgr -o "$new"
fi

# --- modules-load.d: ensure bcachefs loads at boot ---
mkdir -p /mnt/etc/modules-load.d
echo "bcachefs" > /mnt/etc/modules-load.d/bcachefs.conf

echo ""
echo "=== Installation summary ==="
echo "Kernel:  $kname installed to EFI partition"
echo "Modules: /usr/lib/modules/$kver/ (including bcachefs.ko)"
echo "Tools:   /usr/local/sbin/bcachefs (updated)"
echo "Boot:    EFI entry '$efi_label' created and set as default"
echo ""
echo "Old kernels are preserved on EFI partition for rollback."
echo "Select from UEFI boot menu if needed."
echo ""
efibootmgr | grep -E "Boot[0-9]"

umount -R /mnt
