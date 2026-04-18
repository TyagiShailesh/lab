# Hardware

## System specs

| Component | Detail |
|---|---|
| Motherboard | ASUS ProArt Z890-CREATOR WIFI (Rev 1.xx) |
| CPU | Intel Core Ultra 5 235 (Arrow Lake, 14C/14T, 3.6 GHz base / 4.8 GHz boost) |
| RAM | 64 GB DDR5-5600 (2× 32 GB Micron CP32G64C40U5B, slots A1+B1, 2 slots empty) |
| GPU | NVIDIA RTX PRO 2000 Blackwell (16 GB, PCIEX16_2) + Intel Arrow Lake iGPU |
| NPU | Intel Arrow Lake NPU |
| Network | Marvell AQtion 10GbE + Intel 2.5GbE, bridged as br0 (192.168.1.10/24) |
| Thunderbolt | 2× Thunderbolt 5 + 1× Thunderbolt 4 (USB Type-C) |
| WiFi | Wi-Fi 7 (802.11be) 2×2 + Bluetooth 5.4 |
| WireGuard | wg0 (10.0.0.1/30) |
| Kernel | 6.19.10 (PREEMPT_DYNAMIC) |
| OS | Ubuntu 24.04 (XFS root) |

## Slots and drives

| Slot | Drive | Model | Size | Role | Filesystem | Mount |
|---|---|---|---|---|---|---|
| M.2_1 (Gen5, CPU) | Samsung 9100 Pro | Samsung SSD 9100 PRO 1TB (S7YENJ0L200013T) | 1 TB | bcachefs SSD tier (label: ssd, `data_allowed=journal,user`) | bcachefs | `/store` |
| M.2_2 (Gen4, chipset) | Samsung 990 Pro | Samsung SSD 990 PRO 2TB (S7KHNU0Y517886B) | 2 TB | Boot | XFS (root) + vfat (EFI) | `/` + `/boot/efi` |
| M.2_3 (Gen4, chipset) | — | — | — | Empty | — | — |
| M.2_4 (Gen4, chipset) | WD Black SN850X | WD_BLACK SN850X HS 2000GB (24364L800813) | 2 TB | bcachefs SSD tier (label: ssd, `data_allowed=journal,user`) | bcachefs | `/store` |
| M.2_5 (Gen4, chipset) | — | — | — | Empty (shares BW with PCIe 4.0 x16) | — | — |
| SATA 0 | Seagate Exos | ST14000NM000J-2TX103 | 14 TB | bcachefs HDD tier (label: hdd, `data_allowed=btree,user`) | bcachefs | `/store` |
| SATA 1 | Seagate Exos | ST14000NM001G-2KJ103 | 14 TB | bcachefs HDD tier (label: hdd, `data_allowed=btree,user`) | bcachefs | `/store` |

Pool design and per-device rationale: [bcachefs.md](bcachefs.md).

## Expansion slots

| Slot | Type | Notes |
|---|---|---|
| PCIEX16_1 (CPU) | PCIe 5.0 x8 | Empty (x8/x8 split active when M.2_3 populated) |
| PCIEX16_2 (CPU) | PCIe 5.0 x8 | NVIDIA RTX PRO 2000 Blackwell (natively x8) |
| PCIEX16 (chipset) | PCIe 4.0 x16 | x4 mode, disabled if M.2_5 is used |

## BIOS

Current: **3002** (2026-01-30).
Firmware at `/store/data/asus/`.
User manual: `/store/data/asus/E27671_ProArt_Z890-CREATOR_WIFI_EM_V4_WEB.pdf`
