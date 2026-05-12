---
name: rock-5b expansion — testing v1's board-onboarding seams
description: Add rock-5b as a second v1 board alongside orange-pi-5-pro, exercising the existing expansion seams stage-by-stage (image build → staging → hardware E2E) and capturing friction observations as a v1-spec amendment for the third-board onboarding.
---

# rock-5b expansion design

## Goal

Validate v1's board-onboarding story by adding `rock-5b` as a second
supported board. The collection was scoped (per
[2026-05-07-v1-scope-narrowing-design.md](2026-05-07-v1-scope-narrowing-design.md))
to a single board (`orange-pi-5-pro`); v1 is otherwise complete. Before
tagging v1, we add a second board to exercise the expansion seams — the
4–5 touchpoints the operator hits when onboarding a new model — and
capture friction observations so the third board onboards faster.

This rescopes v1 to ship two-board netboot capability rather than one.

## Approach: stage-by-stage, no refactoring

The rock-5b work proceeds in three sequential phases. Each phase
exercises one expansion seam, surfaces friction specific to that seam,
and is small enough to revert independently if something goes sideways.
**No refactoring of expansion seams happens during this work** — every
friction point gets logged and deferred. The point is to *evaluate*
expandability under real load; refactoring during the evaluation would
contaminate the observations.

The four acceptance signals (below) are the proof that the expansion
worked. The friction writeup that lands in the v1-spec amendment is the
artifact that makes the next board easier.

## Acceptance criteria

1. **Image build:** `playbooks/build_image.yml` builds both
   `orange-pi-5-pro` and `rock-5b` in a single invocation. Both
   `.img.xz` files publish to
   `nfs_assets_export/images/<board>/Armbian-unofficial_*_minimal.img.xz`
   on the netboot server.
2. **Staging:** `playbooks/stage_netboot_assets.yml` populates
   `nfs_rootfs_path/_templates/rock-5b/` (per-model rootfs template) +
   `nfs_rootfs_path/rock-5b-01/` (per-host clone) on TrueNAS, and
   stages `armbian/rock-5b/{vmlinuz,initrd.img,board.dtb}` to rb5009
   with three matching `/ip tftp` rows.
3. **Hardware E2E:**
   `playbooks/test_hardware_e2e.yml --limit rock-5b-01` passes
   SD → NFS → SD without any changes to the harness code. Per-board
   retry-knob overrides in `host_vars/rock-5b-01.yml` or
   `group_vars/rock_5b.yml` are allowed; touching
   `playbooks/test_hardware_e2e.yml` or
   `roles/board_boot_state/tasks/*.yml` is disqualifying.
4. **Friction writeup:**
   `docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`
   gains a "rock-5b expansion" amendment that (a) rescopes v1 to two
   boards, (b) lists per-phase friction observations, (c) flags
   deferred refactors with their landing locations.

## Open data items

The rock-5b board metadata fields below are starting hypotheses. Each
is confirmed at the relevant phase before code is written against it.
If any hypothesis is wrong, the spec is updated rather than the code
being forced.

| Field | Hypothesis | Verified by |
|---|---|---|
| `board_model` (inventory) | `rock-5b` | Phase 2 — matches dl_dir/build_name convention |
| `armbian_dl_dir` | `rock-5b` | dl.armbian.com/rock-5b/ exists |
| `armbian_board_name` | `rock-5b` | armbian/build `BOARD=rock-5b` builds |
| `armbian_support` | `standard` | Armbian board status page |
| `dtb` | `rockchip/rk3588-rock-5b.dtb` | Phase 2 — `find` in extracted rootfs |
| `console` | `ttyS2,1500000n8` | Phase 3 — boot log via UART |
| `earlycon` | `uart8250,mmio32,0xfeb50000` | Phase 3 — only consulted when `pxelinux_verbose=true` |
| `armbian_image_urls[rock-5b]` | Pattern unknown until first build | Phase 1 — read post-build filename, fill in |
| `poe_switch` / `poe_port` | Operator-provided | Phase 2 — inventory entry |
| `board_mac` / `ansible_host` | Operator-provided | Phase 1.5 — from rb5009 DHCP lease |

### Chicken-and-egg for `armbian_image_urls[rock-5b]`

`stage_netboot_assets.yml`'s preflight HEAD-checks each board's
`armbian_image_urls` entry before doing any work. The URL must be
correct *before* Phase 2 runs. But Phase 1 (the build) is what
produces the file that the URL points at.

Order: run Phase 1 with the URL set to a placeholder, observe the
actual published filename, update the URL in
`inventory/group_vars/all.yml`, then proceed to Phase 2. **Friction-note
candidate.**

## Phase 1 — Image build

**Files touched:**

- `vars/boards.yml` — add `rock-5b` block with the six fields from the
  hypothesis table.
- `playbooks/build_image.yml` — add `rock-5b` to the inline
  `build_userpatches` dict:

  ```yaml
  rock-5b:
    - dest: "config/boards/rock-5b.conf"
      content: |
        function pre_config_uboot_target__rock_5b_pxe_first() {
            declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
            sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                include/configs/rockchip-common.h
        }
  ```

  Note: armbian/build's hook-name conventions require the function name
  to use underscores (`rock_5b`) even when the userpatches key uses
  dashes (`rock-5b`). **Verify against armbian/build's hook naming
  rules before merging this** — if the convention disagrees, swap the
  function name to whatever armbian/build expects.

- `inventory/group_vars/all.yml` — add a placeholder
  `armbian_image_urls[rock-5b]` entry. Replaced with the concrete
  filename after the first successful build.

**Operator step:**

```bash
ansible-playbook playbooks/build_image.yml
```

**Verification:**

- `/mnt/ssd/public/boot-files/images/rock-5b/Armbian-unofficial_*.img.xz`
  exists on the netboot server.
- (Optional) Extract the `u-boot.bin` from the image and confirm the
  `BOOT_TARGETS` string is `pxe dhcp mmc1 mmc0 nvme scsi usb spi`.

Then update `armbian_image_urls[rock-5b]` with the real filename.

**Likely friction (capture in notes):**

- userpatches key naming convention (dashes vs. underscores)
- hook function-name convention (must be underscored)
- post-build image filename casing (`Rock-5b` vs. `rock-5b`)
- the `build_userpatches` table is hand-duplicated for every RK3588
  board (orangepi5, orangepi5pro, rock-5b) — flagged as deferred-refactor

## Phase 1.5 — Manual hardware bring-up

**External to this collection.** No code changes. Operator-driven.

1. Flash an SD card with the rock-5b `.img.xz` produced in Phase 1
   (`xzcat | dd`, etcher, or equivalent).
2. Insert the SD card into the rock-5b. Wire PoE-HAT (or PoE splitter)
   ethernet into the upstream RouterOS PoE switch port. Power on.
3. Wait for the board to obtain a DHCP lease and respond to SSH.
4. Capture the board's MAC address and current DHCP-leased IP from
   rb5009 (or the upstream switch).
5. **Pin the MAC to a static DHCP reservation on rb5009.** This is owned
   by the operator's separate routeros-config repo (e.g.
   igou-ansible's `deploy_netboot_binaries.yml`), not by this
   collection. Without a static reservation, the board's IP can shift
   and break inventory entries.

The static-reservation requirement is the same external-state gap as
`next-server` — and worth re-flagging in the friction writeup that
*every new board adds external RouterOS state that lives outside this
collection*.

## Phase 2 — Inventory + staging

**Files touched:**

- `.inventory/hosts.yml` (real inventory; gitignored) — add `rock_5b`
  subgroup under `boards`:

  ```yaml
  rock_5b:
    hosts:
      rock-5b-01:
        ansible_host: <pinned IP from Phase 1.5>
        board_mac: "<MAC from Phase 1.5>"
        board_model: rock-5b
        poe_switch: <switch hostname>
        poe_port: <ether N>
  ```

- `inventory/hosts.yml` (doc-only) — same shape with placeholder MAC/IP,
  so the sample inventory matches v1's actual scope.

**Operator steps:**

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit rock-5b-01
ansible-playbook playbooks/stage_netboot_assets.yml
```

(The second command picks up rock-5b automatically via `groups['boards']`
enumeration — no `--limit` needed.)

**Verification on the netboot server:**

- `nfs_rootfs_path/_templates/rock-5b/` is populated with the rootfs
  extracted from the rock-5b image.
- `nfs_rootfs_path/rock-5b-01/` exists as a per-host clone with reset
  hostname, machine-id, and SSH host keys.
- `find _templates/rock-5b/boot/dtb -name '*rock-5b*'` finds a DTB at
  the path declared in `vars/boards.yml`. Update the spec hypothesis
  if it doesn't.

**Verification on rb5009:**

- `flash:/sbc/armbian/rock-5b/{vmlinuz,initrd.img,board.dtb}` present.
- Three `/ip tftp` rows registered: `armbian/rock-5b/vmlinuz`,
  `armbian/rock-5b/initrd.img`, `armbian/rock-5b/board.dtb`.

**Likely friction (capture in notes):**

- DTB path drift between Armbian releases
- `cp --reflink=auto` cost on the first rock-5b template clone
  (one rootfs of bytes; subsequent clones are free)
- any U-Boot expectation for FIT image / DTB naming that differs from
  OPi5Pro

## Phase 3 — Hardware E2E

**Pre-E2E smoke** (recommended before invoking the full harness — keeps
the diagnostic blast radius small if something is misconfigured):

```bash
ansible-playbook playbooks/enable_netboot.yml --limit rock-5b-01
# Confirm: ssh rock-5b-01 'findmnt /' reports the TrueNAS NFS export.

ansible-playbook playbooks/disable_netboot.yml --limit rock-5b-01
# Confirm: board boots back to SD rootfs.
```

If either smoke step fails, the E2E will fail too — fix the smoke
failure first.

**E2E:**

```bash
ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit rock-5b-01 \
  -e capture_serial=true
```

The operator wires a USB-UART to rock-5b's UART2 pins on the 40-pin
header — different physical location from OPi5Pro's dedicated debug
header. Document the rock-5b pinout in the friction notes.

**Tuning surface (if E2E flakes intermittently):** Override retry knobs
in `host_vars/rock-5b-01.yml` or `group_vars/rock_5b.yml`:

- `boot_retry_attempts`
- `cold_boot_wait`
- post-boot SSH-stability window

See [`docs/retry-configuration.md`](../../retry-configuration.md) for
the full knob list. **Touching the harness itself is disqualifying** —
that's the whole point of the third acceptance criterion.

**Likely friction (capture in notes):**

- Retry-knob defaults are OPi5Pro-tuned; rock-5b's PoE-cycle → DHCP
  timing may differ.
- UART pinout differs from OPi5Pro (40-pin header vs. dedicated debug
  header).
- rock-5b may take longer to come up from PoE-off due to eMMC
  enumeration even when unused.

## Friction capture mechanics

During each phase, the operator keeps a running notes file at
`docs/superpowers/specs/.rock5b-friction-notes.md` (the `.`-prefix
keeps it out of the published spec list while in flight). One section
per phase. Each note has shape:

```
- **What hurt:** <one-line description>
  **Where:** <file:line or playbook stage>
  **Root cause:** <why it hurt>
  **Deferred-refactor candidate:** <yes/no — if yes, what would fix it>
```

Notes are written *as friction is hit*, not retroactively. Hot-take
quality is fine; the consolidation pass cleans them up.

## v1-spec amendment

After Phase 3 completes, the running notes are distilled into a new
section appended to
`docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`:

```markdown
## Amendments (YYYY-MM-DD) — rock-5b expansion

### v1 rescope

v1 now ships two-board netboot capability: `orange-pi-5-pro` AND
`rock-5b`. The original spec's acceptance criterion "vars/boards.yml
contains exactly one entry (orangepi5pro)" is voided. Replacement
criterion: vars/boards.yml contains entries for both v1-supported
boards. The original spec's "Adding a new board (post-v1)" section is
no longer post-v1 framing — it documents the path to board 3+.

### Per-phase friction observations

**Phase 1 (image build):** <distilled bullets from notes>
**Phase 2 (staging):** <distilled bullets from notes>
**Phase 3 (hardware E2E):** <distilled bullets from notes>
**External-state callout:** every new board adds external RouterOS
state (static DHCP reservation) that this collection does not manage,
in the same way `next-server` is externally owned.

### Deferred refactors (post-v1)

<bullet list of "Deferred-refactor candidate: yes" items, each linking
to where in the codebase the refactor would land>
```

The working notes file is then deleted (its content has migrated into
the amendment).

## Doc updates that ride along

Not refactors — minimal corrections to keep the published surface
consistent with the rescope:

- `README.md` — change "Status: v1 = orange-pi-5-pro netboot capability
  only" to "Status: v1 = orange-pi-5-pro + rock-5b netboot capability".
- `CLAUDE.md` — same status header update, plus fix the existing drift
  in the "Adding a new board (post-v1)" section: it currently lists
  five `vars/boards.yml` fields but the 2026-05-12 amendment added
  `earlycon` as a sixth required field. One-line correction.
- `inventory/hosts.yml` (doc-only) — add the `rock_5b` subgroup so the
  sample inventory matches the rescoped v1.

## What does NOT get touched (deferred-refactor candidates)

Logged in the friction writeup as candidates, not implemented in this
work:

- Lifting `build_userpatches` from playbook-inline data into a board
  field in `vars/boards.yml`.
- Adding a cross-check that every `board_model` in inventory has a
  matching key in `armbian_image_urls`.
- Factoring the shared RK3588-family BOOT_TARGETS sed (three copies
  once rock-5b lands).
- Reducing the four-string-form naming convention
  (`rock-5b` / `rock_5b` / `Rock-5b` / etc.) to a single canonical
  form with deterministic derivation rules.

These get addressed (or not) post-v1, based on how painful they were
during this work vs. how often boards get added.

## Out of scope

- Refactoring expansion seams during the rock-5b work (deferred per
  approach decision; see "Approach: stage-by-stage, no refactoring").
- Boards beyond rock-5b in v1 (board 3+ is post-v1).
- Reprovision / on-host bootloader flashing for rock-5b — same out-of-
  scope as for orange-pi-5-pro in v1.
- Changing the `board_boot_state` retry stack to be board-aware
  beyond per-host variable overrides (deferred unless E2E reveals the
  current model is insufficient).
- Migrating any RouterOS-side DHCP state into this collection (static
  reservations remain externally owned).
