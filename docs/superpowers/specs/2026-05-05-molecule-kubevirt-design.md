---
name: Molecule + KubeVirt scaffolding for `armbian_build`
description: Test scaffold for the `armbian_build` role: KubeVirt provisioner running real Armbian builds inside a CentOS Stream VM on the OCP hub cluster.
---

# Molecule + KubeVirt design

## Goal

Add a Molecule test scenario for the `armbian_build` role that exercises the
**real** end-to-end build path on a freshly provisioned VM, validating the
role's full contract: preflight, checkout, userpatches, manifest, and a real
`compile.sh` Docker-mode invocation that produces a working `.img.xz`. The
scenario is intentionally slow (tens of minutes to hours) and run manually by
an operator with `make molecule-kubevirt SCENARIO=armbian_build`. CI hookup is
deferred to a follow-up issue.

## Why this shape

Approach **C** (real build, KubeVirt only) was chosen over the lighter
alternatives (mocked `compile.sh`, skip-path-only) because:

1. The role's whole reason to exist is producing a working `.img.xz` with
   PXE-first U-Boot. A mocked build proves the Ansible glue runs but tells us
   nothing about whether the produced image actually has the patched
   `BOOT_TARGETS` baked in. That is the only thing the role is for.
2. The reviewer's open question on PR #24 — does `compile.sh` (no `docker`
   subcommand) auto-delegate to Docker on the pinned ref `v26.2.0-trunk.844`?
   — gets answered by the scenario as a side effect: the scenario either
   passes (auto-delegation works) or fails loudly (it doesn't).
3. The scenario doubles as a clean-room reproduction of the operator-side
   environment, useful for upstream-bug triage when an Armbian build flakes.

## Tech stack

- **Molecule** with the `ansible` driver (per devhost reference repo).
- **KubeVirt** on the OCP hub cluster (`api.ocp.igou.systems:6443`).
- **`kubernetes.core`** + **`community.crypto`** Ansible collections for VM
  lifecycle and ephemeral SSH keypair generation.
- VM image: **`quay.io/containerdisks/centos-stream:10`** (CentOS Stream 10).
  Chosen because it has Docker available via the `docker-ce` repo and is what
  the current cluster operator pre-validated for these Molecule runs.

## Cluster constraints (hard ones)

The OpenShift SA `service-accounts/ansible-molecule` (resolved from 1Password
via the `ocp-hub-ansible-molecule.env` envset) has these permissions in the
`molecule` namespace:

| Resource | Verbs |
|---|---|
| `virtualmachines.kubevirt.io` | get/list/watch/create/delete/patch/edit |
| `services` | same |
| `pods` | get/list (no watch, no create) |
| `cdiconfigs.cdi.kubevirt.io`, `storageprofiles.cdi.kubevirt.io` | get/list/watch |
| `datavolumes.cdi.kubevirt.io` | **none** |
| `persistentvolumeclaims` | **none** |
| `configmaps`, `secrets` | **none** (within molecule namespace) |

This rules out the **DataVolume disk strategy** the devhost reference
provisioner uses for sized root disks. The scaffold must work with
**containerDisk + emptyDisk only**.

## Disk strategy: `containerDisk` root + `emptyDisk` scratch

KubeVirt's `emptyDisk` is a sparse qcow2 disk allocated on the node's
ephemeral storage at VM creation time. No PVC, no DataVolume, no
StorageClass involvement — pure VM-spec field. Disk persists across guest-side
reboots; lost on VM deletion. Capacity is bounded by node ephemeral storage,
which on this cluster is ample.

VM disk layout for the scenario:

| `/dev/vd?` | Source | Mounted as | Purpose |
|---|---|---|---|
| `/dev/vda` | containerDisk (CentOS Stream 10) | `/` | OS root |
| `/dev/vdb` | emptyDisk, capacity `100Gi` | `/var/lib/armbian_build` | build cache + checkout + output |
| `/dev/vdc` | cloudInitNoCloud | (cdrom) | one-shot config |

The scenario's `prepare.yml` formats `/dev/vdb` as xfs and mounts it at
`/var/lib/armbian_build`, so the role's default `armbian_build_cache_dir`
works without override. The VM's root filesystem stays the small COW
container image and the multi-GiB build artifacts land on the scratch
disk. Cloud-init's `disk_setup` was tried first but
`cc_disk_setup` 24.x bails on a fresh empty disk on RHEL/CentOS images
(`sfdisk: /dev/vdb: does not contain a recognized partition table`),
so disk format/mount lives in Ansible — also keeps the provisioner
agnostic to filesystem choice for future scenarios.

## Provisioner adaptations vs. devhost reference

The provisioner is conceptually a copy of devhost's
`extensions/molecule/provisioners/kubevirt/`, with three deliberate changes:

1. **Cloud-init `packages:` directive instead of hardcoded `runcmd: yum
   install`.** Devhost's runcmd assumes a RHEL family. We do too in this
   scenario, but the directive form is package-manager-agnostic, so a future
   Ubuntu/Debian platform Just Works. Idempotent and runs before `runcmd`.
2. **Honor `vm.kubevirt.cpu_cores` from platform config.** Devhost VMs get
   the KubeVirt default of 1 vCPU. An Armbian kernel build on 1 vCPU is
   measured in hours; we want 8.
3. **Honor `vm.kubevirt.scratch_disk_size` to attach an `emptyDisk`.** When
   set, the provisioner adds a second disk to the VM and emits cloud-init
   `disk_setup` / `fs_setup` / `mounts` directives so the disk is formatted
   and mounted at `vm.kubevirt.scratch_mount` (default `/var/lib/molecule-scratch`).

These three changes are also useful upstream in devhost; they're contained
enough that we can offer them as a small follow-up PR there.

## Scenario contract

```
extensions/molecule/armbian_build/
├── molecule.yml      # CentOS Stream 10 platform, KubeVirt-only
├── prepare.yml       # install docker-ce, add user to docker group, xz-utils
├── converge.yml      # apply armbian_build role with orangepi5pro + PXE-first patch
└── verify.yml        # assert .img.xz exists, manifest fields are sane,
                      # patch landed at <cache>/build/userpatches/...
```

### `prepare.yml` (scenario-level, runs after the provisioner's prepare)

Runs on the VM. Installs `docker-ce`, `docker-ce-cli`, `containerd.io`,
`xz-utils`, adds the cloud-init user to the `docker` group, enables and
starts `docker.service`, then asserts `docker info` is happy. Mirrors the
production-builder setup contract documented in the role's README.

### `converge.yml`

Single play, single role invocation:

```yaml
- name: Converge — build orangepi5pro Armbian image with PXE-first U-Boot
  hosts: all
  gather_facts: true
  tasks:
    - name: Apply armbian_build role
      ansible.builtin.include_role:
        name: david_igou.armbian.armbian_build
      vars:
        armbian_build_board: orangepi5pro
        armbian_build_branch: current
        armbian_build_release: bookworm
        armbian_build_cache_dir: /var/lib/armbian_build
        armbian_build_output_dir: /var/lib/armbian_build/output
        armbian_build_userpatches:
          - dest: "config/boards/orangepi5pro.conf"
            content: |
              function pre_config_uboot_target__orangepi5pro_pxe_first() {
                  declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                  sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                      include/configs/rockchip-common.h
              }
```

### `verify.yml`

Smoke tests on the converged VM:

- `<output>/orangepi5pro/Armbian_*_orangepi5pro_*.img.xz` exists, size > 100 MiB
- `<output>/orangepi5pro/manifest.json` parses; `image_filename`,
  `armbian_build_ref`, `patch_hash` fields are present and non-empty
- The userpatch file lives at
  `<cache>/build/userpatches/config/boards/orangepi5pro.conf` and contains
  `pre_config_uboot_target__orangepi5pro_pxe_first`
- `xz -t <image>` succeeds (image is a valid xz archive)

## Resource sizing

| Resource | Value | Rationale |
|---|---|---|
| Memory | `16Gi` | Armbian recommends 8 GiB; 16 leaves headroom for the kernel build's parallel ld + Docker overhead |
| CPU cores | `8` | Single biggest contributor to wall time; cluster nodes have plenty |
| Scratch disk | `100Gi` | Cache (~10 GiB) + ccache (~5 GiB) + output (~3 GiB) + build tree + slack |

## Build_ignore

`extensions` and `Makefile` are already in `galaxy.yml` `build_ignore`
(verified). No change needed there.

## Out of scope (explicitly)

- **Podman provisioner.** Not added in this PR. The scenario is KubeVirt-only.
- **GitHub Actions workflow.** Deferred to a follow-up issue.
- **`molecule.yml` parameterization for multiple platforms.** A single CentOS
  Stream 10 platform is enough; the scenario is gated on real-build
  performance and adding distros multiplies wall time without adding
  signal.
- **Mocked-build / skip-path-only scenarios.** Considered, rejected: see
  "Why this shape" above.
- **Role refactor (e.g., `armbian_build_compile_command` override).** Not
  needed since we run the real `compile.sh`.
- **CI for the provisioner adaptation.** This is a manual scenario by design.

## Open question (deferred)

The reviewer flagged that `compile.sh` (without the `docker` subcommand)
auto-delegating to Docker on the pinned ref needs verification. This
scenario *is* that verification: when it converges successfully, the
question is answered yes. If it fails specifically at the `Build Armbian
image` task with "compile.sh exited 0 but produced no image," the answer
is no, and the working-tree change (drop `docker` keyword) must be
reverted.
