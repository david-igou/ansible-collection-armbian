# Collection playbook fixes (E2E run on opi5pro-01 surfaced)

**Date:** 2026-05-31
**Status:** Draft, awaiting user approval

## Problem

Running `playbooks/tests/test_hardware_e2e.yml --limit opi5pro-01.igou.systems`
surfaced three independent collection-level issues:

1. **Include-path bug** — `playbooks/tasks/render_and_upload_pxelinux.yml:39`
   used `{{ playbook_dir }}/routeros/tasks/upload_pxelinux_one.yml`. When the
   task file is included from a playbook under `playbooks/tests/`, `playbook_dir`
   resolves to `playbooks/tests/`, and the path becomes the non-existent
   `playbooks/tests/routeros/tasks/upload_pxelinux_one.yml`. The bug has been
   present since v3.0.0; it only surfaces when `render_and_upload_pxelinux.yml`
   is included from outside `playbooks/`.

2. **`--limit` footgun on composite playbooks** — `playbooks/converge_boot_mode.yml`
   and other multi-play playbooks target different host groups in different
   plays (router for plumbing-check + upload, boards for render + cycle, etc.).
   `--limit` is global, so a user running e.g.
   `ansible-playbook converge_boot_mode.yml --limit opi5pro-01.igou.systems`
   gets the board-side plays but the router-side plays silently match no hosts
   and skip. The playbook docstring documents `-e target_hosts=…` as the
   correct invocation, but there is no runtime guard. We tripped on this during
   board recovery in the same session.

3. **`test_hardware_e2e.yml` hardcodes `sd` as the baseline mode** — Pre-flight,
   Phase 3, and Cleanup converge router pxelinux to `default sd`. Boards
   configured in inventory as `armbian_boot_mode: local_kernel` (i.e. boards
   with NVMe `armbi_root_local` and no working `armbi_root` SD card) cannot
   boot the SD label, so Phase 1 and Cleanup time out at 181 s waiting for
   TCP/22. The harness's existing `skip_baseline=true` only skips Phase 1; it
   does not help Phase 3 or Cleanup.

## Goal

Land the three fixes as a single PR-shaped change so anyone running E2E on a
local_kernel-only board succeeds end-to-end, and anyone running a composite
playbook with `--limit` instead of `-e target_hosts=…` gets a clear, immediate
error.

Out of scope: backporting to maintenance branches; adding a `local_kernel`
variant test playbook (single mode-parameterised harness is enough); reworking
the `bootflow scan` vs `distro_bootcmd` ordering question (the board boots via
PXE today when pxelinux.cfg's `default` label is a non-`localboot` label, so
that hypothesis isn't load-bearing for this fix).

## Non-goals

- Detect `--limit` directly from env or argv. Ansible exposes neither cleanly;
  the chosen mechanism is inventory vs play-host count comparison, which is
  the strongest signal we can get from inside a play.
- Refactor `render_and_upload_pxelinux.yml` further than the one-line path
  fix. The wider question of "should `playbook_dir` ever be used inside task
  files in `playbooks/tasks/`" can be a follow-up.

## Design

### Fix 1: include-path (already applied in session)

Change the line:

```yaml
# was
ansible.builtin.include_tasks: "{{ playbook_dir }}/routeros/tasks/upload_pxelinux_one.yml"
# now
ansible.builtin.include_tasks: ../routeros/tasks/upload_pxelinux_one.yml
```

Relative paths in `include_tasks` are resolved relative to the file containing
the `include_tasks` statement. The pattern already exists in
`playbooks/tasks/cold_boot_with_retry.yml` (`include_tasks: cold_boot_single_attempt.yml`)
so this matches established usage. A short comment notes the rationale
(playbook_dir varies by caller).

Bundle in the same commit as the other fixes.

### Fix 2: `--limit` footgun guard

Add a shared assertion task file `playbooks/tasks/_assert_no_limit.yml`
parameterised by `_expected_pattern` (the inventory pattern the calling
playbook expects to fully resolve):

```yaml
- name: Assert play matched all hosts in '{{ _expected_pattern }}' (refuse --limit)
  ansible.builtin.assert:
    that:
      - (query('inventory_hostnames', _expected_pattern) | length)
        == (ansible_play_hosts_all | length)
    fail_msg: |
      Pattern '{{ _expected_pattern }}' resolves to
      {{ query('inventory_hostnames', _expected_pattern) | length }} inventory host(s)
      but {{ ansible_play_hosts_all | length }} matched this play. --limit was likely used.

      This composite playbook targets different host groups across plays
      (router, switches, boards, netboot_server). --limit is global and
      silently empties the non-board plays. Use -e target_hosts=<pattern>
      instead — see the playbook docstring.
  run_once: true
```

Each composite playbook prepends a tiny pre-flight play that passes its
expected pattern:

```yaml
- name: Pre-flight — refuse --limit on composite playbook
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - ansible.builtin.include_tasks: tasks/_assert_no_limit.yml
      vars:
        _expected_pattern: "{{ target_hosts | default('boards') }}"
```

`stage_router.yml` passes its own expected pattern instead:

```yaml
- name: Pre-flight — refuse --limit on composite playbook
  hosts: "{{ armbian_netboot_server_group | default('netboot_server') }}"
  gather_facts: false
  tasks:
    - ansible.builtin.include_tasks: tasks/_assert_no_limit.yml
      vars:
        _expected_pattern: "{{ armbian_netboot_server_group | default('netboot_server') }}"
```

Composite playbooks to add the guard to (multi-play, multi-target-group):

- `playbooks/converge_boot_mode.yml` — the canonical case we tripped on;
  six plays mix boards (validate/render/cycle) with router (plumbing/upload).
  Guards `target_hosts | default('boards')`.
- `playbooks/build_and_publish_from_inventory.yml` — three plays across
  boards / armbian_builders / netboot_server; this playbook uses
  `armbian_boards_group | default('boards')` (not `target_hosts`),
  so the guard's `_expected_pattern` is
  `armbian_boards_group | default('boards')`.
- `playbooks/stage_router.yml` — three plays, mixes netboot_server +
  router via import_playbook; guards
  `armbian_netboot_server_group | default('netboot_server')`.
- `playbooks/tests/test_fleet_e2e.yml` — eleven plays mix boards with a
  `hosts: netboot_server` play and an `import_playbook: persist_uboot_env.yml`.
  Guards `target_hosts | default('boards')`.

Single-play and same-group playbooks do not get the guard:

- Single-play: `test_hardware_e2e.yml`, `bootstrap_armbian.yml`,
  `provision_local_disk.yml`, `persist_uboot_env.yml`,
  `cleanup_boot_files.yml`, `test_manual_psu_cold_boot.yml`.
- Same-group multi-play (all plays target the same board pattern; router
  ops happen via per-task `delegate_to`, which `--limit` does not affect):
  `playbooks/reprovision_to_local.yml`, `playbooks/tests/test_reprovision_e2e.yml`.
  Their docstrings document `--limit <host>` and that remains correct.

The assertion fires only when the inventory-resolved host count for
`_expected_pattern` differs from the play's `ansible_play_hosts_all`
count. False-positive scenarios:

- User passes `-e target_hosts=opi5pro-01 --limit opi5pro-01` (redundant but
  intentional): both sides equal `1`, no fire. Correct.
- User passes `-e target_hosts=opi5pro-01` (no `--limit`): both sides equal
  `1`, no fire. Correct.
- User passes nothing and runs the default `boards` group: both sides equal
  the full board count, no fire. Correct.
- User passes `--limit opi5pro-01` only (no `target_hosts` override): inventory
  resolution of `'boards'` returns the full board count; `ansible_play_hosts_all`
  is `1`. Mismatch → fire. Correct — this is the misuse we are catching.

### Fix 3: `test_hardware_e2e.yml` baseline-mode parameterisation

Replace the three hardcoded `vars: armbian_boot_mode: sd` overrides in
`test_hardware_e2e.yml` with an indirection through a play-level
`baseline_mode`:

```yaml
- name: Hardware E2E always-netboot boot-mode test
  hosts: "{{ armbian_boards_group | default('boards') }}"
  gather_facts: false
  vars:
    leave_state: false
    skip_baseline: false
    capture_serial: false
    # baseline_mode defaults to the host's inventory armbian_boot_mode;
    # callers can pin a specific baseline via -e baseline_mode=<mode>.
    # Must be a local-rooted mode (sd, local, local_kernel, or any extra
    # mode whose label doesn't produce an NFS rootfs).
    baseline_mode: "{{ armbian_boot_mode }}"
```

Pre-flight gains an assertion:

```yaml
- name: Pre-flight — assert baseline_mode is a local-rooted mode
  ansible.builtin.assert:
    that:
      - baseline_mode != 'nfs'
    fail_msg: >-
      baseline_mode='{{ baseline_mode }}' is invalid. The test cycles
      baseline → nfs → baseline; baseline=nfs is degenerate. Set
      armbian_boot_mode in inventory to a local mode (sd, local, local_kernel)
      or pass -e baseline_mode=<mode>.
```

The three hardcoded `armbian_boot_mode: sd` overrides become
`armbian_boot_mode: "{{ baseline_mode }}"`:

- Pre-flight `Pre-flight — converge pxelinux default to sd on router`
  → `Pre-flight — converge pxelinux default to {{ baseline_mode }} on router`
- Phase 3 `Phase 3 — render+upload pxelinux for sd`
  → `Phase 3 — render+upload pxelinux for {{ baseline_mode }}`
- Cleanup `Cleanup — converge pxelinux default sd on router`
  → `Cleanup — converge pxelinux default {{ baseline_mode }} on router`

Phase 1 task names update from "SD baseline" → "baseline":

- `Phase 1 — SD baseline (skippable via skip_baseline=true)` →
  `Phase 1 — baseline (skippable via skip_baseline=true)`

Phase 1, Phase 3, and Cleanup assertions stay as `_root_fstype not in ['nfs', 'nfs4']`
and `_root_device is match('^/dev/')`. These already work for sd, local,
local_kernel — anything that produces a local block-device rootfs.

Docstring update at the top of the playbook:

- Add a `baseline_mode` line to the Pre-condition / Usage sections.
- Update phase descriptions to read "baseline → nfsroot → baseline" instead
  of "SD → NFS → SD".

Backward compatibility: existing users whose inventory has `armbian_boot_mode: sd`
get identical behaviour because `baseline_mode` defaults to `armbian_boot_mode`.
Users with `armbian_boot_mode: local_kernel` (this session's case) now succeed
end-to-end. Users with anything else (`local`, custom modes) work as long as
the mode produces a local rootfs.

## Risks / open questions

- **No regression test for the guard**: localhost-only assertion tests
  (`playbooks/tests/test_resolve_*.yml`) cover other resolver primitives;
  could add `test_assert_no_limit.yml` in the same pattern. Listed as a
  follow-up, not in this PR.
- **Localhost SSH-routing edge case** (the `vscode` container quirk we
  found mid-session): fixed in the user's `.inventory/`, not a collection
  change. Mentioned here for record only.

## Testing

- Manual: re-run `test_hardware_e2e.yml --limit opi5pro-01.igou.systems`
  end-to-end. Phase 1 (baseline=local_kernel), Phase 2 (NFS), Phase 3
  (back to local_kernel), Cleanup all pass.
- Manual: run `converge_boot_mode.yml --limit opi5pro-01.igou.systems` and
  confirm the assertion fires fast with the suggested `-e target_hosts=…`
  message; re-run with `-e target_hosts=opi5pro-01.igou.systems` and
  confirm normal completion.
- ansible-lint production profile passes on all changed files.

## Implementation discoveries

Verification surfaced four additional issues in `test_hardware_e2e.yml`
that the original SD-only flow papered over but a real `local_kernel`
→ NFS → `local_kernel` cycle exposes. All four were resolved in the
same PR:

1. **Lazy-var recursion** — A first cut wired `baseline_mode: "{{ armbian_boot_mode }}"`
   as a play-level var while the include blocks set
   `vars: armbian_boot_mode: "{{ baseline_mode }}"`. The two lazy
   expressions form a cycle ("Recursive loop detected in template").
   Fix: materialize via `set_fact` in pre-flight
   (`baseline_mode: "{{ baseline_mode | default(armbian_boot_mode) }}"`)
   so the include sees a concrete string.

2. **`known_hosts` key mismatch mid-play** — Each rootfs identity has
   its own `/etc/ssh/ssh_host_*`. The pre-flight one-shot `ssh-keygen -R`
   can't catch the swap that happens when the test transitions baseline
   → NFS → baseline. `host_key_checking=False` is insufficient because
   `StrictHostKeyChecking=no` still refuses MISMATCH against an existing
   `known_hosts` entry. Fix: play-scoped
   `ansible_ssh_common_args: "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"`
   bypasses the file entirely for the duration of the play.

3. **Cold-boot SSH stability gate races auto-bootstrap** —
   `cold_boot_single_attempt.yml`'s `wait_for_connection` stability
   gate authenticates as the inventory user, which doesn't exist yet
   on a freshly-cloned per-host NFS rootfs (stock root + password only).
   The task file already supports `_skip_ssh_stability_check: true`
   for callers that chain `auto_bootstrap_if_needed.yml`. Fix: pass
   `_skip_ssh_stability_check: true` in Phase 1, Phase 2, and Cleanup
   (the three phases that chain `auto_bootstrap_if_needed`).

4. **Transient cold-boot timeout** — Phase 3's local_kernel boot
   intermittently exceeded the 180 s TCP/22 wait after a Phase 2 NFS
   transition, even though the same boot path on Phase 1 succeeded.
   `test_fleet_e2e.yml` already defaults `armbian_boot_retry_attempts=1`
   for the same flake class. Fix: same default in `test_hardware_e2e.yml`
   play vars (one automatic retry per phase; user can override with
   `-e armbian_boot_retry_attempts=N`).
