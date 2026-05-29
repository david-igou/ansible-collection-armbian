# `playbooks/routeros/`

> **Disclaimer.** These playbooks are what the author runs to test the
> collection in their own environment. They are provided as-is, with
> **no guarantee of functionality, stability, or fitness** for any other setup.
> Expect to read and adapt them before relying on them.

RouterOS-specific **reference playbooks**. The collection's roles are
transport-agnostic; all networking-gear-specific behaviour (TFTP/pxelinux
upload, `/ip tftp` row registration, PoE control, SSH-user provisioning) is
isolated here so it can be swapped.

## Swapping transports

Orchestration playbooks reach these via `armbian_*_playbook` hook variables that
default to the `routeros/` files. To target a different switch ecosystem, write
a parallel `playbooks/<vendor>/` directory exposing the same play interface and
point the hook variables at it — no change to the orchestration playbooks.

| Reference playbook | Default consumer | Override variable |
|---|---|---|
| `upload_pxelinux_cfg.yml` | `../converge_boot_mode.yml` | `armbian_pxelinux_upload_playbook` |
| `upload_tftp_assets.yml` | `../stage_router.yml` | `armbian_tftp_upload_playbook` |
| `plumbing_check.yml` | `../stage_router.yml`, `../converge_boot_mode.yml` | `armbian_plumbing_check_playbook` |
| `bootstrap_user.yml` | manual one-time | — (run directly) |
| `poe_control.yml` | manual ad-hoc | — (run directly) |

In-play power cycling (used by `../converge_boot_mode.yml` and the E2E
harnesses) goes through the `tasks/poe_cycle.yml` primitive via the
`armbian_poe_cycle_tasks_file` hook — not through `poe_control.yml`.

## Requirements

These playbooks need `community.routeros` + `ansible.netcommon`:

```bash
ansible-galaxy collection install -r playbooks/routeros/requirements.yml
```

Connection plumbing (`ansible_connection: ansible.netcommon.network_cli`,
`ansible_network_os`) is pinned in `inventory/group_vars/routeros.yml`;
per-host `ansible_user`/`ansible_port` live on the host entries.

## Run directly

```bash
ansible-playbook playbooks/routeros/poe_control.yml --limit <host> -e armbian_poe_action=cycle
ansible-playbook playbooks/routeros/bootstrap_user.yml -e ansible_user=<existing-admin>
```

Shared primitives used across these playbooks live in [`tasks/`](tasks/).
