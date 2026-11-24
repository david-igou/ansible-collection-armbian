# board_boot_wait

Gets a board booted and reachable. Runs on the board host with
`gather_facts: false` (the board may be off when the play starts).

Each attempt:

1. includes `board_boot_wait_power_cycle_tasks`, when set;
2. waits, from the control node, for the SSH banner on
   `ansible_host`:`ansible_port` (default port 22);
3. when `board_boot_wait_ssh` is true, waits for an SSH login as the inventory
   user (`wait_for_connection`).

A timed-out wait starts the next attempt. After the last attempt the role
fails with a message naming the stage (`port` or `ssh`) that timed out. A
failure inside the power-cycle tasks file is not retried and propagates.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `board_boot_wait_power_cycle_tasks` | `""` | Absolute path of a tasks file that power-cycles the board |
| `board_boot_wait_attempts` | `1` | Number of power-cycle and wait attempts |
| `board_boot_wait_port_timeout` | `180` | Seconds to wait for the SSH banner per attempt |
| `board_boot_wait_ssh` | `true` | Also wait for an SSH login as the inventory user |
| `board_boot_wait_ssh_timeout` | `300` | Seconds to wait for the SSH login per attempt |

## The power-cycle hook

`board_boot_wait_power_cycle_tasks` is the only transport hook in the
collection. The file runs in the board's host context, so it can read the
board's inventory variables and delegate to whatever controls power (a PoE
switch, a PDU, a hypervisor). Make it fail loudly when the power action fails.

```yaml
# tasks/poe_cycle.yml in the consuming repository
- name: Cut PoE power
  ansible.builtin.uri:
    url: "https://pdu.example.com/api/outlets/{{ pdu_outlet }}/off"
    method: POST
  delegate_to: localhost

- name: Restore PoE power
  ansible.builtin.uri:
    url: "https://pdu.example.com/api/outlets/{{ pdu_outlet }}/on"
    method: POST
  delegate_to: localhost
```

## Example

```yaml
- name: Power-cycle a board and wait for it
  hosts: boards
  gather_facts: false
  tasks:
    - name: Boot the board
      ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_wait
      vars:
        board_boot_wait_power_cycle_tasks: "{{ playbook_dir }}/tasks/poe_cycle.yml"
        board_boot_wait_attempts: 3
```

## Idempotency and check mode

The waits are probes and never report a change; whatever the power-cycle file
does is reported as its own tasks report it. In check mode the waits still
run.

## License

MIT
