# `playbooks/tasks/`

Internal `include_tasks`/`import_tasks` fragments composed by the top-level
workflow playbooks (and the E2E harnesses in `../tests/`). These are **not**
standalone playbooks — they have no `hosts:` header and assume the caller's play
context (host loop, facts, delegation). Treat them as the collection's private
playbook-level helpers; the public entrypoints are the playbooks in `../`.

## Resolver primitives

Merge inventory layers / derive per-host facts at run time:

| Fragment | Produces |
|---|---|
| `_resolve_board_config.yml` | `armbian_board_config` (family + model + host merge) |
| `_resolve_build_profile.yml` | `armbian_build` (family + model + host build-layer merge) |
| `_resolve_rootfs_src.yml` | `armbian_rootfs_src` (host_vars → published manifest → fail) |

(Their contracts are covered by the localhost tests in `../tests/`.)

## Boot-mode / lifecycle

| Fragment | Role |
|---|---|
| `_converge_boot_mode.yml` | Inner converge primitive used by lifecycle wrappers |
| `_lifecycle_set_and_verify.yml` | Converge + verify, with diagnostic bundle + auto-revert on failure |
| `validate_local_kernel.yml` | Assert `local_kernel` preconditions per host |
| `compose_uboot_env_vars.yml` | Build the converged U-Boot env dict |

## Boot / power / recovery

| Fragment | Role |
|---|---|
| `cold_boot_with_retry.yml` | Outer retry loop: PoE cycle + wait_for TCP/22 |
| `cold_boot_single_attempt.yml` | Inner block/rescue for one cold-boot attempt (includes the PoE-cycle task via `armbian_poe_cycle_tasks_file`) |
| `wait_for_ssh_with_cycle_retry.yml` | Post-boot SSH wait with cycle retry |
| `auto_bootstrap_if_needed.yml` | SSH probe → `bootstrap_armbian` fallback |
| `render_and_upload_pxelinux.yml` | Render pxelinux locally + upload to router (E2E / manual-PSU helper) |
| `diagnostic_bundle.yml` | findmnt/cmdline/journal capture on failure |
