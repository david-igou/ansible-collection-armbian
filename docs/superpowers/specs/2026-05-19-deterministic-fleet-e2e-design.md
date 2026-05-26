# Deterministic fleet e2e — design

**Date**: 2026-05-19
**Status**: Approved (brainstorming complete; implementation plan TBD)
**Supersedes**: nothing structurally, but replaces the Phase 0/A/B/C/C2/D structure inside `playbooks/test_fleet_e2e.yml`.
**Motivating context**: the existing fleet e2e validates that the boot-mode-transition machinery works, but presumes a clean-ish starting state on each board. Cross-iteration drift (machine-id, SSH host keys, leftover files, stale SPI env) was flagged during validation runs and partially addressed by the `disk_image` role's Phase 0 dd-to-SD step. The deterministic e2e closes the loop: every layer of state (NFS rootfs, SD content, SPI env, NVMe content) is force-recreated before the test exercises it, so an unclean prior-run state cannot poison the next iteration.

## Goal

Replace `playbooks/test_fleet_e2e.yml`'s current phase structure with a six-phase deterministic flow that resets every state layer before validating the corresponding boot mode. Each phase produces a known-clean state for the next. A single canonical fleet test, no "operator-mode" pre-flight shortcuts (no manual igou injection into NFS; `bootstrap_armbian` is the single source of truth for igou).

Out of scope: apt-kernel-update mechanism check (current Phase D — removed; can return as a separate playbook if needed). Recovery of boards with broken SPI that can't reach Linux (operator runs `recovering-uboot-spi-state` skill manually before the e2e).

## Architecture — six phases (0 through 5)

| Phase | Runs on | Produces |
|---|---|---|
| **0 — PoE down** | boards | All target boards powered off; no live rootfs at risk during Phase 1's NFS reset |
| **1 — NFS reset** | netboot_server | Fresh per-model NFS template + fresh per-host NFS clones (force_refresh on both `image_extract` and `rootfs_clone`) |
| **2 — NFS boot + bootstrap + SPI persist** | boards | Boards on freshly-cloned NFS, igou bootstrapped, SPI env converged (no-op for non-SPI boards) |
| **3 — SD imaging via `disk_image`** | boards | `/dev/mmcblk0` carries a fresh canonical image (streamed `xz \| dd` from `armbian_image_urls[<model>]`) |
| **4 — SD boot + bootstrap** | boards | Boards on freshly-dd'd SD, igou bootstrapped |
| **5 — NVMe reprovision + local_kernel verify** | boards | Boards on freshly-rsync'd NVMe rootfs in `local_kernel` mode; TFTP HITS for vmlinuz remain flat across cycle (proof U-Boot used baked localcmd, not PXE) |

Single invariant: every phase's "produces" column is what the next phase relies on, so a board that drops out at Phase N leaves the fleet with explicit per-board phase-N artefacts and the run continues for the survivors.

## Per-phase contract

### Phase 0 — PoE down

- `hosts: "{{ target_hosts | default('boards') }}"`, `gather_facts: false`
- Single task: PoE-off via the existing `routeros/tasks/poe_cycle.yml` "off + drain" half (use the resolved `armbian_poe_cycle_delay` host fact for the drain duration).
- No SSH waits — boards may be wedged or unreachable; we just cut power.
- Rationale: if any target board is currently NFS-booted from a prior run, force-refreshing the NFS clone in Phase 1 would yank the running rootfs out from under it.

### Phase 1 — NFS reset

- `hosts: netboot_server`, `become: true`
- `include_role: image_extract` looped over unique models from `target_hosts` (not the full `boards` group — so a single-board run only re-extracts that board's model), each call with `force_refresh: true`.
- `include_role: rootfs_clone` looped over `target_hosts`, each call with `force_refresh: true`.
- Produces: fresh `_templates/<model>/` + fresh `<board>/` NFS dirs with reset machine-id, hostname, SSH host keys, and **no igou user** (canonical Armbian rootfs has only root + `armbian_default_password`).

### Phase 2 — NFS boot + bootstrap + SPI persist

- `hosts: "{{ target_hosts | default('boards') }}"`
- Sub-step a: `include_tasks: tasks/_lifecycle_set_and_verify.yml` with `target_boot_mode: nfs`, `on_failure_revert_to: sd`. This writes pxelinux.cfg, PoE-cycles, waits for TCP/22.
- Sub-step b: `include_role: bootstrap_armbian` with inline `ansible_user: root` + `ansible_password: "{{ armbian_default_password }}"` + `ansible_ssh_common_args` host-key bypass + `ansible_become: false`. **Unconditional** — no `auto_bootstrap_if_needed` probe, because the fresh NFS clone is guaranteed to lack igou.
- Sub-step c: `ansible.builtin.meta: reset_connection` (so subsequent tasks pick up the new igou identity).
- Sub-step d: `import_playbook: persist_uboot_env.yml` with `armbian_persist_uboot_env_cycle: false`. The play is SPI-only-gated (`end_host` when `uboot_env.storage != 'spi_flash'`) and idempotent (drift detection via `fw_printenv -n`), so non-SPI boards are no-ops. Writing `localcmd` here ensures Phase 5's local_kernel mode has correct SPI env. **Implementation note**: `import_playbook` cannot live inside a `tasks:` block, so Phase 2 splits into two plays (2a: lifecycle + bootstrap + verify; 2b: `import_playbook: persist_uboot_env.yml`). The Summary play treats them as one phase row (`2`) — the timing TSV captures the combined wall time.
- Sub-step e: `include_role: board_boot_verify` with `boot_mode: nfs` to assert rootfs is on NFS.
- Evidence file + timing.

### Phase 3 — SD imaging via `disk_image`

- `hosts: "{{ target_hosts | default('boards') }}"` (reachable as igou over NFS)
- Single `include_role: disk_image` with:
  - `image_source: "{{ armbian_image_urls[armbian_board_model] }}"`
  - `target_device: "{{ armbian_sd_device | default('/dev/mmcblk0') }}"`
- The role's mount-aware guard implicitly verifies we're not booted off SD.
- Evidence file + timing.

### Phase 4 — SD boot + bootstrap

- `hosts: "{{ target_hosts | default('boards') }}"`
- Sub-step a: `include_tasks: tasks/_lifecycle_set_and_verify.yml` with `target_boot_mode: sd`, `on_failure_revert_to: nfs`.
- Sub-step b: `include_role: bootstrap_armbian` with the same connection overrides as Phase 2.
- Sub-step c: `meta: reset_connection`.
- Sub-step d: `include_role: board_boot_verify` with `boot_mode: sd` to assert rootfs is on a local block device.
- No SPI persist here — Phase 2 already converged SPI for boards that need it, and SPI doesn't change between boot modes.
- Evidence file + timing.

### Phase 5 — NVMe reprovision + local_kernel verify

- `hosts: "{{ target_hosts | default('boards') }}"`, `throttle: "{{ fleet_phase_5_throttle | default(2) | int }}"`
- Sub-step a: `include_tasks: tasks/_lifecycle_set_and_verify.yml` with `target_boot_mode: nfs`, `on_failure_revert_to: nfs` (need NFS rootfs as the rsync source). Self-revert is intentional — the helper requires `on_failure_revert_to` but if NFS converge itself fails there's no healthier mode to revert to; we want the diagnostic bundle + hard fail, not silent fallback. Matches the current Phase C pattern.
- Sub-step b: re-gather mount facts; assert `/` is on NFS (cross-binding guard).
- Sub-step c: cross-binding validate of `armbian_local_disks` (preserved from current Phase C — assert no duplicate mount paths, exactly one `/`).
- Sub-step d: `include_role: disk_provision` looped over `armbian_local_disks` — wipes + repartitions NVMe + rsyncs NFS rootfs into it.
- Sub-step e: `include_tasks: tasks/_lifecycle_set_and_verify.yml` with `target_boot_mode: local_kernel`, `on_failure_revert_to: nfs`.
- Sub-step f: record TFTP HITS before and after the local_kernel cycle (delegated to the router); assert delta == 0 (TFTP-flat proof that U-Boot used baked localcmd, not PXE).
- Evidence file + timing.

## What's dropped vs preserved (relative to current `test_fleet_e2e.yml`)

### Dropped

- Phase A (current SD boot + auto_bootstrap_if_needed) → replaced by Phase 4
- Phase B (current NFS boot + auto_bootstrap) → replaced by Phase 2
- Phase D (current apt kernel update) → removed
- Pre-flight play "ensure igou user + key on each per-host NFS rootfs" — removed; `bootstrap_armbian` in Phase 2 owns igou creation
- `auto_bootstrap_if_needed.yml` shortcut — removed; the fresh NFS clone and fresh SD are *known* to lack igou, so unconditional `bootstrap_armbian` is the right contract
- Phase 0 (the dd-to-SD preflight added with the `disk_image` role) — its role moves into Phase 3 within the new flow; `skip_dd_sd` flag goes away

### Preserved

- `target_hosts | default('boards')` for single-board runs
- Pre-flight known_hosts cleanup + `ansible_ssh_common_args` bypass (boot-mode transitions still swap host keys)
- Pre-flight `set_fact` resolution of `armbian_boot_retry_attempts` + `armbian_poe_cycle_delay` defaults
- Per-phase artifact dirs `/tmp/iter-FLEET-<host>/<phase>/` + `timing.tsv` lineinfile pattern
- Final Summary play with per-board per-phase wall-time table (numbering becomes `0  1  2  3  4  5  Total`)
- `throttle: 2` on Phase 5 (NVMe rsync contention guard, tunable via `-e fleet_phase_5_throttle=N`)
- `_lifecycle_set_and_verify.yml` diagnostic-bundle-on-failure + auto-revert
- `skip_phase_<N>` flags so operators can re-run partial sequences
- Per-board `armbian_local_disks` for NVMe layout (consumed by `disk_provision` in Phase 5)

## Failure modes

| Failure | Where it surfaces | Behavior |
|---|---|---|
| Board PoE-stuck on (Phase 0 PoE-off fails) | Phase 0 | Per-host failure; fleet continues. PoE primitive is idempotent — sets `poe-out=off` regardless of current state. If the switch itself is unreachable, the task fails for that host. |
| `image_extract` fails to fetch `.img.xz` URL | Phase 1 | Play fails on netboot_server. No boards have been disturbed yet (still PoE-off from Phase 0). |
| `rootfs_clone` reflink fails (NFS dir on ext4, no CoW) | Phase 1 | Falls back to full `cp -a` per the role's existing logic. Slower but correct. |
| Board fails to boot from NFS in Phase 2 | Phase 2 `_lifecycle_set_and_verify` | Diagnostic bundle captured, auto-revert to `sd`, play fails for that host. Caveat: if the board's SD is also broken, the revert leaves it wedged — operator recovery problem. |
| `bootstrap_armbian` Phase 2 fails (default password rejected) | Phase 2 | Role-level fail. Fresh NFS clone should have default password by construction; this fail hints at deeper drift in the source `.img.xz`. |
| `persist_uboot_env` fails (`/dev/mtd*` not readable, fw_setenv write error) | Phase 2 sub-step d | Play fails for that host. NFS rootfs is still healthy; operator can intervene manually (UART, re-flash SPI). Other boards proceed. |
| `disk_image` Phase 3 fails (curl 404, dd write error, SD bad sectors) | Phase 3 | Role fails per its own contract. Board still on NFS. Re-run Phase 3 is safe (always-write contract). |
| Phase 4 SD boot fails (board can't boot from canonical image) | Phase 4 `_lifecycle_set_and_verify` | Auto-revert to `nfs`. Diagnostic bundle. |
| Phase 5 NVMe `disk_provision` rsync stalls | Phase 5 | `throttle: 2` default. Tunable. Ansible task timeout eventually kicks in for per-board stalls. |
| Phase 5 local_kernel TFTP-flat check fails (HITS incremented across cycle) | Phase 5 sub-step f | Hard fail. Means baked `localcmd` isn't in U-Boot binary or SPI env. Implies `image_build` or `persist_uboot_env` drift; investigate those. |
| Single-host failure | All phases | Ansible default: when one host fails, others continue. Per-host artifact dirs isolate evidence. Summary play renders `-` for missing phases on failed hosts. |

The biggest design risk: Phase 2 is the first time we actually boot the board after a wholesale state reset. If the board has stuck SPI (skill: `recovering-uboot-spi-state`), Phase 2 will fail and operator intervention is needed. This is acceptable: the e2e is for *converging* a healthy fleet, not for first-contact recovery.

## Migration impact

- `-e skip_dd_sd=true` flag (added with `disk_image` role) goes away. Replaced by `-e skip_phase_3=true`. Pattern: `skip_phase_0` through `skip_phase_5`.
- `-e fleet_phase_c_throttle=N` → `-e fleet_phase_5_throttle=N` (rename only).
- `armbian_kernel_target` host fact + `kernel_update_pin` / `kernel_pkg` `-e` vars become unused (Phase D dropped). Inventory entries setting these still work, just have no effect in this playbook.
- Total wall time should land within ±1-2 minutes of the current 30-min run: Phase 1 force_refresh adds ~30-60 s per model, Phase 0 PoE-off adds ~15 s, but we save the dd-twice case (current Phase 0 + Phase A boot now becomes Phase 3 + Phase 4 boot — same work).
- The `Shipped: dd a known image to SD` HTML section in `docs/end-to-end-fleet-test.html` needs a follow-up update — it now references the deterministic e2e flow as the canonical location for that dd, not a Phase 0 of the old structure.

## Verification

1. **Lint + syntax-check**: `make lint` + `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml` clean.
2. **Single-board hardware run**: `ansible-playbook playbooks/test_fleet_e2e.yml -e target_hosts=<one-board>`. Expected: all six phases (0-5) complete with evidence files + summary table showing per-phase timing. Board ends in `local_kernel` mode on NVMe.
3. **Subset run from a known-broken state**: deliberately leave a board in a weird state (stale SD content + stale NFS rootfs from a prior failed run + uncommon SPI env), then run the playbook. Expected: Phase 0-1 reset everything that's broken, Phase 2 (with SPI persist sub-step) re-converges SPI, board converges normally.
4. **Two-board parallel run**: `target_hosts=opi5pro,rock-5b` to confirm Phase 5 `throttle: 2` works and Phase 0/1 reset properly with multiple boards in flight (including an SPI board and a non-SPI board to exercise the persist_uboot_env gating).
5. **`disk_provision_loopback` molecule scenario**: unchanged, still passes (we didn't touch the role).

No new molecule scenarios. The playbook orchestrates existing roles whose molecule tests already cover their individual behavior. The playbook itself is hardware-only.

## File layout

- Modify: `playbooks/test_fleet_e2e.yml` (full rewrite preserving the file path so `-e target_hosts=...` invocations don't change). Includes:
  - Top docstring rewritten to describe Phases 0-5 and the determinism contract (replaces the Phase 0/A/B/C/C2/D commentary).
  - Usage examples updated: `skip_phase_3=true` replaces `skip_dd_sd=true`; the kernel-update override example goes away.
  - The new structure may end up at ~7-9 plays (Phase 0; Phase 1; Phase 2a + 2b; Phase 3; Phase 4; Phase 5; Summary), so a section comment per play boundary helps readability.
- Modify: `docs/end-to-end-fleet-test.html` — update the "Shipped: dd a known image to SD" section to reference the new deterministic flow's Phase 3 + Phase 2 SPI persist (not the old Phase 0). Also update any prose that still references Phase A/B/C/D phase numbering.
- Modify: `CLAUDE.md` "Running playbooks" section if it documents test_fleet_e2e specifically (skim for stale references to Phases A/B/C/D).

No new files. No new roles.
