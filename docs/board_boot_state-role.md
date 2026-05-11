# `board_boot_state` role

End-to-end state-enforcer for an Armbian SBC's boot mode. Given a
desired `boot_state` (`pxe` or `disk`), writes/removes the per-board
pxelinux.cfg + /ip tftp row on the netboot router, PoE-cycles the
board, waits for it to come up, and asserts the resulting rootfs
matches the declared state.

## Role contract

After a successful role invocation:

- `boot_state: pxe` — the netboot router has a per-board pxelinux.cfg
  + /ip tftp row registered for this board; the board has been
  PoE-cycled and is reachable on its inventory `ansible_user` with
  an NFS rootfs.
- `boot_state: disk` — the netboot router has no per-board entries
  for this board; the board has been PoE-cycled and is reachable on
  its inventory `ansible_user` with a local-block-device rootfs
  (`/dev/<block>`).

Both contracts can be weakened: `cycle_board: false` skips the board
PoE cycle and verify (configure rb5009 only); `verify_state: false`
skips the rootfs assertion at the end.

Eventually-consistent against PoE-HAT cold-boot intermittency via a
two-layer retry stack — see [retry-configuration.md](retry-configuration.md)
and the upstream issue [#38].

[#38]: https://github.com/david-igou/ansible-collection-armbian_netboot/issues/38

## Required inventory configuration

`netboot_router` must be defined for every board the role targets.
This is **not** a role default — the role asserts via
`meta/argument_specs.yml` and fails loudly if missing.

The convention is to set it once in `inventory/group_vars/boards.yml`:

```yaml
# inventory/group_vars/boards.yml
netboot_router: rb5009
```

Override per-host (in `host_vars/<board>.yml`) when a specific board
is served by a different router. The host you name must be present in
your inventory with the routeros `network_cli` connection settings —
typically a member of `routeros_routers` (see
`inventory/group_vars/routeros.yml` for the connection plumbing).

## Usage from a playbook

The role is invoked from a play targeting `boards`. Internally it
delegates rb5009 mutations to `netboot_router` (the same delegation
pattern as `routeros_poe`).

```yaml
- name: Bring boards into PXE state
  hosts: boards
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian_netboot.board_boot_state
      vars:
        boot_state: pxe
```

The `enable_netboot.yml` and `disable_netboot.yml` playbooks are
thin wrappers around exactly this pattern with `boot_state: pxe`
and `boot_state: disk` respectively. The `test_hardware_e2e.yml`
harness calls into the role's individual primitives
(`cold_boot_with_retry.yml`, `wait_for_ssh_with_cycle_retry.yml`) via
`tasks_from:` so it can interleave auto-bootstrap detection between
the cold-boot and the post-boot verify.

## Knob reference

| Variable | Default | Required? | What it does |
|---|---|---|---|
| `boot_state` | — | **yes** | `pxe` or `disk`. Determines whether to write or remove rb5009 state, and which rootfs the verify step asserts. |
| `netboot_router` | — | **yes** | Inventory hostname of the RouterOS router. Used as `delegate_to` for rb5009 mutations. |
| `boot_retry_attempts` | `0` | no | Additional cold-boot attempts after a failed PoE cycle / TCP/22 wait / sustained ssh-ping. 0 = single attempt. |
| `boot_attempt_timeout` | `180` | no | Per-attempt TCP/22 wait timeout (seconds). |
| `ssh_wait_timeout` | `90` | no | Sustained ssh-ping stability check timeout inside each layer-1 retry attempt (seconds). |
| `ssh_wait_retry_attempts` | `{{ boot_retry_attempts }}` | no | Layer-2 retry depth for the post-boot SSH wait. Tracks layer 1 unless explicitly overridden. |
| `post_boot_wait_timeout` | `300` | no | Post-retry `wait_for_connection` timeout (seconds) — the "long ssh wait" after layer 1 reports success. |
| `poe_cycle_delay` | `5` | no | Seconds the PoE port stays off during a cycle action. Bigger values give bulk capacitors more drain time. |
| `cycle_board` | `true` | no | If false, write rb5009 state and skip PoE cycle / verify. |
| `verify_state` | `true` | no | If false, skip the rootfs assertion after boot. |

Full descriptions, types, and choices live in
[`roles/board_boot_state/meta/argument_specs.yml`](../roles/board_boot_state/meta/argument_specs.yml).
View at runtime with:

```
ansible-doc -t role david_igou.armbian_netboot.board_boot_state
```

## Common configurations

These are the same recipes from
[retry-configuration.md](retry-configuration.md), expressed against
the role's playbook wrappers. Pass them as `-e` overrides; or set
them in `inventory/group_vars/boards.yml` if a setting should apply
to all boards.

### Healthy hardware

```bash
ansible-playbook playbooks/enable_netboot.yml --limit <board>
```

Defaults — no retries, full timeouts. Fails fast on first attempt
failure so you investigate rather than churn through retries.

### Flaky PoE HAT

```bash
ansible-playbook playbooks/enable_netboot.yml \
  --limit <board> \
  -e boot_retry_attempts=2 \
  -e poe_cycle_delay=60
```

Up to 3 cold-boot attempts. The 60 s drain lets bulk caps fully
discharge before re-energizing. Hits ~80 % on the 4 A HAT topology
described in #38.

### Maximum eventual consistency

```bash
ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit <board> \
  -e boot_retry_attempts=3 \
  -e poe_cycle_delay=60
```

Deep retries with full default timeouts. Slow per-iter; highest
green rate. Use when iter time doesn't matter.

### Configure rb5009 only (board powered off)

```bash
ansible-playbook playbooks/enable_netboot.yml \
  --limit <board> \
  -e netboot_reboot=false
```

The wrapper playbook passes `netboot_reboot` through to the role's
`cycle_board` knob. With `cycle_board: false`, the role writes
rb5009 state and stops there — the board boots into the staged state
the next time it gets power.

### Fresh-rootfs reflash (auto-bootstrap)

The role's layer-1 retry uses the inventory user for its
sustained-ssh-ping check, so a freshly-flashed board (where the
inventory user doesn't exist yet) would fail every attempt. For
those flows, run `bootstrap_armbian.yml` first; the
`test_hardware_e2e.yml` harness handles this automatically via its
auto-bootstrap probe.

## Internal architecture

```
roles/board_boot_state/
├── meta/
│   ├── main.yml                        # role metadata
│   └── argument_specs.yml              # input contract (validated at include time)
├── defaults/main.yml                   # default values for non-required knobs
└── tasks/
    ├── main.yml                        # dispatcher: configure → cycle → verify
    ├── configure_pxe.yml               # delegate to netboot_router: write rb5009 state
    ├── configure_disk.yml              # delegate to netboot_router: remove rb5009 state
    ├── cycle_and_wait.yml              # layer-1 + layer-2 retry stack
    ├── cold_boot_with_retry.yml        # layer 1: PoE cycle + TCP/22 + ssh-ping
    ├── cold_boot_single_attempt.yml    # one attempt within layer 1
    ├── wait_for_ssh_with_cycle_retry.yml  # layer 2: post-boot SSH wait + cycle retry
    └── verify_state.yml                # rootfs assertion (NFS vs /dev/<block>)
```

The two-layer retry stack lives inside the role. Its consumers
(`enable_netboot.yml`, `disable_netboot.yml`, `test_hardware_e2e.yml`)
do not need to know how it works — they just observe that the role's
contract is honored eventually-consistently.

`cold_boot_with_retry.yml`, `cold_boot_single_attempt.yml`, and
`wait_for_ssh_with_cycle_retry.yml` are individually accessible via
`tasks_from:` — the e2e harness uses this to compose its own
auto-bootstrap chain that doesn't fit the role's full contract.

## Failure modes the role does *not* cover

- **Wrong rootfs after successful boot** — board PXE-bootflow falls
  through to local SD instead of pulling pxelinux.cfg, the rootfs
  assertion fails. Successful boot to the wrong place — retry stack
  doesn't trigger. Recovery: re-run the role.
- **rb5009 configuration drift** — the per-model `/ip tftp` rows
  aren't where the role expects. Surfaced by the
  `netboot_assets/plumbing_check.yml` pre-flight in
  `enable_netboot.yml`, not by the role itself.
- **Network-layer issues outside the board** — switch port disabled,
  cable unplugged, VLAN misconfiguration. The retry fires but every
  cycle fails the same way; the layer-1 assert fails loud after
  exhausting attempts.
- **Hard hardware failure** — SD card dead, PoE HAT shorted, board
  non-functional. Same as network-layer; the role exhausts retries
  and fails.
