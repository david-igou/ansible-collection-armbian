# Molecule scenarios

Each scenario lives in its own subdirectory. Invoke from the
collection root:

```bash
# All scenarios, sequentially:
MOLECULE_GLOB="extensions/molecule/*/molecule.yml" molecule test --all

# A single scenario:
MOLECULE_GLOB="extensions/molecule/*/molecule.yml" molecule test -s <scenario>
```

`MOLECULE_GLOB` overrides molecule's default `molecule/<scenario>/`
layout to point at this collection's `extensions/molecule/<scenario>/`
layout. Running from the collection root also lets molecule
auto-discover `extensions/molecule/config.yml` (which only fires when
invoked from collection root, not a scenario subdir).

Backends come from [`david_igou.molecule_provisioners`](https://galaxy.ansible.com/ui/repo/published/david_igou/molecule_provisioners/),
which is **not** in the root `requirements.yml` — it is a test-only
dependency listed in `extensions/molecule/requirements-test.yml`.
Molecule resolves it automatically via its `dependency` step
(configured in `extensions/molecule/config.yml`); no separate install
command is needed. Strict consumers of the collection never auto-pull
it because it is absent from the root `requirements.yml`.

| Scenario | Role exercised | Default backend | Image |
|---|---|---|---|
| `board_boot_verify` | `board_boot_verify` | qemu | Debian 13 (Trixie) genericcloud |
| `board_boot_wait` | `board_boot_wait` | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `bootstrap_armbian` | `bootstrap_armbian` | qemu (UEFI) | Armbian Trixie UEFI x86 cloud_minimal |
| `disk_image` | `disk_image` | qemu | Debian 13 (Trixie) genericcloud |
| `disk_provision` | `disk_provision` | qemu | Debian 13 (Trixie) genericcloud |
| `image_build` | `image_build` (skip-build short-circuit) | qemu | Debian 13 (Trixie) genericcloud |
| `local_kernel_render` | `image_build` (template macro) | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `persist_uboot_env` | `compose_uboot_env_vars.yml` task | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `pxelinux_render` | `pxelinux_render` | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `rootfs_provision` | `rootfs_provision` | qemu | Debian 13 (Trixie) genericcloud |

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

## What the board_boot_* scenarios cover

- **`board_boot_wait`** — happy-path (instance reachable, role completes quickly) plus timeout-path (unroutable host in TEST-NET-2, role MUST fail-into-rescue). Exercises the wrapper's contract; the real hardware concern (board comes up after a cold boot) is still covered by `playbooks/tests/test_hardware_e2e.yml`.
- **`board_boot_verify`** — runs against a real Debian VM (qemu) so `ansible_facts['mounts']['/']` is populated. Asserts `sd`/`local` modes pass (container/VM has a block-device `/`) and `nfs`/`local_kernel` modes correctly fail-into-rescue (rootfs is neither NFS nor `/dev/nvme*`). NFS and local_kernel happy paths still require real hardware via `playbooks/tests/test_hardware_e2e.yml`.

## Why `image_build` and `bootstrap_armbian` are special

- **`image_build`** exercises the role's check_manifest short-circuit instead of running a real Armbian build. `prepare.yml` pre-seeds `manifest.json` plus a placeholder `.img.xz` with a `patch_hash` matching the userpatches list declared in `inventory/group_vars/molecule.yml`; the role then runs preflight + manage_checkout + apply_userpatches + compute_inputs + check_manifest and skips `invoke_build`. Real-image production is left to `playbooks/build_and_publish_from_inventory.yml` against the `armbian_builders` inventory — that is where you validate changes that affect actual compile.sh output.
- **`bootstrap_armbian`** is the only qemu scenario using the actual Armbian image. Other qemu scenarios use Debian Trixie genericcloud because the Armbian cloud_minimal variant ships **without** cloud-init, which molecule_provisioners' qemu role uses for SSH-key injection. The bootstrap_armbian scenario bypasses that injection and connects as `root` with the Armbian default password `1234` — exactly what the role is built to take over.

