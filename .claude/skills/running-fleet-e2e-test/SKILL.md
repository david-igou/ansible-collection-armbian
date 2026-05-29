---
name: running-fleet-e2e-test
description: Use when running the deterministic six-phase fleet e2e (`playbooks/tests/test_fleet_e2e.yml`) — validating cross-iteration determinism after image rebuilds, `disk_image`/`disk_provision`/`bootstrap_armbian` changes, new-board bring-up, or SPI recovery. Covers pre-flight probes, the `.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh` wrapper, Summary-table interpretation, and per-phase recovery routes.
---

# Running the Fleet E2E Test

## Overview

`playbooks/tests/test_fleet_e2e.yml` is the canonical whole-fleet harness: six
deterministic phases (0 PoE-down → 1 NFS reset → 2 NFS boot + bootstrap
+ SPI persist → 3 dd SD → 4 SD boot + bootstrap → 5 NVMe reprovision +
local_kernel TFTP-flat verify). Each phase produces a known-clean state
for the next, so an unclean prior-run state can't poison the next
iteration.

**Core principle:** Pre-flight inventory + dependency probes before
hitting any hardware. Use the `run-fleet-e2e.sh` wrapper so every run
gets a unique artifact dir + an aggregated Summary. When a phase fails,
the per-phase `/tmp/iter-FLEET-<host>/<phase>/` directory plus the
phase-specific diagnostic bundle (auto-captured by
`_lifecycle_set_and_verify`) tells you which board failed at which step.

## When to use

- After **any change to**: `image_build`, `rootfs_provision`,
  `disk_image`, `disk_provision`, `bootstrap_armbian`, `persist_uboot_env`,
  `pxelinux_render`, or `board_boot_verify` roles.
- After a **new board** bring-up (run alongside `adding-armbian-board`).
- After **SPI recovery** on a stuck board (run alongside
  `recovering-uboot-spi-state`) to confirm the board converges normally.
- Periodically against the fleet to **catch drift** before it bites
  during a real change.
- Before **merging a PR** that touches any of the boot-mode-transition
  primitives.

Per-board reliability iteration on a single board (campaign-shaped:
PoE-cycle delay tuning, voltage-select flake debugging, etc.) is the
domain of `playbooks/tests/test_hardware_e2e.yml`, not this skill. That
harness is per-board, per-iter; this one is whole-fleet, deterministic.

## Phase A — Pre-flight probes (do before running)

The fleet test relies on a half-dozen inventory and dependency
preconditions. A missing one fails the playbook mid-flight after wasting
the per-phase warm-up cost. Spend 3 minutes probing first.

### A.1 — Inventory completeness

Every target board needs five hostvars set. Probe one board at a time:

```bash
ansible <board> --list-vars 2>/dev/null \
  | grep -E "armbian_(board_mac|board_model|poe_switch|poe_port|local_disks)"
```

Required:
- `armbian_board_mac` — DHCP lease lookup
- `armbian_board_model` — names the model-group whose `armbian_board_config_model` carries the board's hardware facts (in `inventory/group_vars/<model_group>.yml`)
- `armbian_poe_switch` + `armbian_poe_port` — Phase 0 PoE-off + Phase 2/4/5 PoE-cycle
- `armbian_local_disks` — Phase 5 NVMe layout (a list-of-dicts; see `roles/disk_provision/meta/argument_specs.yml`)

Missing any → playbook fails in the relevant phase. Add them to inventory
before running.

### A.2 — Per-host rootfs source (`armbian_rootfs_src` or manifest)

Each board host needs a resolvable rootfs source. The resolver
(`_resolve_rootfs_src.yml`) tries two paths in order:

1. `armbian_rootfs_src` set explicitly in host_vars — an explicit per-host pin.
2. A published manifest at `<armbian_nfs_assets_export>/images/<host>/manifest.json` — written by the last successful `build_and_publish_from_inventory.yml` run.

If neither is set for a board, the play fails with a clear message at
Phase 1 before touching any hardware.

Probe each board's resolution:

```bash
group="${armbian_boards_group:-boards}"
for board in $(ansible-inventory --list | jq -r --arg g "$group" '.[$g].hosts // .[$g].children | .. | strings'); do
  ansible "$board" -m debug -a 'var=armbian_rootfs_src' || true
done
```

If `armbian_rootfs_src` is undefined and no manifest exists on the netboot
server, run `playbooks/build_and_publish_from_inventory.yml` first to
produce the manifest, then re-probe.

### A.3 — Router TFTP plumbing

Phase 5's TFTP-flat check delegates to `armbian_router` (rb5009)
and queries `/ip tftp` rows. The rows must exist (one per per-board
pxelinux.cfg and one per per-model kernel/initrd/dtb triple).

```bash
ansible <armbian_router> -m community.routeros.command \
  -a 'commands="/ip tftp print count-only"' 2>&1 | tail -3
```

A non-zero count means `stage_router.yml` has been run for the current
inventory. If it's 0 or wildly short of expected, run:

```bash
ansible-playbook playbooks/stage_router.yml
```

### A.4 — SPI persist preconditions

Phase 2b imports `persist_uboot_env.yml`. The play is SPI-only-gated, but
SPI boards need their `local_kernel.persist_via` setting compatible. Quick
check:

```bash
ansible-inventory --host <spi-board> --list 2>/dev/null \
  | jq -er '.armbian_local_kernel.persist_via'
```

- SPI boards (rock-5b etc., `armbian_board_config_model.uboot_env.storage: spi_flash` in `inventory/group_vars/<model_group>.yml` (e.g. `rock_5b.yml`)):
  expect `spi` here (or unset — defaults to `hook` which is fine).
- Non-SPI boards (opi5max etc., `uboot_env.storage: nowhere`):
  must be `hook` (set in inventory). Setting it to `spi` will fail
  `persist_uboot_env.yml`'s validation assertion.

### A.5 — Free space on netboot_server

Phase 1 force-recreates per-host NFS clones. Each clone is ~2 GB on the
first run; reflink on XFS/btrfs/ZFS makes subsequent ones near-zero.
Still, leave headroom:

```bash
ansible netboot_server -m shell -a "df -h $(ansible-inventory --list | jq -r '.all.vars.armbian_nfs_rootfs_path') 2>&1 | tail -1"
```

A full NFS dataset → rootfs_provision fails mid-flight. Cap previous
campaigns' leftover dirs (`/mnt/ssd/netboot/rootfs/<old-board>/`) first.

### A.6 — Controller has SSH keys to everywhere

The fleet run delegates to: boards, netboot_server, rb5009 (router), and
each PoE switch. The pre-flight play strips stale known_hosts then
bypasses host-key checking for the run, but the SSH **key** itself must
be authorised on every target. Quick sweep:

```bash
ansible boards:netboot_server:routeros_switch:routeros_router -m ping 2>&1 \
  | grep -E "FAILED|UNREACHABLE|SUCCESS" | sort | uniq -c
```

All `SUCCESS`? Good. Any failures? Fix before running — bootstrap_armbian
will install the inventory user inside Phase 2/4, but it can only do so
if password-as-root SSH works (which requires the host key to not be
stale and the network path to be alive).

## Phase B — Running the fleet test

The wrapper is `.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh`. It creates a per-run
artifact directory, tees ansible output, archives the per-board
`/tmp/iter-FLEET-<host>/` dirs, and saves the Summary table. The plain
playbook works too — the wrapper just adds artifact bookkeeping.

### B.1 — Full fleet, default target group

```bash
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh
```

That's it. Expect 25-45 min wall time for a 5-board fleet (Phase 5 is
the long pole — NVMe rsync at `throttle: 2`). Artifacts land at
`/tmp/fleet-run-<timestamp>/`.

### B.2 — Subset of boards

```bash
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts opi5pro-01,rock-5b-01
```

**Always use `--target-hosts`, not `--limit`.** The playbook delegates
to netboot_server / rb5009 / PoE switches; `--limit` silently empties
those plays. The wrapper translates `--target-hosts` to
`-e target_hosts=<csv>` which the playbook respects across delegations.

### B.3 — Single-board first run (recommended after any major change)

```bash
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts <one-board>
```

8-12 min. Use this to validate `disk_image` / `disk_provision` changes
before sweeping the whole fleet.

### B.4 — Skip phases (resume / partial re-run)

```bash
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --skip 0,1
```

Translates each phase number to `-e skip_phase_<N>=true`. Useful when
you've already proven the upstream phases on a prior run and want to
re-test only the later ones. Skipping Phase 1 (NFS reset) means you're
trusting the existing per-host NFS clones — the deterministic guarantee
weakens accordingly.

### B.5 — Forensic mode (preserve state for debugging)

Phase failures leave per-host `/tmp/iter-FLEET-<host>/` dirs intact on
the controller (they're never auto-cleaned). The relevant per-phase
artifact dir holds the evidence file from the last successful sub-step.
For Phase 2/4/5 failures, `_lifecycle_set_and_verify`'s diagnostic
bundle is at `./diagnostics/<host>-<timestamp>/` — that's where to look
first.

### B.6 — Knobs the wrapper passes through

After `--`, extra `-e` args go straight to ansible-playbook:

```bash
# Bump per-phase SSH wait timeout
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh -- -e armbian_post_boot_wait_timeout=600

# Reduce throttle to fully serial for Phase 5
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh -- -e fleet_phase_5_throttle=1

# Bump PoE drain (rock-5b SD voltage-select reliability)
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh -- -e armbian_poe_cycle_delay=45
```

## Phase C — Interpreting the run

### C.1 — Summary table (printed at end of run)

```
=== Deterministic fleet test per-phase wall times (seconds) ===

Board                            0      1      2      3      4      5     Total
──────────────────────────────  ────   ────   ────   ────   ────   ─────  ─────
opi5pro-01.igou.systems          15     45     180    220    175    870    1505
rock-5b-01.igou.systems          15     -      -      -      -      -      15
```

- All six columns populated → board converged through every phase.
- A `-` in a column → that phase was skipped, or the board failed
  earlier and never reached it.
- Total roughly tracks: Phase 0 ≈ 15s, Phase 1 ≈ 45s/model, Phase 2 ≈
  3 min/board, Phase 3 ≈ 3-5 min/board (network-bound),
  Phase 4 ≈ 3 min/board, Phase 5 ≈ 15 min/board throttled.

A single-board failure shouldn't kill the fleet — Ansible's default
per-host failure handling drops the failed board from subsequent plays
while survivors continue.

### C.2 — Per-board artifacts

`/tmp/iter-FLEET-<host>/` after a fleet run:

```
0-poe-down/poe-down-evidence.txt
1-nfs-reset/nfs-reset-evidence.txt
2-nfs-bootstrap/nfs-bootstrap-evidence.txt
3-dd-sd/dd-sd-evidence.txt
4-sd-bootstrap/sd-bootstrap-evidence.txt
5-nvme-localkernel/nvme-localkernel-evidence.txt
timing.tsv
```

`timing.tsv` is the per-board timing source; `phase\tstart_epoch\tend_epoch\tduration_s`.
Evidence files are human-readable — open them in a text editor and read
top to bottom.

### C.3 — Aggregated run dir (when using the wrapper)

`/tmp/fleet-run-<timestamp>/` after a wrapper run:

```
meta.txt              # invocation: timestamp, target_hosts, skip flags, args
e2e.log               # full ansible stdout+stderr (tee'd)
summary.txt           # the Summary table extracted from e2e.log
boards/<host>/        # snapshot of each board's /tmp/iter-FLEET-<host>/ dir
```

This is what you keep / archive / attach to a PR. The per-host
`/tmp/iter-FLEET-*/` dirs persist on the controller across runs and get
overwritten on the next run; the per-run dir is the durable record.

### C.4 — When all phases pass

The deterministic flow is working end-to-end. The board ends booted on
NVMe in `local_kernel` mode with TFTP HITS for vmlinuz unchanged across
the Phase 5 cycle (proof U-Boot used baked localcmd from SPI, not PXE).
Subsequent regular workflows (`converge_boot_mode.yml`, ad-hoc operations)
can run against the same fleet without touching the e2e harness.

## Phase D — When a phase fails

Each phase's failure has a different recovery route. Triage from the
PLAY RECAP outward.

### D.0 — Phase 0 (PoE down)

Failure mode: the RouterOS command `/interface ethernet poe set ... poe-out=off`
errored, or the switch was unreachable.

- Check `armbian_poe_switch` is in `routeros_switch` group.
- Check the switch is on the network: `ansible <switch> -m community.routeros.command -a 'commands="/system identity print"'`.
- Wrong port name? `armbian_poe_port` must match the switch's `/interface print` output exactly.
- One board's failure here doesn't poison the rest — Phase 1 still
  runs against survivors.

### D.1 — Phase 1 (NFS reset)

Failure mode: `rootfs_provision` errored (xz/loop/rsync/identity-reset) on netboot_server.

- `xz` failed → the image URL is unreachable from netboot_server (A.2),
  or the .img.xz is corrupt — try a fresh download outside of ansible.
- `losetup` failed → the netboot_server is out of free loop devices
  (rare; clears on netboot_server reboot) or `mount` capability is
  missing (check `lsmod | grep loop`).
- `rsync` mid-stream → disk space (A.5). Free `/mnt/ssd/netboot/rootfs/_templates/<old-model>/`
  dirs from removed-from-inventory boards.
- `cp --reflink=auto` falling back to full copy → expected when the
  NFS dir filesystem doesn't support CoW (ext4). Slower, not broken.

Boards stay powered off the whole time, so a Phase 1 failure has zero
hardware blast radius. Fix and re-run with `--skip 0` to keep the fleet
powered-off rather than re-cycling.

### D.2 — Phase 2 (NFS boot + bootstrap + SPI persist)

Failure mode: `_lifecycle_set_and_verify` failed (board didn't PXE-boot to NFS in time), or `bootstrap_armbian` failed, or `persist_uboot_env` failed on `fw_setenv`.

- **Board didn't PXE-boot**: classic SPI-broken signature on rock-5b
  (stuck at `=>` prompt with no autoboot countdown). Invoke
  `recovering-uboot-spi-state` skill for that board, then re-run the
  fleet test with that one board first to confirm.
- **bootstrap_armbian "Permission denied (publickey,password)"**: the
  fresh NFS clone doesn't have the default Armbian password
  (`armbian_default_password`, typically `1234`). Either the
  upstream image changed its default, or someone customised the template
  manually. Check the `.img.xz` URL hasn't moved.
- **bootstrap_armbian SSH unreachable**: board may have hit Armbian's
  first-boot password+username prompt. The `running-fleet-e2e-test`
  flow shouldn't hit this (the canonical image build disables
  first-boot setup), but if it does, see the fresh-board recipe in
  `recovering-uboot-spi-state`.
- **persist_uboot_env fw_setenv error**: `/dev/mtd*` not present (SPI
  hardware fault), or `/etc/fw_env.config` mismatch with the actual SPI
  layout. Diagnostic bundle has the relevant logs.
- Auto-revert lands the board back on NFS (or NFS-stays-on-NFS for
  self-revert). Board is reachable; serial/SSH diagnostics are
  available for the operator.

### D.3 — Phase 3 (dd canonical SD)

Failure mode: `disk_image` role failed — curl 404, xz CRC, dd write error, or the role's mount-aware guard fired.

- **curl 404**: the URL is unreachable from the board (A.2). Note that
  netboot_server can reach the URL but the board's DNS or routing
  differs.
- **xz CRC error**: corrupt download mid-stream. Re-run Phase 3 alone:
  `--skip 0,1,2`.
- **dd write error**: SD card hardware fault (bad sectors). Replace the
  SD card. The role's always-write contract means re-running on a fresh
  card is a clean retry.
- **Mount-aware guard**: "target device backs a mounted filesystem".
  This means the board was somehow booted off the SD card by the time
  Phase 3 ran — likely Phase 2's NFS verify passed spuriously. Read
  `2-nfs-bootstrap/nfs-bootstrap-evidence.txt` to confirm Phase 2's
  rootfs assertion saw NFS.

### D.4 — Phase 4 (SD boot + bootstrap)

Failure mode: `_lifecycle_set_and_verify` failed (board can't boot from the canonical image), or `bootstrap_armbian` failed on the SD-booted board.

- **Board boots from SD but rootfs assertion fails**: the canonical
  image's rootfs is on a different device-node than `LABEL=armbi_root`
  expects. Check `armbian_sd_root` per-host override.
- **Board doesn't boot from SD at all**: the canonical .img.xz's U-Boot
  binary is broken or has the wrong BOOT_TARGETS. Re-build via
  `image_build.yml`.
- **bootstrap_armbian fails**: same diagnoses as Phase 2's bootstrap
  step, but now against SD content.
- Auto-revert lands the board back on NFS — operator has full SSH
  access to debug.

### D.5 — Phase 5 (NVMe reprovision + local_kernel)

Most complex failure surface. Triage by sub-step:

- **NFS converge sub-step fails**: same as Phase 2 (we've been here
  before — board can't PXE-boot to NFS). SPI broken; see D.2.
- **`disk_provision` rsync stalls**: NFS server-side concurrency is
  saturated. Drop `fleet_phase_5_throttle=1` (fully serial) and re-run
  with `--skip 0,1,2,3,4`.
- **`disk_provision` partprobe fails**: kernel can't re-read the
  partition table mid-flight. Usually transient; re-run.
- **local_kernel converge fails verify**: rootfs isn't on NVMe.
  Diagnostic bundle has `findmnt /` output. Most common cause: the
  U-Boot `localcmd` env isn't loading from NVMe (it's TFTP-fetching
  instead). Check Phase 5's TFTP HITS — if non-zero delta, that's the
  smoking gun.
- **TFTP-flat assertion fails (`HITS delta > 0`)**: U-Boot is still
  PXE-fetching the kernel. Either the baked `localcmd` isn't in the
  U-Boot binary (image_build hook didn't fire) or it's not in SPI
  (Phase 2's persist_uboot_env didn't write it). Read `2-nfs-bootstrap`
  evidence to confirm Phase 2's SPI persist ran for this board.

## Phase E — Closing the loop

### E.1 — Archival

The aggregated `/tmp/fleet-run-<timestamp>/` is the durable record. For
PR validation runs, attach it to the PR (or paste `summary.txt` + the
PLAY RECAP into the PR description).

### E.2 — Drift detection

If a previously-passing fleet starts failing at Phase 2 or Phase 5,
something in the canonical image or the netboot infrastructure has
drifted. Most likely culprits:

- A new Armbian release moved package versions in the .img.xz.
- The NFS export's `_templates/<model>/` got partially overwritten by a
  manual operator op.
- A board's SPI got reset (factory-restore on the switch, accidental
  `sf erase`).

Phase 1's force_refresh + Phase 2's persist_uboot_env are designed to
self-heal most of these. A Phase 2 failure after a force_refresh implies
the **source image itself** has changed in a way that broke autonomous
PXE — investigate `image_build.yml` outputs.

### E.3 — Per-board tracker integration (optional)

For boards with a `board-tracker` GitHub issue (per-board reliability
campaigns), append a fleet-run reference comment manually:

```bash
gh issue comment <tracker> --body "$(cat <<EOF
Fleet-run $(date -u +'%Y-%m-%d') validated this board in the deterministic 6-phase flow.

\`\`\`
$(tail -20 /tmp/fleet-run-<timestamp>/summary.txt)
\`\`\`
EOF
)"
```

This is hand-driven (no wrapper automation) because fleet runs cover
multiple boards and the per-board tracker model doesn't 1:1 with them.

## Common mistakes

| Mistake | Cost | Avoid by |
|---|---|---|
| Use `--limit` instead of `--target-hosts` | Delegated plays (netboot_server, router, switches) silently get no hosts; the fleet test fails in confusing ways | Always `--target-hosts <csv>` in the wrapper, or `-e target_hosts=<csv>` directly |
| Run the playbook without pre-flight probes | Phase 1 fails on disk-full or URL-unreachable after wasting Phase 0's PoE-down + Phase 2's NFS converge | Phase A probes are 3 minutes; saves 20+ on a failed full run |
| Re-run a failed run with the same SD card | Phase 3 dd error on bad SD blocks repeats verbatim; the "always-write" contract doesn't compensate for hardware faults | Replace the SD card on a Phase 3 dd-write failure; the canonical image is fine, the media isn't |
| Trust the Summary table on a partial run | Boards that failed early show `-` in later columns; that's not "they passed those phases by skip" — they never reached them | Cross-check Summary with `grep "PLAY RECAP" /tmp/fleet-run-<ts>/e2e.log -A1` to see which boards actually failed |
| Skip Phase 1 (NFS reset) routinely | The deterministic guarantee weakens; cross-iteration drift can re-enter the loop | Use `--skip 1` only when you've just run Phase 1 in a prior run and the fleet has stayed powered-off since |
| Run with stale `stage_router.yml` state | Phase 5's TFTP-flat check fails on missing `/ip tftp` rows even though the rest of the run is fine | Pre-flight A.3 catches this; re-run `stage_router.yml` first |
| Mix-and-match `armbian_local_kernel.persist_via` against `uboot_env.storage` | Phase 5 local_kernel boot fails on either: SPI board with `persist_via: hook` (localcmd never written to SPI), or NOWHERE board with `persist_via: spi` (persist_uboot_env assertion fires) | Pre-flight A.4 catches both; `inventory/group_vars/<model_group>.yml`'s `armbian_board_config_model.uboot_env.storage` is authoritative |
| Run the fleet test against a board that's mid-recovery (`recovering-uboot-spi-state`) | Phase 2 will fail at boot-verify; you waste the slot debugging the wrong layer | Finish the per-board recovery skill first, then run the fleet test with `--target-hosts <that-board>` first to confirm before sweeping |
| Forget to push image changes before running | Phase 1 pulls a stale `.img.xz`; Phase 3's dd writes the wrong content; everything passes verify but the fleet ends up on yesterday's image | After `image_build.yml`, confirm the new image is published before kicking off the fleet test |

## Quick reference

```bash
# Pre-flight probes (Phase A)
ansible <board> --list-vars | grep armbian_
ansible <board> -m debug -a 'var=armbian_rootfs_src'  # per-host rootfs source probe
ansible <armbian_router> -m community.routeros.command -a 'commands="/ip tftp print count-only"'
ansible boards:netboot_server:routeros_switch:routeros_router -m ping | grep -E "FAILED|UNREACHABLE|SUCCESS" | sort | uniq -c

# Full fleet
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh

# Single board first
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts opi5pro-01

# Two boards
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --target-hosts opi5pro-01,rock-5b-01

# Skip already-proven phases
.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh --skip 0,1

# Bypass the wrapper (full control)
ansible-playbook playbooks/tests/test_fleet_e2e.yml -e target_hosts=opi5pro-01

# Re-read per-board artifacts
ls /tmp/iter-FLEET-<host>/
cat /tmp/iter-FLEET-<host>/timing.tsv

# Aggregated run artifact (from the wrapper)
cat /tmp/fleet-run-<timestamp>/summary.txt
cat /tmp/fleet-run-<timestamp>/e2e.log

# Find diagnostic bundle for a Phase 2/4/5 failure
ls -la ./diagnostics/<host>-*/

# Confirm U-Boot baked localcmd is working (Phase 5 evidence)
grep "delta=" /tmp/iter-FLEET-<host>/5-nvme-localkernel/nvme-localkernel-evidence.txt
```

## Cross-references

- `playbooks/tests/test_fleet_e2e.yml` — the six-phase deterministic fleet test orchestrated by this skill.
- `.claude/skills/running-fleet-e2e-test/scripts/run-fleet-e2e.sh` — wrapper that creates per-run artifact dirs + archives per-board state + saves the Summary.
- `playbooks/persist_uboot_env.yml` — imported as Phase 2b; idempotent SPI env converge (no-op for non-SPI boards).
- `playbooks/stage_router.yml` — pre-requisite; populates rb5009's `/ip tftp` rows.
- `playbooks/stage_netboot_assets.yml` — pre-requisite; runs `rootfs_provision` initially (Phase 1 is the deterministic re-run with force_refresh).
- `playbooks/tasks/_lifecycle_set_and_verify.yml` — the converge + verify primitive used in Phases 2/4/5, with auto-revert on failure + diagnostic bundle.
- `roles/disk_image/` — the role consumed in Phase 3 for the SD imaging step.
- `roles/disk_provision/` — the role consumed in Phase 5 for NVMe wipe + repartition + rsync.
- `roles/bootstrap_armbian/` — the role consumed in Phases 2 and 4 to install the inventory user from a fresh-image starting state.
- `docs/superpowers/specs/2026-05-19-deterministic-fleet-e2e-design.md` — design spec for the six-phase flow.
- `docs/superpowers/plans/2026-05-19-deterministic-fleet-e2e.md` — implementation plan.
- `docs/end-to-end-fleet-test.html` — historical operator runbook (some content predates the deterministic refactor; section markers updated for the new structure).
- `recovering-uboot-spi-state` skill — invoked when Phase 2 fails on a stuck-SPI board.
- `adding-armbian-board` skill — usually run before this skill on a new board's first fleet entry.
- `playbooks/tests/test_hardware_e2e.yml` — per-board reliability iteration harness; complementary to (not replaced by) the fleet test.
