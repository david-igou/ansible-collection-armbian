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

- Multi-disk VM scenarios. Where a role needs a second block device
  (`disk_image`, `disk_provision`, `image_extract`), the scenario creates
  a sparse file inside the VM and binds it to a loop device. molecule_provisioners
  exposes only one virtio disk per host (the cloud-init overlay), and the
  in-VM loopfile is a proven workaround (current podman scenarios use it).
  Adding multi-disk support to molecule_provisioners is a future enhancement
  if a real per-device assertion becomes necessary.
- Per-role hardware-equivalent assertions. Roles that need real PXE-booted
  board state (`board_boot_verify`) or that wrap Ansible's own modules
  with no role logic (`board_boot_wait`) are deliberately uncovered.
  `playbooks/test_hardware_e2e.yml` is their integration test.
- Touching `playbooks/`, `roles/*/tasks/`, or `vars/`. This is a test-layer
  change only on the armbian_netboot side.

## molecule_provisioners is modifiable

The companion collection (`david_igou.molecule_provisioners`) is privately
used. If the implementation surfaces a gap, fix it there and push — same
operator, same release cadence, no external consumers to break. The
implementation plan flags places where a collection change may be needed
versus places where the existing API suffices.

Identified gap (resolved by existing escape hatch): the qemu role's
`user-data.j2` template creates only the configured `ssh_user` and locks
root. `bootstrap_armbian` needs root SSH with the default Armbian password
to simulate a fresh-flash board. Resolution: ship a scenario-local
`user-data.j2` and point at it via `mp_qemu_template_dir_override` (already
supported by the role — see `_seed_iso.yml`). No provisioner change
required.

Other gaps (not currently blocking, listed for visibility):
- No multi-disk per-VM. Worked around with in-VM loopfile. If a future
  scenario must assert against a real second virtio disk, add
  `extra_disks: [{size, format?}]` to the qemu schema.
- No `cpu host` passthrough toggle. Comment in `_create_process.yml`
  notes this is deferred; not needed for these scenarios.

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
| 1 | `bootstrap_armbian` | qemu (UEFI) | Armbian Trixie cloud_minimal | Role on fresh Armbian VM (root/1234) |
| 2 | `disk_image` | qemu | Debian Trixie genericcloud | Streaming write to loop device |
| 3 | `disk_provision` | qemu | Debian Trixie genericcloud | systemd-repart + preserve + populate |
| 4 | `image_extract` | qemu | Debian Trixie genericcloud | losetup + mount + rsync + artifact copy |
| 5 | `rootfs_clone` | podman | debian:13 | Reflink fallback + identity reset |
| 6 | `pxelinux_render` | podman | debian:13 | Template rendering (nfs/sd/verbose/local_kernel/extra_modes) |
| 7 | `image_build` | qemu (heavy) | Debian Trixie genericcloud | Real Armbian build — slow, gated/manual (was kubevirt before user redirect on 2026-05-22) |
| 8 | `local_kernel_render` | podman | docker.io/geerlingguy/docker-ubuntu2404-ansible | `render_localcmd_chain.j2` macro output |
| 9 | `persist_uboot_env` | podman | docker.io/geerlingguy/docker-ubuntu2404-ansible | `compose_uboot_env_vars.yml` precedence |

### Image source rationale (added 2026-05-22)

The original spec called for "Armbian UEFI x86 Trixie cloud_minimal qcow2"
across all qemu scenarios. Implementation surfaced a hard incompatibility:

- The Armbian `cloud_minimal` image variant **does not ship cloud-init**
  (the "cloud" refers to the cloud kernel, not cloud-init enablement).
- `david_igou.molecule_provisioners.qemu` v1.1 provisions VMs exclusively
  via cloud-init NoCloud seed ISOs for SSH-key + user injection.
- Without cloud-init, there is no mechanism for the provisioner's prepare
  phase to authenticate.

**Resolution**: Debian Trixie (`debian-13-genericcloud-amd64.qcow2`) for
all qemu scenarios except `bootstrap_armbian`. The role logic under test
in disk_image / disk_provision / image_extract / image_build is
distro-agnostic — Debian or Armbian userland makes no difference to xz
streaming, systemd-repart, loop-mount, or armbian/build's Docker host
requirements.

`bootstrap_armbian` is the exception: its whole purpose is bootstrapping
the Armbian fresh-flash workflow (root SSH with password `1234`, remove
`/root/.not_logged_in_yet`, etc.). Testing it against a non-Armbian image
would test nothing. To make Armbian work, two molecule_provisioners
enhancements were required:

1. **UEFI firmware support** (already landed: commits `549a7b5` + `10c8aa1`
   on molecule_provisioners main). The `mp.qemu.firmware: uefi` per-host
   option launches the VM with OVMF pflash drives — required since the
   Armbian image is UEFI-only.
2. **Cloud-init bypass** (still to be added). Provide a per-host
   `mp.qemu.skip_cloud_init: true` option that omits the seed-ISO mount
   and writes the runtime inventory with password auth + the consumer's
   declared user. The bootstrap_armbian scenario then connects as
   `root:1234` directly. See Task 3.4 for implementation.

Not covered (with rationale in `extensions/molecule/README.md`):

- **`board_boot_wait`** — single `wait_for` + `wait_for_connection` wrapper. Exercising the wrapper exercises Ansible's own modules, not role logic. Hardware E2E covers the real concern.
- **`board_boot_verify`** — asserts `ansible_mounts['/']` matches `boot_mode`. Verifying that on a stock qcow2 boot requires either staging an NFS sidecar VM (large plumbing, low signal) or asserting the negative path only (no positive coverage). `playbooks/test_hardware_e2e.yml` exercises both modes on real hardware.

## Per-scenario design

### 1. `bootstrap_armbian` (qemu)

The role's contract: connect as root with the Armbian default password, create
an unprivileged user, authorise a fixture SSH key, drop a NOPASSWD sudoers
file, remove `/root/.not_logged_in_yet`, set `PasswordAuthentication no`.

**Prepare strategy** — clean version using the existing escape hatch:

The scenario ships its own `templates/user-data.j2` that diverges from
molecule_provisioners' stock template by:

- Setting a root password (`chpasswd: list: ['root:1234']`, `expire: false`)
- `ssh_pwauth: true`
- Sshd override to `PermitRootLogin yes`
- Touching `/root/.not_logged_in_yet` so the role has the sentinel to remove
- *Not* creating an unprivileged `cloud-user` (the role does that)

The scenario sets `mp_qemu_template_dir_override:
"{{ playbook_dir }}/templates"` in `inventory/group_vars/molecule.yml`,
which `_seed_iso.yml` already honours.

**Converge**: runs against an override inventory entry that points
`ansible_user: root` + `ansible_password: 1234` + `ansible_connection: ssh`
+ `ansible_host: 127.0.0.1` + `ansible_port: <slirp port from runtime
inventory>`. The scenario's `prepare.yml` writes this override file under
`{{ molecule_ephemeral_directory }}/inventory/bootstrap_inventory.yml`
after extracting the port from the molecule_provisioners runtime inventory.

**Verify**: SSH in as the new user with the fixture key, run `sudo -n
true`, read `/etc/sudoers.d/<user>`, read `/etc/ssh/sshd_config` and assert
`PasswordAuthentication no`, stat `/root/.not_logged_in_yet` and assert
absent.

**If `mp_qemu_template_dir_override` proves awkward** (e.g., it resolves
the wrong path relative to `playbook_dir` in a molecule context), fall back
to adding `extra_user_data: <jinja-block>` schema to the qemu role and
shipping the diff via that. Either way, no in-VM reverting of cloud-init
state is needed.

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

Install from git, not Galaxy — the collection is privately published and
git lets us iterate on it without a Galaxy release per change.

```yaml
collections:
  - name: https://github.com/david-igou/ansible-collection-molecule_provisioners.git
    type: git
    version: main
```

Molecule's dependency phase consumes this via `ansible-galaxy collection
install -r requirements.yml`. The scenario's `molecule.yml` does not
need its own `dependency` block — relying on the collection being
installed at the project root (where pytest / `molecule test` is invoked
from) keeps the install step the same for both pre-commit and CI.

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
- **Ambiguity check**: `image_extract` fixture image source resolved (option A: real SBC `.img.xz`). `bootstrap_armbian` cloud-init customisation resolved (use existing `mp_qemu_template_dir_override`; fall back to extending qemu schema only if that path proves awkward).
- **Out-of-scope reminders**: not touching `roles/`/`playbooks/`/`vars/` in armbian_netboot; not adding multi-disk VM support to molecule_provisioners; not covering `board_boot_wait` / `board_boot_verify`. molecule_provisioners IS in scope for fixes if the implementation surfaces blockers.

## Implementation plan

To be written via the `superpowers:writing-plans` skill once this design is approved.
