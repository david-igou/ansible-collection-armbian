# `disk_image` Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single-purpose, transport-agnostic Ansible role that streams an `.img.xz` (or `.img`) from an HTTP URL or local file directly onto a block device via `xzcat | dd`, with a mount-aware safety guard and post-write partition-table settle.

**Architecture:** Three include_tasks blocks (Validate → Write → Settle) composed by `tasks/main.yml`. Block A asserts target is a whole-disk block device and not currently mounted. Block B dispatches on source-classify × format-classify to one of four `shell` invocations (URL/path × .xz/.img), all with `set -o pipefail` so curl/xz failures aren't swallowed by dd. Block C runs `sync` + `partprobe`. Phase 0 is added to `test_fleet_e2e.yml` to call the role on the SD card while booted on NFS. Validation lives in `extensions/molecule/disk_image/` and mirrors the existing `disk_provision_loopback` scenario (privileged Debian container + loop device + sparse test image).

**Tech Stack:** Ansible 2.15+, `xz-utils`, `curl`, `parted` (partprobe), `util-linux` (lsblk), `python3 -m http.server` for the molecule URL-branch test.

**Spec:** [`docs/superpowers/specs/2026-05-19-disk-image-role-design.md`](../specs/2026-05-19-disk-image-role-design.md)

---

## Task 1: Role skeleton + initial commit

Creates the role directory tree with the metadata files. Includes a no-op `tasks/main.yml` so `ansible-lint` is happy. No behaviour yet.

**Files:**
- Create: `roles/disk_image/meta/main.yml`
- Create: `roles/disk_image/meta/argument_specs.yml`
- Create: `roles/disk_image/defaults/main.yml`
- Create: `roles/disk_image/tasks/main.yml`
- Create: `roles/disk_image/README.md`

- [ ] **Step 1: Create `roles/disk_image/meta/main.yml`**

```yaml
---
galaxy_info:
  role_name: disk_image
  author: david-igou
  description: "Stream an .img.xz or .img to a block device via xzcat | dd."
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: Generic
      versions: [all]
dependencies: []
```

- [ ] **Step 2: Create `roles/disk_image/meta/argument_specs.yml`**

```yaml
---
argument_specs:
  main:
    short_description: "Stream a defined image to a defined block device."
    description:
      - >-
        Accepts an http(s):// URL or an absolute path to an .img.xz or .img,
        and a target block device (e.g. /dev/mmcblk0). Streams the image
        to the device via curl/xzcat/dd with set -o pipefail. Refuses if
        the target device, or any of its partitions, currently backs a
        mounted filesystem.
      - >-
        Runs on the board (or any host with root) that owns the target
        device. Caller is responsible for ensuring the running rootfs is
        NOT on the target device — the mount-aware guard enforces this.
        Always writes; no idempotency cache.

    options:
      image_source:
        type: str
        required: true
        description: >-
          Either an http(s):// URL or an absolute path on the running host.
          Auto-dispatch by extension: .img.xz → xzcat | dd; .img → dd direct.
          Mismatched extension is a hard failure (no content sniffing).
      target_device:
        type: str
        required: true
        description: >-
          Absolute path to a block device (e.g. /dev/mmcblk0, /dev/nvme0n1).
          Must be a real block device (S_ISBLK), not a partition node.
      dd_bs:
        type: str
        default: "4M"
        description: "dd block size. Default tuned for SD/NVMe throughput."
```

- [ ] **Step 3: Create `roles/disk_image/defaults/main.yml`**

```yaml
---
# disk_image role defaults.
# Inputs are documented in meta/argument_specs.yml — defaults here
# are only for optional knobs.

# dd block size. 4 MiB is a good default for SD and NVMe.
dd_bs: "4M"
```

- [ ] **Step 4: Create `roles/disk_image/tasks/main.yml` (no-op placeholder)**

```yaml
---
# disk_image — stream an image to a block device.
# See meta/argument_specs.yml for the contract.

- name: "No-op placeholder (filled in by Tasks 3/4/5)"
  ansible.builtin.meta: noop
```

- [ ] **Step 5: Create `roles/disk_image/README.md`**

````markdown
# disk_image

Single-purpose, transport-agnostic role. Streams an `.img.xz` or raw
`.img` to a block device via `curl | xz -dc | dd` (or `dd` direct for
raw images) with `set -o pipefail`. Refuses to write to a target whose
partition table currently backs a mounted filesystem.

## When to use

- Reimage the SD card from an NFS-booted board (fleet-test Phase 0
  state reset).
- Reimage an NVMe device from any rootfs that isn't on it.

## Inputs

See `meta/argument_specs.yml`. Required: `image_source`, `target_device`.
Optional: `dd_bs` (default `4M`).

## Example

```yaml
- ansible.builtin.include_role:
    name: disk_image
  vars:
    image_source: "https://images.example.org/orange-pi-5-pro.img.xz"
    target_device: /dev/mmcblk0
```

## Prerequisites

The running rootfs must have `curl`, `xz`, `dd`, `sync`, and `partprobe`
(from `parted`) installed. All present in stock Armbian.

## What this role does NOT do

- Reset identity (machine-id, ssh host keys, hostname).
- Resize partitions.
- Verify image integrity (sha256). Streaming means a corrupt or
  truncated source leaves a partial image on the target — re-invoke
  to recover.
````

- [ ] **Step 6: Run yamllint**

Run: `make yamllint`
Expected: PASS (no errors on the new files).

- [ ] **Step 7: Run ansible-lint**

Run: `make ansible-lint`
Expected: PASS. ansible-lint will validate `meta/argument_specs.yml`
and refuse `tasks/main.yml` if there are FQCN or syntax problems.

- [ ] **Step 8: Commit**

```bash
git add roles/disk_image/
git commit -m "disk_image: role skeleton (meta + defaults + README, no behaviour)"
```

---

## Task 2: Molecule scenario scaffolding

Mirrors `extensions/molecule/disk_provision_loopback/`. Privileged Debian
12 container, loop device backed by a sparse file. Adds `disk_image` to
the Makefile's `MOLECULE_SCENARIOS` so `make molecule SCENARIO=disk_image`
works.

**Files:**
- Create: `extensions/molecule/disk_image/molecule.yml`
- Create: `extensions/molecule/disk_image/prepare.yml`
- Create: `extensions/molecule/disk_image/converge.yml`
- Create: `extensions/molecule/disk_image/verify.yml`
- Modify: `Makefile` (one-line MOLECULE_SCENARIOS additions)

- [ ] **Step 1: Create `extensions/molecule/disk_image/molecule.yml`**

```yaml
---
# Privileged Debian 12 container + loop device.
# Mirrors disk_provision_loopback. Same SYS_ADMIN + /dev:/dev mount
# pattern so losetup + partprobe work.

dependency:
  name: galaxy
  options:
    requirements-file: extensions/molecule/provisioners/${PROVISIONER:-podman}/requirements.yml
    force: true

driver:
  name: default
  options:
    managed: true
    ansible_connection_options:
      connection: local

platforms:
  - name: disk-image
    podman:
      image: docker.io/library/debian:12
      command: sleep 1d
      privileged: true
      capabilities:
        - SYS_ADMIN
      volumes:
        - /dev:/dev

provisioner:
  name: ansible
  playbooks:
    converge: converge.yml
    create: ../provisioners/${PROVISIONER:-podman}/create.yml
    destroy: ../provisioners/${PROVISIONER:-podman}/destroy.yml
    prepare: prepare.yml
    verify: verify.yml
  inventory:
    links:
      group_vars: ../provisioners/${PROVISIONER:-podman}/group_vars/

verifier:
  name: ansible

scenario:
  name: disk_image
  test_sequence:
    - dependency
    - syntax
    - create
    - prepare
    - converge
    - verify
    - destroy
```

- [ ] **Step 2: Create `extensions/molecule/disk_image/prepare.yml`**

```yaml
---
# Prepares the disk_image molecule scenario:
#   - python3 + tools the role's runtime prereqs require
#   - 64 MiB loop device (target_device under test)
#   - 32 MiB test "image": one ext4 partition, sentinel file inside
#   - .img.xz copy of the test image for the xz dispatch branch
#   - background python http.server on 127.0.0.1:8765 serving both

- name: Prepare disk-image instance (raw bootstrap)
  hosts: all
  gather_facts: false
  tasks:
    - name: Update apt cache
      ansible.builtin.raw: apt-get update -qq
      changed_when: true

    - name: Bootstrap python3
      ansible.builtin.raw: apt-get install -y --no-install-recommends python3
      changed_when: true

- name: Install runtime prereqs and stage fixtures
  hosts: all
  gather_facts: true
  tasks:
    - name: "Install runtime prereqs: curl xz-utils parted util-linux e2fsprogs"
      ansible.builtin.apt:
        name:
          - curl
          - xz-utils
          - parted
          - util-linux
          - e2fsprogs
        state: present
        update_cache: false

    - name: "Create a 64 MiB sparse file as the target block-device backing"
      ansible.builtin.command: "truncate -s 64M /tmp/target.img"
      changed_when: true

    - name: "Attach target.img as a loop device"
      ansible.builtin.command: "losetup -f --show /tmp/target.img"
      register: _target_loop
      changed_when: true

    - name: "Persist target loop device path"
      ansible.builtin.copy:
        dest: /tmp/target_loop
        content: "{{ _target_loop.stdout }}\n"
        mode: "0644"

    - name: "Create a 32 MiB raw test image with one ext4 partition + sentinel"
      ansible.builtin.shell: |
        set -euo pipefail
        truncate -s 32M /tmp/test.img
        parted -s /tmp/test.img mklabel msdos
        parted -s /tmp/test.img mkpart primary ext4 1MiB 100%
        SRC_LOOP=$(losetup -f --show -P /tmp/test.img)
        mkfs.ext4 -F -L diskimg_test "${SRC_LOOP}p1"
        mkdir -p /tmp/mnt
        mount "${SRC_LOOP}p1" /tmp/mnt
        echo "DISK_IMAGE_SENTINEL" > /tmp/mnt/sentinel
        umount /tmp/mnt
        losetup -d "${SRC_LOOP}"
      args:
        creates: /tmp/test.img

    - name: "Compress the test image to .img.xz (for xz dispatch branch test)"
      ansible.builtin.command: "xz -k -f /tmp/test.img"
      args:
        creates: /tmp/test.img.xz

    - name: "Start a background http.server serving /tmp on 127.0.0.1:8765"
      ansible.builtin.shell: |
        nohup python3 -m http.server 8765 \
          --bind 127.0.0.1 \
          --directory /tmp \
          >/tmp/http.log 2>&1 &
        echo $! > /tmp/http.pid
        # Wait until the port is accepting connections.
        for _ in $(seq 1 20); do
          if (echo > /dev/tcp/127.0.0.1/8765) >/dev/null 2>&1; then
            exit 0
          fi
          sleep 0.25
        done
        echo "http.server did not come up" >&2
        exit 1
      args:
        executable: /bin/bash
      changed_when: true
```

- [ ] **Step 3: Create `extensions/molecule/disk_image/converge.yml` (no-op for now)**

```yaml
---
# Converge is intentionally empty in Task 2.
# Tasks 3/4/5/6 add include_role calls here as the role's behaviour
# is implemented.
- hosts: all
  gather_facts: true
  tasks:
    - name: "Placeholder converge — role-skeleton scenario boot test"
      ansible.builtin.debug:
        msg: "disk_image molecule scaffolding works; behaviour added in later tasks."
```

- [ ] **Step 4: Create `extensions/molecule/disk_image/verify.yml` (no-op for now)**

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Placeholder verify — checks fixtures exist (no role behaviour yet)"
      ansible.builtin.stat:
        path: "{{ item }}"
      register: _fixtures
      loop:
        - /tmp/target_loop
        - /tmp/test.img
        - /tmp/test.img.xz

    - name: "Assert all fixtures exist"
      ansible.builtin.assert:
        that:
          - _fixtures.results | map(attribute='stat.exists') | min
        fail_msg: >-
          Prepare did not produce all fixtures. Got:
          {{ _fixtures.results | map(attribute='item') | zip(_fixtures.results | map(attribute='stat.exists')) | list }}
```

- [ ] **Step 5: Add scenario to Makefile**

In `Makefile`, the line currently reads:

```makefile
MOLECULE_SCENARIOS := default rootfs_clone pxelinux_render image_build local_kernel_render persist_uboot_env
```

Change it to:

```makefile
MOLECULE_SCENARIOS := default rootfs_clone pxelinux_render image_build local_kernel_render persist_uboot_env disk_image
```

- [ ] **Step 6: Run yamllint and ansible-lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 7: Run the scenario**

Run: `make molecule SCENARIO=disk_image`
Expected: PASS. The scenario creates a privileged container, builds the
fixtures, runs the placeholder converge and verify, and destroys.

- [ ] **Step 8: Commit**

```bash
git add extensions/molecule/disk_image/ Makefile
git commit -m "disk_image: molecule scenario scaffolding (loopback + http fixture)"
```

---

## Task 3: Block A — pre-flight validation

Implements the no-side-effects validation block. After this task the
role still does not write anything, but it asserts the target is a
whole-disk block device and is not currently mounted.

**Files:**
- Create: `roles/disk_image/tasks/_validate.yml`
- Modify: `roles/disk_image/tasks/main.yml`
- Modify: `extensions/molecule/disk_image/converge.yml`
- Modify: `extensions/molecule/disk_image/verify.yml`

- [ ] **Step 1: Add converge call that exercises Block A on a clean target**

Edit `extensions/molecule/disk_image/converge.yml`:

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Read target loop device path"
      ansible.builtin.slurp:
        src: /tmp/target_loop
      register: _target_b64

    - name: "Set target loop fact"
      ansible.builtin.set_fact:
        _target_loop: "{{ (_target_b64.content | b64decode).strip() }}"

    - name: "Converge: invoke role on a clean (unmounted) target — Block A only for now"
      ansible.builtin.include_role:
        name: disk_image
      vars:
        image_source: "/tmp/test.img"
        target_device: "{{ _target_loop }}"
```

- [ ] **Step 2: Add verify assertions for Block A happy path**

Edit `extensions/molecule/disk_image/verify.yml`:

```yaml
---
- hosts: all
  gather_facts: true
  tasks:
    - name: "Read target loop device path"
      ansible.builtin.slurp:
        src: /tmp/target_loop
      register: _target_b64

    - name: "Set target loop fact"
      ansible.builtin.set_fact:
        _target_loop: "{{ (_target_b64.content | b64decode).strip() }}"

    # --- Negative tests for Block A ---
    # We exercise each rejection branch by calling the role with a bad
    # input and asserting the role failed (block/rescue captures the
    # failure so verify continues).

    - name: "Block A — reject: target is a partition node"
      block:
        - name: "Create a child partition to use as a bad target"
          ansible.builtin.shell: |
            set -euo pipefail
            parted -s {{ _target_loop }} mklabel msdos
            parted -s {{ _target_loop }} mkpart primary ext4 1MiB 100%
            partprobe {{ _target_loop }}
            sleep 1
          changed_when: true

        - name: "Call role with the partition as target_device — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.img"
            target_device: "{{ _target_loop }}p1"
          register: _result_partition
      rescue:
        - name: "Confirm role failed because target was a partition"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is defined
              - "'partition' in ansible_failed_result.msg"
            fail_msg: >-
              Expected failure mentioning 'partition'; got:
              {{ ansible_failed_result | default({}) }}

    - name: "Block A — reject: image_source is gibberish"
      block:
        - name: "Call role with non-URL, non-abs-path image_source — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "neither-url-nor-path"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed on image_source classification"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is defined
              - "'image_source' in ansible_failed_result.msg"
            fail_msg: >-
              Expected failure mentioning 'image_source'; got:
              {{ ansible_failed_result | default({}) }}

    - name: "Block A — reject: unsupported extension"
      block:
        - name: "Create a bogus-extension fixture"
          ansible.builtin.copy:
            dest: /tmp/test.iso
            content: ""
            mode: "0644"

        - name: "Call role with .iso source — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.iso"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed on extension classification"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is defined
              - "'unsupported format' in ansible_failed_result.msg"
            fail_msg: >-
              Expected failure mentioning 'unsupported format'; got:
              {{ ansible_failed_result | default({}) }}

    - name: "Block A — reject: target is mounted"
      block:
        - name: "Mount a partition on the target loop device"
          ansible.builtin.shell: |
            set -euo pipefail
            # Reuse the partition we created above; format + mount it
            mkfs.ext4 -F {{ _target_loop }}p1
            mkdir -p /tmp/mounted-target
            mount {{ _target_loop }}p1 /tmp/mounted-target
          changed_when: true

        - name: "Call role on a target whose partition is mounted — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.img"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed because target was mounted"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is defined
              - "'backs a mounted filesystem' in ansible_failed_result.msg"
            fail_msg: >-
              Expected failure mentioning 'backs a mounted filesystem'; got:
              {{ ansible_failed_result | default({}) }}

      always:
        - name: "Cleanup: unmount the test mount + wipe the partition table"
          ansible.builtin.shell: |
            umount /tmp/mounted-target || true
            wipefs -a {{ _target_loop }} || true
            partprobe {{ _target_loop }} || true
          changed_when: false
```

- [ ] **Step 3: Run molecule converge to see Block A is not yet implemented (smoke)**

Run: `make molecule SCENARIO=disk_image`
Expected: the placeholder `tasks/main.yml` is a no-op, so the role call
succeeds and the verify negative-tests FAIL because the role didn't
reject anything. Read the failure messages — they should reference
"Expected failure mentioning ..." messages.

- [ ] **Step 4: Create `roles/disk_image/tasks/_validate.yml`**

```yaml
---
# Block A — pre-flight validation. No side effects.
#
# Asserts:
#   1. target_device exists and is a whole-disk block device.
#   2. Neither target_device nor any of its partitions is currently
#      mounted (read from /proc/mounts).
#   3. image_source is either an http(s):// URL or an absolute path.
#   4. image_source ends in .img.xz or .img (extension-based, no
#      content sniffing).

- name: "Block A — stat target_device"
  ansible.builtin.stat:
    path: "{{ target_device }}"
  register: _target_stat

- name: "Block A — assert target_device is a block device"
  ansible.builtin.assert:
    that:
      - _target_stat.stat.exists
      - _target_stat.stat.isblk | default(false)
    fail_msg: "not a block device: {{ target_device }}"

- name: "Block A — check /sys/class/block/<basename>/partition (whole-disk discriminator)"
  ansible.builtin.stat:
    path: "/sys/class/block/{{ target_device | basename }}/partition"
  register: _partition_sysfs

- name: "Block A — assert target_device is a whole disk, not a partition"
  ansible.builtin.assert:
    that:
      - not _partition_sysfs.stat.exists
    fail_msg: >-
      target_device is a partition, not a whole disk: {{ target_device }}.
      Pass the parent disk (e.g. /dev/mmcblk0, not /dev/mmcblk0p1).

- name: "Block A — enumerate target_device + its partitions via lsblk"
  ansible.builtin.command: "lsblk -nro NAME {{ target_device }}"
  register: _lsblk_names
  changed_when: false

- name: "Block A — read /proc/mounts"
  ansible.builtin.slurp:
    src: /proc/mounts
  register: _mounts_b64

- name: "Block A — derive the set of mount-source paths for target + partitions"
  ansible.builtin.set_fact:
    _candidate_sources: >-
      {{ _lsblk_names.stdout_lines | map('regex_replace', '^', '/dev/') | list }}
    _proc_mounts: "{{ (_mounts_b64.content | b64decode).splitlines() }}"

- name: "Block A — find any /proc/mounts line whose source matches target or a partition"
  ansible.builtin.set_fact:
    _mounted_match: >-
      {{ _proc_mounts
         | select('match', '^(' + (_candidate_sources | join('|')) + ') ')
         | list }}

- name: "Block A — assert target_device and its partitions are not mounted"
  ansible.builtin.assert:
    that:
      - _mounted_match | length == 0
    fail_msg: >-
      target device {{ target_device }} backs a mounted filesystem:
      {{ _mounted_match | first | default('<unknown>') }}

- name: "Block A — classify image_source (URL vs path)"
  ansible.builtin.set_fact:
    _src_is_url: "{{ image_source is match('^https?://') }}"
    _src_is_path: "{{ image_source is match('^/') }}"

- name: "Block A — fail when image_source is neither URL nor abs path"
  ansible.builtin.fail:
    msg: "image_source must be http(s):// URL or absolute path, got: {{ image_source }}"
  when:
    - not _src_is_url
    - not _src_is_path

- name: "Block A — for path source, stat it and assert regular file"
  when: _src_is_path
  block:
    - name: "Block A — stat image_source path"
      ansible.builtin.stat:
        path: "{{ image_source }}"
      register: _src_stat

    - name: "Block A — assert image_source path exists and is a regular file"
      ansible.builtin.assert:
        that:
          - _src_stat.stat.exists
          - _src_stat.stat.isreg | default(false)
        fail_msg: "image_source path does not exist or is not a regular file: {{ image_source }}"

- name: "Block A — classify format by extension"
  ansible.builtin.set_fact:
    _fmt: >-
      {{ 'xz'  if image_source | regex_search('\\.img\\.xz$')
         else 'raw' if image_source | regex_search('\\.img$')
         else 'unknown' }}

- name: "Block A — fail on unsupported format"
  ansible.builtin.fail:
    msg: "unsupported format; only .img and .img.xz: {{ image_source }}"
  when: _fmt == 'unknown'
```

- [ ] **Step 5: Wire `_validate.yml` into `tasks/main.yml`**

Replace `roles/disk_image/tasks/main.yml` with:

```yaml
---
# disk_image — stream an image to a block device.
# See meta/argument_specs.yml for the contract.

- name: "Block A — validate inputs (no side effects)"
  ansible.builtin.import_tasks: _validate.yml
```

- [ ] **Step 6: Re-run molecule, see Block A negative tests pass; happy-path converge still no-op**

Run: `make molecule SCENARIO=disk_image`
Expected: PASS. The converge call (clean target) flows through Block A
without failing (target is a block device, not mounted, image_source
is a valid path, format is `raw`). Each negative branch in verify.yml
hits its `rescue:` with the expected failure substring.

- [ ] **Step 7: Commit**

```bash
git add roles/disk_image/tasks/ extensions/molecule/disk_image/converge.yml extensions/molecule/disk_image/verify.yml
git commit -m "disk_image: Block A — pre-flight validation (mount-aware guard + extension classify)"
```

---

## Task 4: Block B — stream and write

Implements the streaming write block. Four dispatch branches by
`(source-classify, format-classify)`. All use `set -o pipefail` so a
curl 404 or xz CRC error doesn't get swallowed by dd's zero exit.

**Files:**
- Create: `roles/disk_image/tasks/_write.yml`
- Modify: `roles/disk_image/tasks/main.yml`
- Modify: `extensions/molecule/disk_image/verify.yml`

- [ ] **Step 1: Add positive-path verify steps that exercise all four branches**

Append to `extensions/molecule/disk_image/verify.yml`:

```yaml
    # --- Positive tests for Block B (4 dispatch branches) ---
    # Each test wipes the target, invokes the role with a different
    # (source-classify, format-classify) combination, then asserts the
    # ext4 partition + sentinel from the test image landed on the target.

    - name: "Block B — exercise: path + raw .img"
      block:
        - name: "Wipe target loop"
          ansible.builtin.command: "wipefs -a {{ _target_loop }}"
          changed_when: true

        - name: "Invoke role: path + .img"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.img"
            target_device: "{{ _target_loop }}"

        - name: "Read written bytes from target (whole-disk)"
          ansible.builtin.command: "lsblk -nro NAME,FSTYPE,LABEL {{ _target_loop }}"
          register: _lsblk_after_path_raw
          changed_when: false

        - name: "Assert target now carries the test image's labelled partition"
          ansible.builtin.assert:
            that:
              - "'diskimg_test' in _lsblk_after_path_raw.stdout"
              - "'ext4' in _lsblk_after_path_raw.stdout"

    - name: "Block B — exercise: path + .img.xz"
      block:
        - name: "Wipe target loop"
          ansible.builtin.command: "wipefs -a {{ _target_loop }}"
          changed_when: true

        - name: "Invoke role: path + .img.xz"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.img.xz"
            target_device: "{{ _target_loop }}"

        - name: "lsblk shows partition + label"
          ansible.builtin.command: "lsblk -nro NAME,FSTYPE,LABEL {{ _target_loop }}"
          register: _lsblk_after_path_xz
          changed_when: false

        - name: "Assert"
          ansible.builtin.assert:
            that:
              - "'diskimg_test' in _lsblk_after_path_xz.stdout"
              - "'ext4' in _lsblk_after_path_xz.stdout"

    - name: "Block B — exercise: URL + raw .img"
      block:
        - name: "Wipe target loop"
          ansible.builtin.command: "wipefs -a {{ _target_loop }}"
          changed_when: true

        - name: "Invoke role: URL + .img"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "http://127.0.0.1:8765/test.img"
            target_device: "{{ _target_loop }}"

        - name: "lsblk shows partition + label"
          ansible.builtin.command: "lsblk -nro NAME,FSTYPE,LABEL {{ _target_loop }}"
          register: _lsblk_after_url_raw
          changed_when: false

        - name: "Assert"
          ansible.builtin.assert:
            that:
              - "'diskimg_test' in _lsblk_after_url_raw.stdout"
              - "'ext4' in _lsblk_after_url_raw.stdout"

    - name: "Block B — exercise: URL + .img.xz"
      block:
        - name: "Wipe target loop"
          ansible.builtin.command: "wipefs -a {{ _target_loop }}"
          changed_when: true

        - name: "Invoke role: URL + .img.xz"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "http://127.0.0.1:8765/test.img.xz"
            target_device: "{{ _target_loop }}"

        - name: "lsblk shows partition + label"
          ansible.builtin.command: "lsblk -nro NAME,FSTYPE,LABEL {{ _target_loop }}"
          register: _lsblk_after_url_xz
          changed_when: false

        - name: "Assert"
          ansible.builtin.assert:
            that:
              - "'diskimg_test' in _lsblk_after_url_xz.stdout"
              - "'ext4' in _lsblk_after_url_xz.stdout"

    - name: "Block B — failure propagation: curl 404 must fail the task"
      block:
        - name: "Wipe target loop"
          ansible.builtin.command: "wipefs -a {{ _target_loop }}"
          changed_when: true

        - name: "Invoke role with a URL that 404s"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "http://127.0.0.1:8765/nonexistent.img.xz"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed (pipefail propagated curl's exit)"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.rc is defined
              - ansible_failed_result.rc != 0
            fail_msg: >-
              Expected non-zero exit from a 404; got:
              {{ ansible_failed_result | default({}) }}
```

- [ ] **Step 2: Run molecule, see new tests fail (Block B not yet implemented)**

Run: `make molecule SCENARIO=disk_image`
Expected: FAIL. The role's `main.yml` only imports Block A; the four
positive Block B tests should fail with "diskimg_test not in
_lsblk_after_*.stdout" because nothing wrote bytes to the target.

- [ ] **Step 3: Create `roles/disk_image/tasks/_write.yml`**

```yaml
---
# Block B — stream and write.
#
# Four shell dispatch branches by (_src_is_url, _fmt). All use
# `set -o pipefail` so a curl 404 / xz CRC error / partial read in the
# pipe is propagated to the task's rc, instead of being swallowed by
# dd's zero exit. become: true is required for dd-to-block-device.

- name: "Block B — path + raw .img → dd direct"
  ansible.builtin.shell:
    cmd: >-
      dd if={{ image_source | quote }} of={{ target_device | quote }}
      bs={{ dd_bs | quote }} conv=fsync status=progress
    executable: /bin/bash
  become: true
  when:
    - _src_is_path
    - _fmt == 'raw'
  register: _write_path_raw
  changed_when: true

- name: "Block B — path + .img.xz → xzcat | dd"
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      xz -dc {{ image_source | quote }}
      | dd of={{ target_device | quote }}
      bs={{ dd_bs | quote }} conv=fsync status=progress
    executable: /bin/bash
  become: true
  when:
    - _src_is_path
    - _fmt == 'xz'
  register: _write_path_xz
  changed_when: true

- name: "Block B — URL + raw .img → curl | dd"
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      curl -fsSL {{ image_source | quote }}
      | dd of={{ target_device | quote }}
      bs={{ dd_bs | quote }} conv=fsync status=progress
    executable: /bin/bash
  become: true
  when:
    - _src_is_url
    - _fmt == 'raw'
  register: _write_url_raw
  changed_when: true

- name: "Block B — URL + .img.xz → curl | xzcat | dd"
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      curl -fsSL {{ image_source | quote }}
      | xz -dc
      | dd of={{ target_device | quote }}
      bs={{ dd_bs | quote }} conv=fsync status=progress
    executable: /bin/bash
  become: true
  when:
    - _src_is_url
    - _fmt == 'xz'
  register: _write_url_xz
  changed_when: true
```

- [ ] **Step 4: Wire Block B into `tasks/main.yml`**

Replace `roles/disk_image/tasks/main.yml`:

```yaml
---
# disk_image — stream an image to a block device.
# See meta/argument_specs.yml for the contract.

- name: "Block A — validate inputs (no side effects)"
  ansible.builtin.import_tasks: _validate.yml

- name: "Block B — stream and write"
  ansible.builtin.import_tasks: _write.yml
```

- [ ] **Step 5: Run molecule, see all Block B tests pass**

Run: `make molecule SCENARIO=disk_image`
Expected: PASS. All four dispatch branches write the test image, the
sentinel partition is detected by lsblk on the target, and the 404
test produces a non-zero rc thanks to `set -o pipefail`.

- [ ] **Step 6: Commit**

```bash
git add roles/disk_image/tasks/ extensions/molecule/disk_image/verify.yml
git commit -m "disk_image: Block B — streaming write with pipefail propagation"
```

---

## Task 5: Block C — settle

Implements the post-write sync + partprobe. Verifies the kernel's
partition node materialises after the write.

**Files:**
- Create: `roles/disk_image/tasks/_settle.yml`
- Modify: `roles/disk_image/tasks/main.yml`
- Modify: `extensions/molecule/disk_image/verify.yml`

- [ ] **Step 1: Add a verify step that asserts the partition device-node exists post-converge**

Append to `extensions/molecule/disk_image/verify.yml`:

```yaml
    # --- Block C — partition node must exist after settle ---
    - name: "Block C — wipe target loop and reimage one last time"
      ansible.builtin.command: "wipefs -a {{ _target_loop }}"
      changed_when: true

    - name: "Block C — invoke role to write image"
      ansible.builtin.include_role:
        name: disk_image
      vars:
        image_source: "/tmp/test.img"
        target_device: "{{ _target_loop }}"

    - name: "Block C — stat the first partition node"
      ansible.builtin.stat:
        path: "{{ _target_loop }}p1"
      register: _part_node

    - name: "Block C — assert partprobe published the partition node"
      ansible.builtin.assert:
        that:
          - _part_node.stat.exists
        fail_msg: >-
          Expected {{ _target_loop }}p1 to exist after Block C settle;
          partprobe did not publish the partition node.
```

- [ ] **Step 2: Run molecule, see the new assertion fail**

Run: `make molecule SCENARIO=disk_image`
Expected: FAIL. The role's `main.yml` runs Block A + B but no settle;
the partition node `<loop>p1` may not exist yet when verify checks it.

- [ ] **Step 3: Create `roles/disk_image/tasks/_settle.yml`**

```yaml
---
# Block C — settle the kernel's view of the new partition table.
#
# `conv=fsync` in Block B flushed dd's own buffer. The explicit sync
# below is belt-and-braces against page-cache writes from other
# processes. partprobe asks the kernel to re-read the partition table
# so udev can materialise <target>p1, p2, ... nodes for downstream
# mounts.

- name: "Block C — sync filesystem buffers"
  ansible.builtin.command: sync
  become: true
  changed_when: false

- name: "Block C — partprobe target_device (re-read partition table)"
  ansible.builtin.command: "partprobe {{ target_device }}"
  become: true
  changed_when: false

- name: "Block C — give udev a moment to materialise partition nodes"
  ansible.builtin.pause:
    seconds: 1
```

- [ ] **Step 4: Wire Block C into `tasks/main.yml`**

Replace `roles/disk_image/tasks/main.yml`:

```yaml
---
# disk_image — stream an image to a block device.
# See meta/argument_specs.yml for the contract.

- name: "Block A — validate inputs (no side effects)"
  ansible.builtin.import_tasks: _validate.yml

- name: "Block B — stream and write"
  ansible.builtin.import_tasks: _write.yml

- name: "Block C — settle (sync + partprobe + udev settle)"
  ansible.builtin.import_tasks: _settle.yml
```

- [ ] **Step 5: Run molecule, see Block C assertion pass**

Run: `make molecule SCENARIO=disk_image`
Expected: PASS. After Block C, `<loop>p1` exists.

- [ ] **Step 6: Commit**

```bash
git add roles/disk_image/tasks/ extensions/molecule/disk_image/verify.yml
git commit -m "disk_image: Block C — sync + partprobe + udev settle"
```

---

## Task 6: Lint + dry-run against real inventory (no hardware writes)

The role is functionally complete after Task 5. Before wiring into the
fleet test, run a syntax-check against the real inventory to make sure
the role plays nicely with the collection's playbook conventions.

**Files:** none modified. This task is verification-only.

- [ ] **Step 1: Full lint pass**

Run: `make lint`
Expected: PASS. yamllint + ansible-lint clean.

- [ ] **Step 2: Build the collection tarball**

Run: `make collection-build`
Expected: PASS. Produces
`david_igou-armbian-<version>.tar.gz` at the repo root with
`roles/disk_image/` included.

- [ ] **Step 3: Confirm the role is in the tarball**

Run: `tar -tzf david_igou-armbian-*.tar.gz | grep '^roles/disk_image/'`
Expected: lists the role's files (tasks/, meta/, defaults/, README.md).

- [ ] **Step 4: Clean up the build artefact**

Run: `make clean`

- [ ] **Step 5: Commit (only if any lint fixes were needed)**

If `make lint` surfaced anything in steps 1-4 that required edits,
commit those now. Otherwise skip.

---

## Task 7: Phase 0 integration in `test_fleet_e2e.yml`

Adds Phase 0 to the fleet test: while the fleet is on NFS (Phase B's
end state), dd the canonical image to each board's SD card. This is
the motivating use case from the spec.

Per spec §5, the design assumes the prior fleet run ended on NFS (or
that the operator converges to NFS before running Phase 0). For first
runs the operator can `-e skip_dd_sd=true` until they're confident the
fleet is in the right state.

**Files:**
- Modify: `playbooks/test_fleet_e2e.yml`
- Modify: `inventory/group_vars/all.yml` (default for `armbian_sd_device`)

- [ ] **Step 1: Add `armbian_sd_device` default to inventory docs**

Append to `inventory/group_vars/all.yml`:

```yaml
# Default block device for SD-card reimaging (test_fleet_e2e.yml Phase 0).
# Override per-host in inventory if a future board's SD slot enumerates
# differently (see CLAUDE.md "MMC controller index varies per board").
armbian_sd_device: /dev/mmcblk0
```

- [ ] **Step 2: Insert Phase 0 into `playbooks/test_fleet_e2e.yml`**

Find the existing line near the top of the file (around line 60-95)
where the pre-flight play begins. After the pre-flight play(s) but
**before** `Phase A`, insert a new Phase 0 play. The full block to
insert immediately before `- name: "Phase A — boot from SD card (parallel)"`:

```yaml
- name: "Phase 0 — dd canonical image to SD (state reset, parallel)"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_dd_sd: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/0-dd-sd"
  pre_tasks:
    - name: Load board configs (consumed by pxelinux_render via _converge_boot_mode)
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"
  tasks:
    - name: "Phase 0 — block"
      when: not (skip_dd_sd | bool)
      block:
        - name: "Phase 0 — start timer"
          ansible.builtin.set_fact:
            _t_phase_0_start: "{{ lookup('pipe', 'date +%s') | int }}"

        # The dd target is /dev/mmcblk0. The role's mount-aware guard
        # will refuse if we're booted off SD — converge to NFS first.
        - name: "Phase 0 — set + verify nfs"
          ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
          vars:
            target_boot_mode: nfs
            on_failure_revert_to: sd

        - name: "Phase 0 — auto-bootstrap if needed (NFS rootfs may be fresh)"
          ansible.builtin.include_tasks: tasks/auto_bootstrap_if_needed.yml
          vars:
            _phase_label: "Phase 0"

        - name: "Phase 0 — dd canonical image to SD"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "{{ armbian_image_urls[armbian_board_model] }}"
            target_device: "{{ armbian_sd_device | default('/dev/mmcblk0') }}"

        - name: "Phase 0 — write evidence"
          ansible.builtin.copy:
            content: |
              === Phase 0 (dd SD) — {{ inventory_hostname }} ===
              date:    {{ ansible_date_time.iso8601 | default('') }}
              source:  {{ armbian_image_urls[armbian_board_model] }}
              target:  {{ armbian_sd_device | default('/dev/mmcblk0') }}
              From-state: NFS rootfs (Phase 0 always re-converges nfs before dd)
            dest: "{{ fleet_artifact_dir }}/dd-sd-evidence.txt"
          delegate_to: localhost
          vars:
            ansible_connection: local

        - name: "Phase 0 — record timing"
          ansible.builtin.lineinfile:
            path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
            line: "0\t{{ _t_phase_0_start }}\t{{ _t_end }}\t{{ (_t_end | int) - (_t_phase_0_start | int) }}"
            create: true
            mode: '0644'
          vars:
            _t_end: "{{ lookup('pipe', 'date +%s') | int }}"
            ansible_connection: local
          delegate_to: localhost
```

- [ ] **Step 3: Add `0-dd-sd` to the pre-flight artifact-dir creation loop**

Near the top of `playbooks/test_fleet_e2e.yml`, find the pre-flight
play's task `Create /tmp/iter-FLEET-<host>/{...}`. The loop currently
reads:

```yaml
      loop: [A-sd, B-nfs, C-reprovision, C2-localkernel, D-kupdate]
```

Change it to:

```yaml
      loop: [0-dd-sd, A-sd, B-nfs, C-reprovision, C2-localkernel, D-kupdate]
```

- [ ] **Step 4: Update the Summary play to include Phase 0 in the timing table**

In the final `Summary` play near the bottom of `playbooks/test_fleet_e2e.yml`,
find the timing-table Jinja block. The header row currently reads:

```
Board                            A      B      C      C2     D     Total
──────────────────────────────  ────   ────   ─────  ─────  ─────  ─────
```

Change it to:

```
Board                            0      A      B      C      C2     D     Total
──────────────────────────────  ────   ────   ────   ─────  ─────  ─────  ─────
```

Then update the namespace and per-row format to include `0`. The
current block:

```jinja
{%- set ns = namespace(A='-', B='-', C='-', C2='-', D='-', total=0) -%}
{%- for line in rows.split('\n') -%}
  {%- set f = line.split('\t') -%}
  {%- if f | length >= 4 and f[0] in ['A','B','C','C2','D'] -%}
    {%- if f[0] == 'A' %}{% set ns.A = f[3] %}{% endif -%}
    {%- if f[0] == 'B' %}{% set ns.B = f[3] %}{% endif -%}
    {%- if f[0] == 'C' %}{% set ns.C = f[3] %}{% endif -%}
    {%- if f[0] == 'C2' %}{% set ns.C2 = f[3] %}{% endif -%}
    {%- if f[0] == 'D' %}{% set ns.D = f[3] %}{% endif -%}
    {%- set ns.total = ns.total + (f[3] | int) -%}
  {%- endif -%}
{%- endfor %}
{{ '%-30s' | format(h) }}  {{ '%-5s' | format(ns.A) }}  {{ '%-5s' | format(ns.B) }}  {{ '%-5s' | format(ns.C) }}  {{ '%-5s' | format(ns.C2) }}  {{ '%-5s' | format(ns.D) }}  {{ ns.total }}
```

Change to:

```jinja
{%- set ns = namespace(P0='-', A='-', B='-', C='-', C2='-', D='-', total=0) -%}
{%- for line in rows.split('\n') -%}
  {%- set f = line.split('\t') -%}
  {%- if f | length >= 4 and f[0] in ['0','A','B','C','C2','D'] -%}
    {%- if f[0] == '0' %}{% set ns.P0 = f[3] %}{% endif -%}
    {%- if f[0] == 'A' %}{% set ns.A = f[3] %}{% endif -%}
    {%- if f[0] == 'B' %}{% set ns.B = f[3] %}{% endif -%}
    {%- if f[0] == 'C' %}{% set ns.C = f[3] %}{% endif -%}
    {%- if f[0] == 'C2' %}{% set ns.C2 = f[3] %}{% endif -%}
    {%- if f[0] == 'D' %}{% set ns.D = f[3] %}{% endif -%}
    {%- set ns.total = ns.total + (f[3] | int) -%}
  {%- endif -%}
{%- endfor %}
{{ '%-30s' | format(h) }}  {{ '%-5s' | format(ns.P0) }}  {{ '%-5s' | format(ns.A) }}  {{ '%-5s' | format(ns.B) }}  {{ '%-5s' | format(ns.C) }}  {{ '%-5s' | format(ns.C2) }}  {{ '%-5s' | format(ns.D) }}  {{ ns.total }}
```

- [ ] **Step 5: Update the playbook's header comment to document Phase 0**

Near the top of `playbooks/test_fleet_e2e.yml` find the docstring that
lists phases. Change:

```
#   Phase A — set boot_mode=sd, cycle, auto-bootstrap inventory user if
#             needed, gather facts, assert rootfs is a local block device
```

to:

```
#   Phase 0 — converge to NFS, then dd canonical SD image to /dev/mmcblk0
#             (cross-iteration state reset). Skip with -e skip_dd_sd=true.
#   Phase A — set boot_mode=sd, cycle, auto-bootstrap inventory user if
#             needed, gather facts, assert rootfs is a local block device
```

And in the `Per-board artefacts:` line:

```
# Per-board artefacts: /tmp/iter-FLEET-<host>/{A-sd,B-nfs,C-reprovision,
# C2-localkernel,D-kupdate}/. Final play emits a summary table.
```

Change to:

```
# Per-board artefacts: /tmp/iter-FLEET-<host>/{0-dd-sd,A-sd,B-nfs,
# C-reprovision,C2-localkernel,D-kupdate}/. Final play emits a summary
# table.
```

- [ ] **Step 6: Run lint on the modified playbook**

Run: `make lint`
Expected: PASS.

- [ ] **Step 7: Syntax-check the playbook**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add playbooks/test_fleet_e2e.yml inventory/group_vars/all.yml
git commit -m "test_fleet_e2e: Phase 0 — dd canonical image to SD for state reset"
```

---

## Task 8: Documentation updates

Update CLAUDE.md's role table and the operator runbook to reflect the
new role and Phase 0.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/end-to-end-fleet-test.html`

- [ ] **Step 1: Update CLAUDE.md role table**

In `CLAUDE.md`, find the "Mental model: roles + workflow playbooks"
section's table. Insert a new row for `disk_image` after `image_extract`:

```
| `disk_image` | a board (or any host owning the target) | One block device imaged via streaming `xz | dd`; mount-aware refusal |
```

Then in the "Collection structure" tree, find the `roles/` block and add
`disk_image` to the list:

```
│   ├── image_build/               # Build custom .img.xz on armbian_builders host
│   ├── image_extract/             # Extract one .img.xz → template rootfs + TFTP files
│   ├── disk_image/                # Stream an .img.xz/.img to a block device (dd-style)
│   ├── rootfs_clone/              # Reflink-clone a template into a per-host rootfs
```

Also add the role to the "Key files" list:

```
- `roles/disk_image/tasks/main.yml` — orchestrate validate → write → settle
- `roles/disk_image/tasks/_validate.yml` — mount-aware guard + extension classify
- `roles/disk_image/tasks/_write.yml` — four-branch streaming write with pipefail
```

- [ ] **Step 2: Update operator runbook (`docs/end-to-end-fleet-test.html`)**

This file is HTML. Find the `<h3 id="improve-dd-preflight">Open: dd a
known image to SD as a pre-flight (full state reset)</h3>` section and
change the heading text:

- Change `Open:` → `Shipped:` in the `<h3>`.
- Update the surrounding `<p>` paragraphs from "we should consider" /
  "open question" framing to past tense, citing
  `playbooks/test_fleet_e2e.yml` Phase 0 and the `disk_image` role.

Also find the comparison table row:

```html
    <tr><td>dd canonical image to SD as Phase 0 (full state reset)</td>
        <td>Deterministic SD state per run; cost: ~30 s + bandwidth per board</td></tr>
```

Change the row's status cell (find the corresponding column) to mark
it as shipped.

- [ ] **Step 3: Lint the docs change (yamllint won't touch HTML; spot-check manually)**

Run: `make lint`
Expected: PASS (no Ansible/YAML changes; HTML unaffected by lint).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/end-to-end-fleet-test.html
git commit -m "docs: disk_image role + Phase 0 fleet-test dd preflight (shipped)"
```

---

## Task 9: Final verification

Sanity-check the whole thing end-to-end before declaring done.

**Files:** none modified.

- [ ] **Step 1: Run the full molecule scenario one more time**

Run: `make molecule SCENARIO=disk_image`
Expected: PASS. All Block A negative tests, Block B positive tests
(four branches), the 404 pipefail test, and the Block C partition-node
assertion pass.

- [ ] **Step 2: Run full lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Syntax-check every playbook (sanity sweep)**

Run: `for p in playbooks/*.yml; do ansible-playbook --syntax-check "$p" || echo "FAIL: $p"; done`
Expected: every playbook PASSes (no "FAIL:" lines).

- [ ] **Step 4: Confirm the role is reachable from the collection**

Run: `ansible-doc -t role david_igou.armbian.disk_image`
Expected: prints the `meta/argument_specs.yml` rendered as docs.

- [ ] **Step 5: No commit needed; report done**

Tell the operator: implementation complete. Hardware validation of
Phase 0 against the fleet is a follow-up (run
`ansible-playbook playbooks/test_fleet_e2e.yml -e target_hosts=<one-board>`,
observe the dd evidence file, confirm Phase A still passes against the
freshly imaged SD).
