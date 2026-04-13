# Post-Install

After installing rootfs (`install-rootfs.sh`) and kernel (`install-kernel.sh`), apply these steps to configure the system. The rootfs is generic — everything below is hardware/environment-specific.

---

## 1. Hostname

```bash
echo "lab" > /etc/hostname
```

## 2. Network — bridge with static IP

```bash
cat > /etc/netplan/00-en.yaml << 'EOF'
network:
  version: 2
  renderer: networkd

  ethernets:
    eno1:
      dhcp4: no
      mtu: 9000
      optional: true
    eno2:
      dhcp4: no
      mtu: 9000
      optional: true
    thunderbolt0:
      dhcp4: no
      mtu: 9000
      optional: true

  bridges:
    br0:
      interfaces: [eno1, eno2, thunderbolt0]
      mtu: 9000
      dhcp4: no
      addresses:
        - 192.168.1.10/24
      routes:
        - to: 0.0.0.0/0
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
      parameters:
        stp: false
        forward-delay: 4
EOF
netplan apply
```

## 3. Samba

```bash
cat > /etc/samba/smb.conf << 'EOF'
[global]
   workgroup = WORKGROUP
   server role = standalone server
   disable netbios = yes
   server min protocol = SMB3
   server max protocol = SMB3_11
   security = user
   map to guest = never
   log file = /var/log/samba/log.%m
   max log size = 1000
   load printers = no
   printcap name = /dev/null
   server signing = auto
   ea support = yes
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:resource = stream
   fruit:locking = none
   fruit:delete_empty_adfiles = yes
   fruit:posix_rename = yes
   fruit:aapl = yes
   unix charset = UTF-8
   dos charset = CP437

[media]
   path = /store/media
   valid users = st
   force user = st
   read only = no
   create mask = 0644
   directory mask = 0755
   inherit permissions = no

[st]
   path = /store/st
   valid users = st
   force user = st
   read only = no
   create mask = 0600
   directory mask = 0700
   inherit permissions = no

[tm]
   path = /store/tm
   valid users = st
   read only = no
   vfs objects = catia fruit streams_xattr
   fruit:time machine = yes
   fruit:time machine max size = 4000G

[data]
   path = /store/data
   valid users = st
   force user = st
   read only = no
   create mask = 0600
   directory mask = 0700
   inherit permissions = no

[iris]
   path = /cache/iris
   valid users = st
   force user = st
   read only = no
   create mask = 0600
   directory mask = 0700
   inherit permissions = no
EOF

# Set samba password for st user
smbpasswd -a st

systemctl restart smbd
```

## 4. bcachefs storage pool

The pool already exists on disk — just needs the mount service and share directories.

```bash
# Service is created by build-rootfs.sh, but verify:
cat > /etc/systemd/system/bcachefs-store.service << 'EOF'
[Unit]
Description=Mount BcacheFS storage pool
Requires=dev-nvme1n1.device dev-sda.device dev-sdb.device systemd-modules-load.service
After=dev-nvme1n1.device dev-sda.device dev-sdb.device systemd-modules-load.service

[Service]
ExecStartPre=/sbin/modprobe bcachefs
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/sh -c 'mount -t bcachefs /dev/nvme1n1:/dev/sda:/dev/sdb -o version_upgrade=none /store'
ExecStop=/usr/bin/umount /store

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now bcachefs-store

# Share directories (these exist on the bcachefs pool, not root)
mkdir -p /store/media /store/st /store/data /store/tm
chown st:st /store/media /store/st /store/data /store/tm

# Iris lives on /cache and is written by the root-run iris service.
mkdir -p /cache/iris
chgrp -R st /cache/iris
chmod -R g+rwX,o-rwx /cache/iris
find /cache/iris -type d -exec chmod g+s {} +
```

### bcachefs tuning

```bash
# SSD durability 2 — writes ack at NVMe speed, background migration to HDD
echo 2 > /sys/fs/bcachefs/$(bcachefs show-super /dev/sda 2>/dev/null | grep "External UUID" | awk '{print $NF}')/dev-2/durability

# Foreground compression off, zstd on HDD migration only
bcachefs set-fs-option --compression=none /dev/sda
# background_compression=zstd should already be set from format
```

## 5. Thunderbolt tuning

```bash
cat > /etc/systemd/system/thunderbolt-tune.service << 'EOF'
[Unit]
Description=Thunderbolt network performance tuning
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'IRQ_RX=$(grep -l thunderbolt /proc/irq/*/actions 2>/dev/null | grep -oP "\d+" | tail -1); IRQ_TX=$(grep -l thunderbolt /proc/irq/*/actions 2>/dev/null | grep -oP "\d+" | tail -2 | head -1); [ -n "$IRQ_RX" ] && echo 0 > /proc/irq/$IRQ_RX/smp_affinity_list; [ -n "$IRQ_TX" ] && echo 1 > /proc/irq/$IRQ_TX/smp_affinity_list'
ExecStart=/bin/sh -c 'echo 3fff > /sys/class/net/thunderbolt0/queues/rx-0/rps_cpus 2>/dev/null; echo 4096 > /sys/class/net/thunderbolt0/queues/rx-0/rps_flow_cnt 2>/dev/null'
ExecStart=/bin/sh -c 'echo 2 > /sys/class/net/thunderbolt0/napi_defer_hard_irqs 2>/dev/null; echo 200000 > /sys/class/net/thunderbolt0/gro_flush_timeout 2>/dev/null'

[Install]
WantedBy=multi-user.target
EOF

systemctl enable thunderbolt-tune
```

## 6. Sysctl tuning

```bash
cat > /etc/sysctl.d/99-lab.conf << 'EOF'
# Network — BBR, 256MB socket buffers
net.core.somaxconn = 262144
net.ipv4.tcp_max_syn_backlog = 262144
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
net.ipv4.ip_forward = 1

# Memory — 64GB RAM, NAS workload
vm.swappiness = 1
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.dirty_expire_centisecs = 12000
vm.dirty_writeback_centisecs = 1200
vm.vfs_cache_pressure = 50

# File limits
fs.file-max = 2097152
fs.nr_open = 2097152

# Security
kernel.randomize_va_space = 2
kernel.kptr_restrict = 1
EOF

sysctl --system
```

## 7. I/O scheduler

```bash
cat > /etc/udev/rules.d/60-ioscheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
EOF

udevadm trigger
```

## 8. NVMe tuning (Samsung 9100 Pro)

Kernel cmdline already sets `iommu=pt` (identity-mapped DMA, removes 128KB transfer cap) and `nvme.poll_queues=4` (polled I/O for Gen5 NVMe). These additional runtime settings are applied by udev:

```bash
cat > /etc/udev/rules.d/61-nvme-perf.rules << 'EOF'
# Samsung 9100 Pro: strict CPU completion affinity + interrupt coalescing
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/rq_affinity}="2"
EOF

udevadm trigger
```

Interrupt coalescing (50us aggregation, threshold 10) — run once:

```bash
nvme set-feature /dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T -f 0x08 -v 0x320a
```

Verify with fio (should match Samsung's rated 14,700 MB/s):

```bash
fio --name=seqread --filename=/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T \
  --ioengine=io_uring --direct=1 --bs=128k --iodepth=32 --numjobs=1 --rw=read \
  --runtime=30 --time_based --group_reporting
```

## 9. WireGuard

```bash
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
PrivateKey = <GENERATE: wg genkey>
Address = 10.0.0.1/30
ListenPort = 51820

[Peer]
PublicKey = <PEER_PUBLIC_KEY>
AllowedIPs = 10.0.0.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
```

## 10. PostgreSQL 18

```bash
# Add PGDG repo
apt install -y curl ca-certificates
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt update && apt install -y postgresql-18

# Create resolve user and database
sudo -u postgres createuser -d resolve
sudo -u postgres createdb -O resolve nas

# Allow LAN access
echo "host all all 192.168.1.0/24 scram-sha-256" >> /etc/postgresql/18/main/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/18/main/postgresql.conf
systemctl restart postgresql

# Set resolve user password
sudo -u postgres psql -c "ALTER USER resolve PASSWORD '<password>';"
```

### PostgreSQL backup cron

```bash
cat > /etc/cron.d/postgres-backup << 'EOF'
# Nightly PostgreSQL backup (mirrored HDDs)
0 3 * * * postgres pg_dumpall -f /store/media/resolve/backup/resolve_latest.sql && cp /store/media/resolve/backup/resolve_latest.sql /store/media/resolve/backup/resolve_$(date +\%Y\%m\%d).sql
# Keep last 30 days
5 3 * * * postgres find /store/media/resolve/backup -name 'resolve_2*.sql' -mtime +30 -delete
EOF

mkdir -p /store/media/resolve/backup
chown postgres:postgres /store/media/resolve/backup
```

## 11. Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

## 12. Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy.list
apt update && apt install -y caddy
systemctl enable --now caddy
```

## 13. Path symlinks (for DaVinci Resolve path matching with Mac)

```bash
mkdir -p /Volumes
ln -sf /store/media /Volumes/media
ln -sf /store/st /Volumes/st
```

## 14. Verify

```bash
# Storage
bcachefs fs usage /store
cat /sys/fs/bcachefs/*/dev-2/durability   # should be 2

# Network
ip addr show br0
iperf3 -s &  # then test from Mac

# Services
systemctl status bcachefs-store smbd postgresql avahi-daemon wg-quick@wg0 cpu-performance thunderbolt-tune caddy ollama

# Samba
smbclient -L //localhost -U st

# PostgreSQL
sudo -u postgres psql -c "\l"
```
