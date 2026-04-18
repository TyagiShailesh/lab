# One-time migration: legacy pool → final bcachefs layout

This is the **one-time** procedure to move from the originally-formatted pool
(SN850X alone at `durability=2`, 9100 Pro on separate XFS `/cache`) to the
final layout in [bcachefs.md](bcachefs.md).

After it runs successfully it will not be re-run. Keep the doc for history,
not as a recurring playbook.

> **CRITICAL DATA LIVES ON `/store`.** Every destructive step is flagged. Do
> not skip backup verification. Do not combine phases. Complete each phase
> and its verification before starting the next.

## Starting state (as of 2026-04-18)

| Device | Current role |
|---|---|
| Seagate Exos ST14000NM000J (14 TB) | in pool, `hdd`, `durability=1` |
| Seagate Exos ST14000NM001G (14 TB) | in pool, `hdd`, `durability=1` |
| WD_BLACK SN850X (2 TB) | in pool, `ssd`, **`durability=2`** |
| Samsung 9100 Pro (1 TB) | **separate XFS** on `/cache`; holds `/cache/iris`, possibly `/cache/models` |

Filesystem options on the live pool: `data_replicas=2`, `metadata_replicas=2`,
`foreground_target=ssd`, `background_target=hdd`, `promote_target=ssd`,
`metadata_target=ssd`, `compression=none`, `background_compression=zstd`.

## Ending state

Both NVMe drives are in the pool as SSD tier. All four devices are
`durability=1`. HDDs allow only `btree,user`. SSDs allow only `journal,user`.
`metadata_target=hdd`. See [bcachefs.md §4](bcachefs.md#4-core-decisions)
for why.

---

## Phase 0 — Backup and snapshot (do not skip)

**Before anything else**, verify you have a current, restorable backup of
`/store` and `/cache/iris`. The migration passes through several windows where
a single device failure could lose data.

```bash
# Inventory what is on /cache right now
ls -lah /cache/
du -sh /cache/*

# Confirm existing backups are readable and reasonably fresh
# (adjust to whatever your backup target is)
```

Check free space on `/store` (iris + models will land there):

```bash
bcachefs fs usage -h /store
```

Ensure enough HDD free space to hold everything currently on `/cache` plus
headroom for reconcile.

---

## Phase 1 — Evacuate `/cache/iris` → `/var/iris`

`iris` is a root-run service; its working dir moves to the boot SSD at
`/var/iris` so the old `/cache` XFS can be destroyed. The Samba share
definition is updated to the new path in Phase 8.

```bash
# Stop iris writers (adjust to the actual service name on the host)
systemctl stop iris   # if iris runs as a systemd service

# Copy with attributes preserved
mkdir -p /var/iris
rsync -aHAX --info=progress2 /cache/iris/ /var/iris/

# Compare sizes and file counts
du -sh /cache/iris /var/iris
find /cache/iris -type f | wc -l
find /var/iris  -type f | wc -l

# Reapply ownership/modes consistent with post-install.md
chgrp -R st /var/iris
chmod -R g+rwX,o-rwx /var/iris
find /var/iris -type d -exec chmod g+s {} +
```

Restart iris pointing at `/var/iris` (update its service/config to the new
path first). Verify it writes.

**Do not delete `/cache/iris` yet** — it stays as the rollback source until
Phase 3.

---

## Phase 2 — Move models to `/store/models`

If `/cache/models` exists:

```bash
mkdir -p /store/models
rsync -aHAX --info=progress2 /cache/models/ /store/models/
du -sh /cache/models /store/models
```

If models are in use by a running service (LLM loader, Resolve scratch,
etc.), stop it, move, update its config to `/store/models`, restart, verify.

Other directories on `/cache` (e.g. `/cache/resolve`): decide case-by-case.
Either migrate into `/store/<name>` or discard. **Nothing on `/cache` survives
Phase 4.**

---

## Phase 3 — Unmount and remove `/cache`

```bash
# Confirm nothing is using /cache
lsof +D /cache            # should be empty
fuser -vm /cache          # should be empty

# Stop and disable (if any) anything still pointing at /cache
umount /cache

# Remove the fstab entry for /cache (XFS on the 9100 Pro by-id)
# Edit /etc/fstab — drop the line referencing nvme-Samsung_SSD_9100_PRO_1TB_...
vi /etc/fstab

# Remove the now-empty mountpoint so nothing writes there accidentally
rmdir /cache
```

---

## Phase 4 — Prepare 9100 Pro for pool membership

> **Destructive.** Wipes the 9100 Pro.

```bash
DEV=/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T

# Confirm the right device
lsblk "$DEV"
blkid "$DEV"

# Wipe filesystem signatures
wipefs -a "$DEV"
blkid "$DEV"              # should now print nothing
```

---

## Phase 5 — Add 9100 Pro to the pool

```bash
DEV=/dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T

bcachefs device add --label=ssd --durability=1 /store "$DEV"

# Expect 4 members now: 2 hdd + 2 ssd
bcachefs fs usage -h /store
bcachefs show-super "$DEV" | grep -E 'Device|Label|Durability'
```

At this point the pool has four devices but policy is still the *starting*
configuration (`metadata_target=ssd`, SN850X at `durability=2`, no
`data_allowed` split). The 9100 starts absorbing foreground writes.

---

## Phase 6 — Move metadata onto the HDDs

Change `metadata_target` first, then wait for the btree to migrate to HDDs
*before* tightening `data_allowed`. If you set `data_allowed=journal,user` on
the SSDs while btree still lives there, bcachefs has to evacuate while
simultaneously having nowhere new to land — avoid that race.

```bash
bcachefs set-option metadata_target=hdd /store
# Exact flag varies by version. Verify with:
#   bcachefs set-option --help
#   bcachefs set-fs-option --help

# Watch btree bytes per device drain off SSDs and accumulate on HDDs
watch -n 5 'bcachefs fs usage -h -a /store | grep -A2 "btree"'
```

Wait until SSD btree bytes are at (or near) zero before continuing.

---

## Phase 7 — Flip SN850X `durability` from 2 to 1

> **Sensitive window.** Before the flip, a single SSD copy counts for 2
> replicas. After the flip, `data_replicas=2` requires two *distinct* copies.
> Any extent whose only durable home was the SN850X will become
> under-replicated until reconcile places a second copy (on either the 9100
> or an HDD).

```bash
# Pre-flip: force reconcile to be as complete as possible
bcachefs fs usage -h -a /store
# look for "dirty" bytes; wait until small

UUID=$(bcachefs show-super /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
       | awk '/External UUID/ {print $NF}')
# Identify the dev-N directory for the SN850X in sysfs
ls /sys/fs/bcachefs/$UUID/
# Each dev-N has a 'label' file — find the one pointing at the SN850X

# Flip durability live
echo 1 > /sys/fs/bcachefs/$UUID/dev-<SN850X>/durability

# Verify
bcachefs show-super /dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813 \
  | grep -E 'Durability'

# Let reconcile re-balance. Do not touch anything else until dirty/
# under-replicated accounting is clean.
watch -n 5 'bcachefs fs usage -h -a /store'
```

Hold here until the pool reports fully-replicated state.

---

## Phase 8 — Apply `data_allowed` splits

Now the clean allocation rule: journal off HDDs, btree off SSDs.

```bash
# HDDs: btree + user, no journal
for D in \
  /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
  /dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZLW212GF; do
  bcachefs set-option --dev "$D" data_allowed=btree,user /store
done

# SSDs: journal + user, no btree
for D in \
  /dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813 \
  /dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T; do
  bcachefs set-option --dev "$D" data_allowed=journal,user /store
done
# Exact syntax varies — verify with `bcachefs set-option --help` first.
```

Journal on HDDs (if any) evacuates to SSDs. Any stray btree bytes on SSDs
evacuate to HDDs.

```bash
watch -n 5 'bcachefs fs usage -h -a /store'
```

Wait for the final steady state: journal bytes only on `ssd` devices, btree
bytes only on `hdd` devices.

---

## Phase 9 — Update the systemd mount unit

Replace the legacy unit's kernel-name device list with the full by-id list
for all four members. Target content is in [bcachefs.md §7](bcachefs.md#7-boot-and-systemd-not-fstab).

```bash
cp /etc/systemd/system/bcachefs-store.service \
   /etc/systemd/system/bcachefs-store.service.pre-migrate.bak

vi /etc/systemd/system/bcachefs-store.service
# Replace ExecStart device list with the four by-id paths from bcachefs.md §7
# Change Requires= to Wants= (or drop the .device dependencies entirely)

systemctl daemon-reload

# Test a full stop/start cycle to prove the unit is correct
systemctl stop bcachefs-store
systemctl start bcachefs-store
systemctl status bcachefs-store
mountpoint /store
bcachefs fs usage -h /store
```

---

## Phase 10 — Update Samba share for iris

Edit `/etc/samba/smb.conf` and change the `[iris]` share path from
`/cache/iris` to `/var/iris`. See [post-install.md §3](post-install.md).

```bash
vi /etc/samba/smb.conf      # update [iris] path
testparm -s                 # verify config parses
systemctl restart smbd
```

Mount the share from a client and verify reads/writes work.

---

## Phase 11 — Final verification

Runs through the checks in [bcachefs.md §10](bcachefs.md#10-verify-the-running-config-matches-this-doc).
If any value disagrees with the table there, stop and investigate before
reporting the migration done.

```bash
# Per-device
for D in \
  /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
  /dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZLW212GF \
  /dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_24364L800813 \
  /dev/disk/by-id/nvme-Samsung_SSD_9100_PRO_1TB_S7YENJ0L200013T; do
  echo "=== $D ==="
  bcachefs show-super "$D" | grep -E 'Label|Durability|Allowed'
done

# Filesystem-wide
bcachefs show-super /dev/disk/by-id/ata-ST14000NM000J-2TX103_ZR900CTB \
  | grep -E 'replicas|target|compression'

# Accounting
bcachefs fs usage -h -a /store
```

Expected:

- All devices `durability=1`.
- HDDs `data_allowed=btree,user`; SSDs `data_allowed=journal,user`.
- `data_replicas=2`, `metadata_replicas=2`.
- `foreground_target=ssd`, `background_target=hdd`, `promote_target=ssd`, `metadata_target=hdd`.
- Btree bytes only on HDD rows in `fs usage -a`; journal bytes only on SSD rows.

Once the above all check out:

```bash
# Now safe to delete the original /cache/iris tree — rollback no longer useful
rm -rf /cache           # directory already unmounted in Phase 3; this is belt-and-braces
```

Record the date in [bcachefs.md §12 Changelog](bcachefs.md#12-changelog).

---

## Rollback notes

- **Before Phase 4:** rollback is trivial — data on `/cache` is still intact; restart the service pointing back at `/cache/iris`.
- **Phase 4 onward:** the 9100 Pro has been wiped. Rollback means restoring iris/models from the `/var/iris` and `/store/models` copies made in Phases 1–2 and rebuilding XFS on the 9100.
- **Phase 7 onward:** the SN850X no longer double-counts. If the pool becomes unhealthy during reconcile, do not flip `durability` back to 2 unless you understand which extents that re-masks; prefer letting reconcile complete.

If anything fails with an error you don't understand, stop, capture
`bcachefs show-super` for every device and `dmesg | grep -i bcachefs`, and
escalate before taking further action.
