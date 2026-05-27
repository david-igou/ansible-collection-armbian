# david_igou.armbian

![Galaxy Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fgalaxy.ansible.com%2Fapi%2Fv3%2Fplugin%2Fansible%2Fcontent%2Fpublished%2Fcollections%2Findex%2Fdavid_igou%2Farmbian%2F&query=%24.highest_version.version&label=galaxy)
![Ansible](https://img.shields.io/badge/ansible-%3E%3D2.15-blue?logo=ansible)
![CI](https://img.shields.io/github/actions/workflow/status/david-igou/ansible-collection-armbian/tests.yml?branch=main&label=CI)
![License](https://img.shields.io/github/license/david-igou/ansible-collection-armbian)
![Last Commit](https://img.shields.io/github/last-commit/david-igou/ansible-collection-armbian)

## Description

Ansible collection for end-to-end management of Armbian-based ARM SBCs:
build custom images with PXE-first U-Boot, stage NFS rootfs templates and
TFTP assets, toggle boards between SD and NFS rootfs via PXE, provision
local disks via `systemd-repart`, and drive PoE power cycles.

Roles are single-purpose state enforcers; playbooks compose them into
workflows. Switch-ecosystem-specific behaviour lives in swappable
reference playbooks under [`playbooks/routeros/`](playbooks/routeros/);
substitute a parallel directory to target a different ecosystem.

Targeted at homelab / lab operators running a fleet of Armbian-supported
SBCs with PXE-netboot from a router and NFS-from-NAS topology.

> **Status: early-stage (4.x) — expect breaking changes.** Inventory
> variables, defaults, group names, role names, and playbook names may
> shift between 4.x releases without long deprecation windows. Pin a
> specific version in your `requirements.yml`.

## Requirements

- **Ansible** >= 2.15 on the control node
- **Netboot server** reachable via SSH (`become: true`) that exports
  per-host NFS rootfs to the boards. Anything that speaks NFSv4 + SSH.
- **RouterOS device** (or equivalent) reachable via
  `ansible.netcommon.network_cli`. The SBC subnet's DHCP `next-server`
  must already point at this device (owned externally).
- **Docker-capable build host** in the `armbian_builders` inventory
  group — only needed if you build your own images.

### Collection dependencies

| Collection | Required for | Version |
|---|---|---|
| `ansible.posix` | always (auto-resolved by Galaxy) | >= 1.5.0 |
| `community.routeros` | RouterOS reference playbooks | >= 2.0.0 |
| `ansible.netcommon` | RouterOS reference playbooks | >= 5.0.0 |

The RouterOS deps are not auto-resolved (only the reference playbooks
under `playbooks/routeros/` import them):

```bash
ansible-galaxy collection install -r playbooks/routeros/requirements.yml
```

See [docs/architecture.md](docs/architecture.md) for the full role /
playbook / data-flow picture.

## Installation

Install from Ansible Galaxy:

```bash
ansible-galaxy collection install david_igou.armbian
```

Or pin a version in `requirements.yml`:

```yaml
---
collections:
  - name: david_igou.armbian
    version: 0.0.1-alpha
```

Upgrade to the latest:

```bash
ansible-galaxy collection install david_igou.armbian --upgrade
```

## Use Cases

### Build a custom PXE-first Armbian image

Stock Armbian images put PXE at position 6 in U-Boot's `BOOT_TARGETS`.
This collection patches U-Boot to put PXE first so a board reliably
netboots from a fresh power-up.

```bash
ansible-playbook playbooks/build_and_publish_from_inventory.yml
```

Produces a `.img.xz` on `armbian_builders` and publishes it to the
netboot server's HTTP root. See
[docs/lifecycle.md §0.1](docs/lifecycle.md#01-build-or-download-the-custom-armbian-image).

### Onboard a freshly flashed board

After flashing the custom image to an SD card and powering the board on:

```bash
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01
ansible-playbook playbooks/stage_netboot_assets.yml
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01
```

Creates the SSH-key user, stages the per-host NFS rootfs, writes the
per-board `pxelinux.cfg/01-<MAC>`, cold-cycles the board via PoE, and
verifies it comes up on the declared rootfs. Full walkthrough:
[docs/lifecycle.md](docs/lifecycle.md).

### Toggle a board between NFS and SD rootfs

Flip a board's boot mode without touching the board:

```bash
# Inventory-driven (persists across runs):
#   edit armbian_boot_mode on the host, then converge.
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01

# Ad-hoc (single-run override):
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 -e armbian_boot_mode=sd
```

See [docs/boot-mode-override.md](docs/boot-mode-override.md) for all
three methods (inventory, `-e`, U-Boot env).

### Provision a board's local NVMe for high-IO workloads

Boot a board into NFS so its `/` is the cleanly-identity-reset per-host
rootfs, then copy it onto a local NVMe with a declarative GPT layout
(supports `preserve_on_reprovision: true` per partition for state you
want to survive re-runs):

```bash
ansible-playbook playbooks/reprovision_to_local.yml --limit orange-pi-5-max-01
```

Auto-reverts to NFS on local-boot failure with a diagnostic bundle
captured. See
[docs/runbooks/reprovision-local-disk.md](docs/runbooks/reprovision-local-disk.md).

### Recover a wedged board via PoE

```bash
ansible-playbook playbooks/poe_control.yml \
  --limit orange-pi-5-pro-01 -e armbian_poe_action=cycle
```

Delegates the PoE command to each board's `armbian_poe_switch`. Also
takes `armbian_poe_action=off` / `=on`. See
[docs/daily-operations.md](docs/daily-operations.md).

## Roles

| Role | Runs on | Enforces / produces |
|---|---|---|
| [`image_build`](roles/image_build/) | `armbian_builders` | Custom Armbian `.img.xz` with PXE-first U-Boot baked in; staged to controller (companion `build_and_publish_from_inventory.yml` publishes to the netboot server; runs per-host after resolving the `armbian_build` profile) |
| [`rootfs_provision`](roles/rootfs_provision/) | netboot server | Per-host NFS rootfs: resolves `armbian_rootfs_src`, extracts per-model template from `.img.xz`, reflink-clones per-host rootfs, resets identity (hostname / machine-id / SSH host keys), emits TFTP artefacts |
| [`disk_image`](roles/disk_image/) | a board | Stream an `.img.xz` or `.img` (URL or absolute path) to a whole-disk block device via `curl \| xz -dc \| dd` with a mount-aware refusal guard |
| [`disk_provision`](roles/disk_provision/) | a board | Apply a declarative GPT layout to one block device via `systemd-repart`, rsync `source` rootfs onto it, regenerate `/etc/fstab` (root by `LABEL=`). Idempotent on filesystem label; supports `preserve_on_reprovision: true` per partition for state preservation (e.g. `/var` for k3s). Single-disk contract — multi-disk hosts loop the role. |
| [`pxelinux_render`](roles/pxelinux_render/) | `localhost` (via `delegate_to`) | One `01-<mac>` pxelinux.cfg file in a local directory |
| [`board_boot_wait`](roles/board_boot_wait/) | a board | `wait_for` TCP/22 + `wait_for_connection` SSH (no power knowledge) |
| [`board_boot_verify`](roles/board_boot_verify/) | a board | Asserts `ansible_mounts['/']` matches declared boot mode |
| [`bootstrap_armbian`](roles/bootstrap_armbian/) | a board | SSH-key user with passwordless sudo on a freshly flashed board |

## Testing

[Molecule](https://ansible.readthedocs.io/projects/molecule/) scenarios
live in `extensions/molecule/`. They use a pluggable provisioner pattern
so the same converge / verify plays can run against either local
containers or real VMs.

```bash
make molecule                       # podman driver, all scenarios
make molecule SCENARIO=rootfs_provision
make molecule-kubevirt              # KubeVirt driver (heavier scenarios)
```

See [`extensions/molecule/README.md`](extensions/molecule/README.md) for
the scenarios list, driver-selection knobs, and what each scenario
covers.

End-to-end hardware tests against a real fleet (`test_hardware_e2e.yml`,
`test_fleet_e2e.yml`, `test_reprovision_e2e.yml`, etc.) are not run in
CI — they require physical boards. See
[docs/daily-operations.md](docs/daily-operations.md) for usage.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev runbook (Makefile
targets, PR checklist, board onboarding pointer). The project follows
the [Ansible Community Code of Conduct](https://docs.ansible.com/ansible/devel/community/code_of_conduct.html);
local copy at [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Bug reports and feature requests:
<https://github.com/david-igou/ansible-collection-armbian/issues/new/choose>.

## Support

This is a personal-project collection — **not an Ansible Certified
Collection**, no commercial support. Best-effort community support via
GitHub:

- **Issues**: <https://github.com/david-igou/ansible-collection-armbian/issues>
- **Security**: see [SECURITY.md](SECURITY.md) for the private-disclosure flow
- **Discussions / questions**: open an issue; there is no separate forum

Only the most recent release receives fixes. The collection is at
0.0.x (alpha) — pin to a specific version if you depend on a given
shape.

## Release Notes and Roadmap

- **Release notes**: [CHANGELOG.rst](CHANGELOG.rst)
- **Galaxy listing**: <https://galaxy.ansible.com/ui/repo/published/david_igou/armbian/>
- **Roadmap**: no formal roadmap. Open issues tagged `enhancement` at
  <https://github.com/david-igou/ansible-collection-armbian/issues?q=label%3Aenhancement>
  are the de-facto backlog.

## Related Information

Documentation in this repo:

- [Architecture and data flow](docs/architecture.md) — roles,
  dependencies, mental model, full playbooks table
- [Lifecycle walkthrough](docs/lifecycle.md) — Phase 0 (control plane)
  + Phase 1 (per-board onboarding)
- [Daily operations](docs/daily-operations.md) — boot-mode toggling,
  PoE control, reprovisioning, hardware E2E
- [Boot mode override methods](docs/boot-mode-override.md) — inventory,
  `-e`, and U-Boot env approaches
- [Retry / timeout knob recipes](docs/retry-configuration.md)
- [Reprovision a board's local disk](docs/runbooks/reprovision-local-disk.md)

External:

- [Armbian](https://www.armbian.com/) — upstream OS
- [armbian/build](https://github.com/armbian/build) — used by `image_build`

## License Information

MIT License. See [LICENSE](LICENSE).
