# Network

LAN bridge, Thunderbolt networking, and WireGuard VPN.

```
eno1 (Marvell AQtion 10GbE) ─┐
                             ├─ br0 (192.168.1.10/24, MTU 9000, STP off)
eno2 (Intel 2.5GbE)         ─┤
thunderbolt0 (TB5 via port) ─┘

wg0 (10.0.0.1/30, UDP 51820)
```

Static IP, jumbo frames, no DHCP. Bridge managed by netplan → systemd-networkd. Thunderbolt hardware details: [thunderbolt.md](thunderbolt.md).

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

## Verify

```bash
ip addr show br0
iperf3 -s &                 # test from Mac: iperf3 -c lab.local
wg show
```
