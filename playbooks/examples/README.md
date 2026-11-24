# `playbooks/examples/`

One playbook per role, showing the minimal call with the role's current
inputs. They assume a `boards` group (and a builder or netboot host where the
role needs one) and use RFC 5737 addresses and example names; adapt them
before running. Each role's README is the parameter reference.

| Example | Role |
|---|---|
| `board_config.yml` | `board_config` (all three entry points) |
| `board_boot_wait.yml` | `board_boot_wait` with a power-cycle hook |
| `board_boot_verify.yml` | `board_boot_verify` |
| `pxelinux_render.yml` | `pxelinux_render`, delegated to the control node |
| `bootstrap_armbian.yml` | `bootstrap_armbian` after `board_boot_wait` |
| `image_build.yml` | `image_build` |
| `rootfs_provision.yml` | `rootfs_provision` |
| `disk_image.yml` | `disk_image` |
| `disk_provision.yml` | `disk_provision` |
