# Per-role molecule scenarios via `david_igou.molecule_provisioners` — design

**Date**: 2026-05-22
**Status**: brainstorming complete; implementation plan TBD
**Scope**: `david_igou.armbian_netboot` collection test layer
**Supersedes**: current `extensions/molecule/` layout (in-repo
`provisioners/` directory + legacy `platforms:`/`provisioner:` molecule shape)

## Goal

Replace the in-repo molecule provisioner setup with the published
`david_igou.molecule_provisioners` v1.1 collection, and land one molecule
scenario per role (plus two retained auxiliary scenarios). Real-VM scenarios
boot the Armbian UEFI x86 Trixie qcow2 cloud image; pure-template scenarios
stay on podman; the heavy `image_build` scenario stays on KubeVirt.

After this change a single command — `cd extensions/molecule/<scenario> &&
molecule test` — exercises a role end-to-end with the right backend
auto-selected, and no per-repo `create.yml`/`destroy.yml`/`prepare.yml`
implementations live in this collection.

## Non-goals

- Modifying `david_igou.molecule_provisioners`. Its v1.1 qemu role
  (`process` driver, SLIRP networking, single virtio disk) is the contract;
  this collection consumes it as-is.
- Multi-disk VM scenarios. Where a role needs a second block device
  (`disk_image`, `disk_provision`, `image_extract`), the scenario creates
  a sparse file inside the VM and binds it to a loop device. molecule_provisioners
  exposes only one virtio disk per host (the cloud-init overlay) and adding
  a second is a v1.2-or-later change in that collection.
- Per-role hardware-equivalent assertions. Roles that need real PXE-booted
  board state (`board_boot_verify`) or that wrap Ansible's own modules
  with no role logic (`board_boot_wait`) are deliberately uncovered.
  `playbooks/test_hardware_e2e.yml` is their integration test.
- Touching `playbooks/`, `roles/*/tasks/`, or `vars/`. This is a test-layer
  change only.

## Why

Three problems with the current `extensions/molecule/` layout:

1. **In-repo provisioner is private duplication.** `extensions/molecule/provisioners/podman/{create,destroy,prepare}.yml` and the parallel `kubevirt/` directory reimplement what `david_igou.molecule_provisioners` ships. Bug fixes to the published collection don't reach this repo; bug fixes here don't reach other consumers. The collection exists specifically to remove this duplication.
2. **Legacy molecule shape.** Scenarios use `platforms:` + `provisioner:` (pre-ansible-native). The published collection's README documents the modern `ansible:` block shape. Continuing to use the legacy shape closes off backend additions (qemu in v1.1, future backends in v1.x) without per-scenario rewrites.
3. **Three roles silently uncovered.** `image_extract` (loop-device + mount, broken under nested-container constraints), `board_boot_wait` (no signal), `board_boot_verify` (needs real board). The current `extensions/molecule/README.md` documents this gap. A qemu backend solves `image_extract`; the other two stay uncovered for documented reasons.

## Scenarios — final list

Nine scenarios total. Seven roles get a 1:1 scenario; two auxiliary scenarios
(neither tied to a single role) are kept; two roles are intentionally not
covered by molecule.

| # | Scenario dir | Backend | Image | Tests |
|---|---|---|---|---|
| 1 | `bootstrap_armbian` | qemu | Trixie cloud-minimal | Role on fresh Armbian VM |
| 2 | `disk_image` | qemu | Trixie cloud-minimal | Streaming write to loop device |
| 3 | `disk_provision` | qemu | Trixie cloud-minimal | systemd-repart + preserve + populate |
| 4 | `image_extract` | qemu | Trixie cloud-minimal | losetup + mount + rsync + artifact copy |
| 5 | `rootfs_clone` | podman | debian:13 | Reflink fallback + identity reset |
| 6 | `pxelinux_render` | podman | debian:13 | Template rendering (nfs/sd/verbose/local_kernel/extra_modes) |
| 7 | `image_build` | kubevirt | (containerdisk) | Real Armbian build — slow, gated |
| 8 | `local_kernel_render` | podman | debian:13 | `render_localcmd_chain.j2` macro output |
| 9 | `persist_uboot_env` | podman | debian:13 | `compose_uboot_env_vars.yml` precedence |

Not covered (with rationale in `extensions/molecule/README.md`):

- **`board_boot_wait`** — single `wait_for` + `wait_for_connection` wrapper. Exercising the wrapper exercises Ansible's own modules, not role logic. Hardware E2E covers the real concern.
- **`board_boot_verify`** — asserts `ansible_mounts['/']` matches `boot_mode`. Verifying that on a stock qcow2 boot requires either staging an NFS sidecar VM (large plumbing, low signal) or asserting the negative path only (no positive coverage). `playbooks/test_hardware_e2e.yml` exercises both modes on real hardware.

## Per-scenario design

### 1. `bootstrap_armbian` (qemu)

The role's contract: connect as root with the Armbian default password, create
an unprivileged user, authorise a fixture SSH key, drop a NOPASSWD sudoers
file, remove `/root/.not_logged_in_yet`, set `PasswordAuthentication no`.

**Prepare**: cloud-init must put the VM in the same state as a fresh Armbian
flash — root must accept the configured password over SSH. The default
Trixie cloud-minimal image's cloud-init creates `cloud-user` and locks root.
The scenario overrides this by writing a `user-data` snippet that sets the
root password and enables `PermitRootLogin yes` + `PasswordAuthentication yes`.

Since `david_igou.molecule_provisioners.qemu`'s `user-data.j2` template is
fixed and only creates the `ssh_user` user, the scenario uses a
`prepare.yml` that runs *after* the molecule_provisioners prepare (which
sets up the unprivileged `cloud-user` over SSH) and reverts the VM to a
"fresh Armbian" state: sets a root password, restores
`PermitRootLogin`/`PasswordAuthentication yes`, restarts sshd, deletes
`cloud-user` so the role doesn't run against a pre-bootstrapped host, and
recreates `/root/.not_logged_in_yet` so the role has something to remove.

**Converge**: runs against a re-targeted inventory (`ansible_user: root`,
`ansible_password: 1234`, `ansible_ssh_pass: 1234`) — molecule_provisioners
writes the runtime inventory under the SSH key, so converge re-points
`hostvars` to the root-with-password path.

**Verify**: SSH in as the new user with the fixture key, run `sudo -n
true`, read `/etc/sudoers.d/<user>`, read `/etc/ssh/sshd_config` and assert
`PasswordAuthentication no`, stat `/root/.not_logged_in_yet` and assert
absent.

### 2. `disk_image` (qemu)

**Prepare**: inside the VM, write a 64 MiB random fixture to `/tmp/test.img`,
`xz -9 /tmp/test.img → /tmp/test.img.xz`, then `truncate -s 1G
/tmp/target.img && losetup -f --show /tmp/target.img > /tmp/target_loop`.

**Converge**: `include_role disk_image` with `image_source=/tmp/test.img.xz`,
`target_device={{ _target_loop }}`.

**Verify**: cmp the first 64 MiB of the loop device against `/tmp/test.img`.
Then run the four negative cases the existing scenario covers (partition
target → fails with `partition` in msg; gibberish source; mounted target;
mismatched extension). Block/rescue captures each failure and asserts the
right error fired.

### 3. `disk_provision` (qemu)

**Prepare**: `truncate -s 2G /tmp/repart.img && losetup -f --show
/tmp/repart.img > /tmp/repart_loop`.

**Converge — pass 1**: `include_role disk_provision` with the three-partition
layout from the existing `disk_provision_loopback` scenario
(`boot/var/root`, with `preserve_on_reprovision: true` on `/var`).

**Converge — pass 2**: write a sentinel file into the `/var` partition,
unmount, re-run `disk_provision` with the same layout. The role should skip
`/var` reformat.

**Converge — pass 3**: same role with `render_only: true` to cover the
render-only mode currently in `disk_provision_render`.

**Verify**: `lsblk -no NAME,FSTYPE,LABEL` shows three ext4 partitions with
correct labels; mount `/var` and assert sentinel file content; assert
`/run/disk_provision/<dev>/repart.d/*.conf` exists and matches expected.

### 4. `image_extract` (qemu)

This is the role that the current README explicitly documents as uncovered
("requires `losetup` + `mount` of a loop device. Even with `privileged: true`
on the podman container, nested-container loop access is unreliable in CI
environments"). A real VM with a real kernel makes this trivial.

**Prepare**: fetch a small Armbian `.img.xz` once and cache it. *Open
question for review*: this role expects a real Armbian image (with
`/boot/dtb/`, `/boot/vmlinuz*`, etc). The minimal Trixie cloud image is not
an SBC image and has no DTB. Options:

- **A**: Pull a real SBC image (e.g. `Armbian_*_Orangepi5-pro_bookworm_current_*.img.xz`)
  from `dl.armbian.com`. ~400 MiB. Slow first download; cached by URL hash.
- **B**: Build a synthetic minimal `.img.xz` in prepare with a fake `/boot`
  layout (vmlinuz/initrd/dtb stub files). Doesn't test the rsync path
  against real Armbian content but exercises the role's flow.

Recommend **A**. The role is meaningless if its inputs don't look like
Armbian. The cache is reused across runs.

**Converge**: `include_role image_extract` with `armbian_image_src=<cached
.img.xz>`, `model_name=orange-pi-5-pro`, `template_dir=/tmp/template`,
`tftp_dir=/tmp/tftp`, `board_dtb=rk3588s-orangepi-5-pro.dtb`.

**Verify**: stat `/tmp/template/bin/bash` (rsync ran); stat
`/tmp/template/.armbian_extract_complete` (sentinel); stat
`/tmp/tftp/{vmlinuz,initrd.img,board.dtb}`.

### 5. `rootfs_clone` (podman)

Mirrors the current scenario verbatim, just on the ansible-native shape.
Synthetic template in `/tmp/fixture/template`, clone to
`/tmp/fixture/clone`, assert identity reset.

Podman is the right backend here: reflink falls back to full copy on the
container's overlayfs anyway, so qemu wouldn't actually exercise the
reflink path with the default backing store. The role's logic (identity
reset, file copy) is what matters.

### 6. `pxelinux_render` (podman)

Mirrors the current scenario verbatim, just on the ansible-native shape.
Renders in nfs/sd/verbose/local_kernel/extra_modes, plus the negative test.

### 7. `image_build` (kubevirt)

Mirrors the current scenario verbatim, just on the ansible-native shape.
Real Armbian build for `orangepi5pro` on `current`, ~30+ min, gated behind
a CI label or manual trigger.

### 8. `local_kernel_render` (podman)

Mirrors the current scenario verbatim, just on the ansible-native shape.
Renders the dispatch table from a three-board fixture and asserts row
content + absence of the no-`local_kernel` board.

### 9. `persist_uboot_env` (podman)

Mirrors the current scenario verbatim, just on the ansible-native shape.
Three host fixtures (override / control / hook-persist) covering the
precedence of `compose_uboot_env_vars.yml`.

## Shared infra

### Scenario directory shape (every scenario)

```
extensions/molecule/<scenario>/
├── molecule.yml                # ansible-native shape, single scenario.name override
├── create.yml                  # import_playbook: david_igou.molecule_provisioners.create
├── destroy.yml                 # import_playbook: david_igou.molecule_provisioners.destroy
├── prepare.yml                 # import_playbook: david_igou.molecule_provisioners.prepare
│                               # + scenario-specific prepare steps (loop devices, fixtures)
├── converge.yml                # role invocation(s)
├── verify.yml                  # assertions
└── inventory/
    ├── hosts.yml               # one host with mp.<backend> blocks
    └── group_vars/
        └── molecule.yml        # mp_backend selector + mp_defaults
```

### `molecule.yml` (identical across scenarios, only `scenario.name` differs)

```yaml
---
ansible:
  executor:
    args:
      ansible_playbook:
        - --inventory=inventory/
        - --inventory=${MOLECULE_EPHEMERAL_DIRECTORY}/inventory/
  playbooks:
    create: create.yml
    destroy: destroy.yml
    prepare: prepare.yml
    converge: converge.yml
    verify: verify.yml

scenario:
  name: <scenario-name>
  test_sequence: [dependency, syntax, create, prepare, converge, verify, destroy]

verifier:
  name: ansible
```

### `inventory/group_vars/molecule.yml` (per scenario; default backend varies)

```yaml
---
mp_backend: "{{ lookup('env', 'PROVISIONER') | default('qemu', true) }}"

mp_defaults:
  qemu:
    cpus: 2
    memory: 2048              # Trixie cloud-minimal boots fine in 1G; 2G for headroom
    ssh_user: cloud-user
  podman:
    command: /sbin/init
    privileged: true
  kubevirt:
    namespace: molecule
    memory: 2Gi
    ssh_user: cloud-user
```

For `disk_image` / `disk_provision` / `image_extract`, podman block needs
`capabilities: [SYS_ADMIN]` + `volumes: ['/dev:/dev']` (matches current
scenarios) — but those scenarios default to qemu, so podman is only used
if the operator explicitly overrides `PROVISIONER=podman`.

Each scenario's default `PROVISIONER` is set by `mp_backend` line above;
operators override at the command line.

### `inventory/hosts.yml` (per scenario)

```yaml
---
all:
  children:
    molecule:
      hosts:
        test-vm:
          mp:
            qemu:
              image: https://dl.armbian.com/uefi-x86/Trixie_cloud_minimal-qcow2
            podman:
              image: docker.io/library/debian:13
            kubevirt:
              image: quay.io/containerdisks/debian:13
              ssh_user: cloud-user
```

`disk_image` / `disk_provision` / `image_extract` host blocks add the
SYS_ADMIN/volumes podman fields. Scenarios that only ever run under one
backend (`image_build` only under kubevirt) ship only that backend's block.

### `requirements.yml`

Add:

```yaml
collections:
  - name: david_igou.molecule_provisioners
    version: ">=1.1.0,<2.0.0"
```

### Image cache

molecule_provisioners qemu caches qcow2 downloads under
`$XDG_CACHE_HOME/molecule-qemu/<sha256-of-url>/disk.qcow2`. The Trixie
URL is the same across all four qemu scenarios → one download, reused.

The Armbian SBC `.img.xz` fixture for `image_extract` is fetched by
scenario-specific prepare code (not by molecule_provisioners) into the
controller's `~/.cache/armbian-netboot-molecule/` and pushed into the VM
via `synchronize` so the in-VM cache is repopulated quickly across runs.

## Migration plan

### Delete

- `extensions/molecule/provisioners/` (entire dir — podman + kubevirt + group_vars + requirements)
- `extensions/molecule/default/` (smoke scaffold; replaced by per-role coverage)
- `extensions/molecule/disk_provision_loopback/` (consolidated into `disk_provision`)
- `extensions/molecule/disk_provision_render/` (consolidated into `disk_provision`)

### Add (new directories)

- `extensions/molecule/bootstrap_armbian/`
- `extensions/molecule/image_extract/`
- `extensions/molecule/disk_provision/` (replaces both `_loopback` and `_render`)

### Migrate (in place, ansible-native shape + collection-based provisioner)

- `extensions/molecule/disk_image/`
- `extensions/molecule/image_build/`
- `extensions/molecule/local_kernel_render/`
- `extensions/molecule/persist_uboot_env/`
- `extensions/molecule/pxelinux_render/`
- `extensions/molecule/rootfs_clone/`

### Update

- `extensions/molecule/README.md` — rewrite to reflect the new layout, backend rationale, and skip rationale for `board_boot_wait` / `board_boot_verify`.
- `requirements.yml` — add `david_igou.molecule_provisioners`.
- `.github/workflows/` — job matrix per scenario (see CI section).
- `CLAUDE.md` — update the molecule section if it references the old layout.

## CI

Each scenario gets one CI job. Three job families:

| Family | Runner needs | Scenarios |
|---|---|---|
| podman | `podman` | `rootfs_clone`, `pxelinux_render`, `local_kernel_render`, `persist_uboot_env` |
| qemu | `qemu-system-x86_64`, `qemu-img`, `cloud-localds`, ideally `/dev/kvm` | `bootstrap_armbian`, `disk_image`, `disk_provision`, `image_extract` |
| kubevirt | `kubectl` + kind+KubeVirt cluster | `image_build` |

The qemu family falls back to TCG when `/dev/kvm` isn't present. The
qemu role's `mp_qemu_wait_timeout` default (180 s) is already generous
for TCG boot of Trixie cloud-minimal. The `image_extract` job needs an
extra ~30 s prepare for the Armbian `.img.xz` first-time download
(cached on subsequent runs).

`image_build` stays gated (manual dispatch or `ci-image-build` label)
because of wall time.

## Testing — operator entry points

```bash
# Run a scenario with its default backend (per scenario's group_vars)
cd extensions/molecule/<scenario>
molecule test

# Override backend (only meaningful for scenarios with multiple mp.<backend> blocks)
PROVISIONER=podman molecule test
PROVISIONER=qemu molecule test

# Iterate without teardown
molecule create
molecule converge
molecule verify
# ...
molecule destroy
```

For qemu scenarios, the controller (the devcontainer) needs
`qemu-system-x86_64`, `qemu-img`, `cloud-localds` — all already
present in `/workspace/igou-devenv` per its CLAUDE.md.

## Spec self-review

- **Placeholders**: none. All scenario names, backends, and image URLs are concrete.
- **Internal consistency**: `disk_image` / `disk_provision` / `image_extract` need a second block device → addressed via in-VM loop file in each scenario's prepare. Same approach as the current podman scenarios, but now running on a real VM where losetup is reliable.
- **Scope check**: one design doc, one implementation plan. No decomposition needed.
- **Ambiguity check**: one explicit open question flagged in §4 (`image_extract` fixture image source — recommend option A, real SBC image). Resolved during user review.
- **Out-of-scope reminders**: not touching `david_igou.molecule_provisioners`; not touching `roles/`/`playbooks/`/`vars/`; not adding multi-disk VM support; not covering `board_boot_wait` / `board_boot_verify`.

## Implementation plan

To be written via the `superpowers:writing-plans` skill once this design is approved.
