# board_boot_wait

## Purpose

Wait for a board to come up over TCP/22 plus SSH. Single-host role
targeting the board itself: waits for the inventory host to accept TCP
connections on port 22 (probed from `localhost`, no `become`), then
performs a `wait_for_connection` SSH probe.

No notion of how the board was powered — the caller is responsible for
cycling PoE (or pressing a button) before invoking this role. The
companion `playbooks/tasks/cold_boot_with_retry.yml` wraps the role in
the outer retry loop.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `armbian_netboot_boot_attempt_timeout` | no | `180` | Per-attempt TCP/22 wait, seconds. |
| `armbian_netboot_post_boot_wait_timeout` | no | `300` | Final `wait_for_connection` wait, seconds. |

## Outputs / side effects

After a successful run:

- The board accepts SSH connections from the control node.
- No filesystem or configuration mutations on the board itself; the
  role's purpose is purely to gate downstream tasks on the board being
  reachable.

## Idempotency & check mode

- Trivially idempotent — both module calls (`wait_for`,
  `wait_for_connection`) are pure probes and report `changed` based on
  their own internal logic.
- `--check` mode: probes still run; the role does not write anything.
- The role does NOT retry across boot attempts itself; chain it with
  `playbooks/tasks/cold_boot_with_retry.yml` when the upstream power
  state is uncertain.

## Example

```yaml
- name: Wait for a board to finish booting
  hosts: orange-pi-5-pro-01
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian_netboot.board_boot_wait
```

Typically reached via `playbooks/converge_boot_mode.yml` after the
PoE-cycle step.
