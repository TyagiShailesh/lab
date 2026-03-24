#!/bin/bash
# Builds a generic Ubuntu 24.04 minimal rootfs tarball.
# Hardware-specific config (netplan, samba, bcachefs service, etc.) is done post-install.
# Always use the latest release URL — it points to the most recent build.
set -euo pipefail

src="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz"
rootfs="ubuntu-24.04-amd64"

build=$(mktemp -d)

cleanup() {
  umount "$build"/dev/pts 2>/dev/null || true
  umount "$build"/dev      2>/dev/null || true
  umount "$build"/proc     2>/dev/null || true
  umount "$build"/sys      2>/dev/null || true
  rm -rf "$build"
}
trap cleanup EXIT

echo "Downloading and extracting base image"
wget -O- "$src" | tar -xJpf - -C "$build"

rm -f "$build"/etc/resolv.conf
cp /etc/resolv.conf "$build"/etc/resolv.conf

mount -t proc   none "$build/proc"
mount -t sysfs  none "$build/sys"
mount -o bind /dev "$build/dev"
mount -t devpts none "$build/dev/pts"

chroot "$build" /bin/bash -e << 'EOF'
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Prevent services from starting during installation
echo 'exit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update && apt-get install -y --no-install-recommends \
  systemd-sysv openssh-server chrony \
  iputils-ping tcpdump mtr vim \
  lshw lm-sensors nvme-cli smartmontools \
  xfsprogs efibootmgr \
  samba avahi-daemon wireguard-tools \
  rsync zstd unzip htop iotop lsof strace tree jq \
  cpufrequtils irqbalance fio \
  python3 python3-pip

apt-get autoremove --purge cloud-init snapd -y
rm -rf /var/lib/snapd /var/cache/snapd
rm -rf /var/lib/apt/lists/*
apt-get clean

# SSH — pubkey only, no password login
ssh-keygen -A
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys << 'SSH'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGkBsm4JVpJHIgXwg8Ccb/IjGIJwFwcRVstVPkly4R8 st@tlkn.com
SSH
chmod 600 /root/.ssh/authorized_keys

# User: st (samba/file ownership)
useradd -m -s /bin/bash st
usermod -aG users st

# bcachefs module autoload
mkdir -p /etc/modules-load.d
echo "bcachefs" > /etc/modules-load.d/bcachefs.conf

# CPU performance governor service
cat > /etc/systemd/system/cpu-performance.service << 'SVC'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

# Services
systemctl enable chrony
systemctl enable irqbalance
systemctl enable avahi-daemon
systemctl enable smbd
systemctl enable cpu-performance
systemctl enable fstrim.timer

# Sysctl — tuned for high-bandwidth NAS workloads
cat > /etc/sysctl.d/99-lab.conf << 'SYSCTL'
# Network — BBR congestion control (requires CONFIG_TCP_CONG_BBR=y in kernel)
net.core.somaxconn = 262144
net.core.netdev_max_backlog = 30000
net.core.rmem_default = 262144
net.core.rmem_max = 268435456
net.core.wmem_default = 262144
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 262144 268435456
net.ipv4.tcp_wmem = 4096 262144 268435456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Memory — NAS workload (large file I/O)
vm.swappiness = 1
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 12000
vm.dirty_writeback_centisecs = 1200
vm.vfs_cache_pressure = 50

# File limits
fs.file-max = 2097152
fs.nr_open = 2097152
SYSCTL

# I/O scheduler — mq-deadline for rotational, none for NVMe
mkdir -p /etc/udev/rules.d
cat > /etc/udev/rules.d/60-ioscheduler.rules << 'UDEV'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
UDEV

rm -rf /etc/resolv.conf
rm -f /usr/sbin/policy-rc.d

:> /etc/fstab
EOF

# Unmount virtual filesystems (but keep $build for tarball)
umount "$build"/dev/pts 2>/dev/null || true
umount "$build"/dev      2>/dev/null || true
umount "$build"/proc     2>/dev/null || true
umount "$build"/sys      2>/dev/null || true

echo "Creating compressed tarball"
mkdir -p "images"
rm -f "images/${rootfs}.tar.zst"
(cd "$build" && tar -I 'zstd -6 --threads=0' -Scf "$OLDPWD/images/${rootfs}.tar.zst" *)
du -sh "images/${rootfs}.tar.zst"
echo "Rootfs ready: images/${rootfs}.tar.zst"
# EXIT trap handles rm -rf "$build"
