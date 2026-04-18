# Thunderbolt-Net Upstream Plan

Working doc for a possible upstream contribution that ports the `ice` driver's
page_pool RX conversion onto `drivers/net/thunderbolt/`. Captures the analysis
and the plan so we can pick it back up.

Related: [thunderbolt.md](thunderbolt.md) — current driver state, measured performance, OOT patch
history.

## Problem

On the lab box (ProArt Z890, Arrow Lake, TB5 via discrete Barlow Ridge at
`87:00.0` on a CPU PCIe 4.0 x4 root port), TB5 RX tops out at ~20 Gbps with the
in-tree `thunderbolt_net`. TX hits ~41 Gbps with the OOT patch, RX ~30 Gbps
with the OOT patch. In-tree driver leaves ~10 Gbps on the table vs. the OOT
version, and ~10–20 Gbps is available before we hit the protocol wall.

Decomposition of the ceiling:

| Cause | Nature | Fixable? |
|---|---|---|
| Single TX/RX ring (USB4NET spec) | Wire protocol — macOS/Windows interop | **No** — breaks peers |
| Single NAPI core on RX | Consequence of single ring | **No** — same reason |
| Per-packet `dma_map_page`/`dma_unmap_page` | Driver design | **Yes** — page_pool |
| Manual skb alloc + header copy | Driver design | **Yes** — `build_skb` |
| Hardcoded `TBNET_RING_SIZE = 256` | Driver default | **Yes** — bump to 1024 |
| No XDP | Feature gap | Optional |

Hard ceiling after fixing everything fixable: **~40 Gbps RX** (single NAPI core
on a 5 GHz P-core). Realistic target: **~35 Gbps RX**.

## What the current mainline driver looks like (kernel 7.0, Apr 2026)

Note: Linus jumped 6.19 → 7.0 (released 2026-04-12) because he was running out
of fingers/toes, not because of architectural change. `drivers/net/thunderbolt/`
is unchanged vs. 6.19 from a data-path perspective. See
[Phoronix — Linux 7.0](https://www.phoronix.com/news/Linux-7.0-Changes).

Verified directly against
[drivers/net/thunderbolt/main.c](https://github.com/torvalds/linux/blob/master/drivers/net/thunderbolt/main.c):

- `TBNET_RING_SIZE = 256` — unchanged since 2017
- No `page_pool` — `dev_alloc_pages()` + manual `dma_map_page()`/`dma_unmap_page()` per packet
- Single TX ring, single RX ring, single NAPI poll
- No XDP, no `build_skb` fast path

[Commits to drivers/net/thunderbolt in 2025–2026](https://github.com/torvalds/linux/commits/master/drivers/net/thunderbolt)
have all been admin/correctness work — zero hot-path performance commits in 18 months:

| Date | Commit |
|---|---|
| 2026-01-19 | `net: thunderbolt: Allow reading link settings` |
| 2026-01-19 | `net: thunderbolt: Allow changing MAC address of the device` |
| 2025-07-02 | `net: thunderbolt: Enable end-to-end flow control also in transmit` |
| 2025-07-02 | parameter-passing fix for `tb_xdomain_*_paths()` |

## Why nobody has fixed it

Per [Phoronix — Intel Loses One Of Its USB4 / Thunderbolt Linux Driver Maintainers](https://www.phoronix.com/news/USB4-Thunderbolt-Maintainer):
Intel lost Mika as a paid maintainer. He kept maintaining it as
`westeri@kernel.org` (community capacity), but bandwidth goes to USB4 v2 /
Barlow Ridge bring-up, not the net data-path. No vendor-paid engineer owns
`thunderbolt_net` performance. The user base is tiny vs. `ice`/`mlx5`/`igc`,
so no commercial pressure.

The fix is architecturally trivial post-`ice`. It just needs someone with a
TB5 box and time — which is us.

## Reference implementation: the `ice` page_pool conversion

[PATCH iwl-next 0/3] ice: convert Rx path to Page Pool (Jul 2025) by Michal
Kubiak (Intel) — [archive](https://lists.openwall.net/netdev/2025/07/07/287).

Three patches:

1. Rip out the legacy RX path (no more hand-rolled skb + header copy → use `build_skb()`)
2. Drop page-splitting logic (accept 1 packet per 4K page; branchless hot path)
3. Wire up `page_pool` via `libeth` / `libeth_xdp`
   - `page_pool` keeps pages DMA-mapped once, recycles on free
   - `DMA_BIDIRECTIONAL` so same page can be used for RX and XDP_TX
   - Registers pool with XDP memory model via `xdp_reg_page_pool()`

Measured result: **>5× XDP_TX in IOMMU-on VMs**, flat otherwise (IOMMU map/unmap
was the bottleneck). For `thunderbolt_net` the win is different — no IOMMU in
the TB path normally, but we reclaim the allocator/copy overhead and the
cacheline-miss cost per packet.

Same antipatterns in `thunderbolt_net` today vs. `ice` before this patch:

| Issue | `ice` (pre-Jul 2025) | `thunderbolt_net` (7.0, today) |
|---|---|---|
| Per-packet `dma_map_page` | yes | **yes** |
| Manual skb alloc + copy | yes | **partially** — uses `build_skb()` already, but allocs order-1 pages per frame without recycling |
| Uses `page_pool` | no | **no** |
| `build_skb` fast path | no | **yes** (since 2017 v3 series) |
| XDP | no | **no** |

Correction from earlier draft: `thunderbolt_net` has used `build_skb()` since the
[2017 v3 series](https://lkml.iu.edu/hypermail/linux/kernel/1710.0/00406.html).
The win here is purely the **page_pool recycling path** — not adding
`build_skb`.

### Critical technical constraint: 4 KB boundary

The NHI (Native Host Interface) hardware **cannot cope with a frame crossing
a 4 KB boundary**. The driver allocates **order-1 (8 KB) pages** specifically
to guarantee alignment. Source:
[2017 thunderbolt_net v3 cover letter](https://lkml.iu.edu/hypermail/linux/kernel/1710.0/00406.html).

Any page_pool port MUST preserve this guarantee. Options:

1. Use page_pool with `PP_FLAG_DMA_MAP` + explicit order-1 page allocation.
2. Use page_pool fragments (`page_pool_alloc_frag`) sized to stay within 4 KB.
3. Hand-maintain a recycle ring on top of order-1 pages, bypassing page_pool.

Option 1 is cleanest for upstream. Reviewers will ask for commit-message
justification of the page order choice — this is the single biggest technical
review risk.

### Related precedents
- [Intel Wired LAN Driver Updates 2025-01-06](https://lists.openwall.net/netdev/2025/01/06/300) — igb/igc/ixgbe/i40e/fm10k batch
- [ice page_pool v1](https://lists.openwall.net/netdev/2025/07/07/287) hit a WARN in `libeth_rx_recycle_slow()` during review ([Jacob Keller report](https://www.mail-archive.com/intel-wired-lan@osuosl.org/msg11986.html)); needed [v2](https://www.mail-archive.com/intel-wired-lan@osuosl.org/msg12569.html) and [v3](https://www.mail-archive.com/intel-wired-lan@osuosl.org/msg13650.html) to merge. **Three spins minimum.**
- [bcmgenet RX page_pool v6, Apr 2026](https://lkml.org/lkml/2026/4/12/555) — at v6 when Jakub Kicinski gave nit review. **Five respins before his substantive comments.**

These numbers set expectations: even clean, well-tested page_pool conversions
go through 3–6 versions before landing.

## Prior art in this repo

OOT patched driver, removed in commit `b62fe82` — sources live in git history
under `system/thunderbolt_net/`. Restoration recipe is in [thunderbolt.md](thunderbolt.md).
That patch already proved the approach at ~30 Gbps RX but wasn't structured
for upstream.

## Target throughput

| Configuration | Expected RX |
|---|---|
| In-tree, kernel 7.0, current (measured) | ~20 Gbps |
| OOT patch (page_pool + ring=1024) (measured) | ~30 Gbps |
| + tuned GRO + busy-poll on 5 GHz P-core | ~33–35 Gbps |
| + jumbo MTU (if peer negotiates) | ~35–38 Gbps |
| Single-core NAPI ceiling (protocol wall) | ~40 Gbps |

## Who owns what upstream

Per
[MAINTAINERS](https://github.com/torvalds/linux/blob/master/MAINTAINERS):

**THUNDERBOLT NETWORK DRIVER** (status: Maintained)
- Mika Westerberg `<westeri@kernel.org>` — note `@kernel.org`, not `@intel.com`
- Yehezkel Bernat `<YehezkelShB@gmail.com>`
- List: `netdev@vger.kernel.org`
- Tree: `git://git.kernel.org/pub/scm/linux/kernel/git/westeri/thunderbolt.git`

**NETWORKING [GENERAL]** (netdev gatekeepers)
- David S. Miller `<davem@davemloft.net>`
- Eric Dumazet `<edumazet@google.com>`
- Jakub Kicinski `<kuba@kernel.org>`
- Paolo Abeni `<pabeni@redhat.com>`
- Simon Horman `<horms@kernel.org>` (reviewer)

Linus does **not** review this directly. Path to mainline:
`us → netdev list → Mika ack → Greg KH USB/Thunderbolt pull → Linus merge`.

## Approach to the kernel community

### Phase 0 — Prep (before posting anything)

1. Rebase the OOT patch from `git show b62fe82^:system/thunderbolt_net/*`
   onto current `net-next` (not `master`).
2. Read the ice series
   ([netdev, Jul 2025](https://lists.openwall.net/netdev/2025/07/07/287))
   end-to-end. Understand `libeth_xdp` helpers. Decide: use `libeth`
   directly, or keep thunderbolt_net standalone with bare `page_pool`?
   Recommendation: **standalone page_pool first**. `libeth` is an Intel
   Ethernet library; pulling it in for a USB4 driver may be rejected on
   scope grounds. Keep the patch tight and thunderbolt-local.
3. Read
   [Documentation/process/maintainer-netdev.rst](https://docs.kernel.org/process/maintainer-netdev.html)
   — netdev has specific rules about patch format, `net` vs `net-next`,
   resend cadence, etc.
4. Check that the fix doesn't regress the macOS/Windows peer path.
   `page_pool` is RX-side memory only; wire format is unchanged.
   Reconfirm by testing against a Mac peer before posting.

### Phase 1 — RFC

Post as `[RFC PATCH net-next 0/N]`:

- Subject line: `[RFC PATCH net-next 0/3] net: thunderbolt: convert Rx path to page_pool`
- Cover letter includes:
  - What the patch does (mirror ice's structure: remove legacy path, drop
    split logic if any, wire up page_pool)
  - **Before/after iperf3 numbers with CPU util** — this is non-negotiable
    for netdev. Post `perf top` output showing where time was going before.
  - Confirm no protocol change, confirm macOS peer interop preserved.
  - Note memory delta: `256 → 1024` entries × 4 KB = +3 MB per direction,
    trivially acceptable.
- `Cc:` Mika, Yehezkel, netdev maintainers, linux-usb.
- Tag as RFC so reviewers know it's open to restructuring.

### Phase 2 — Review cycles

Expected: **3–6 rounds over 3–6 months wall-clock** (revised up from
earlier estimate after checking ice and bcmgenet review histories).

Jakub's feedback style (from
[bcmgenet review](https://lkml.org/lkml/2026/4/12/555)) is nit-dense but
collaborative:

- "You can drop `__GFP_NOWARN`, page_pool adds it."
- "Use `XDP_PACKET_HEADROOM` directly, no need to wrap."
- Nit-level per patch, but with "more 'real' comments on later patches" —
  expect deeper structural comments on RX loop and error paths.

Keller-style hardware-test failure is the bigger risk — ice v1 hit a
`libeth_rx_recycle_slow()` WARN in testing. Expect reviewers to ask for
logs under load + hardware test reports before accepting.

Architectural review will come from Mika. Likely asks:
- Does the page_pool buffer still guarantee no 4 KB crossing? (the NHI
  hardware constraint — see above)
- Does it coexist cleanly with existing `tbnet_frame` struct?
- Does it break the flow-control path he added in 2022 (RX E2E) and 2025
  (TX E2E)?
- Does it work on the older pre-USB4 Thunderbolt hosts (Alpine Ridge, Titan
  Ridge) too, or just Barlow Ridge?

Note on Mika bandwidth: post-Intel he is community-only. Debian
[bug #1121032](http://www.mail-archive.com/debian-kernel@lists.debian.org/msg145931.html)
(`ndo_set_mac_address` breaking 802.3ad bonding, Nov 2025) had no visible
upstream fix months later — suggests backlog. Plan for slower ack cadence
than 2022-era Mika.

### Phase 3 — Merge

Once acked by Mika and reviewed-by netdev, the patch lands via Mika's tree
or directly via netdev. Included in Greg KH's USB/Thunderbolt pull or
netdev's pull to Linus.

### Realistic release target

Linux 7.0 released 2026-04-12. Current state (as of today, 2026-04-17):

| Version | Status | Our shot? |
|---|---|---|
| 7.0 | Released 2026-04-12 | Too late — merge window closed |
| 7.1 | Merge window open Apr 12–26; release ~mid-June 2026 | Too late — nothing posted; `net-next` closed during merge window |
| **7.2** | Merge window ~mid-June; release ~late August 2026 | **Target** |
| 7.3 | Merge window ~late August; release ~late October 2026 | Fallback |

Per
[maintainer-netdev.rst](https://docs.kernel.org/process/maintainer-netdev.html),
`net-next` is closed during merge windows and ~2 weeks before them. It reopens
~late April / early May 2026. That's when we post.

### Concrete schedule (revised)

Realistic target is **7.3 or 7.4**, not 7.2, once we account for 3–6
respins observed on comparable page_pool conversions.

1. **Now → early May 2026** — rebase OOT patch on `net-next`, benchmark
   against Mac peer, write cover letter with iperf3 numbers + `perf top`.
   Also: verify 4 KB boundary preservation path works with page_pool.
2. **Early May** (`net-next` reopens) — post **v1** RFC to
   `netdev@vger.kernel.org`, `Cc:` Mika, Yehezkel, linux-usb.
3. **May → August** — expected 3–6 review rounds.
4. **Mid-August 2026** — 7.3 merge window. Likely land here if all goes well.
5. **Late October 2026** — ships in Linux 7.3.
6. **Fallback: mid-October merge window → Linux 7.4 (~December 2026)** if
   review cycles stretch.

## Risk assessment (revised)

| Risk | Likelihood | Mitigation |
|---|---|---|
| 4 KB-crossing violation under page_pool | **High** — single biggest technical risk | Use `PP_FLAG_DMA_MAP` with explicit order-1 pages; document in commit msg |
| Hardware test failure on reviewer's rig (Keller-style WARN) | Medium | Test under iperf3 load + dd + concurrent workloads before v1 |
| Regresses E2E flow control (Mika's 2022+2025 patches) | Medium | Preserve the flow-control paths verbatim; call it out in cover letter |
| Mika ack slow (post-Intel bandwidth) | Medium | Ping after 2 weeks; cc linux-usb for co-visibility |
| Regresses older TB hosts (Alpine/Titan Ridge) | Low | Test on both, or gate by capability |
| Breaks macOS/Windows peer | Very low | RX-side only, wire unchanged; confirm by testing |
| Memory regression flagged | Very low | +3 MB per direction; justified by >50% throughput gain |
| Request to use `libeth` instead of bare page_pool | Medium | Prep answer: `libeth` is Intel-Eth scoped; bare page_pool is simpler |

**Revised acceptance probability: 55–65%** over a 3–6 month wall-clock.
The technical direction is well-trodden (ice, iavf, bcmgenet), no competing
in-flight series, and the driver is modernizing rather than redesigning.
The schedule risk is the real risk, not the technical direction.

## Open questions to resolve before posting

- [ ] **Does our OOT patch actually preserve the 4 KB boundary guarantee?**
      — the NHI hardware constraint is the single biggest review risk. If
      the OOT version doesn't preserve it, we may have been getting lucky.
      Check `b62fe82^:system/thunderbolt_net/main.c` RX alloc path.
- [ ] Does the OOT patch still apply cleanly to current `net-next`, or does
      it need restructuring?
- [ ] Should it add XDP support in the same series, or leave XDP as a
      follow-up? (Recommendation: leave XDP for v2 — keeps this series
      small and focused.)
- [ ] Is there value in exposing `ethtool -g` ring-size tuning as part of
      this, or leave ring size as a compile-time constant bumped to 1024?
- [ ] Benchmark plan: iperf3 single-stream, bidirectional, pktgen
      micro-benchmark? Also measure CPU util and `softirq` %.
- [ ] Test matrix: Mac peer, Windows peer, Linux→Linux, all three TB
      generations (TB3/Alpine, TB4/Titan, TB5/Barlow). We have TB5
      (Barlow) on hand; need access to TB3/TB4 peers for full matrix.

---

## System migration to kernel 7.0

Parallel track: get our build pipeline onto 7.0 so we can develop, test, and
submit the patch against a current tree. Current running kernel is 6.19.10
(see [hardware.md](hardware.md)).

### Blockers

> **R9700 blocker (historical):** the AMD Radeon AI PRO R9700 amdgpu SMU v50
> mismatch on kernel 7.0 was the decisive block on this migration. The R9700
> has since been removed from the box (2026-04), so the block is moot. The
> section below is preserved as historical rationale for the dual-boot plan
> that is no longer needed.

| Component | Status | Action |
|---|---|---|
| **AMD Radeon AI PRO R9700 (amdgpu)** | ✅ **N/A** — card removed from box 2026-04. Was previously a hard blocker per [ROCm#6101](https://github.com/ROCm/ROCm/issues/6101). | None. |
| **bcachefs OOT (v1.37.3)** | ⚠ Stale. v1.37.5 (2026-04-07) adds 7.0 support. | Bump `bcachefs_tag=v1.37.5` in `build-kernel.sh:15`. |
| **NVIDIA GDS nvidia-fs (v2.28.2)** | ⚠ Our existing 6.18-era sed patches (`vm_flags`, `blk_map_iter`, `memdesc_flags_t`) are expected to still apply, but 7.0 reworked driver-core module loading + folio/flags. Smoke-test-required. | Try a build; if a 4th API site fails, add a 4th sed. Consider CUDA 12.8 PCI P2PDMA as escape hatch. |
| **NVIDIA open-gpu-kernel-modules (595.58.03)** | ✅ 595 GA branch supports Blackwell on 7.0. | No change required, optionally bump to latest 595.x point release. |
| **Kernel source URL** | ⚠ Path changes `v6.x/` → `v7.x/`. | Update `build-kernel.sh:9`. |
| **XFS root** | ✅ "Self-healing XFS" is additive, on-disk format unchanged. | No action. |
| **Intel Arrow Lake NPU** | ✅ `drivers/accel/ivpu` supports it since NPU driver v1.5. | Ensure `CONFIG_DRM_ACCEL_IVPU=m`. |
| **thunderbolt_net** | ✅ No 7.0 regressions. | No action. |
| **Kconfig** | ✅ No documented 6.19→7.0 breaking renames. `olddefconfig` should carry forward. | Re-verify explicit `scripts/config --enable` list in `build-kernel.sh:64-83` still resolves — specifically `DRM_AMDGPU_SI/CIK` (upstream threatens retirement). |
| **Rust in-tree** | ✅ "Experimental" label dropped but still opt-in per subsystem. None of our drivers require it. | Keep `CONFIG_RUST` off. |

### The R9700 thermal blocker (obsolete)

Preserved as history. The R9700 fan-doesn't-spin issue on 7.0 was why the
migration was gated behind a dual-boot plan. The card was removed from the
box in 2026-04, so this blocker is gone and a single-boot 7.x upgrade is
viable when we're ready.

### Migration plan (single-boot)

1. **Update `build-kernel.sh`** — new kernel URL (`v7.x/linux-7.0.tar.xz`),
   bump `bcachefs_tag=v1.37.5`, keep NVIDIA pins.
2. **Build 7.0 tarball** — expect nvidia-fs patches may need a 4th sed.
3. **Install as a new EFI entry** — keep 6.19.10 as fallback, add 7.0 as
   `Boot0006`.
4. **Smoke test on 7.0**: bcachefs mount, NVIDIA CUDA, nvidia-fs GDS,
   thunderbolt_net basic connectivity, XFS root, NPU.
5. **Develop the thunderbolt_net page_pool patch against 7.0 net-next** —
   this is where iperf3 benchmarks happen.
6. Retire 6.19.10 once 7.x has proven stable on this workload.

### `build-kernel.sh` diff (to be made)

```
-src=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.10.tar.xz
+src=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.tar.xz

-bcachefs_tag=v1.37.3
+bcachefs_tag=v1.37.5
```

Plus possibly a 4th sed in the nvidia-fs patch block — determined by build.

### Migration blocker watch items

- [ ROCm#6101 ] R9700 SMU v50 — track weekly
- nvidia-fs v2.28.2 against 7.0 — build & report
- 595.x NVIDIA release notes for any 7.0-specific fixes

## References

Driver state & patch history
- [drivers/net/thunderbolt/main.c (mainline)](https://github.com/torvalds/linux/blob/master/drivers/net/thunderbolt/main.c)
- [Recent commit log](https://github.com/torvalds/linux/commits/master/drivers/net/thunderbolt)
- [MAINTAINERS](https://github.com/torvalds/linux/blob/master/MAINTAINERS)

Reference page_pool conversions
- [ice: convert Rx path to Page Pool (Jul 2025)](https://lists.openwall.net/netdev/2025/07/07/287)
- [Intel Wired LAN Driver Updates 2025-01-06](https://lists.openwall.net/netdev/2025/01/06/300)
- [bcmgenet RX page_pool conversion, Apr 2026](https://lkml.org/lkml/2026/4/12/555)

Subsystem context
- [Page Pool API — kernel docs](https://kernel.org/doc/html//v5.13/networking/page_pool.html)
- [USB4 and Thunderbolt — kernel docs](https://docs.kernel.org/admin-guide/thunderbolt.html)
- [maintainer-netdev.rst](https://docs.kernel.org/process/maintainer-netdev.html)
- [Kicinski — netdev in 2024](https://people.kernel.org/kuba/netdev-in-2024)
- [FOSDEM 2020 — XDP and page_pool (Apalodimas)](https://archive.fosdem.org/2020/schedule/event/xdp_and_page_pool_api/attachments/paper/3625/export/events/attachments/xdp_and_page_pool_api/paper/3625/XDP_and_page_pool.pdf)

Community signal
- [Phoronix — Intel Loses Thunderbolt Maintainer](https://www.phoronix.com/news/USB4-Thunderbolt-Maintainer)
- [Phoronix — Linux 6.19 Networking Delivers 4x Improvement](https://www.phoronix.com/news/Linux-6.19-Networking)
- [Phoronix — Linux 7.0 Released](https://www.phoronix.com/news/Linux-7.0-Released)
- [LWN — Thunderbolt networking (2017 intro)](https://lwn.net/Articles/735235/)
- [2017 thunderbolt_net v3 series (4 KB constraint, build_skb)](https://lkml.iu.edu/hypermail/linux/kernel/1710.0/00406.html)
- [scyto gist — Thunderbolt Networking Setup (community perf thread)](https://gist.github.com/scyto/67fdc9a517faefa68f730f82d7fa3570)
- [Westerberg post-Intel reply, 5 Jan 2026](https://lkml.org/lkml/2026/1/5/678)
- [Debian bug #1121032 — ndo_set_mac_address bonding regression](http://www.mail-archive.com/debian-kernel@lists.debian.org/msg145931.html)

Migration references
- [kernel.org v7.x directory](https://cdn.kernel.org/pub/linux/kernel/v7.x/)
- [Phoronix — Bcachefs 1.37 Released With Linux 7.0 Support](https://www.phoronix.com/news/Bcachefs-1.37-Released)
- [koverstreet/bcachefs-tools tags](https://github.com/koverstreet/bcachefs-tools/tags)
- [NVIDIA/open-gpu-kernel-modules releases](https://github.com/NVIDIA/open-gpu-kernel-modules/releases)
- [gds-nvidia-fs releases](https://github.com/NVIDIA/gds-nvidia-fs/releases)
- [ROCm#6101 — R9700 fan/SMU mismatch on kernel 7.0](https://github.com/ROCm/ROCm/issues/6101)
- [Phoronix — XFS Self-Healing in 7.0](https://www.phoronix.com/forums/forum/software/general-linux-open-source/1613150-xfs-introducing-autonomous-self-healing-capabilities-with-linux-7-0)
