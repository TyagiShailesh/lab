# Network

LAN bridge, Thunderbolt networking, and WireGuard VPN.

```
eno1 (Marvell AQtion 10GbE) ─┐
                             ├─ br0 (192.168.1.10/24, MTU 9000, STP off)
eno2 (Intel 2.5GbE)         ─┤
thunderbolt0 (TB5 via port) ─┘

wg0 (10.0.0.1/30, UDP 51820)
```

Static IP, jumbo frames, no DHCP. Bridge managed by netplan → systemd-networkd. Thunderbolt hardware details and upstream work: [thunderbolt.md](thunderbolt.md), [thunderbolt-upstream.md](thunderbolt-upstream.md).

---

## Bridge (netplan)

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

---

## Thunderbolt tuning service

IRQ pinning, RPS, busy-poll. Persisted via systemd unit.

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

Settings applied:

```
IRQ pinning:  RX → P-core 0 (5 GHz), TX → P-core 1
RPS:          all 14 cores (3fff), 4096 flow entries
NAPI:         busy-poll (defer_hard_irqs=2, gro_flush_timeout=200000)
```

---

## WireGuard

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

---

## Sysctl network + memory tuning

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

# Memory — 64 GB RAM, NAS workload
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

Key settings: BBR congestion control, 256 MB socket buffers, `vm.swappiness=1`, `vm.dirty_ratio=5`, `vm.vfs_cache_pressure=50`. No swap.

---

## Verify

```bash
ip addr show br0
iperf3 -s &                 # test from Mac: iperf3 -c lab.local
wg show
sysctl net.ipv4.tcp_congestion_control   # should be bbr
```
