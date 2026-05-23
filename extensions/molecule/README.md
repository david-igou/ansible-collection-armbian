# Molecule scenarios

Each scenario lives in its own subdirectory and is invoked via
`cd extensions/molecule/<scenario> && molecule test`. Backends are
provided by [`david_igou.molecule_provisioners`](https://github.com/david-igou/ansible-collection-molecule_provisioners)
(installed via `requirements.yml` at the collection root).

| Scenario | Role exercised | Default backend | Image |
|---|---|---|---|
| `bootstrap_armbian` | `bootstrap_armbian` | qemu (UEFI) | Armbian Trixie UEFI x86 cloud_minimal |
| `disk_image` | `disk_image` | qemu | Debian 13 (Trixie) genericcloud |
| `disk_provision` | `disk_provision` | qemu | Debian 13 (Trixie) genericcloud |
| `image_extract` | `image_extract` | qemu | Debian 13 (Trixie) genericcloud |
| `image_build` | `image_build` (skip-build short-circuit) | qemu | Debian 13 (Trixie) genericcloud |
| `local_kernel_render` | `image_build` (template macro) | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `persist_uboot_env` | `compose_uboot_env_vars.yml` task | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `pxelinux_render` | `pxelinux_render` | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `rootfs_clone` | `rootfs_clone` | podman | `geerlingguy/docker-ubuntu2404-ansible` |

Switch backend per invocation (only meaningful when the scenario's
inventory ships multiple `mp.<backend>` blocks):

```bash
PROVISIONER=podman molecule test
```

## Backend prerequisites on the controller

| Backend | Required tools |
|---|---|
| podman | `podman` |
| qemu | `qemu-system-x86_64`, `qemu-img`, `cloud-localds` (or `genisoimage`), OVMF firmware (for UEFI scenarios); `/dev/kvm` strongly recommended — TCG works but is much slower |

The devcontainer (`/workspace/igou-devenv`) ships all of the above plus
`/dev/kvm` passthrough.

## Why some roles aren't covered

Two roles are deliberately not exercised by molecule:

- **`board_boot_wait`** — a thin wrapper around `wait_for` + `wait_for_connection`. Asserting that the wrapper works asserts that Ansible's own modules work. `playbooks/test_hardware_e2e.yml` exercises the real concern (board comes up after a cold boot).
- **`board_boot_verify`** — asserts `ansible_mounts['/']` matches the declared boot mode. Meaningful only against a real PXE-booted board; a stock cloud-image VM can't produce that state without standing up an NFS sidecar (and at that point we're testing the sidecar, not the role). `playbooks/test_hardware_e2e.yml` covers both NFS and local modes on real hardware.

## Why `image_build` and `bootstrap_armbian` are special

- **`image_build`** exercises the role's check_manifest short-circuit instead of running a real Armbian build. `prepare.yml` pre-seeds `manifest.json` plus a placeholder `.img.xz` with a `patch_hash` matching the userpatches list declared in `inventory/group_vars/molecule.yml`; the role then runs preflight + manage_checkout + apply_userpatches + compute_inputs + check_manifest and skips `invoke_build`. Real-image production is left to `playbooks/build_image.yml` against the `armbian_builders` inventory — that is where you validate changes that affect actual compile.sh output.
- **`bootstrap_armbian`** is the only qemu scenario using the actual Armbian image. Other qemu scenarios use Debian Trixie genericcloud because the Armbian cloud_minimal variant ships **without** cloud-init, which molecule_provisioners' qemu role uses for SSH-key injection. The bootstrap_armbian scenario bypasses that injection and connects as `root` with the Armbian default password `1234` — exactly what the role is built to take over.

## Spec & plan

- Design: [`docs/superpowers/specs/2026-05-22-qemu-molecule-scenarios-design.md`](../../docs/superpowers/specs/2026-05-22-qemu-molecule-scenarios-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-05-22-qemu-molecule-scenarios.md`](../../docs/superpowers/plans/2026-05-22-qemu-molecule-scenarios.md)
