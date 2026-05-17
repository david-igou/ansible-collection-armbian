# v3.0.0 — Role refactor: single-purpose, single-host, transport-agnostic

Status: design approved 2026-05-16. Target release: `david_igou.armbian_netboot` 3.0.0
(clean break from v2; no compatibility shims).

## Why

v2 roles work but are loaded and tangled:

- `boot_mode` is the worst offender. One role includes `routeros_pxe_config`
  (delegates to rb5009 to write pxelinux.cfg), `routeros_poe` (delegates to a
  switch to PoE-cycle), then waits for SSH and verifies the rootfs. Failure
  modes blend transport, retry, identity probing, and rootfs assertion.
- `netboot_assets` runs on the netboot server but reads `groups['boards']`
  internally, loops over hosts, then `fetch`es kernel artifacts back to
  `localhost`. The role decides three different transports (HTTP download,
  local copy, `fetch`) and owns assumptions about both the NFS server and
  the control node.
- `routeros_pxe_config`, `routeros_poe`, `bootstrap_routeros_user` make the
  collection unusable on networks without a RouterOS switch/router. The
  "agnostic" surface that users would want to fork for OPNsense, Cisco,
  pfSense, or a plain dnsmasq/tftpd box is buried inside roles.

The refactor's goals (operator-facing, in order):

1. **Shareability.** A user with no RouterOS hardware can install the collection,
   write a `playbooks/<their-transport>/` directory, point a handful of variables
   at it, and use the rest of the collection unchanged.
2. **Debuggability.** Each role does one thing; failure points to one input
   contract and one host. Multi-host orchestration is explicit in playbooks.
3. **Single-host-or-group invocation.** Roles are invoked per target. The
   playbook decides whether to loop. Running for one host (`--limit`) does not
   require role-internal logic to filter `groups['boards']`.

## New role inventory

Seven roles. Each one runs on a single host or group, has a single purpose, and
has zero knowledge of any specific networking gear or fileserver brand. One
role (`image_build`) keeps an optional publish step gated behind an explicit
`armbian_netboot_publish_target` variable — opting in means accepting that the
role talks to a fileserver; the default is local-only. Every other role
produces artifacts at a known local path; cross-host hops are the playbook's
job.

| Role | Runs on | Inputs (sketch) | Produces |
|---|---|---|---|
| `image_build` | `armbian_builders` | board metadata, kernel branch, `armbian_netboot_publish_target` (opt-in) | `.img.xz` at known local path; optional SCP publish |
| `image_extract` | any host with sudo + losetup (typically `netboot_server`) | `armbian_image_src` (local path **or** `http(s)://` URL), `model_name`, `template_dir`, `tftp_dir`, `board_dtb`, `force_refresh` | rootfs template at `template_dir`, `vmlinuz`/`initrd.img`/`board.dtb` at `tftp_dir` |
| `rootfs_clone` | any host that owns the template + target paths | `template_dir`, `target_dir`, `hostname` | reflink-cloned per-host rootfs with identity reset (hostname, machine-id, ssh host keys, `.no_armbian_first_login`) |
| `pxelinux_render` | `localhost` (typically reached via `delegate_to: localhost` inside a `hosts: boards` play, so per-board hostvars are in scope for one invocation per board) | board MAC, `boot_mode`, `nfs_server_ip`, `nfs_root_path`, TFTP-relative kernel/initrd/dtb paths (e.g. `armbian/<model>/vmlinuz` — strings written verbatim into pxelinux.cfg, *not* local FS paths), `sd_root`, `pxe_verbose`, `earlycon`, `output_dir` | `output_dir/01-<mac>` |
| `board_boot_wait` | a board | `wait_timeout`, `retry_attempts`, `attempt_timeout` | succeeds when TCP/22 + SSH are up |
| `board_boot_verify` | a board | `boot_mode` (`nfs`\|`sd`) | asserts `ansible_mounts['/']` matches |
| `bootstrap_armbian` | a board | (unchanged from v2) | inventory user with passwordless sudo + SSH keys |

Roles removed vs. v2: `boot_mode`, `netboot_assets`, `routeros_pxe_config`,
`routeros_poe`, `bootstrap_routeros_user`.

Every new role ships with `meta/argument_specs.yml` declaring the contract above
so callers fail at include time with a useful message rather than mid-task with
an undefined-variable trace.

## Reference playbooks (RouterOS-specific, swappable)

All RouterOS-aware code lives under `playbooks/routeros/`. Top-level playbooks
include these via path variables; a user swapping ecosystems writes a parallel
directory (`playbooks/opnsense/`, `playbooks/cisco/`, ...) and points the
variables at it.

```
playbooks/routeros/
  bootstrap_user.yml          provisions ansible-netboot user / group / SSH keys
  upload_pxelinux_cfg.yml     net_put 01-<mac> + /ip tftp row
                              (loops over the board list passed in)
  upload_tftp_assets.yml      net_put kernel/initrd/dtb + /ip tftp rows
                              (loops over the unique model list passed in)
  plumbing_check.yml          asserts /ip tftp rows exist for the requested models
  poe_control.yml             on / off / cycle a single PoE port (delegated)
  tasks/
    upload_file.yml           shared primitive: ensure dir, size-check,
                              net_put, /ip tftp row
    poe_cycle.yml             shared primitive: poe off → sleep → poe on
```

Transport-hook variables (defaulted at the top-level playbook, override in
inventory or with `-e`):

```yaml
armbian_netboot_pxelinux_upload_playbook: routeros/upload_pxelinux_cfg.yml
armbian_netboot_tftp_upload_playbook:     routeros/upload_tftp_assets.yml
armbian_netboot_plumbing_check_playbook:  routeros/plumbing_check.yml
armbian_netboot_poe_cycle_tasks_file:     routeros/tasks/poe_cycle.yml
```

`import_playbook` is used for upload/plumbing operations (separate play targeting
the router group). `include_tasks` is used for the PoE cycle inside retry
helpers (same play, delegated to the per-board switch).

## Top-level orchestration playbooks

Multi-stage where they need to be — each play targets one group with one
purpose. The orchestration that v2 buried inside `boot_mode`'s `delegate_to`
becomes explicit plays in the playbook.

```
playbooks/
  build_image.yml          one play on armbian_builders; image_build role
  bootstrap_armbian.yml    one play on boards (root); bootstrap_armbian role
  stage_netboot_assets.yml one play on netboot_server:
                             loop image_extract over unique models
                             loop rootfs_clone over groups['boards']
  stage_router.yml         play 1: fetch TFTP cache from netboot_server → controller
                           play 2: import_playbook {{ armbian_netboot_tftp_upload_playbook }}
                           play 3: import_playbook {{ armbian_netboot_plumbing_check_playbook }}
  converge_boot_mode.yml   play 1: import_playbook plumbing_check (preflight)
                           play 2: pxelinux_render on boards (delegate_to localhost)
                           play 3: import_playbook {{ armbian_netboot_pxelinux_upload_playbook }}
                           play 4: cold_boot_with_retry + board_boot_wait + board_boot_verify
                                   (single play on boards, helpers include_tasks
                                    the parameterised poe_cycle hook)
  set_boot_mode.yml        thin wrapper that reads armbian_netboot_boot_mode from -e
                           instead of inventory; otherwise calls converge_boot_mode.yml
  poe_control.yml          import_playbook routeros/poe_control.yml
                           (kept as a top-level shorthand)
  persist_uboot_env.yml    unchanged structurally (rock-5b SPI fw_setenv)
  test_hardware_e2e.yml    multi-phase composition; uses the same role + helper set
                           three times with serial capture + auto-bootstrap probes
  tasks/
    cold_boot_with_retry.yml          generic primitive (parameterised cycle hook)
    wait_for_ssh_with_cycle_retry.yml generic primitive
    auto_bootstrap_if_needed.yml      short probe → bootstrap_armbian fallback
                                      (replaces the 3x duplication in v2's
                                       test_hardware_e2e.yml)
    diagnostic_bundle.yml             (existing)
```

Two consequences worth flagging:

1. **`stage_router.yml` does the controller-cache fetch.** v2's `netboot_assets`
   ran on `netboot_server` and used `fetch:` to copy kernel artifacts back to
   `localhost`. Under v3 that cross-host hop belongs to the playbook because
   roles never touch a host they don't own. The role leaves artifacts at a
   known path on `netboot_server`; `stage_router.yml`'s first play fetches them
   to the controller cache; its second play `net_put`s them to rb5009 via the
   reference playbook.
2. **`converge_boot_mode.yml` is four plays, not one.** That is the price of
   single-host roles — the orchestration shape is explicit instead of hidden
   inside delegation. Operators running with `--limit` see the same behaviour
   because each play uses the same target/limit semantics.

## Migration and user-facing breakage

**Inventory shape is preserved.** All `armbian_netboot_*` variables in
`group_vars/all.yml`, `boards.yml`, and per-host vars keep their names and
meanings. The user-facing commands (`ansible-playbook playbooks/converge_boot_mode.yml --limit <host>`)
keep their semantics. `vars/boards.yml` schema is unchanged.

What breaks in v3.0.0:

| Surface | Change |
|---|---|
| Roles imported directly | All five removed role names disappear. External callers of `boot_mode`, `netboot_assets`, `routeros_pxe_config`, `routeros_poe`, `bootstrap_routeros_user` must update. |
| Role contracts | `boot_mode`'s `argument_specs` is gone. Its retry knobs (`armbian_netboot_boot_retry_attempts`, `armbian_netboot_boot_attempt_timeout`, `armbian_netboot_ssh_wait_*`, `armbian_netboot_post_boot_wait_timeout`, `armbian_netboot_poe_cycle_delay`) keep the same names and defaults but now apply to the playbook-side helpers under `playbooks/tasks/`. |
| `pxelinux.cfg` rendering | Produced on `localhost` by `pxelinux_render`, then uploaded by a transport-specific playbook. Anyone calling `routeros_pxe_config` via `include_role` from a downstream playbook must switch to the new playbook path. |
| `bootstrap_routeros_user` invocation | Becomes `ansible-playbook playbooks/routeros/bootstrap_user.yml -e ansible_user=<existing-admin>` instead of `playbooks/bootstrap_routeros_user.yml`. The shorter top-level path stays as an alias if convenient. |

Implementation sequence (clean break — implementer's choice on PR boundaries):

1. Land new roles alongside v2 (`image_build`, `image_extract`, `rootfs_clone`,
   `pxelinux_render`, `board_boot_wait`, `board_boot_verify`) without touching
   the old ones. Each ships with `meta/argument_specs.yml` and a smoke test
   where one is feasible.
2. Land reference playbooks under `playbooks/routeros/` plus the shared
   primitives in `routeros/tasks/`.
3. Rewrite top-level playbooks to compose the new roles + reference playbooks.
   Delete the old roles in the same commit. Bump `galaxy.yml` to `3.0.0`.
   Update CLAUDE.md, README, and the v2 design spec
   (`2026-05-14-always-netboot-migration-design.md`) to point at this spec.

Out of scope for this refactor:
- `vars/boards.yml` schema
- `image_build`'s build-time userpatches mechanism
- Hardware E2E test phase structure (its retry pattern stops being duplicated
  once the helpers are extracted, but the three-phase shape stays)
- `persist_uboot_env.yml` (rock-5b SPI special case stays as-is)
