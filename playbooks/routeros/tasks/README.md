# `playbooks/routeros/tasks/`

Shared RouterOS task primitives — small `include_tasks`/`import_tasks` fragments
reused by the reference playbooks in `../`. They are not standalone playbooks
(no `hosts:` header); each expects its caller to provide the loop item and the
delegation/connection context.

| Fragment | Used by | Does |
|---|---|---|
| `upload_file.yml` | `../upload_pxelinux_cfg.yml`, `../upload_tftp_assets.yml` | `net_put` one file + register its `/ip tftp` row |
| `upload_pxelinux_one.yml` | per-host pxelinux upload (in-play use) | Upload one board's `01-<mac>` pxelinux.cfg + row |
| `plumbing_check_one.yml` | `../plumbing_check.yml` | Assert the `/ip tftp` row for one req-filename exists |
| `poe_cycle.yml` | `../poe_control.yml`, and `../../tasks/cold_boot_*` via `armbian_poe_cycle_tasks_file` | off → drain (`armbian_poe_cycle_delay`) → on |

`poe_cycle.yml` is the reusable power-cycle primitive the orchestration
playbooks bind to through the `armbian_poe_cycle_tasks_file` hook variable —
swap that variable to retarget power cycling at a non-RouterOS transport.
