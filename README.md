# david_igou.armbian

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.19-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian)
[![Docs](https://img.shields.io/badge/docs-online-success?logo=readthedocs)](https://david-igou.github.io/ansible-collection-armbian/)

Roles for Armbian single-board computers that netboot and get reimaged:
build a custom image, stage a per-host NFS root, render the board's
pxelinux.cfg, power-cycle and wait for it, check which root it booted, and
write images or partition layouts to local disks.

The collection ships **roles only**. Inventory, orchestration and transport
(TFTP upload, PoE or PDU control) live in the consuming repository; the one
place they plug in is the `board_boot_wait` power-cycle hook.

> Early-stage (0.0.x): role interfaces can change between releases. Pin a
> version.

## Roles

| Role | Runs on | Does |
|---|---|---|
| `board_config` | a board | Merges layered inventory into `board_config`, `board_config_build` and the rootfs image source |
| `image_build` | a Docker-capable builder | Builds an Armbian image with `armbian/build` and the board's userpatches |
| `rootfs_provision` | the netboot server | Extracts an image into a per-host NFS root and stages kernel, initrd and dtb for TFTP |
| `pxelinux_render` | the control node (delegated) | Renders the board's `01-<mac>` pxelinux.cfg |
| `board_boot_wait` | a board | Power-cycles through the caller's hook and waits for SSH, with retries |
| `board_boot_verify` | a board | Asserts the root filesystem matches the boot mode |
| `bootstrap_armbian` | a fresh board, as root | Creates an SSH-key automation user with passwordless sudo |
| `disk_image` | a board | Streams an image onto a block device |
| `disk_provision` | a board | Applies a GPT layout with `systemd-repart` and copies a root filesystem onto it |

Each role's README and `meta/argument_specs.yml` are the parameter reference;
[`playbooks/examples/`](playbooks/examples/) has one short call per role.

## Boot modes

Every board's pxelinux.cfg carries all labels; its `default` line picks one.

| Mode | Kernel from | Root filesystem | `board_boot_verify` expects |
|---|---|---|---|
| `nfs` | TFTP | NFS export `<root path>/<hostname>` | an `nfs`/`nfs4` root |
| `sd` | TFTP | `root=LABEL=armbi_root` (SD card) | a non-NFS root on `/dev/*` |
| `local` | TFTP | `root=LABEL=armbi_root_local` (written by `disk_provision`) | a non-NFS root on `/dev/*` |
| `local_kernel` | the local disk (`localboot 0`, U-Boot's `localcmd`) | the local disk | a non-NFS root on `/dev/nvme*` |

`local_kernel` needs a U-Boot that defines `localcmd`, the command `localboot`
runs. Stock Armbian U-Boot does not define one, and the collection does not
ship it: add it to your image through an Armbian userpatch (`image_build`
installs userpatches). The other three modes work with stock U-Boot once the
board tries PXE.

## Wiring it together

A consumer typically:

1. layers board data in inventory (`board_config_family` in a SoC group,
   `board_config_model` in a model group, `board_config_host` in host vars,
   and the matching `board_config_build_*` layers) and runs `board_config`;
2. on a builder, feeds `board_config_build` into `image_build` and publishes
   `<name>/{image, image.sha, manifest.json}` under an HTTP assets tree;
3. resolves the image URL with `board_config` `tasks_from: rootfs_src` and runs
   `rootfs_provision` on the netboot server;
4. renders the pxelinux.cfg with `pxelinux_render` (console and earlycon from
   `board_config`) and uploads `pxelinux_render_file` to its TFTP server;
5. boots with `board_boot_wait`, passing its own power-cycle tasks file, then
   checks the result with `board_boot_verify`.

```yaml
- name: Boot a board from NFS
  hosts: boards
  gather_facts: false
  tasks:
    - name: Resolve hardware facts
      ansible.builtin.include_role:
        name: david_igou.armbian.board_config

    - name: Render the pxelinux.cfg
      ansible.builtin.include_role:
        name: david_igou.armbian.pxelinux_render
        apply:
          delegate_to: localhost
      vars:
        pxelinux_render_board_mac: "{{ board_mac }}"
        pxelinux_render_boot_mode: nfs
        pxelinux_render_console: "{{ board_config.console }}"
        pxelinux_render_nfs_server_ip: 192.0.2.10
        pxelinux_render_nfs_root_path: /srv/netboot/rootfs
        pxelinux_render_hostname: "{{ inventory_hostname }}"
        pxelinux_render_output_dir: "{{ playbook_dir }}/.cache/pxelinux.cfg"

    # Upload pxelinux_render_file to the TFTP server here (consumer-specific).

    - name: Power-cycle and wait
      ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_wait
      vars:
        board_boot_wait_power_cycle_tasks: "{{ playbook_dir }}/tasks/power_cycle.yml"
        board_boot_wait_attempts: 3

    - name: Check the board booted from NFS
      ansible.builtin.include_role:
        name: david_igou.armbian.board_boot_verify
      vars:
        board_boot_verify_mode: nfs
```

## Requirements

- ansible-core 2.19 or later.
- `ansible.posix` (installed with the collection).
- Host-side tools per role, listed in each role's README (for example Docker
  on the builder, `losetup` and `rsync` on the netboot server).
- `sshpass` on the control node for `bootstrap_armbian`, which first logs in
  with a password.

## Installation

```bash
ansible-galaxy collection install david_igou.armbian
```

```yaml
# requirements.yml
collections:
  - name: david_igou.armbian
    version: 0.1.0-alpha
```

## Testing

Every role has a [Molecule](https://ansible.readthedocs.io/projects/molecule/)
scenario under [`extensions/molecule/`](extensions/molecule/), provisioned
with `david_igou.molecule_provisioners` (podman or local qemu VMs).

```bash
make lint
make molecule SCENARIO=board_config   # one scenario
make molecule                          # all scenarios
```

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). This is a personal project with
best-effort support through
[GitHub issues](https://github.com/david-igou/ansible-collection-armbian/issues);
security reports follow [SECURITY.md](SECURITY.md). Release notes are in
[CHANGELOG.rst](CHANGELOG.rst).

## License

MIT. See [LICENSE](LICENSE).
