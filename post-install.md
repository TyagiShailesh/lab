# Post-Install

After installing rootfs (`kernel/install-rootfs.sh`) and kernel (`kernel/install-kernel.sh`), apply these steps to configure the system. The rootfs is generic — everything below is hardware/environment-specific.

Topic docs this runbook relies on:

- [bcachefs.md](bcachefs.md) — pool architecture; [migrate-bcachefs.md](migrate-bcachefs.md) for the one-time transition.
- [network.md](network.md) — netplan bridge, Thunderbolt tuning service, WireGuard, sysctl.
- [postgres.md](postgres.md) — PostgreSQL 18 + backup cron.
- [gpu.md](gpu.md) — NVIDIA driver + GDS.
- [thunderbolt.md](thunderbolt.md) — TB networking details.

---

## 1. Hostname

```bash
echo "lab" > /etc/hostname
```

## 2. Network

Netplan bridge (`br0`), Thunderbolt tuning service, WireGuard, sysctl — full configs in [network.md](network.md).

## 3. Samba

Install `samba` + `samba-vfs-modules` (the base `samba` package on Ubuntu 24.04 **does not** pull in the VFS plugins; without `streams_xattr.so` every share mount fails silently with `NT_STATUS_LOGON_FAILURE` / "original item … can't be found" from Finder).

```bash
apt install -y samba samba-vfs-modules
```

```bash
cat > /etc/samba/smb.conf << 'EOF'
[global]
   netbios name = nas
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
   path = /nas/media
   valid users = st
   force user = st
   read only = no
   create mask = 0644
   directory mask = 0755
   inherit permissions = no

[st]
   path = /nas/st
   valid users = st
   force user = st
   read only = no
   create mask = 0600
   directory mask = 0700
   inherit permissions = no

[tm]
   path = /nas/tm
   valid users = st
   read only = no
   vfs objects = catia fruit streams_xattr
   fruit:time machine = yes
   fruit:time machine max size = 4000G

[data]
   path = /nas/data
   valid users = st
   force user = st
   read only = no
   create mask = 0600
   directory mask = 0700
   inherit permissions = no

[iris]
   path = /var/iris
   valid users = st
   force user = st
   force group = iris
   read only = no
   create mask = 0660
   directory mask = 2770
   inherit permissions = no
EOF

# Set samba password for st user
smbpasswd -a st

systemctl restart smbd
```

## 4. bcachefs storage pool

Full architecture, per-device policy, and reasoning: [bcachefs.md](bcachefs.md).
One-time migration from the legacy single-SSD layout: [migrate-bcachefs.md](migrate-bcachefs.md).

Steady-state unit (by-id, all four members):

```bash
cat > /etc/systemd/system/nas.service << 'EOF'
[Unit]
Description=NAS storage pool
# Wants= (not Requires=) so a missing disk doesn't block boot
After=systemd-modules-load.service

[Service]
ExecStartPre=/sbin/modprobe bcachefs
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount -t bcachefs \
  /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB:\
/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZLW212GF:\
/dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813:\
/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_2TB_S7KHNU0Y517886B \
  -o version_upgrade=none /nas
ExecStop=/usr/bin/umount /nas

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now nas

# Share directories on the pool
mkdir -p /nas/media /nas/st /nas/data /nas/tm /nas/models
chown st:st /nas/media /nas/st /nas/data /nas/tm /nas/models

# iris service user + /var/iris (on boot SSD, not bcachefs)
useradd -r -s /usr/sbin/nologin -G video,render iris
gpasswd -a st iris                              # st needs iris group for SMB share
install -d -m 2770 -o iris -g iris /var/iris    # setgid so new files inherit iris group
```

### bcachefs filesystem options (verify after any policy change)

Expected on a correctly-configured pool:

- `data_replicas=2`, `metadata_replicas=2`
- `foreground_target=ssd`, `background_target=hdd`, `promote_target=ssd`, `metadata_target=hdd`
- `compression=none`, `background_compression=zstd`
- HDDs: `durability=1`, `data_allowed=btree,user`
- SSDs: `durability=1`, `data_allowed=journal,user`

Verification commands: [bcachefs.md §10](bcachefs.md#10-verify-the-running-config-matches-this-doc).

## 5. I/O scheduler

```bash
cat > /etc/udev/rules.d/60-ioscheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
EOF

udevadm trigger
```

## 6. NVMe tuning (Samsung 9100 Pro)

Kernel cmdline already sets `iommu=pt` (identity-mapped DMA, removes 128 KB transfer cap) and `nvme.poll_queues=4` (polled I/O for Gen5 NVMe). Additional runtime settings applied by udev:

```bash
cat > /etc/udev/rules.d/61-nvme-perf.rules << 'EOF'
# Samsung 9100 Pro: strict CPU completion affinity + interrupt coalescing
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/rq_affinity}="2"
EOF

udevadm trigger
```

Interrupt coalescing (50 µs aggregation, threshold 10) — run once:

```bash
nvme set-feature /dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T -f 0x08 -v 0x320a
```

Verify with fio (should match Samsung's rated 14,700 MB/s):

```bash
fio --name=seqread --filename=/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T \
  --ioengine=io_uring --direct=1 --bs=128k --iodepth=32 --numjobs=1 --rw=read \
  --runtime=30 --time_based --group_reporting
```

## 7. PostgreSQL

See [postgres.md](postgres.md).

## 8. Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

## 9. Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy.list
apt update && apt install -y caddy
systemctl enable --now caddy
```

## 10. Path symlinks (Mac path matching)

Mac DaVinci Resolve sees Samba mounts at `/Volumes/...`; mirror those paths locally so project references resolve on both sides:

```bash
mkdir -p /Volumes
ln -sf /nas/media /Volumes/media
ln -sf /nas/st /Volumes/st
```

## 11. Verify

```bash
# Storage
bcachefs fs usage -h /nas
# Per-device options — see bcachefs.md §10 for the full checklist

# Network
ip addr show br0
iperf3 -s &  # then test from Mac

# Services
systemctl status nas smbd postgresql avahi-daemon wg-quick@wg0 cpu-performance thunderbolt-tune caddy ollama

# Samba
smbclient -L //localhost -U st

# PostgreSQL
sudo -u postgres psql -c "\l"
```
