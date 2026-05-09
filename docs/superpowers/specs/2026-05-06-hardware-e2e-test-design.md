---
name: Hardware end-to-end test for PXE-first boot toggle
description: Repeatable on-board test that proves a custom Armbian image's PXE-first U-Boot toggles rootfs source per RouterOS DHCP option state, run against a manually flashed SD card with PoE-driven transitions and SSH+findmnt assertions.
---

# Hardware end-to-end test design

## Goal

A repeatable hardware regression test that proves the PXE-first boot-mode
invariant the `armbian_build` role exists to deliver. With a custom-built
Armbian image manually flashed to an SD card and inserted in the board, the
test toggles rootfs source via RouterOS DHCP options and asserts the board
lands on the expected rootfs at each transition.

**Pass condition:** `findmnt -no SOURCE /` returns the NFS server's path in
nfsroot mode and a local block device in disk-boot mode, in that order,
after a single PoE cycle drives each transition.

The test exists primarily as a *debugging tool* during current netboot
development, not as a polished release-gate artifact. Diagnostic output is
front-and-centre at every verify checkpoint so a failure tells the operator
what went wrong without re-SSHing.

## Architecture

A single top-level playbook (`playbooks/test_hardware_e2e.yml`) composes
existing primitives — the `routeros_dhcp` role's `enable_netboot.yml` /
`disable_netboot.yml` task entry-points and the `routeros_poe` role — and
adds inline verify tasks between each transition. Three phases exercise the
boot-mode toggle once: disk → nfsroot → disk. A diagnostic bundle is
gathered at every verify checkpoint regardless of pass/fail. Failure
cleanup is governed by `-e leave_state=true|false` (default `false`).

The playbook adds *no* new role for v1; verify logic stays inline. If the
playbook or the diagnostic bundle grows past ~150 lines, refactor into
`roles/hardware_e2e_test/`.

## Out of scope for v1

- **Serial-log capture.** The operator handles this out of band on the
  hardware they happen to have wired. Bringing serial into the Ansible
  layer (`-e capture_serial=...`) is a future enhancement; capturing
  serial reliably from inside a playbook is more complex than the
  debugging value it currently buys us.
- **`reprovision.yml` integration.** v1 starts from a board with a
  manually-flashed SD card already inserted and does not exercise the
  reprovision flash path. Phase 2 (a future revision) will fold in
  `reprovision.yml` as the bootstrap step.
- **Multi-board loop.** Single board per run, scoped via `--limit`.
- **Toggle-loop durability** (N×5 cycles) — distinct concern (DHCP/RouterOS
  caching, not the role contract).

## File layout

```
playbooks/test_hardware_e2e.yml          # the playbook (single play, hosts: boards)
playbooks/tasks/diagnostic_bundle.yml    # the bundle (import_tasks'd)
```

The diagnostic bundle is a separate task file because it's reused at three
checkpoints. It lives under `playbooks/tasks/` (not inside a role) because
it's a playbook-level utility, not a role concern.

## Targeting and concurrency

```yaml
hosts: boards
gather_facts: false        # gathered explicitly per-phase after wait_for_connection
serial: 1
```

Operator invocation matches existing playbooks (`reprovision.yml`,
`enable_netboot.yml`):

```bash
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01
```

The play asserts `ansible_play_hosts | length == 1` in pre-flight — this
is intentionally a single-board operation, not a multi-board loop. Operating
on multiple boards in parallel would compete for RouterOS DHCP option-set
state and produce confusing failures.

## Sequence

### Pre-flight

Runs against `localhost` (or any control-side delegate that can probe
RouterOS), before any board interaction.

| Check | Behaviour on miss |
|---|---|
| `host_board_overrides.armbian_build_enabled is defined and == true` | warning (not failure) — v1 explicitly supports manually-flashed SD cards from a board not yet opted into `armbian_build` |
| `poe_switch is defined and length > 0` | hard fail |
| `poe_port is defined and length > 0` | hard fail |
| `armbian_default_password is defined` | hard fail |
| RouterOS has the `armbian-nfsroot` DHCP option-set object | hard fail with operator hint to run `setup_routeros_dhcp.yml` first |
| `play_hosts | length == 1` | hard fail with operator hint to use `--limit` |

The RouterOS probe reuses whatever fact-gathering the `routeros_dhcp` role
exposes today. If it doesn't expose a probe directly, the test queries
`/ip dhcp-server option sets print` via `community.routeros.command` and
asserts `armbian-nfsroot` is in the output.

### Phase 1 — disk-boot baseline

```
PoE cycle (poe_control role, action=cycle)
wait_for_connection (ansible_user + key, timeout=300s)
gather minimal facts
import_tasks diagnostic_bundle.yml
assert findmnt -no SOURCE / matches /dev/
```

Establishes "the board comes up on disk by default, with the rootfs on a
local block device". The custom-built U-Boot's `BOOT_TARGETS` may have PXE
first, but no DHCP option is set, so PXE fails to find a `next-server` and
falls through to disk.

### Phase 2 — nfsroot

```
include_role routeros_dhcp tasks=enable_netboot.yml (mode=nfsroot)
PoE cycle
override ansible_user=root, ansible_password=armbian_default_password
wait_for_connection (timeout=300s)
gather minimal facts
import_tasks diagnostic_bundle.yml
assert findmnt -no SOURCE / starts with "{{ nfs_server_ip | default(netboot_server_ip) }}:"
```

The connection identity override mirrors `reprovision.yml`'s NFS-mounted
phase: stock Armbian's NFS rootfs ships with `root` / `armbian_default_password`
credentials. The override is play-scoped (`vars:` block on the phase 2
play, or `set_fact` if everything is one play); restored for phase 3.

This is the load-bearing assertion. Stock Armbian Rockchip `current` would
not deliver this — its `BOOT_TARGETS` ordering hits mmc1's `boot.scr` first
via `bootflow scan` and never reaches PXE. Reaching NFS root therefore
proves the custom U-Boot's patched `BOOT_TARGETS` is in effect.

### Phase 3 — back to disk

```
include_role routeros_dhcp tasks=disable_netboot.yml
PoE cycle
restore ansible_user + key
wait_for_connection (timeout=300s)
gather minimal facts
import_tasks diagnostic_bundle.yml
assert findmnt -no SOURCE / matches /dev/
```

Confirms the toggle is bidirectional — clearing the DHCP option returns
the board to disk boot.

### Cleanup (always-block)

`block: [phase 1, phase 2, phase 3]` followed by `always:` containing:

- if `leave_state | bool == false` (default):
  - run `routeros_dhcp/disable_netboot.yml`
  - PoE-cycle, wait for SSH on the disk-boot identity
  - gather diagnostic bundle one more time, assert disk-boot rootfs
- if `leave_state | bool == true`:
  - print last-known mode + DHCP option-set state, exit

`rescue:` is empty — failures propagate after `always` runs.

## Connection identity per phase

| Phase | `ansible_user` | Auth | Set how |
|---|---|---|---|
| 1, 3, cleanup | inventory `ansible_user` | SSH key | inventory default |
| 2 | `root` | `armbian_default_password` | `vars:` on the phase 2 play (or per-task) |

The override pattern matches `reprovision.yml` line-for-line. No new
mechanism.

## Diagnostic bundle

Implemented in `playbooks/tasks/diagnostic_bundle.yml`, `import_tasks`'d at
every verify checkpoint. Gathers and prints (via `ansible.builtin.debug`):

- `findmnt -no SOURCE /`
- `cat /proc/cmdline`
- `ip -4 route`
- `cat /etc/resolv.conf`
- `lsblk -no NAME,SIZE,TYPE,MOUNTPOINT`
- `dpkg -l 'linux-u-boot-*'` (meaningful only in disk-boot mode — no-op in
  NFS root, since the NFS rootfs is the per-host clone created by
  `netboot_assets` and may not have `linux-u-boot-*` installed)
- `journalctl -b 0 --no-pager | tail -100`

Every gather task uses `failed_when: false` and `changed_when: false` so a
missing tool (e.g., `journalctl` if a future minimal NFS rootfs drops
systemd) does not abort the test. The bundle is printed inline as a single
`debug` task with `msg:` listing all gathered values, so the operator sees
the full picture in one place rather than scattered across N task outputs.

## Pre-flight assertions in detail

```yaml
- name: Pre-flight — assert exactly one board targeted
  ansible.builtin.assert:
    that: ansible_play_hosts | length == 1
    fail_msg: "test_hardware_e2e.yml is single-board; pass --limit <host>"

- name: Pre-flight — assert per-board PoE state
  ansible.builtin.assert:
    that:
      - poe_switch is defined
      - poe_switch | length > 0
      - poe_port is defined
      - poe_port | length > 0
    fail_msg: "{{ inventory_hostname }} needs poe_switch + poe_port hostvars set"

- name: Pre-flight — armbian_default_password defined
  ansible.builtin.assert:
    that: armbian_default_password is defined
  delegate_to: localhost
  run_once: true

- name: Pre-flight — board opted into custom build (warning only)
  ansible.builtin.debug:
    msg: >-
      WARNING: host_board_overrides.armbian_build_enabled is not true on
      {{ inventory_hostname }}. v1 supports manual flash, but if you
      meant to use a custom build, the inventory state is inconsistent.
  when: not (host_board_overrides.armbian_build_enabled | default(false))

- name: Pre-flight — RouterOS has armbian-nfsroot option-set
  community.routeros.command:
    commands:
      - "/ip dhcp-server option sets print where name=armbian-nfsroot"
  delegate_to: "{{ groups['routeros_routers'] | first }}"
  run_once: true
  register: _opt_probe
  failed_when: "'armbian-nfsroot' not in _opt_probe.stdout_lines | join(' ')"
```

## Cleanup behaviour reference

| `leave_state` | On pass | On fail |
|---|---|---|
| `false` (default) | clear DHCP, PoE-cycle, verify disk boot | clear DHCP, PoE-cycle, verify disk boot, then propagate fail |
| `true` | clear DHCP, PoE-cycle, verify disk boot | print last-known phase + DHCP state, propagate fail |

Note: even with `leave_state=true`, the test cleans up on *pass* — leaving
state on success would be surprising. The flag exclusively governs
fail-path forensic preservation.

## Future iterations (parked)

- **Serial-log integration.** `-e capture_serial=...` opt-in, attaches a
  background `socat`/`screen`/`picocom` capture to the verify report.
  Deferred because reliable Ansible-side serial capture is non-trivial.
- **`reprovision.yml` integration.** Drives the test from "freshly built
  image on netboot server" through reprovision into the toggle test. Full
  pipeline regression.
- **Multi-board loop.** Run sequentially across `boards` with a per-board
  pass/fail summary at the end.
- **Toggle-loop durability test.** N=5 toggles to disprove flake in DHCP
  lease caching, RouterOS option-set state, U-Boot env on the board.

## Open questions (deferred)

None blocking v1. The serial integration and reprovision integration are
known unknowns whose specs will be authored when those phases start.
