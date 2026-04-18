# Submitting the thunderbolt_net page_pool patch

Step-by-step to send `0001-net-thunderbolt_net-convert-Rx-path-to-page_pool.patch`
upstream. Do this from the `st@samespace.com` mail client.

## 1. Regenerate the patch against current net-next

The formatted patch needs an up-to-date `base-commit:` trailer. From
`/root/lab/kernel/tb-upstream/net-next`:

```bash
git fetch origin
git checkout -B tbnet-page-pool origin/main
git am /root/lab/kernel/tb-upstream/0001-net-thunderbolt_net-convert-Rx-path-to-page_pool.patch
./scripts/checkpatch.pl --strict -g HEAD          # must be clean
git format-patch --base=auto -o /tmp/tbnet-out origin/main
```

Output: `/tmp/tbnet-out/0001-net-thunderbolt_net-convert-Rx-path-to-page_pool.patch`.

If `git am` fails with a conflict, the upstream driver has changed — rebase
manually, re-run `checkpatch.pl`, regenerate.

## 2. Re-confirm recipients

Maintainers rotate. Always regenerate:

```bash
./scripts/get_maintainer.pl /tmp/tbnet-out/*.patch
```

Current list (as of net-next `1f5ffc672165`):

**To**
- Mika Westerberg `<westeri@kernel.org>`
- Yehezkel Bernat `<YehezkelShB@gmail.com>`

**Cc**
- Andrew Lunn `<andrew+netdev@lunn.ch>`
- David S. Miller `<davem@davemloft.net>`
- Eric Dumazet `<edumazet@google.com>`
- Jakub Kicinski `<kuba@kernel.org>`
- Paolo Abeni `<pabeni@redhat.com>`
- `netdev@vger.kernel.org`
- `linux-kernel@vger.kernel.org`

## 3. Compose the mail

**Subject** (copy exactly):

```
[PATCH] net: thunderbolt_net: convert Rx path to page_pool
```

**Body**: open the `.patch` file. Copy everything **starting from the blank
line after the `Subject:` header** down to the end of the file (includes the
changelog, `Signed-off-by`, `---`, diffstat, unified diff, and final
`base-commit:` trailer). Do **not** include the `From …Mon Sep 17…`, `From:`,
`Date:`, `Subject:` lines at the top — those belong in the mail headers, not
the body.

**From**: `Shailesh Tyagi <st@samespace.com>` — must match the
`Signed-off-by:` line in the body.

## 4. Client settings — non-negotiable

Kernel patches reject trivially if whitespace is corrupted. See
`Documentation/process/email-clients.rst` in the tree.

- **Plain text only.** Disable HTML/rich text/Markdown for this message.
- **No attachments.** Patch goes inline in the body.
- **No word-wrap on send.** Long diff context lines must travel byte-for-byte.
- **No auto-signature, tracking pixel, disclaimer, or banner** after the diff.
- **No `format=flowed`** (Apple Mail: uncheck "Send windows-friendly
  attachments" and disable flowed).
- **Outlook is not usable** for this. If your client is Outlook, switch to
  Thunderbird or use `git send-email` instead.

Gmail web in plain-text mode works. Thunderbird works (uncheck "Compose
messages in HTML format" globally or per-identity).

## 5. Self-verify before sending

Send a copy to yourself first. In the received message, use "show original"
/ "view source" and save it as `received.eml`. Then:

```bash
cd /root/lab/kernel/tb-upstream/net-next
git checkout origin/main
git apply --check /path/to/received.eml
```

If it applies cleanly, maintainers will be able to apply it too. If `git
apply` complains about whitespace or corrupt patch, the client mangled
something — fix and retry. Do not send to the lists until the self-test
passes.

## 6. Send

To the **To** and **Cc** lists from step 2. Single message, one patch.

## 7. After sending

- Archive the sent mail. Note the `Message-ID` — needed if a v2 is required.
- Find the post on lore: https://lore.kernel.org/netdev/ — search by subject
  to confirm it was delivered to the list.
- Expect review within 2–3 weeks. During merge windows (rc1 → rc2 of each
  cycle) netdev is slower; don't ping before a week has passed.
- Reviewers reply inline. Respond **interleaved**, trim quoted text, no
  top-posting.
- If changes are requested, prepare v2:
  - Amend/rebase the commit in `tbnet-page-pool`.
  - `git format-patch -v2 --base=auto ...`
  - Below the `---` in the patch, add a short `v1 → v2:` changelog.
  - Cc everyone who replied to v1, plus the original list.
  - Include `Link:` to the v1 lore URL in the commit message.

## Reference

- `Documentation/process/submitting-patches.rst` — canonical guide.
- `Documentation/process/email-clients.rst` — per-client settings.
- `Documentation/process/submit-checklist.rst` — pre-submission checklist.
- https://lore.kernel.org/netdev/ — the list archive.
