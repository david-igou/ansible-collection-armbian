# Disk Provision DSL + Headless Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-partition `disk_provision` PoC with a declarative multi-partition / multi-disk DSL backed by `systemd-repart`, plus a headless `reprovision_to_local.yml` lifecycle playbook with auto-revert on failure. Add user-defined named boot modes to `pxelinux_render`.

**Architecture:** Per-host inline `armbian_netboot_local_disks` list of disk bindings. Each binding's `layout` is translated to `systemd-repart` `.repart.d/*.conf` files on the target board. `disk_provision` refactored from single-partition into single-disk role (the playbook loops over multi-disk bindings). `pxelinux_render` template extended for `armbian_netboot_extra_modes`. `converge_boot_mode.yml` refactored so its body is includable from a `block/rescue` for the lifecycle wrapper's auto-revert.

**Tech Stack:** Ansible 2.15+, `systemd-repart` (systemd 252+, present in Debian 12 / Armbian base), rsync, ext4/vfat, molecule + podman for Layer 1/2/3 tests, real hardware (`orange-pi-5-max-01`) for Layer 4 E2E.

**Spec:** [`docs/superpowers/specs/2026-05-17-disk-provision-dsl-design.md`](../specs/2026-05-17-disk-provision-dsl-design.md).

---

## File Structure

### Modified

| File | Why |
|---|---|
| `roles/disk_provision/defaults/main.yml` | New default schema (disk_binding, fstab template paths, mount_dir base) |
| `roles/disk_provision/meta/argument_specs.yml` | New `disk_binding` argument shape; old flat options removed |
| `roles/disk_provision/tasks/main.yml` | Orchestrates the five new sub-tasks files |
| `roles/disk_provision/templates/fstab.j2` | Loops over all layout mounts (multiple LABEL= rows, ordered by path depth) |
| `roles/pxelinux_render/meta/argument_specs.yml` | Adds `extra_modes` dict; widens `boot_mode` validation via deferred assert |
| `roles/pxelinux_render/defaults/main.yml` | Adds `extra_modes: {}` |
| `roles/pxelinux_render/templates/pxelinux_cfg.j2` | Loop over extra_modes after the built-in labels |
| `roles/board_boot_verify/tasks/main.yml` | New custom-mode handler reading `verify_match` |
| `roles/board_boot_verify/meta/argument_specs.yml` | Add `extra_modes` for lookup |
| `playbooks/converge_boot_mode.yml` | Refactor to thin wrapper around tasks file |
| `extensions/molecule/pxelinux_render/converge.yml` | Add extra_modes test case |
| `extensions/molecule/pxelinux_render/verify.yml` | Assert extra label rendered |
| `README.md` | Update playbooks + roles tables; add `reprovision_to_local` section |

### Created

| File | Responsibility |
|---|---|
| `roles/disk_provision/tasks/_validate.yml` | All 8 pre-flight checks before any destructive op |
| `roles/disk_provision/tasks/_render_repart.yml` | Layout list → `.repart.d/*.conf` files |
| `roles/disk_provision/tasks/_preserve_scan.yml` | `lsblk` preserved labels → skip-list fact |
| `roles/disk_provision/tasks/_apply_repart.yml` | `systemd-repart` invocation with skip-list |
| `roles/disk_provision/tasks/_populate.yml` | Mount in dep order, rsync, fstab, extlinux rewrite, unmount |
| `roles/disk_provision/templates/repart.conf.j2` | Single partition's `.repart.d` config |
| `playbooks/tasks/_converge_boot_mode.yml` | Extracted body of `converge_boot_mode.yml`; includable from a block |
| `playbooks/tasks/_lifecycle_set_and_verify.yml` | Block/rescue helper that sets boot mode + verifies + auto-reverts |
| `playbooks/reprovision_to_local.yml` | Top-level lifecycle: nfs → provision (loop) → local + auto-revert |
| `playbooks/test_reprovision_e2e.yml` | Hardware E2E, target `orange-pi-5-max-01` |
| `extensions/molecule/disk_provision_render/molecule.yml` | Layer 1 scenario config |
| `extensions/molecule/disk_provision_render/converge.yml` | Run disk_provision in render-only mode |
| `extensions/molecule/disk_provision_render/verify.yml` | Assert `.repart.d/*.conf` content matches fixtures |
| `extensions/molecule/disk_provision_loopback/molecule.yml` | Layer 2 scenario (privileged podman + losetup) |
| `extensions/molecule/disk_provision_loopback/prepare.yml` | Create sparse file + losetup -f |
| `extensions/molecule/disk_provision_loopback/converge.yml` | Run disk_provision against loop device |
| `extensions/molecule/disk_provision_loopback/verify.yml` | Assert lsblk + preserve idempotency |

### Removed (subsumed by new schema)

None — old role files are refactored in place; argument_specs change is a breaking API change (acceptable: v3 is recent enough that no external callers rely on the singular-partition contract).

---

## Conventions

- **Branch**: work on a feature branch `feature/77-disk-provision-dsl`. Do not push to main without explicit user approval.
- **Commit cadence**: one commit per task (end of each Task N), with imperative subject and a one-line body if non-obvious.
- **Lint**: `make yamllint && make ansible-lint` after every task. Both must be clean.
- **TDD**: tests first; verify failure; implement; verify pass; commit.

---

## Task 1: Branch + new disk_provision argument_specs

**Files:**
- Create: feature branch
- Modify: `roles/disk_provision/meta/argument_specs.yml`
- Modify: `roles/disk_provision/defaults/main.yml`

- [ ] **Step 1.1: Create feature branch**

```bash
git checkout -b feature/77-disk-provision-dsl
```

- [ ] **Step 1.2: Replace `meta/argument_specs.yml` with new disk_binding schema**

Overwrite the file with:

```yaml
---
argument_specs:
  main:
    short_description: "Apply a declarative partition layout to one block device and populate it from a source rootfs."
    description:
      - >-
        Given one disk_binding (device + layout list), validates the
        layout, translates it to systemd-repart .repart.d/*.conf files,
        invokes systemd-repart against the device, populates the
        resulting filesystems by rsyncing `source` (default /), writes
        a generated /etc/fstab on the root partition referencing every
        mount by LABEL=, and unmounts.
      - >-
        Single-disk contract. Callers with multiple disks loop the
        role per disk binding.
      - >-
        Preserved partitions (preserve_on_reprovision: true with a
        matching label already present on the disk) are skipped at
        systemd-repart and excluded from rsync. Set `force: true` on
        the binding to bypass preserve idempotency.
      - >-
        Transport-agnostic. Knows nothing about netboot, PXE, boot
        modes, or what the rootfs will be used for.

    options:
      disk_binding:
        type: dict
        required: true
        description: >-
          One entry from armbian_netboot_local_disks. Shape:
          {device, wipe?, force?, layout: [partition_spec, ...]}.
        options:
          device:
            type: path
            required: true
            description: "Whole-disk path, e.g. /dev/nvme0n1. WILL BE WIPED unless preserve rules apply."
          wipe:
            type: bool
            default: true
            description: "When true, allow destructive partitioning. When false, fail if disk layout doesn't already match (read-only audit mode)."
          force:
            type: bool
            default: false
            description: "Bypass preserve_on_reprovision idempotency — destructively wipe preserved partitions too."
          layout:
            type: list
            elements: dict
            required: true
            options:
              id:
                type: str
                required: true
                description: "Unique within this layout. Drives the .repart.d filename ordering."
              size:
                type: str
                required: true
                description: "Size string: <number>MiB|GiB|TiB, or 'grow' (exactly one 'grow' per disk)."
              type:
                type: str
                required: true
                choices: [esp, linux, root, var, home, srv, swap]
                description: "GPT partition type purpose. systemd-repart resolves to the architecture-appropriate GUID."
              format:
                type: str
                required: true
                choices: [vfat, ext4, xfs, btrfs, swap]
                description: "Filesystem type."
              label:
                type: str
                description: "Filesystem label. Required if preserve_on_reprovision is true. Recommended otherwise (fstab references it)."
              mount:
                type: path
                description: "Absolute mount path written to /etc/fstab. Optional (e.g. swap has no mount)."
              mount_opts:
                type: str
                description: "fstab mount options. Defaults: ext4='defaults,noatime'; vfat='defaults,noatime'; swap='sw'; xfs='defaults,noatime'; btrfs='defaults,noatime,compress=zstd'."
              preserve_on_reprovision:
                type: bool
                default: false
                description: "If true and a partition with matching label already exists, skip wipe + exclude from rsync. Requires label."
      source:
        type: path
        default: "/"
        description: "Source rootfs to rsync. Default / (the running rootfs)."
      armbian_installed_marker:
        type: bool
        default: true
        description: "Write INSTALLED=true to /etc/armbian-image-release on the target to suppress armbian-resize-filesystem."
      reset_identity:
        type: bool
        default: false
        description: "Zero /etc/machine-id and /var/lib/dbus/machine-id on the target."
      mount_dir_base:
        type: path
        default: "/var/lib/armbian_netboot/disk_provision_mnt"
        description: "Base for per-device temporary mount points. Each device mounts under <base>/<device-basename>/."
      render_only:
        type: bool
        default: false
        description: "When true, render .repart.d configs and run validation, then return. Used by Layer 1 molecule test."
```

- [ ] **Step 1.3: Replace `defaults/main.yml` to match**

```yaml
---
# Defaults mirror meta/argument_specs.yml so the role is callable
# without argument-spec validation enabled.
source: "/"
armbian_installed_marker: true
reset_identity: false
mount_dir_base: "/var/lib/armbian_netboot/disk_provision_mnt"
render_only: false

# Default mount_opts per fstype, used by the fstab template when a
# layout entry does not specify mount_opts explicitly.
_disk_provision_default_mount_opts:
  ext4: "defaults,noatime"
  vfat: "defaults,noatime"
  xfs:  "defaults,noatime"
  btrfs: "defaults,noatime,compress=zstd"
  swap: "sw"
```

- [ ] **Step 1.4: Run ansible-lint to verify the argspec parses**

```bash
make ansible-lint
```

Expected: passes. argument_specs syntax valid.

- [ ] **Step 1.5: Commit**

```bash
git add roles/disk_provision/meta/argument_specs.yml roles/disk_provision/defaults/main.yml
git commit -m "disk_provision: new disk_binding argument_specs (#77)"
```

---

## Task 2: Pre-flight validation tasks file

**Files:**
- Create: `roles/disk_provision/tasks/_validate.yml`
- Modify: `roles/disk_provision/tasks/main.yml` (call _validate.yml first)

Validation runs before any destructive op. All 8 spec checks live here.

- [ ] **Step 2.1: Write `_validate.yml`**

Create `roles/disk_provision/tasks/_validate.yml`:

```yaml
---
# Pre-flight validation for one disk_binding. Runs before any
# destructive op. All failures abort the playbook.

- name: "Validate: device is set, starts with /dev/, is whole-disk path"
  ansible.builtin.assert:
    that:
      - disk_binding.device is defined
      - disk_binding.device.startswith('/dev/')
      - not (disk_binding.device is match('/dev/.*p[0-9]+$|/dev/.*[a-z][0-9]+$'))
    fail_msg: >-
      device must be a whole-disk path under /dev/ (e.g. /dev/nvme0n1).
      Got: {{ disk_binding.device | default('<unset>') }}.
      Partition-suffixed paths (nvme0n1p1, sda1) are not accepted —
      that would target a partition, not the disk.

- name: "Validate: device is a real block device"
  ansible.builtin.stat:
    path: "{{ disk_binding.device }}"
  register: _dp_device_stat
  become: true

- name: "Validate: device stat returned a block device"
  ansible.builtin.assert:
    that:
      - _dp_device_stat.stat.exists
      - _dp_device_stat.stat.isblk
    fail_msg: >-
      device {{ disk_binding.device }} does not exist or is not a block device.

- name: "Validate: find source of running rootfs"
  ansible.builtin.set_fact:
    _dp_root_source: "{{ ansible_mounts | selectattr('mount', 'equalto', '/') | map(attribute='device') | first }}"

- name: "Validate: refuse to wipe the disk the board is booted from"
  ansible.builtin.assert:
    that:
      - not _dp_root_source.startswith(disk_binding.device)
    fail_msg: >-
      REFUSING: / is on {{ _dp_root_source }}, which is on
      {{ disk_binding.device }} (the disk this binding would wipe).
      Boot the board into a different rootfs (NFS or another local
      disk) before provisioning this one.

- name: "Validate: every preserve_on_reprovision: true partition has a label"
  ansible.builtin.assert:
    that:
      - item.label is defined
      - item.label | length > 0
    fail_msg: >-
      Partition id={{ item.id }} has preserve_on_reprovision: true but
      no `label` field. Preserve idempotency is keyed on label —
      labels are required for preserved partitions.
  loop: "{{ disk_binding.layout }}"
  loop_control:
    label: "{{ item.id }}"
  when: item.preserve_on_reprovision | default(false)

- name: "Validate: every mount path is absolute"
  ansible.builtin.assert:
    that:
      - item.mount.startswith('/')
    fail_msg: >-
      Partition id={{ item.id }} has mount={{ item.mount }} — must be
      an absolute path starting with /.
  loop: "{{ disk_binding.layout }}"
  loop_control:
    label: "{{ item.id }}"
  when: item.mount is defined

- name: "Validate: at most one 'grow' partition per disk"
  ansible.builtin.assert:
    that:
      - (disk_binding.layout | selectattr('size', 'equalto', 'grow') | list | length) <= 1
    fail_msg: >-
      Disk {{ disk_binding.device }} has more than one partition with
      size: grow. Exactly one partition per disk may grow to fill
      remaining space.

- name: "Validate: ids are unique within this layout"
  ansible.builtin.assert:
    that:
      - (disk_binding.layout | map(attribute='id') | list | unique | length) == (disk_binding.layout | length)
    fail_msg: >-
      Duplicate id values in layout for {{ disk_binding.device }}.
      Each partition must have a unique id.
```

The "no two disks share a mount path" and "exactly one mount: /" checks are cross-binding; they live in the playbook layer, not the role (see Task 15).

- [ ] **Step 2.2: Write `tasks/main.yml` to invoke `_validate.yml`**

Replace the existing `roles/disk_provision/tasks/main.yml` with:

```yaml
---
# disk_provision — apply a declarative layout to one disk.
# See meta/argument_specs.yml for the contract.

- name: "Pre-flight validation"
  ansible.builtin.import_tasks: _validate.yml

- name: "Render systemd-repart configs"
  ansible.builtin.import_tasks: _render_repart.yml

- name: "Scan for preserved partitions"
  ansible.builtin.import_tasks: _preserve_scan.yml

- name: "Return early in render-only mode"
  ansible.builtin.meta: end_host
  when: render_only | bool

- name: "Apply systemd-repart"
  ansible.builtin.import_tasks: _apply_repart.yml

- name: "Populate filesystems"
  ansible.builtin.import_tasks: _populate.yml
```

The later import_tasks files don't exist yet — `ansible-lint` will warn but `--syntax-check` accepts missing imports until called. For now we only test the validation file directly via molecule in a later task.

- [ ] **Step 2.3: Create empty placeholder files for the other imports**

So `import_tasks` doesn't fail before we get to the next tasks. Create each as a one-line placeholder file:

```yaml
# roles/disk_provision/tasks/_render_repart.yml
---
- name: "TODO: implemented in Task 3"
  ansible.builtin.debug:
    msg: "_render_repart.yml not yet implemented"
```

Same shape for `_preserve_scan.yml`, `_apply_repart.yml`, `_populate.yml`.

- [ ] **Step 2.4: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 2.5: Commit**

```bash
git add roles/disk_provision/tasks/
git commit -m "disk_provision: pre-flight validation + tasks skeleton (#77)"
```

---

## Task 3: Layout → .repart.d rendering

**Files:**
- Create: `roles/disk_provision/templates/repart.conf.j2`
- Replace: `roles/disk_provision/tasks/_render_repart.yml`

- [ ] **Step 3.1: Write `repart.conf.j2`**

```jinja2
{{ ansible_managed | comment }}
# Generated by david_igou.armbian_netboot.disk_provision.
# Source: layout entry id={{ partition.id }}

[Partition]
Type={{ partition.type }}
{% if partition.label is defined %}
Label={{ partition.label }}
{% endif %}
Format={{ partition.format }}
{% if partition.size == 'grow' %}
SizeMinBytes=4G
{% else %}
SizeMinBytes={{ partition.size | regex_replace('iB$', '') }}
SizeMaxBytes={{ partition.size | regex_replace('iB$', '') }}
{% endif %}
```

`SizeMinBytes`/`SizeMaxBytes` accept `512M`, `1G`, etc. (without `iB`); the Jinja regex strips it. `grow` becomes a min-only spec so repart fills remaining space.

- [ ] **Step 3.2: Replace `_render_repart.yml`**

```yaml
---
# Render one .repart.d/<NN>-<id>.conf per layout entry, into a
# per-device subdirectory under /run/disk_provision/. Numeric prefix
# orders the partitions on disk.

- name: "Render: derive device basename"
  ansible.builtin.set_fact:
    _dp_device_basename: "{{ disk_binding.device | basename }}"

- name: "Render: define repart.d directory path"
  ansible.builtin.set_fact:
    _dp_repart_dir: "/run/disk_provision/{{ _dp_device_basename }}/repart.d"

- name: "Render: ensure repart.d directory exists"
  ansible.builtin.file:
    path: "{{ _dp_repart_dir }}"
    state: directory
    mode: "0755"
  become: true

- name: "Render: emit one .conf per layout entry"
  ansible.builtin.template:
    src: repart.conf.j2
    dest: "{{ _dp_repart_dir }}/{{ '%02d' | format(idx * 10 + 10) }}-{{ partition.id }}.conf"
    mode: "0644"
  loop: "{{ disk_binding.layout }}"
  loop_control:
    loop_var: partition
    label: "{{ partition.id }}"
    index_var: idx
  become: true
```

- [ ] **Step 3.3: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 3.4: Commit**

```bash
git add roles/disk_provision/templates/repart.conf.j2 roles/disk_provision/tasks/_render_repart.yml
git commit -m "disk_provision: render systemd-repart configs from layout (#77)"
```

---

## Task 4: Preserve-label scan

**Files:**
- Replace: `roles/disk_provision/tasks/_preserve_scan.yml`

Pre-scans labeled partitions BEFORE systemd-repart runs (because repart would wipe them otherwise). Emits a per-partition skip list as a fact.

- [ ] **Step 4.1: Replace `_preserve_scan.yml`**

```yaml
---
# For each preserve_on_reprovision: true partition, check whether a
# partition with the requested label already exists on the disk.
# If yes, mark its slot as "skip"; _apply_repart.yml will hold that
# slot's existing partition and _populate.yml will rsync-exclude its
# mount path.

- name: "Preserve scan: list existing partitions on device"
  ansible.builtin.command: "lsblk -no NAME,LABEL --pairs {{ disk_binding.device }}"
  register: _dp_lsblk
  changed_when: false
  become: true

- name: "Preserve scan: parse labels into a list of {name, label} dicts"
  ansible.builtin.set_fact:
    _dp_existing_labels: >-
      {{ _dp_lsblk.stdout_lines
         | map('regex_findall', 'NAME="([^"]+)"\s+LABEL="([^"]*)"')
         | map('first', default=[])
         | reject('equalto', [])
         | map('list')
         | list }}

- name: "Preserve scan: build skip set of partition ids to preserve"
  ansible.builtin.set_fact:
    _dp_preserve_ids: >-
      {{ disk_binding.layout
         | selectattr('preserve_on_reprovision', 'defined')
         | selectattr('preserve_on_reprovision')
         | selectattr('label', 'in', _dp_existing_labels | map('last') | list)
         | map(attribute='id')
         | list }}

- name: "Preserve scan: report skip decision"
  ansible.builtin.debug:
    msg: >-
      Preserve scan: existing labels on {{ disk_binding.device }}:
      {{ _dp_existing_labels }}; partitions to preserve (skip wipe):
      {{ _dp_preserve_ids }}; force={{ disk_binding.force | default(false) }}

- name: "Preserve scan: when force=true, clear preserve list (operator escape hatch)"
  ansible.builtin.set_fact:
    _dp_preserve_ids: []
  when: disk_binding.force | default(false) | bool
```

- [ ] **Step 4.2: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 4.3: Commit**

```bash
git add roles/disk_provision/tasks/_preserve_scan.yml
git commit -m "disk_provision: preserve-label scan + force escape hatch (#77)"
```

---

## Task 5: systemd-repart invocation

**Files:**
- Replace: `roles/disk_provision/tasks/_apply_repart.yml`

`systemd-repart --empty=force --definitions=<dir> --dry-run=no` wipes and partitions per the .repart.d configs. When `_dp_preserve_ids` is non-empty, we exclude those partitions' `.conf` files from the definitions directory by symlinking the surviving subset to a filtered directory before invoking repart. This means repart sees only the partitions we want it to create; the preserved partitions are left untouched on the disk.

This approach (filter the definitions, not the repart invocation) is simpler than trying to use `MatchPartitionType=` predicates and works because `--empty=force` only writes the partitions repart sees, leaving unmentioned slots alone — BUT `--empty=force` zeros the partition table itself, which would lose the preserved partition. We avoid this by using `--empty=allow` when any partition is preserved (preserves existing partition table, repart adds/updates only the slots in definitions).

- [ ] **Step 5.1: Replace `_apply_repart.yml`**

```yaml
---
# Invoke systemd-repart against the device. Handles two modes:
#   - No preserves: --empty=force wipes the partition table from
#     scratch; all partitions are created per the .repart.d configs.
#   - Some preserves: --empty=allow leaves the existing partition
#     table alone; only the non-preserved slots in the definitions
#     dir are written.

- name: "Apply repart: assert systemd-repart is available"
  ansible.builtin.command: "systemd-repart --version"
  register: _dp_repart_version
  changed_when: false
  failed_when: _dp_repart_version.rc != 0

- name: "Apply repart: build filtered definitions dir (excludes preserved ids)"
  ansible.builtin.file:
    path: "{{ _dp_repart_dir }}.filtered"
    state: directory
    mode: "0755"
  become: true
  when: _dp_preserve_ids | length > 0

- name: "Apply repart: symlink non-preserved configs into filtered dir"
  ansible.builtin.file:
    src: "{{ _dp_repart_dir }}/{{ '%02d' | format(idx * 10 + 10) }}-{{ partition.id }}.conf"
    dest: "{{ _dp_repart_dir }}.filtered/{{ '%02d' | format(idx * 10 + 10) }}-{{ partition.id }}.conf"
    state: link
  loop: "{{ disk_binding.layout }}"
  loop_control:
    loop_var: partition
    label: "{{ partition.id }}"
    index_var: idx
  when:
    - _dp_preserve_ids | length > 0
    - partition.id not in _dp_preserve_ids
  become: true

- name: "Apply repart: determine effective definitions dir and empty mode"
  ansible.builtin.set_fact:
    _dp_repart_defs: >-
      {{ _dp_repart_dir + '.filtered' if _dp_preserve_ids | length > 0 else _dp_repart_dir }}
    _dp_repart_empty: >-
      {{ 'allow' if _dp_preserve_ids | length > 0 else 'force' }}

- name: "Apply repart: run systemd-repart"
  ansible.builtin.command:
    cmd: >-
      systemd-repart
      --definitions={{ _dp_repart_defs }}
      --empty={{ _dp_repart_empty }}
      --dry-run=no
      --discard=yes
      {{ disk_binding.device }}
  become: true
  register: _dp_repart_run
  changed_when: true

- name: "Apply repart: report what repart did"
  ansible.builtin.debug:
    msg: "{{ _dp_repart_run.stdout_lines }}"

- name: "Apply repart: force partition-table re-read"
  ansible.builtin.command: "partprobe -s {{ disk_binding.device }}"
  changed_when: false
  failed_when: false
  become: true

- name: "Apply repart: wait for all expected partitions to appear by label"
  ansible.builtin.command: "blkid -L {{ partition.label }}"
  register: _dp_blkid
  retries: 5
  delay: 1
  until: _dp_blkid.rc == 0
  loop: "{{ disk_binding.layout }}"
  loop_control:
    loop_var: partition
    label: "{{ partition.id }}"
  when: partition.label is defined
  changed_when: false
  become: true
```

- [ ] **Step 5.2: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 5.3: Commit**

```bash
git add roles/disk_provision/tasks/_apply_repart.yml
git commit -m "disk_provision: invoke systemd-repart with preserve-aware definitions (#77)"
```

---

## Task 6: Multi-LABEL fstab template

**Files:**
- Replace: `roles/disk_provision/templates/fstab.j2`

The old template wrote one fstab row (the role's single label). New template loops over every layout entry that has a `mount`.

- [ ] **Step 6.1: Replace `fstab.j2`**

```jinja2
{{ ansible_managed | comment }}
# Generated by david_igou.armbian_netboot.disk_provision.
# Do not edit; re-run reprovision_to_local.yml (or equivalent) to change.
#
# <file system>	<mount point>	<type>	<options>	<dump>	<pass>
tmpfs	/tmp	tmpfs	defaults,nosuid	0	0
{% for p in disk_binding.layout | selectattr('mount', 'defined') | sort(attribute='mount') %}
{% set opts = p.mount_opts | default(_disk_provision_default_mount_opts[p.format]) %}
{% set passno = '1' if p.mount == '/' else '2' %}
LABEL={{ p.label }}	{{ p.mount }}	{{ p.format }}	{{ opts }}	0	{{ passno }}
{% endfor %}
```

`sort(attribute='mount')` orders by path lexically, which puts `/` first, then `/boot`, then `/boot/efi`, then `/var` — correct mount order. `passno` is 1 for root, 2 for everything else (Debian convention).

- [ ] **Step 6.2: Lint**

```bash
make yamllint
```

Expected: passes.

- [ ] **Step 6.3: Commit**

```bash
git add roles/disk_provision/templates/fstab.j2
git commit -m "disk_provision: multi-LABEL fstab template (#77)"
```

---

## Task 7: Mount + rsync + populate

**Files:**
- Replace: `roles/disk_provision/tasks/_populate.yml`

- [ ] **Step 7.1: Replace `_populate.yml`**

```yaml
---
# Mount partitions in dependency order, rsync source rootfs onto root,
# write /etc/fstab, rewrite /boot/extlinux/extlinux.conf root= reference,
# unmount in reverse order.

- name: "Populate: define per-device mount root"
  ansible.builtin.set_fact:
    _dp_mount_root: "{{ mount_dir_base }}/{{ _dp_device_basename }}"

- name: "Populate: ensure mount root exists"
  ansible.builtin.file:
    path: "{{ _dp_mount_root }}"
    state: directory
    mode: "0755"
  become: true

- name: "Populate: build ordered mount list (by path depth)"
  ansible.builtin.set_fact:
    _dp_mount_order: >-
      {{ disk_binding.layout
         | selectattr('mount', 'defined')
         | sort(attribute='mount')
         | list }}

- name: "Populate: mount partitions in dependency order"
  block:
    - name: "Populate: ensure each mount point exists under mount_root"
      ansible.builtin.file:
        path: "{{ _dp_mount_root }}{{ p.mount }}"
        state: directory
        mode: "0755"
      loop: "{{ _dp_mount_order }}"
      loop_control:
        loop_var: p
        label: "{{ p.id }}"
      become: true

    - name: "Populate: mount each partition by label"
      ansible.posix.mount:
        path: "{{ _dp_mount_root }}{{ p.mount }}"
        src: "LABEL={{ p.label }}"
        fstype: "{{ p.format }}"
        state: ephemeral
      loop: "{{ _dp_mount_order }}"
      loop_control:
        loop_var: p
        label: "{{ p.id }}"
      when: p.id not in _dp_preserve_ids
      become: true

    - name: "Populate: write rsync exclude file"
      ansible.builtin.copy:
        dest: "{{ _dp_mount_root }}.excludes"
        content: |
          /dev/*
          /proc/*
          /sys/*
          /run/*
          /tmp/*
          /mnt/*
          /media/*
          /var/log/journal
          {% for p in _dp_mount_order %}{% if p.id in _dp_preserve_ids %}{{ p.mount }}/*
          {% endif %}{% endfor %}
        mode: "0644"
      become: true

    - name: "Populate: rsync source into mounted root"
      ansible.builtin.command:
        cmd: >-
          rsync -aAX --numeric-ids --one-file-system --delete
          --exclude-from={{ _dp_mount_root }}.excludes
          {{ source }}/ {{ _dp_mount_root }}/
      changed_when: true
      become: true

    - name: "Populate: recreate virtual mount-point directories on target"
      ansible.builtin.file:
        path: "{{ _dp_mount_root }}/{{ item }}"
        state: directory
        mode: "{{ '1777' if item == 'tmp' else '0755' }}"
      loop:
        - dev
        - proc
        - sys
        - run
        - tmp
        - mnt
        - media
      become: true

    - name: "Populate: write generated /etc/fstab on target root"
      ansible.builtin.template:
        src: fstab.j2
        dest: "{{ _dp_mount_root }}/etc/fstab"
        mode: "0644"
      become: true

    - name: "Populate: rewrite /boot/extlinux/extlinux.conf root= if present"
      ansible.builtin.replace:
        path: "{{ _dp_mount_root }}/boot/extlinux/extlinux.conf"
        regexp: 'root=\S+'
        replace: "root=LABEL={{ _dp_root_label }}"
      vars:
        _dp_root_label: "{{ disk_binding.layout | selectattr('mount', 'equalto', '/') | map(attribute='label') | first }}"
      failed_when: false  # extlinux.conf may not exist; not on boot path under passthrough model
      become: true

    - name: "Populate: write INSTALLED=true marker on target"
      ansible.builtin.lineinfile:
        path: "{{ _dp_mount_root }}/etc/armbian-image-release"
        regexp: "^INSTALLED="
        line: "INSTALLED=true"
        create: false
      when: armbian_installed_marker | bool
      failed_when: false
      become: true

    - name: "Populate: reset machine-id files if requested"
      ansible.builtin.copy:
        dest: "{{ _dp_mount_root }}/{{ item }}"
        content: ""
        mode: "0444"
        force: true
      loop:
        - etc/machine-id
        - var/lib/dbus/machine-id
      when: reset_identity | bool
      become: true

    - name: "Populate: sync to flush rsync data"
      ansible.builtin.command: "sync"
      changed_when: false
      become: true

  always:
    - name: "Populate: unmount in reverse order"
      ansible.posix.mount:
        path: "{{ _dp_mount_root }}{{ p.mount }}"
        state: unmounted
      loop: "{{ _dp_mount_order | reverse | list }}"
      loop_control:
        loop_var: p
        label: "{{ p.id }}"
      when: p.id not in _dp_preserve_ids
      failed_when: false
      become: true

    - name: "Populate: remove excludes file"
      ansible.builtin.file:
        path: "{{ _dp_mount_root }}.excludes"
        state: absent
      become: true
```

- [ ] **Step 7.2: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 7.3: Commit**

```bash
git add roles/disk_provision/tasks/_populate.yml
git commit -m "disk_provision: mount/rsync/fstab/extlinux populate step (#77)"
```

---

## Task 8: Layer 1 molecule scenario — render only

**Files:**
- Create: `extensions/molecule/disk_provision_render/molecule.yml`
- Create: `extensions/molecule/disk_provision_render/converge.yml`
- Create: `extensions/molecule/disk_provision_render/verify.yml`

Tests pure .repart.d rendering — no block devices, no systemd-repart invocation. Asserts the generated `.conf` files match expected content for several fixture layouts.

- [ ] **Step 8.1: Write `molecule.yml`**

```yaml
---
# Render-only Layer 1: no block devices, no privileged container.
# Verifies disk_provision pre-flight + repart.d rendering produces
# expected .conf files for several fixture layouts.

dependency:
  name: galaxy
driver:
  name: ${PROVISIONER:-podman}
platforms:
  - name: disk-provision-render
    image: docker.io/library/debian:12
    pre_build_image: false
    command: /sbin/init
    systemd: true
    capabilities:
      - SYS_ADMIN
    privileged: true
provisioner:
  name: ansible
  inventory:
    group_vars:
      all:
        # Mocked facts needed by _validate.yml (it normally reads
        # ansible_mounts to refuse wiping booted-from disk).
        ansible_mounts:
          - mount: /
            device: overlay
            fstype: overlay
verifier:
  name: ansible
```

- [ ] **Step 8.2: Write `converge.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Install losetup so we can fake a block device for the validator"
      ansible.builtin.apt:
        name: util-linux
        state: present
        update_cache: true

    - name: "Create a 1 MiB sparse file as a fake block device"
      ansible.builtin.command: "truncate -s 1M /tmp/fake.img"
      changed_when: true

    - name: "Attach as a loop device"
      ansible.builtin.command: "losetup -f --show /tmp/fake.img"
      register: _loop
      changed_when: true

    - name: "Fixture 1: full ESP + boot + var + root layout"
      ansible.builtin.include_role:
        name: disk_provision
      vars:
        render_only: true
        disk_binding:
          device: "{{ _loop.stdout }}"
          wipe: true
          layout:
            - { id: esp,  size: 512MiB, type: esp,   format: vfat, label: armbi_esp,        mount: /boot/efi }
            - { id: boot, size: 1GiB,   type: linux, format: ext4, label: armbi_boot,       mount: /boot }
            - { id: var,  size: 20GiB,  type: var,   format: ext4, label: armbi_var,        mount: /var, preserve_on_reprovision: true }
            - { id: root, size: grow,   type: root,  format: ext4, label: armbi_root_local, mount: / }

    # Note: render_only ends the host via `meta: end_host`; subsequent
    # plays here would not run. Single fixture per converge is the
    # pattern. For more fixtures, add additional molecule scenarios.
```

- [ ] **Step 8.3: Write `verify.yml`**

```yaml
---
- hosts: all
  gather_facts: false
  tasks:
    - name: "Verify: discover the loop device basename used in converge"
      ansible.builtin.shell: |
        ls /run/disk_provision/
      register: _devs
      changed_when: false

    - name: "Verify: assert exactly one device subdirectory exists"
      ansible.builtin.assert:
        that:
          - _devs.stdout_lines | length == 1
        fail_msg: "Expected exactly one device dir under /run/disk_provision/, got: {{ _devs.stdout_lines }}"

    - name: "Verify: list the .repart.d files"
      ansible.builtin.find:
        paths: "/run/disk_provision/{{ _devs.stdout_lines[0] }}/repart.d"
        patterns: "*.conf"
      register: _confs

    - name: "Verify: assert four .conf files exist with correct prefix ordering"
      ansible.builtin.assert:
        that:
          - (_confs.files | map(attribute='path') | map('basename') | sort) == ['10-esp.conf', '20-boot.conf', '30-var.conf', '40-root.conf']
        fail_msg: "Expected files [10-esp, 20-boot, 30-var, 40-root], got: {{ _confs.files | map(attribute='path') | map('basename') | sort }}"

    - name: "Verify: read the ESP config and assert content"
      ansible.builtin.slurp:
        src: "/run/disk_provision/{{ _devs.stdout_lines[0] }}/repart.d/10-esp.conf"
      register: _esp

    - name: "Verify: ESP config has Type=esp, Label=armbi_esp, Format=vfat, 512M size"
      ansible.builtin.assert:
        that:
          - (_esp.content | b64decode) is search('Type=esp')
          - (_esp.content | b64decode) is search('Label=armbi_esp')
          - (_esp.content | b64decode) is search('Format=vfat')
          - (_esp.content | b64decode) is search('SizeMinBytes=512M')
          - (_esp.content | b64decode) is search('SizeMaxBytes=512M')

    - name: "Verify: read the root config and assert it grows (no SizeMaxBytes)"
      ansible.builtin.slurp:
        src: "/run/disk_provision/{{ _devs.stdout_lines[0] }}/repart.d/40-root.conf"
      register: _root

    - name: "Verify: root config has Type=root, no SizeMaxBytes (grow)"
      ansible.builtin.assert:
        that:
          - (_root.content | b64decode) is search('Type=root')
          - (_root.content | b64decode) is search('Label=armbi_root_local')
          - (_root.content | b64decode) is not search('SizeMaxBytes')
```

- [ ] **Step 8.4: Run molecule**

```bash
PROVISIONER=podman molecule test -s disk_provision_render
```

Expected: scenario passes through prepare, converge, and verify.

- [ ] **Step 8.5: Commit**

```bash
git add extensions/molecule/disk_provision_render/
git commit -m "molecule: disk_provision_render scenario (Layer 1, #77)"
```

---

## Task 9: Layer 2 molecule scenario — loopback systemd-repart

**Files:**
- Create: `extensions/molecule/disk_provision_loopback/molecule.yml`
- Create: `extensions/molecule/disk_provision_loopback/prepare.yml`
- Create: `extensions/molecule/disk_provision_loopback/converge.yml`
- Create: `extensions/molecule/disk_provision_loopback/verify.yml`

Real systemd-repart invocation against a loop device inside a privileged podman container. Verifies partition table, filesystem labels, preserve idempotency, and force-flag bypass.

- [ ] **Step 9.1: Write `molecule.yml`**

```yaml
---
# Layer 2: privileged podman + loop device + real systemd-repart.
# CI risk noted in spec; may fall back to hardware-only if flaky.

dependency:
  name: galaxy
driver:
  name: ${PROVISIONER:-podman}
platforms:
  - name: disk-provision-loopback
    image: docker.io/library/debian:12
    pre_build_image: false
    command: /sbin/init
    systemd: true
    privileged: true
    capabilities:
      - SYS_ADMIN
    volumes:
      - /dev:/dev
provisioner:
  name: ansible
verifier:
  name: ansible
```

- [ ] **Step 9.2: Write `prepare.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Install systemd-repart, util-linux, rsync, e2fsprogs, dosfstools"
      ansible.builtin.apt:
        name:
          - systemd
          - util-linux
          - rsync
          - e2fsprogs
          - dosfstools
        state: present
        update_cache: true

    - name: "Create a 2 GiB sparse file"
      ansible.builtin.command: "truncate -s 2G /tmp/loopback.img"
      changed_when: true

    - name: "Attach as a loop device"
      ansible.builtin.command: "losetup -f --show /tmp/loopback.img"
      register: _loop
      changed_when: true

    - name: "Persist the loop device path for converge + verify"
      ansible.builtin.copy:
        dest: /tmp/loop_device
        content: "{{ _loop.stdout }}\n"
        mode: "0644"
```

- [ ] **Step 9.3: Write `converge.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Read loop device path"
      ansible.builtin.slurp:
        src: /tmp/loop_device
      register: _loop_b64

    - name: "Set loop device fact"
      ansible.builtin.set_fact:
        _loop: "{{ (_loop_b64.content | b64decode).strip() }}"

    - name: "First provision: full layout, no preserves yet (disk is empty)"
      ansible.builtin.include_role:
        name: disk_provision
      vars:
        source: "/usr"  # small known directory for rsync test
        disk_binding:
          device: "{{ _loop }}"
          wipe: true
          layout:
            - { id: boot, size: 256MiB, type: linux, format: ext4, label: lp_boot, mount: /boot }
            - { id: var,  size: 512MiB, type: var,   format: ext4, label: lp_var,  mount: /var, preserve_on_reprovision: true }
            - { id: root, size: grow,   type: root,  format: ext4, label: lp_root, mount: / }
```

- [ ] **Step 9.4: Write `verify.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Read loop device path"
      ansible.builtin.slurp:
        src: /tmp/loop_device
      register: _loop_b64

    - name: "Set loop device fact"
      ansible.builtin.set_fact:
        _loop: "{{ (_loop_b64.content | b64decode).strip() }}"

    - name: "lsblk -no NAME,FSTYPE,LABEL on the loop device"
      ansible.builtin.command: "lsblk -no NAME,FSTYPE,LABEL {{ _loop }}"
      register: _lsblk
      changed_when: false

    - name: "Assert all three partitions exist with correct labels and fstypes"
      ansible.builtin.assert:
        that:
          - "'lp_boot' in _lsblk.stdout"
          - "'lp_var'  in _lsblk.stdout"
          - "'lp_root' in _lsblk.stdout"
          - _lsblk.stdout.count('ext4') == 3
        fail_msg: "Unexpected lsblk output:\n{{ _lsblk.stdout }}"

    - name: "Second provision: same layout, /var should be preserved (not reformatted)"
      block:
        - name: "Write a sentinel into /var on the loop disk"
          ansible.builtin.shell: |
            mount LABEL=lp_var /mnt
            echo SENTINEL > /mnt/preserve_test
            sync
            umount /mnt
          changed_when: true

        - name: "Re-run disk_provision with the same layout"
          ansible.builtin.include_role:
            name: disk_provision
          vars:
            source: "/usr"
            disk_binding:
              device: "{{ _loop }}"
              wipe: true
              layout:
                - { id: boot, size: 256MiB, type: linux, format: ext4, label: lp_boot, mount: /boot }
                - { id: var,  size: 512MiB, type: var,   format: ext4, label: lp_var,  mount: /var, preserve_on_reprovision: true }
                - { id: root, size: grow,   type: root,  format: ext4, label: lp_root, mount: / }

        - name: "Assert sentinel survived"
          ansible.builtin.shell: |
            mount LABEL=lp_var /mnt
            cat /mnt/preserve_test
            umount /mnt
          register: _sentinel
          changed_when: false

        - name: "Sentinel reads back as SENTINEL"
          ansible.builtin.assert:
            that:
              - _sentinel.stdout.strip() == 'SENTINEL'
            fail_msg: "Preserve idempotency failed: sentinel content is {{ _sentinel.stdout }}"
```

- [ ] **Step 9.5: Run molecule**

```bash
PROVISIONER=podman molecule test -s disk_provision_loopback
```

Expected: passes. If `losetup` fails in CI, document the scenario as hardware-only and run only the Layer 1 scenario in CI (the spec accepts this fallback).

- [ ] **Step 9.6: Commit**

```bash
git add extensions/molecule/disk_provision_loopback/
git commit -m "molecule: disk_provision_loopback scenario (Layer 2, #77)"
```

---

## Task 10: pxelinux_render extra_modes support

**Files:**
- Modify: `roles/pxelinux_render/meta/argument_specs.yml`
- Modify: `roles/pxelinux_render/defaults/main.yml`
- Modify: `roles/pxelinux_render/templates/pxelinux_cfg.j2`

- [ ] **Step 10.1: Modify `meta/argument_specs.yml`**

Find the existing `boot_mode:` block and replace its `choices:` constraint (which currently restricts to `[nfs, sd, local]`). Replace with no `choices:` (validation moves into a task-level assert that knows the extra_modes keys at runtime). Add `extra_modes`:

Use Edit. Find:

```yaml
      boot_mode:
        type: str
        required: true
        choices: [nfs, sd, local]
```

Replace with:

```yaml
      boot_mode:
        type: str
        required: true
        description: >-
          Which label the rendered pxelinux.cfg's `default` directive
          points at. Built-in choices: nfs, sd, local. May also be any
          key in extra_modes. Validated at task level against the
          union {nfs, sd, local} ∪ keys(extra_modes).
      extra_modes:
        type: dict
        default: {}
        description: >-
          User-defined named boot modes. Each entry adds a label to the
          rendered pxelinux.cfg with the supplied root= and rootfstype.
          Keys become label names and valid boot_mode values.
```

- [ ] **Step 10.2: Modify `defaults/main.yml`**

Append:

```yaml

# User-defined extra boot modes. Each key becomes a pxelinux label
# coexisting with nfs/sd/local. Empty by default.
extra_modes: {}
```

- [ ] **Step 10.3: Modify `templates/pxelinux_cfg.j2`**

Append after the existing `label local` block (currently ending at line 30):

```jinja2

{% for mode_name, mode in (extra_modes | default({})).items() %}
label {{ mode_name }}
  menu label {{ mode.menu_label }} ({{ hostname }})
  kernel {{ tftp_kernel }}
  initrd {{ tftp_initrd }}
  fdt    {{ tftp_dtb }}
  append root={{ mode.root }} rootfstype={{ mode.rootfstype | default('ext4') }} rootwait rw console={{ board_console }}{% if mode.extra_append is defined %} {{ mode.extra_append }}{% endif %}{{ _verbose_suffix }}
{% endfor %}
```

- [ ] **Step 10.4: Add the runtime validation task**

The `boot_mode` choices restriction is gone from argspec; add a runtime assert in `roles/pxelinux_render/tasks/main.yml`. Read the current `main.yml` first to find the right insertion point — add at the top of the task list.

Insert as the first task in `roles/pxelinux_render/tasks/main.yml`:

```yaml
- name: "Validate boot_mode is built-in or in extra_modes"
  ansible.builtin.assert:
    that:
      - boot_mode in (['nfs', 'sd', 'local'] + (extra_modes | default({}) | dict2items | map(attribute='key') | list))
    fail_msg: >-
      boot_mode={{ boot_mode }} is not valid. Must be one of
      nfs|sd|local or a key in armbian_netboot_extra_modes. Defined
      extra_modes keys: {{ extra_modes | default({}) | dict2items | map(attribute='key') | list }}.
```

- [ ] **Step 10.5: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 10.6: Commit**

```bash
git add roles/pxelinux_render/
git commit -m "pxelinux_render: support user-defined extra_modes (#77)"
```

---

## Task 11: Extend pxelinux_render molecule scenario

**Files:**
- Modify: `extensions/molecule/pxelinux_render/converge.yml`
- Modify: `extensions/molecule/pxelinux_render/verify.yml`

Adds positive (extra_modes renders) and negative (bad boot_mode fails) test cases.

- [ ] **Step 11.1: Read the current converge.yml to see existing fixture pattern**

```bash
cat extensions/molecule/pxelinux_render/converge.yml
```

Note the existing block style (separate plays or single play with multiple include_role calls).

- [ ] **Step 11.2: Append a new test case to `converge.yml`**

Add after the existing test invocations (use the same style as existing fixtures — adapt as needed if the file uses a different pattern):

```yaml
- hosts: all
  gather_facts: false
  tasks:
    - name: "extra_modes: render a custom usb_rescue label"
      ansible.builtin.include_role:
        name: pxelinux_render
      vars:
        board_mac: "aa:bb:cc:dd:ee:ff"
        boot_mode: usb_rescue
        board_console: "ttyS2,1500000"
        model_name: "test-model"
        nfs_server_ip: "10.10.9.213"
        nfs_root_path: "/srv/nfs"
        hostname: "test-board"
        output_dir: "/tmp/pxelinux_render_extra"
        extra_modes:
          usb_rescue:
            menu_label: "USB rescue rootfs"
            root: "LABEL=rescue_root"
            rootfstype: ext4
```

- [ ] **Step 11.3: Append assertions to `verify.yml`**

```yaml
    - name: "Read the rendered extra_modes pxelinux.cfg"
      ansible.builtin.slurp:
        src: "/tmp/pxelinux_render_extra/01-aa-bb-cc-dd-ee-ff"
      register: _extra

    - name: "Assert default points at usb_rescue"
      ansible.builtin.assert:
        that:
          - (_extra.content | b64decode) is search('^default usb_rescue', multiline=true)
          - (_extra.content | b64decode) is search('label usb_rescue')
          - (_extra.content | b64decode) is search('append root=LABEL=rescue_root')
        fail_msg: "Extra mode rendering wrong:\n{{ _extra.content | b64decode }}"
```

- [ ] **Step 11.4: Negative test — bad boot_mode**

Append to `converge.yml`:

```yaml
- hosts: all
  gather_facts: false
  tasks:
    - name: "extra_modes negative: bad boot_mode value fails fast"
      block:
        - name: "Invoke with a typo'd boot_mode"
          ansible.builtin.include_role:
            name: pxelinux_render
          vars:
            board_mac: "11:22:33:44:55:66"
            boot_mode: nonexistent_mode
            board_console: "ttyS2,1500000"
            model_name: "test-model"
            nfs_server_ip: "10.10.9.213"
            nfs_root_path: "/srv/nfs"
            hostname: "test-board"
            output_dir: "/tmp/pxelinux_render_neg"
          register: _neg
      rescue:
        - name: "Record that the role failed (expected)"
          ansible.builtin.set_fact:
            _boot_mode_negative_failed: true

    - name: "Assert the negative test failed as expected"
      ansible.builtin.assert:
        that:
          - _boot_mode_negative_failed | default(false)
        fail_msg: "Expected pxelinux_render to fail for boot_mode=nonexistent_mode but it succeeded."
```

- [ ] **Step 11.5: Run molecule**

```bash
PROVISIONER=podman molecule test -s pxelinux_render
```

Expected: passes (existing fixtures + new extra_modes + negative).

- [ ] **Step 11.6: Commit**

```bash
git add extensions/molecule/pxelinux_render/
git commit -m "molecule: pxelinux_render extra_modes + negative test (#77)"
```

---

## Task 12: board_boot_verify custom-mode handler

**Files:**
- Modify: `roles/board_boot_verify/tasks/main.yml`
- Modify: `roles/board_boot_verify/meta/argument_specs.yml`

Adds a handler for custom modes: looks up the mode in `extra_modes`, reads its `verify_match` regex, asserts `ansible_mounts['/'].device` matches.

- [ ] **Step 12.1: Modify `meta/argument_specs.yml` to add `extra_modes`**

Read the current argspec first:

```bash
cat roles/board_boot_verify/meta/argument_specs.yml
```

Add an `extra_modes` option mirroring pxelinux_render's:

```yaml
      extra_modes:
        type: dict
        default: {}
        description: >-
          Mirrors armbian_netboot_extra_modes for verify_match lookups.
          When boot_mode is a key in extra_modes, this role reads the
          mode's `verify_match` regex and asserts ansible_mounts['/'].
          device matches it.
```

- [ ] **Step 12.2: Append custom-mode handler to `tasks/main.yml`**

Append after the existing `when: boot_mode == 'local'` block:

```yaml
- name: "Assert custom mode rootfs source matches verify_match"
  ansible.builtin.assert:
    that:
      - extra_modes[boot_mode] is defined
      - extra_modes[boot_mode].verify_match is defined
      - _root_device is match(extra_modes[boot_mode].verify_match)
    fail_msg: >-
      boot_mode[{{ boot_mode }}]: _root_device={{ _root_device }}
      does not match verify_match regex
      '{{ extra_modes[boot_mode].verify_match | default('<unset>') }}'.
      Define armbian_netboot_extra_modes[{{ boot_mode }}].verify_match
      so this role can assert the rootfs source.
  when: boot_mode not in ['nfs', 'sd', 'local']
```

- [ ] **Step 12.3: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 12.4: Commit**

```bash
git add roles/board_boot_verify/
git commit -m "board_boot_verify: verify_match handler for custom modes (#77)"
```

---

## Task 13: Extract converge_boot_mode body into includable tasks file

**Files:**
- Create: `playbooks/tasks/_converge_boot_mode.yml`
- Modify: `playbooks/converge_boot_mode.yml`

`reprovision_to_local.yml` needs to call "set boot mode + verify" from inside a `block/rescue` for auto-revert. `import_playbook` can't appear inside a block; `include_tasks` can. Extract the body.

- [ ] **Step 13.1: Read the current `converge_boot_mode.yml`**

```bash
cat playbooks/converge_boot_mode.yml
```

Identify the four plays: pre-flight plumbing check (router), local pxelinux render (boards), upload reference playbook (router), cycle+wait+verify on boards. Extract everything except the play-level scaffolding.

- [ ] **Step 13.2: Create `playbooks/tasks/_converge_boot_mode.yml`**

Move the play *contents* (tasks lists) of the original `converge_boot_mode.yml` into one tasks file. Each original play's tasks become a `block` with `hosts:` lifted via `delegate_to`/`run_once` where needed. Since the original orchestrates across `routeros_routers` and `boards`, and tasks files can't change `hosts:` mid-stream, the cleanest model is: this tasks file is *meant to be included from a play whose `hosts:` is the union of routers+boards*, and uses `delegate_to: "{{ armbian_netboot_router }}"` for router operations and per-host execution for board operations.

Implementation note: if the existing converge_boot_mode.yml's structure makes this awkward (e.g. it uses true per-play `hosts:` switches that can't be flattened into one tasks file), keep `converge_boot_mode.yml` as-is for the existing callers, and create `_converge_boot_mode.yml` as a *new* alternative entry point that uses `delegate_to` / `run_once` patterns from inside a single-play context — used only by `_lifecycle_set_and_verify.yml`. Document this in the file header.

For the conservative path (recommended), write `_converge_boot_mode.yml` as a self-contained tasks file that orchestrates everything via `delegate_to` from a single-play context:

```yaml
---
# Single-play-compatible version of converge_boot_mode.yml. Used by
# _lifecycle_set_and_verify.yml (which can't import_playbook from
# inside a block/rescue). Behaviour matches converge_boot_mode.yml
# exactly; only the play scaffolding differs.
#
# Caller must run this from a `hosts: <board pattern>` context with
# armbian_netboot_router defined per host.

- name: "Plumbing check via reference playbook"
  ansible.builtin.include_tasks: "{{ armbian_netboot_plumbing_check_tasks | default('../routeros/tasks/plumbing_check_one.yml') }}"
  run_once: true
  delegate_to: "{{ armbian_netboot_router }}"

- name: "Render pxelinux.cfg locally"
  ansible.builtin.include_role:
    name: pxelinux_render
  delegate_to: localhost

- name: "Upload pxelinux.cfg via reference playbook tasks"
  ansible.builtin.include_tasks: "{{ armbian_netboot_pxelinux_upload_tasks | default('../routeros/tasks/upload_pxelinux_one.yml') }}"
  delegate_to: "{{ armbian_netboot_router }}"

- name: "Cold boot with retry"
  ansible.builtin.include_tasks: "cold_boot_with_retry.yml"
  when: armbian_netboot_cycle_board | default(true) | bool

- name: "Wait for SSH"
  ansible.builtin.include_tasks: "wait_for_ssh_with_cycle_retry.yml"
  when: armbian_netboot_cycle_board | default(true) | bool

- name: "Verify board on declared boot mode"
  ansible.builtin.include_role:
    name: board_boot_verify
```

**Note for the implementing engineer:** the `armbian_netboot_plumbing_check_tasks` / `armbian_netboot_pxelinux_upload_tasks` references assume there are per-host-invocable tasks files in `playbooks/routeros/tasks/`. If only the per-router-batch reference playbooks exist today (`routeros/upload_pxelinux_cfg.yml` runs across all hosts at once), this task may need to either (a) add `_one.yml` variants of those reference playbooks, or (b) batch-run the upload outside the loop in `_lifecycle_set_and_verify.yml`. **Read `playbooks/routeros/upload_pxelinux_cfg.yml` and `playbooks/routeros/tasks/upload_pxelinux_one.yml` before implementing to confirm which variant exists.**

- [ ] **Step 13.3: Refactor `converge_boot_mode.yml` to use the tasks file**

Replace its play bodies with `include_tasks: tasks/_converge_boot_mode.yml`. Keep the file's existing `hosts:` plays so external callers don't break.

- [ ] **Step 13.4: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 13.5: Run an existing E2E that exercises converge_boot_mode against the test board**

```bash
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-max-01
```

Expected: same end state as before the refactor (board reaches its inventory-declared boot mode, board_boot_verify passes). This is the regression check that the refactor preserved behavior.

- [ ] **Step 13.6: Commit**

```bash
git add playbooks/converge_boot_mode.yml playbooks/tasks/_converge_boot_mode.yml
git commit -m "playbooks: extract converge_boot_mode body to includable tasks file (#77)"
```

---

## Task 14: _lifecycle_set_and_verify helper

**Files:**
- Create: `playbooks/tasks/_lifecycle_set_and_verify.yml`

The block/rescue helper used by `reprovision_to_local.yml`. Takes a target boot mode and an `on_failure_revert_to` mode; sets the target mode, verifies the board comes up healthy, and on failure captures diagnostics + auto-reverts.

- [ ] **Step 14.1: Write `_lifecycle_set_and_verify.yml`**

```yaml
---
# Set boot mode to `target_boot_mode` and verify; on failure, capture
# diagnostics + auto-revert to `on_failure_revert_to` mode + fail the
# play with a pointer to the bundle.
#
# Caller contract:
#   target_boot_mode:        required (nfs|sd|local|<extra>)
#   on_failure_revert_to:    required (nfs|sd|local|<extra>)
#   armbian_netboot_diagnostic_bundle_dir: optional, default ./diagnostics

- name: "Lifecycle: set + verify {{ target_boot_mode }}"
  block:
    - name: "Set boot mode (via convergence tasks)"
      ansible.builtin.include_tasks: _converge_boot_mode.yml
      vars:
        armbian_netboot_boot_mode: "{{ target_boot_mode }}"

  rescue:
    - name: "Lifecycle: capture diagnostic bundle before revert"
      ansible.builtin.include_tasks: diagnostic_bundle.yml
      vars:
        bundle_dir: "{{ armbian_netboot_diagnostic_bundle_dir | default('./diagnostics') }}/{{ inventory_hostname }}-{{ ansible_date_time.iso8601_basic_short }}"
      failed_when: false   # don't lose the original failure if diagnostics fail

    - name: "Lifecycle: auto-revert to {{ on_failure_revert_to }}"
      ansible.builtin.include_tasks: _converge_boot_mode.yml
      vars:
        armbian_netboot_boot_mode: "{{ on_failure_revert_to }}"

    - name: "Lifecycle: fail loudly with diagnostic bundle pointer"
      ansible.builtin.fail:
        msg: >-
          Boot mode '{{ target_boot_mode }}' failed for {{ inventory_hostname }};
          auto-reverted to '{{ on_failure_revert_to }}'. Diagnostic bundle:
          {{ armbian_netboot_diagnostic_bundle_dir | default('./diagnostics') }}/{{ inventory_hostname }}-{{ ansible_date_time.iso8601_basic_short }}/
```

- [ ] **Step 14.2: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 14.3: Commit**

```bash
git add playbooks/tasks/_lifecycle_set_and_verify.yml
git commit -m "playbooks: _lifecycle_set_and_verify block/rescue helper (#77)"
```

---

## Task 15: reprovision_to_local.yml

**Files:**
- Create: `playbooks/reprovision_to_local.yml`

The top-level lifecycle playbook. Cross-binding validation (no two disks share a mount path; exactly one mount: /) lives here.

- [ ] **Step 15.1: Write `reprovision_to_local.yml`**

```yaml
---
# Headless full-lifecycle reprovision to local-disk boot.
#
# Usage:
#   ansible-playbook playbooks/reprovision_to_local.yml \
#     --limit orange-pi-5-max-01
#
# Requires:
#   armbian_netboot_local_disks: list of disk_binding dicts (per host)
#   armbian_netboot_boot_mode: local (per host or via -e)
#
# Phases:
#   1. Set boot mode to nfs and verify board is NFS-rooted.
#   2. Cross-binding validation (mount-path collisions, exactly one /).
#   3. Loop disk_provision over armbian_netboot_local_disks.
#   4. Set boot mode to local and verify; on failure, auto-revert to nfs.

- name: "1. Boot board into NFS so we can safely wipe local disks"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Set + verify nfs"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: nfs
        on_failure_revert_to: nfs   # already on nfs is the safe state

- name: "2-3. Cross-binding validate + provision each disk"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: true
  gather_subset: [mounts]
  pre_tasks:
    - name: "Assert / is on NFS before wiping anything"
      ansible.builtin.assert:
        that: >-
          ansible_mounts | selectattr('mount', 'equalto', '/')
          | map(attribute='fstype') | first in ['nfs', 'nfs4']
        fail_msg: "Board must be NFS-booted before reprovisioning local disks."

    - name: "Cross-binding validate: no two disks share a mount path"
      ansible.builtin.assert:
        that:
          - >-
            (armbian_netboot_local_disks
             | map(attribute='layout') | flatten
             | selectattr('mount', 'defined')
             | map(attribute='mount') | list
             | length)
            ==
            (armbian_netboot_local_disks
             | map(attribute='layout') | flatten
             | selectattr('mount', 'defined')
             | map(attribute='mount') | list
             | unique | length)
        fail_msg: >-
          Two or more disks declare the same mount path in their layouts.
          Mount paths: {{ armbian_netboot_local_disks | map(attribute='layout') | flatten | selectattr('mount', 'defined') | map(attribute='mount') | list }}

    - name: "Cross-binding validate: exactly one '/' across all disks"
      ansible.builtin.assert:
        that:
          - (armbian_netboot_local_disks | map(attribute='layout') | flatten | selectattr('mount', 'equalto', '/') | list | length) == 1
        fail_msg: >-
          Expected exactly one partition with mount: / across all
          armbian_netboot_local_disks; found
          {{ armbian_netboot_local_disks | map(attribute='layout') | flatten | selectattr('mount', 'equalto', '/') | list | length }}.

  tasks:
    - name: "Provision each disk"
      ansible.builtin.include_role:
        name: disk_provision
      vars:
        disk_binding: "{{ item }}"
      loop: "{{ armbian_netboot_local_disks }}"
      loop_control:
        label: "{{ item.device }}"

- name: "4. Flip pxelinux to local, verify, auto-revert on failure"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Set + verify local; auto-revert to nfs on failure"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: local
        on_failure_revert_to: nfs
```

- [ ] **Step 15.2: Lint**

```bash
make yamllint && make ansible-lint
```

Expected: both pass.

- [ ] **Step 15.3: Syntax-check**

```bash
ansible-playbook playbooks/reprovision_to_local.yml --syntax-check
```

Expected: passes.

- [ ] **Step 15.4: Commit**

```bash
git add playbooks/reprovision_to_local.yml
git commit -m "playbooks: reprovision_to_local.yml headless lifecycle (#77)"
```

---

## Task 16: Hardware E2E playbook against orange-pi-5-max-01

**Files:**
- Create: `playbooks/test_reprovision_e2e.yml`

Drives the full lifecycle on a real board and asserts intermediate state at each transition. Use orange-pi-5-max-01 as the canonical target.

- [ ] **Step 16.1: Write `test_reprovision_e2e.yml`**

```yaml
---
# Hardware E2E for reprovision_to_local.yml. Canonical target:
# orange-pi-5-max-01 (NVMe, PoE-powered). Other boards may run via
# --limit but acceptance criteria target this one.
#
# Phases:
#   A. Assert starting on NFS.
#   B. Run reprovision_to_local → assert findmnt / matches armbi_root_local.
#   C. Re-run reprovision_to_local → assert no destructive change
#      (preserved partition's sentinel survives).
#   D. set_boot_mode nfs → assert NFS rootfs.
#   E. set_boot_mode local → assert local rootfs intact.
#   F. Cleanup: set_boot_mode nfs.

- name: "A: Assert NFS starting state"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: true
  gather_subset: [mounts]
  tasks:
    - name: "Set boot mode to nfs (in case not already)"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: nfs
        on_failure_revert_to: nfs

- name: "B: First reprovision"
  import_playbook: reprovision_to_local.yml

- name: "B2: Assert local rootfs label"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: true
  gather_subset: [mounts]
  tasks:
    - name: "findmnt / reports armbi_root_local"
      ansible.builtin.command: "findmnt -no SOURCE,LABEL /"
      register: _fm
      changed_when: false

    - name: "Assert local label present"
      ansible.builtin.assert:
        that:
          - "'armbi_root_local' in _fm.stdout"
        fail_msg: "findmnt / shows {{ _fm.stdout }}; expected armbi_root_local."

    - name: "Write sentinel into the preserved /var partition"
      ansible.builtin.copy:
        dest: /var/reprovision_sentinel
        content: "E2E_PRESERVE_TEST\n"
        mode: "0644"
      become: true

- name: "C: Second reprovision (idempotency on preserved /var)"
  import_playbook: reprovision_to_local.yml

- name: "C2: Assert sentinel survived"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: false
  tasks:
    - name: "Read sentinel"
      ansible.builtin.slurp:
        src: /var/reprovision_sentinel
      register: _sent

    - name: "Sentinel content matches"
      ansible.builtin.assert:
        that:
          - (_sent.content | b64decode).strip() == 'E2E_PRESERVE_TEST'
        fail_msg: "Preserve idempotency failed: sentinel reads as {{ _sent.content | b64decode }}"

- name: "D: Back to nfs, assert NFS rootfs"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: false
  tasks:
    - name: "Set + verify nfs"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: nfs
        on_failure_revert_to: nfs

- name: "E: Back to local, sentinel still there"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: false
  tasks:
    - name: "Set + verify local"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: local
        on_failure_revert_to: nfs

    - name: "Sentinel still present after a nfs↔local round-trip"
      ansible.builtin.slurp:
        src: /var/reprovision_sentinel
      register: _sent2

    - name: "Sentinel content still matches"
      ansible.builtin.assert:
        that:
          - (_sent2.content | b64decode).strip() == 'E2E_PRESERVE_TEST'

- name: "F: Cleanup → nfs"
  hosts: "{{ target_hosts | default('orange-pi-5-max-01') }}"
  gather_facts: false
  tasks:
    - name: "Final set + verify nfs"
      ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
      vars:
        target_boot_mode: nfs
        on_failure_revert_to: nfs
```

- [ ] **Step 16.2: Syntax-check**

```bash
ansible-playbook playbooks/test_reprovision_e2e.yml --syntax-check
```

Expected: passes.

- [ ] **Step 16.3: Run against the real board (interactive, requires hardware)**

```bash
ansible-playbook playbooks/test_reprovision_e2e.yml --limit orange-pi-5-max-01
```

Expected: all phases A–F succeed. Inventory for orange-pi-5-max-01 must have `armbian_netboot_local_disks` defined with the full ESP+boot+var+root layout per the spec, plus `armbian_netboot_poe_switch` / `armbian_netboot_poe_port`. **If the inventory entry doesn't have these yet, add them first** — that's a prerequisite for the test, not part of this task's commit.

- [ ] **Step 16.4: Commit**

```bash
git add playbooks/test_reprovision_e2e.yml
git commit -m "playbooks: test_reprovision_e2e.yml hardware E2E (#77)"
```

---

## Task 17: Update README

**Files:**
- Modify: `README.md`

Update the Roles table, Playbooks table, Quick Reference table; add a "Headless reprovision to local boot" section under Daily operations with a mermaid lifecycle diagram.

- [ ] **Step 17.1: Add `reprovision_to_local.yml` to the Playbooks table**

Insert after the existing `provision_local_disk.yml` row (line ~301):

```markdown
| 10 | `reprovision_to_local.yml` | Once per board (or whenever layout changes) | Headless full-lifecycle: boot board into NFS → loop disk_provision over `armbian_netboot_local_disks` → flip pxelinux to local → verify. Auto-reverts to nfs on local-boot failure with a diagnostic bundle captured. |
```

- [ ] **Step 17.2: Add to the Quick reference table**

Insert after the existing `provision_local_disk.yml` row:

```markdown
| 10 | `reprovision_to_local.yml --limit <host>` | Headless reprovision: NFS → local with auto-revert |
```

- [ ] **Step 17.3: Add a new "Headless reprovision to local boot" section under Daily operations**

Insert between "Reprovision a board's local disk" and "Hardware E2E test":

```markdown
### Headless reprovision to local boot

```bash
ansible-playbook playbooks/reprovision_to_local.yml --limit orange-pi-5-max-01
```

Drives a board from any boot mode to verified local-disk boot in one
command. The board's inventory must define
`armbian_netboot_local_disks` (a list of disk bindings, each with a
declarative `layout` of GPT partitions) and
`armbian_netboot_boot_mode: local`.

Inventory example:

```yaml
armbian_netboot_local_disks:
  - device: /dev/nvme0n1
    wipe: true
    layout:
      - { id: esp,  size: 512MiB, type: esp,   format: vfat, label: armbi_esp,        mount: /boot/efi }
      - { id: boot, size: 1GiB,   type: linux, format: ext4, label: armbi_boot,       mount: /boot }
      - { id: var,  size: 20GiB,  type: var,   format: ext4, label: armbi_var,        mount: /var, preserve_on_reprovision: true }
      - { id: root, size: grow,   type: root,  format: ext4, label: armbi_root_local, mount: / }
```

`preserve_on_reprovision: true` partitions (typically `/var` for k3s state)
are detected by filesystem label and skipped on every re-run. Set
`force: true` on a binding to bypass preserve idempotency.

If the final cold-boot in local mode fails, the playbook captures a
diagnostic bundle (`findmnt`, `/proc/cmdline`, `lsblk`, `journalctl -k`,
last 200 UART lines if `-e capture_serial=true`), then auto-reverts
the board to nfs mode for forensic access. Operator fixes the root
cause and re-runs.
```

(Use the existing mermaid diagram style if you want to add one; minimum text-only is acceptable.)

- [ ] **Step 17.4: Update the Roles table**

The existing `disk_provision` row reads "Wipes + partitions + formats a block device, rsyncs source rootfs onto it..." Update it to:

```markdown
| [`disk_provision`](roles/disk_provision/) | a board | Apply a declarative GPT layout to one block device via `systemd-repart`, rsync `source` rootfs onto it, regenerate `/etc/fstab` (root by `LABEL=`). Idempotent on filesystem label; supports `preserve_on_reprovision: true` per partition for state preservation (e.g. `/var` for k3s). Single-disk contract — multi-disk hosts loop the role. |
```

- [ ] **Step 17.5: Lint markdown**

```bash
# Visually inspect — the repo doesn't have an automated markdown lint
# in CI, but the existing tables should parse correctly in GitHub's renderer.
grep -n "reprovision_to_local" README.md
```

Expected: at least 4 hits (Playbooks table, Quick reference, Daily ops section, possibly any link cross-refs).

- [ ] **Step 17.6: Commit**

```bash
git add README.md
git commit -m "README: document reprovision_to_local lifecycle + DSL (#77)"
```

---

## Task 18: Push branch + open PR

**Files:**
- (Remote: `origin`)

- [ ] **Step 18.1: Verify branch state**

```bash
git status && git log --oneline main..HEAD
```

Expected: clean working tree; all 18 task commits present on the feature branch.

- [ ] **Step 18.2: Push and open PR**

```bash
git push -u origin feature/77-disk-provision-dsl

gh pr create --title "Headless disk-provision DSL + reprovision_to_local lifecycle (#77)" --body "$(cat <<'EOF'
## Summary

Implements the design from [`docs/superpowers/specs/2026-05-17-disk-provision-dsl-design.md`](docs/superpowers/specs/2026-05-17-disk-provision-dsl-design.md). Closes #77.

- Per-host inline `armbian_netboot_local_disks` DSL for declarative multi-partition, multi-disk layouts.
- `disk_provision` refactored to use `systemd-repart` under the hood; preserve-on-reprovision idempotency keyed on filesystem label.
- `pxelinux_render` extended with `armbian_netboot_extra_modes` for user-defined named boot modes.
- `board_boot_verify` light-touched for custom-mode `verify_match`.
- New `reprovision_to_local.yml` lifecycle playbook with auto-revert to nfs on local-boot failure.
- New molecule scenarios `disk_provision_render` (Layer 1) and `disk_provision_loopback` (Layer 2). Extended `pxelinux_render` scenario for extra_modes.
- Hardware E2E playbook `test_reprovision_e2e.yml` targeting orange-pi-5-max-01.

## Test plan

- [ ] `make yamllint && make ansible-lint` clean
- [ ] `molecule test -s disk_provision_render` passes
- [ ] `molecule test -s disk_provision_loopback` passes (or documented hardware-only fallback)
- [ ] `molecule test -s pxelinux_render` passes (existing fixtures + new extra_modes + negative)
- [ ] `ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-max-01` regression-clean
- [ ] `ansible-playbook playbooks/test_reprovision_e2e.yml --limit orange-pi-5-max-01` end-to-end pass

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Return the PR URL.

---

## Self-Review Notes

**Spec coverage** — every section of the spec maps to a task:
- Boot model (passthrough) — embodied in Tasks 10, 11 (pxelinux extra_modes) and 16 (E2E asserts kernel-from-TFTP path).
- Architecture / 3-role-change + 1-playbook — Tasks 1-7 (disk_provision refactor), 10 (pxelinux_render), 12 (board_boot_verify), 13-15 (playbooks).
- DSL inventory schema — Task 1 (argspec) + Task 17 (README example).
- systemd-repart translation — Task 3 (rendering) + Task 5 (invocation).
- /etc/fstab generation — Task 6.
- Rendered pxelinux.cfg with extra_modes — Tasks 10 (template), 11 (molecule), 17 (README).
- disk_provision 10-step algorithm — Tasks 2 (validate), 3 (render), 4 (preserve scan), 5 (apply repart), 7 (populate including extlinux rewrite).
- Lifecycle reprovision_to_local.yml — Task 15.
- Auto-revert + diagnostic bundle — Task 14 (_lifecycle_set_and_verify) + reuse of existing diagnostic_bundle.yml.
- Pre-flight validation summary — Task 2 (per-binding) + Task 15 (cross-binding).
- Idempotency rules — Task 4 (preserve scan) + Task 5 (force flag clears preserve list).
- Cross-link with #78 — README mention deferred until #78 lands; not a code change.
- Testing strategy 4 layers — Tasks 8 (Layer 1), 9 (Layer 2), 11 (Layer 3), 16 (Layer 4).
- MVP acceptance criteria 1-8 — all covered.

**Type consistency check** — fact names used across tasks:
- `_dp_device_basename` (Task 3) → referenced in Task 7. ✓
- `_dp_repart_dir` (Task 3) → referenced in Task 5. ✓
- `_dp_preserve_ids` (Task 4) → referenced in Tasks 5, 7. ✓
- `_dp_existing_labels` (Task 4) — only used internally to derive `_dp_preserve_ids`. ✓
- `_dp_mount_root` (Task 7) — used internally. ✓
- `disk_binding` (Task 1 argspec) — referenced by all internal tasks files. ✓

**Placeholder scan** — no "TODO" markers, no "implement later", no missing code blocks. Step 2.3 deliberately creates placeholder files that get replaced by Tasks 3/4/5/7 — this is intentional scaffolding, not a plan failure (the placeholders are marked and replaced within the same plan).

**Known soft spot** — Task 13 (converge_boot_mode refactor) carries the risk that `playbooks/routeros/tasks/upload_pxelinux_one.yml` / `plumbing_check_one.yml` may not exist as per-host-invocable variants. The task header flags this and tells the engineer to read the existing reference playbooks first. Mitigation: if only per-batch variants exist, the implementer must add `_one.yml` variants OR refactor the lifecycle wrapper to do batch operations outside the loop. This is genuinely a "read the code and decide" moment that can't be specified further without examining state.
