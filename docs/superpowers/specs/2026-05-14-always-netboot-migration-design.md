# Always-netboot migration design

**Date:** 2026-05-14
**Status:** Approved (brainstorming complete, pending implementation plan)
**Breaks:** v1 API — this is a v2.0.0 release

## Summary

Migrate the collection from the v1 "stateful toggle" model (pxelinux.cfg
file presence/absence on rb5009 switches a board between NFS and SD boot)
to an "always-netboot" model where every onboarded board always has a
pxelinux.cfg on rb5009, and the `default` directive inside that file
selects the boot mode. This eliminates the imperative enable/disable
toggle pair, replaces it with a single idempotent convergence playbook,
renames all variables to follow Ansible collection best practices
(`armbian_netboot_` prefix), and simplifies role names.

## Motivation

The v1 binary toggle (file present = NFS, file absent = SD fallthrough)
is a one-bit channel. Every new boot mode (NVMe rootfs, eMMC, recovery
shell, installer, last-known-good kernel) requires encoding intent
somewhere outside the file-presence model. The toggle also creates
asymmetric codepaths (write vs remove, configure_pxe vs configure_disk)
and an imperative playbook pair (enable_netboot / disable_netboot) that
don't compose well.

The always-netboot model turns the one-bit channel into an enum: the
`default` line inside a persistent pxelinux.cfg selects among rendered
`label` blocks. Changing boot mode is a re-render, not a create/delete.

Additionally, v1 variable names (`board_mac`, `boot_state`,
`nfs_rootfs_path`) lack a collection namespace prefix, risking collisions
in multi-collection inventories and violating Ansible collection
development best practices.

## Scope

### First-class boot modes (v2)

- **`nfs`** — TFTP kernel + NFS rootfs (equivalent to v1 `boot_state: pxe`)
- **`sd`** — TFTP kernel + local SD rootfs via `PARTUUID`

### Template-ready but not wired end-to-end

The template is structured so adding future modes is one new `label`
block gated on a host var. Anticipated future modes:

- `nvme` — TFTP kernel + NVMe rootfs
- `emmc` — TFTP kernel + eMMC rootfs
- `recovery` — TFTP kernel + RAM-rooted rescue shell
- `installer` — one-shot NFS-based provisioning rootfs
- `lkg` — last-known-good pinned kernel
- `localboot` — chain to SD's boot.scr via U-Boot `LOCALBOOT`

## Design

### 1. Role structure

Seven roles, two renamed, one replaced:

| Role | Purpose | Change from v1 |
|---|---|---|
| `boot_mode` | Converge a board to its declared boot mode. Renders pxelinux.cfg, net_puts to rb5009, ensures `/ip tftp` row, optionally PoE-cycles and verifies. | Replaces `board_boot_state`. Single codepath — no configure_pxe/configure_disk split. No file removal path. |
| `routeros_pxe_config` | Low-level: render pxelinux.cfg template, net_put to rb5009, ensure `/ip tftp` row. Invoked by `boot_mode`. | Replaces `routeros_sbc_tftp`. Always writes, never removes. |
| `routeros_poe` | PoE power control. | Unchanged (variable renames only). |
| `netboot_assets` | NFS rootfs staging + TFTP kernel/initrd/dtb staging on rb5009. | Unchanged (variable renames only). Split across two playbooks but still one role internally. |
| `bootstrap_armbian` | SSH-key user provisioning on freshly flashed boards. | Unchanged (variable renames only). |
| `bootstrap_routeros_user` | RouterOS user/group/SSH-key state. | Unchanged. |
| `armbian_build` | Build custom Armbian `.img.xz`. | Unchanged (variable renames only). |

#### `boot_mode` role internal task files

```
roles/boot_mode/tasks/
├── main.yml                          # converge + optional cycle + verify
├── converge.yml                      # include_role routeros_pxe_config
├── cycle_and_wait.yml                # (carried from board_boot_state)
├── cold_boot_with_retry.yml          # (carried)
├── cold_boot_single_attempt.yml      # (carried)
├── wait_for_ssh_with_cycle_retry.yml # (carried)
└── verify.yml                        # conditional: NFS fstype or block device PARTUUID
```

The role always converges — it writes the pxelinux.cfg reflecting
current inventory state. There is no remove path. Deleted from v1:
`configure_pxe.yml`, `configure_disk.yml`, `remove_pxelinux_cfg.yml`.

### 2. Variable contract

All variables use the `armbian_netboot_` prefix.

#### Per-host inventory vars (`hosts.yml`)

| Variable | Required | Notes |
|---|---|---|
| `armbian_netboot_board_mac` | always | MAC address for pxelinux.cfg filename |
| `armbian_netboot_board_model` | always | Key into `armbian_netboot_board_configs` |
| `armbian_netboot_boot_mode` | always | `nfs` or `sd`. Determines `default` line. No default — must be declared. |
| `armbian_netboot_sd_partuuid` | when `boot_mode: sd` | PARTUUID of the SD rootfs partition |
| `armbian_netboot_poe_switch` | for PoE boards | PoE switch inventory hostname |
| `armbian_netboot_poe_port` | for PoE boards | Interface name on PoE switch |

#### Group vars — boards (`group_vars/boards.yml`)

| Variable | Default | Notes |
|---|---|---|
| `armbian_netboot_router` | (none, required) | Inventory hostname of RouterOS router for rb5009 delegation |

#### Global vars (`group_vars/all.yml`)

Cross-role variables live here (not duplicated in role defaults):

| Variable | Default | Consumers |
|---|---|---|
| `armbian_netboot_server_ip` | (required) | Multiple roles |
| `armbian_netboot_nfs_server_ip` | (falls back to `_server_ip`) | routeros_pxe_config template, netboot_assets |
| `armbian_netboot_nfs_rootfs_path` | `/mnt/ssd/netboot/rootfs` | netboot_assets, routeros_pxe_config |
| `armbian_netboot_tftp_flash_dir` | `sbc` | netboot_assets, routeros_pxe_config |
| `armbian_netboot_tftp_cache_dir` | `{{ playbook_dir }}/../.cache/sbc-tftp` | netboot_assets, routeros_pxe_config |
| `armbian_netboot_nfs_assets_export` | `/mnt/ssd/public/boot-files` | netboot_assets, armbian_build |
| `armbian_netboot_image_urls` | (required, per model) | netboot_assets |
| `armbian_netboot_branch` | `current` | Informational |
| `armbian_netboot_bootstrap_ssh_keys` | (required) | bootstrap_armbian |
| `armbian_netboot_pxe_verbose` | `false` | routeros_pxe_config template |

#### Role defaults (single-consumer only)

| Variable | Default | Role |
|---|---|---|
| `armbian_netboot_image_cache` | `/mnt/ssd/netboot/cache` | netboot_assets |
| `armbian_netboot_image_mount` | `/mnt/ssd/netboot/.loop-mount` | netboot_assets |
| `armbian_netboot_cycle_board` | `true` | boot_mode |
| `armbian_netboot_verify_state` | `true` | boot_mode |
| `armbian_netboot_boot_retry_attempts` | `0` | boot_mode |
| `armbian_netboot_boot_attempt_timeout` | `180` | boot_mode |
| `armbian_netboot_ssh_wait_timeout` | `90` | boot_mode |
| `armbian_netboot_ssh_wait_retry_attempts` | `{{ armbian_netboot_boot_retry_attempts }}` | boot_mode |
| `armbian_netboot_post_boot_wait_timeout` | `300` | boot_mode |
| `armbian_netboot_poe_cycle_delay` | `5` | boot_mode |

#### Per-model metadata (`vars/boards.yml`)

Top-level dict renamed to `armbian_netboot_board_configs`. Inner keys
stay short (already scoped by the dict):

```yaml
armbian_netboot_board_configs:
  orange-pi-5-pro:
    armbian_dl_dir: orangepi5pro
    armbian_board_name: orangepi5pro
    armbian_support: community
    dtb: rockchip/rk3588s-orangepi-5-pro.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
```

### 3. Template design

The pxelinux.cfg template
(`roles/routeros_pxe_config/templates/pxelinux_cfg.j2`) uses lowercase
directives per the
[U-Boot PXE spec](https://docs.u-boot.org/en/stable/usage/pxe.html).

All directives used (`default`, `timeout`, `prompt`, `label`, `kernel`,
`initrd`, `fdt`, `append`) are explicitly listed as supported in the
U-Boot stable docs. `menu label` is cosmetic — U-Boot's `pxe_utils.c`
parses it but it's not in the stable spec's supported-commands list. It
is rendered first within each label block so that if a future U-Boot
version stops recognizing it, the label terminates before load-bearing
directives, producing a detectable boot failure rather than silent
misconfiguration.

Template sketch (`_target_host` is a `set_fact` set by the calling
role before template rendering — the same pattern v1 uses with
`target_board_host`):

```jinja2
{% set _mode = hostvars[_target_host].armbian_netboot_boot_mode %}
{% set _model = hostvars[_target_host].armbian_netboot_board_model %}
{% set _board = armbian_netboot_board_configs[_model] %}
{% set _verbose = (hostvars[_target_host].armbian_netboot_pxe_verbose
                   | default(armbian_netboot_pxe_verbose | default(false)))
                  | bool %}
{% set _verbose_suffix = ' earlycon=' ~ _board.earlycon ~ ' loglevel=8 ignore_loglevel initcall_debug printk.devkmsg=on systemd.log_level=debug systemd.log_target=console systemd.journald.forward_to_console=1' if _verbose else '' %}
# pxelinux.cfg for {{ _target_host }} ({{ _model }})
# MAC: {{ hostvars[_target_host].armbian_netboot_board_mac }}
# Active mode: {{ _mode }}
# Generated by Ansible — do not edit manually.

default {{ _mode }}
timeout 50
prompt  0

label nfs
  menu label Armbian NFS root ({{ _target_host }})
  kernel armbian/{{ _model }}/vmlinuz
  initrd armbian/{{ _model }}/initrd.img
  fdt    armbian/{{ _model }}/board.dtb
  append root=/dev/nfs nfsroot={{ armbian_netboot_nfs_server_ip | default(armbian_netboot_server_ip) }}:{{ armbian_netboot_nfs_rootfs_path }}/{{ _target_host }},nfsvers=3,rw ip=dhcp console={{ _board.console }} rootwait rw{{ _verbose_suffix }}

{% if hostvars[_target_host].armbian_netboot_sd_partuuid is defined %}
label sd
  menu label Armbian on SD ({{ _target_host }})
  kernel armbian/{{ _model }}/vmlinuz
  initrd armbian/{{ _model }}/initrd.img
  fdt    armbian/{{ _model }}/board.dtb
  append root=PARTUUID={{ hostvars[_target_host].armbian_netboot_sd_partuuid }} rootfstype=ext4 rootwait rw console={{ _board.console }}{{ _verbose_suffix }}
{% endif %}
```

Key design points:

- **`nfs` label is always rendered** — every onboarded board has NFS
  assets staged, so NFS is always a valid fallback.
- **`sd` label is gated on `armbian_netboot_sd_partuuid`** — only
  rendered when the host declares it.
- **Pre-render validation**: the role asserts that `armbian_netboot_boot_mode`
  matches a label that will actually be rendered. Setting `boot_mode: sd`
  without `sd_partuuid` fails with a clear message before any write.
- **Label names match `armbian_netboot_boot_mode` values exactly** — no
  mapping layer.
- **`append` is always a single line** — U-Boot's PXE bootmeth does not
  honor backslash line continuations.
- **Adding a future mode** means: add a gated `label` block in the
  template, add a host var for the gate condition, add validation in
  the role. Three touchpoints, no structural changes.

#### U-Boot spec compliance notes

- All directives verified against
  [U-Boot PXE stable docs](https://docs.u-boot.org/en/stable/usage/pxe.html).
- `fallback` global command is supported by U-Boot but not rendered in
  v2. Template structure allows adding `fallback nfs` as a one-line
  addition for future A/B kernel rollouts.
- `pxe_label_override` U-Boot env var can override the `default` line
  at runtime without re-rendering the template. Documented in
  `docs/boot-mode-override.md`.

### 4. Playbook surface

| Playbook | Replaces | Purpose |
|---|---|---|
| `converge_boot_mode.yml` | `enable_netboot.yml` + `disable_netboot.yml` | Reads `armbian_netboot_boot_mode` from inventory, converges pxelinux.cfg on rb5009. Idempotent. |
| `set_boot_mode.yml` | (new) | Same convergence but expects `-e armbian_netboot_boot_mode=nfs\|sd` for ad-hoc overrides. |
| `stage_nfs_rootfs.yml` | `stage_netboot_assets.yml` (NFS half) | Download image, extract per-model template, clone per-host rootfs on TrueNAS. |
| `stage_tftp_assets.yml` | `stage_netboot_assets.yml` (TFTP half) | Net_put per-model kernel/initrd/dtb to rb5009, register `/ip tftp` rows. |
| `build_image.yml` | (stays) | Variable references updated. |
| `bootstrap_armbian.yml` | (stays) | Variable references updated. |
| `bootstrap_routeros_user.yml` | (stays) | Unchanged. |
| `poe_control.yml` | (stays) | Variable references updated. |
| `persist_uboot_env.yml` | (stays) | Variable references updated. |
| `test_hardware_e2e.yml` | (stays) | Uses `converge_boot_mode.yml` internally instead of enable/disable pair. |

Deleted: `enable_netboot.yml`, `disable_netboot.yml`,
`stage_netboot_assets.yml`.

### 5. Boot mode override methods

Three ways to control a board's boot mode, documented in
`docs/boot-mode-override.md`:

| Method | Durability | Touches rb5009? |
|---|---|---|
| Set `armbian_netboot_boot_mode` in inventory, run `converge_boot_mode.yml` | Permanent until inventory changes | Yes |
| `set_boot_mode.yml -e armbian_netboot_boot_mode=sd` | Until next `converge_boot_mode.yml` | Yes |
| `setenv pxe_label_override sd` at U-Boot prompt | Single boot (unless `saveenv` on SPI boards) | No |

### 6. Migration path

This is a breaking change — v2.0.0 in `galaxy.yml`.

#### Deleted

- `roles/board_boot_state/` — replaced by `roles/boot_mode/`
- `roles/routeros_sbc_tftp/` — replaced by `roles/routeros_pxe_config/`
- `playbooks/enable_netboot.yml`
- `playbooks/disable_netboot.yml`
- `playbooks/stage_netboot_assets.yml`

#### Created

- `roles/boot_mode/`
- `roles/routeros_pxe_config/`
- `playbooks/converge_boot_mode.yml`
- `playbooks/set_boot_mode.yml`
- `playbooks/stage_nfs_rootfs.yml`
- `playbooks/stage_tftp_assets.yml`
- `docs/boot-mode-override.md`

#### Updated in place

- `vars/boards.yml` — dict rename
- `inventory/hosts.yml` — all host vars renamed
- `inventory/group_vars/all.yml` — all global vars renamed, cross-role defaults moved here
- `inventory/group_vars/boards.yml` — var renames
- `galaxy.yml` — version 1.0.0 → 2.0.0
- `CLAUDE.md` — updated to reflect new structure
- All remaining playbooks — variable reference updates
- All remaining roles — variable reference updates, cross-role vars removed from defaults

#### No backward compatibility layer

Old variable names are not aliased. Clean break. The doc-only inventory
and CLAUDE.md serve as the migration guide. Single-operator fleet makes
aliases unnecessary overhead.

#### Operator migration checklist

1. Rename all vars in real inventory to `armbian_netboot_*` prefix
2. Replace `boot_state` references with `armbian_netboot_boot_mode`
   (`pxe` → `nfs`, `disk` → `sd`)
3. Add `armbian_netboot_sd_partuuid` to boards that need SD boot mode
4. Replace `enable_netboot.yml` / `disable_netboot.yml` invocations
   with `converge_boot_mode.yml` / `set_boot_mode.yml`
5. Replace `stage_netboot_assets.yml` invocations with
   `stage_nfs_rootfs.yml` + `stage_tftp_assets.yml`

## Deliverables

1. `roles/boot_mode/` — new role with argument_specs
2. `roles/routeros_pxe_config/` — new role with spec-compliant template
3. `playbooks/converge_boot_mode.yml`
4. `playbooks/set_boot_mode.yml`
5. `playbooks/stage_nfs_rootfs.yml`
6. `playbooks/stage_tftp_assets.yml`
7. `docs/boot-mode-override.md`
8. Variable renames across all existing roles, playbooks, inventory, vars
9. Deletion of replaced roles/playbooks
10. `galaxy.yml` version bump to 2.0.0
11. `CLAUDE.md` rewrite

## References

- [U-Boot PXE spec (stable)](https://docs.u-boot.org/en/stable/usage/pxe.html)
- [Always-netboot model explainer](../../always-netboot-model-explainer.html)
- [pxelinux.cfg explainer](../../pxelinux-cfg-explainer.html)
- [Armbian kernel explainer](../../armbian-kernel-explainer.html)
- [v1 scope narrowing spec](2026-05-07-v1-scope-narrowing-design.md)
- [rb5009 SBC TFTP design](2026-05-08-rb5009-sbc-tftp-design.md)
