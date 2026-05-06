# routeros_poe

Controls PoE power state on a MikroTik RouterOS switch port connected to an
Armbian board. The role wraps `/interface ethernet poe set` with three
actions (`on`, `off`, `cycle`) and delegates to the upstream switch
identified per-board via host variables, so a single play can target boards
across multiple PoE switches.

The role is invoked indirectly through `playbooks/poe_control.yml`; calling
it directly is also supported.

## Required host variables

Each target board must declare:

| Variable | Description |
|---|---|
| `poe_switch` | Inventory hostname of the RouterOS switch supplying power. |
| `poe_port` | Switch interface name carrying PoE to the board (e.g. `ether3`). |

These belong in inventory `host_vars/<board>.yml` — they're SKU-level
identity, not collection-level configuration.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `poe_action` | `"on"` | One of `on`, `off`, `cycle`. |
| `poe_cycle_delay` | `5` | Seconds to pause between `off` and `on` during a power cycle. |

## Example

```yaml
- name: Power cycle a single board
  hosts: rock-5b-01
  gather_facts: false
  roles:
    - role: david_igou.armbian_netboot.routeros_poe
      vars:
        poe_action: cycle
```

The play targets boards (not the switches), and the role delegates each
RouterOS command to the board's `poe_switch` automatically. `group_vars/
routeros.yml` pins the `network_cli` connection plumbing so the delegated
command picks up the switch's connection settings without extra wiring.

## License

GPL-3.0-or-later
