# Per-role molecule scenarios via molecule_provisioners — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `extensions/molecule/`'s in-repo provisioner with the published `david_igou.molecule_provisioners` v1.1 collection (installed via git), migrate every existing scenario to molecule's ansible-native shape, and add three new qemu-backed scenarios (`bootstrap_armbian`, `image_extract`, `disk_provision`) that exercise their roles against the Armbian UEFI x86 Trixie cloud-minimal qcow2.

**Architecture:** Each scenario directory becomes `molecule.yml` (ansible-native, identical except `scenario.name`) + `create.yml`/`destroy.yml`/`prepare.yml` (one-line `import_playbook: david_igou.molecule_provisioners.<phase>`) + per-scenario `inventory/hosts.yml` (one host, with `mp.<backend>` blocks for each supported backend) + `inventory/group_vars/molecule.yml` (`mp_backend` selector + `mp_defaults`) + scenario-specific `converge.yml`/`verify.yml`. Backend choice per scenario: qemu for VM-needing roles, podman for template/render roles, kubevirt for `image_build`. Scenarios needing a second block device create a loop file inside the VM (preserves the single-virtio-disk constraint of molecule_provisioners v1.1).

**Tech Stack:** Ansible ≥2.15, `david_igou.molecule_provisioners` v1.1+ (installed via git from `https://github.com/david-igou/ansible-collection-molecule_provisioners.git`), Molecule (modern release with ansible-native support), `qemu-system-x86_64` + `qemu-img` + `cloud-localds` on the controller for qemu scenarios, `podman` for podman scenarios, kind+KubeVirt for `image_build`.

**Spec:** `docs/superpowers/specs/2026-05-22-qemu-molecule-scenarios-design.md`

---

## File map

**Delete:**
- `extensions/molecule/provisioners/` (whole directory — podman + kubevirt + group_vars + per-backend requirements.yml)
- `extensions/molecule/default/` (smoke scaffold; role coverage lost = none)
- `extensions/molecule/disk_provision_loopback/` (consolidated into new `disk_provision/`)
- `extensions/molecule/disk_provision_render/` (consolidated into new `disk_provision/`)

**Create (new scenarios):**
- `extensions/molecule/bootstrap_armbian/`
- `extensions/molecule/disk_provision/` (replaces both `_loopback` and `_render`)
- `extensions/molecule/image_extract/`

**Rewrite (in place — full file replacement on the ansible-native shape):**
- `extensions/molecule/disk_image/{molecule,create,destroy,prepare,converge,verify}.yml` + `inventory/`
- `extensions/molecule/image_build/{molecule,create,destroy,prepare,converge,verify}.yml` + `inventory/`
- `extensions/molecule/local_kernel_render/...`
- `extensions/molecule/persist_uboot_env/...`
- `extensions/molecule/pxelinux_render/...`
- `extensions/molecule/rootfs_clone/...`

**Modify:**
- `requirements.yml` (add molecule_provisioners via git)
- `.github/workflows/tests.yml` (matrix update)
- `extensions/molecule/README.md` (rewrite to reflect new layout)

**Conditionally modify (only if Phase 3 Task 3.4 path A fails):**
- `roles/qemu/` in `david_igou.molecule_provisioners` (add `extra_user_data` schema)

---

## Phase 0: Foundation

### Task 0.1: Add molecule_provisioners to requirements.yml

**Files:**
- Modify: `requirements.yml`

- [ ] **Step 1: Add the collection entry**

Edit `requirements.yml` to append the new collection. The full file becomes:

```yaml
---
collections:
  - name: community.routeros
    version: ">=2.0.0"
  - name: ansible.posix
    version: ">=1.5.0"
  - name: ansible.netcommon
    version: ">=5.0.0"
  - name: https://github.com/david-igou/ansible-collection-molecule_provisioners.git
    type: git
    version: main
```

- [ ] **Step 2: Install the collection locally to verify the entry resolves**

Run from the repo root:

```bash
ansible-galaxy collection install -r requirements.yml --force
```

Expected: `david_igou.molecule_provisioners` reports installed. List with:

```bash
ansible-galaxy collection list david_igou.molecule_provisioners
```

Expected: shows a `1.1.0`-or-later version + a path under `~/.ansible/collections/`.

- [ ] **Step 3: Commit**

```bash
git add requirements.yml
git commit -m "deps: add david_igou.molecule_provisioners via git"
```

---

### Task 0.2: Delete the smoke-only `default` scenario

The `default` scenario only runs a `debug` task and verifies nothing about any role. With per-role scenarios landing in Phases 1-3, it's pure clutter.

**Files:**
- Delete: `extensions/molecule/default/` (whole dir)

- [ ] **Step 1: Remove the directory**

```bash
rm -r extensions/molecule/default
```

- [ ] **Step 2: Remove `default` from the CI matrix**

Edit `.github/workflows/tests.yml`. The `molecule` job's `strategy.matrix.scenario` is currently:

```yaml
        scenario:
          - default
          - rootfs_clone
          - pxelinux_render
```

Change to:

```yaml
        scenario:
          - rootfs_clone
          - pxelinux_render
```

(Later phases re-expand this list.)

- [ ] **Step 3: Commit**

```bash
git add extensions/molecule/default .github/workflows/tests.yml
git commit -m "ci: drop the smoke-only default molecule scenario"
```

---

## Phase 1: Template podman scenario (`pxelinux_render`)

This scenario is the simplest existing podman case (pure template render, no second disk, no privileged container). Porting it first establishes the boilerplate every later scenario reuses. End state: `pxelinux_render` runs under `david_igou.molecule_provisioners.podman` instead of the in-repo `provisioners/podman/`.

### Task 1.1: Rewrite `pxelinux_render/molecule.yml` to the ansible-native shape

**Files:**
- Modify: `extensions/molecule/pxelinux_render/molecule.yml`

- [ ] **Step 1: Replace the file entirely**

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
  name: pxelinux_render
  test_sequence:
    - dependency
    - syntax
    - create
    - prepare
    - converge
    - verify
    - destroy

verifier:
  name: ansible
```

### Task 1.2: Write `create.yml`/`destroy.yml`/`prepare.yml` one-liners

**Files:**
- Create: `extensions/molecule/pxelinux_render/create.yml`
- Create: `extensions/molecule/pxelinux_render/destroy.yml`
- Modify: `extensions/molecule/pxelinux_render/prepare.yml` (currently absent — `pxelinux_render` has no prepare today)

- [ ] **Step 1: `create.yml`**

```yaml
---
- name: Create molecule instances
  import_playbook: david_igou.molecule_provisioners.create
```

- [ ] **Step 2: `destroy.yml`**

```yaml
---
- name: Destroy molecule instances
  import_playbook: david_igou.molecule_provisioners.destroy
```

- [ ] **Step 3: `prepare.yml`**

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare
```

### Task 1.3: Write the inventory

**Files:**
- Create: `extensions/molecule/pxelinux_render/inventory/hosts.yml`
- Create: `extensions/molecule/pxelinux_render/inventory/group_vars/molecule.yml`

- [ ] **Step 1: `inventory/hosts.yml`**

`pxelinux_render` only needs a target capable of running templates — podman is the right default; no qemu/kubevirt blocks needed.

```yaml
---
all:
  children:
    molecule:
      hosts:
        instance:
          mp:
            podman:
              image: docker.io/geerlingguy/docker-ubuntu2404-ansible:latest
```

- [ ] **Step 2: `inventory/group_vars/molecule.yml`**

```yaml
---
mp_backend: "{{ lookup('env', 'PROVISIONER') | default('podman', true) }}"

mp_defaults:
  podman:
    command: /sbin/init
    privileged: true
```

### Task 1.4: `converge.yml` and `verify.yml` — port verbatim from old scenario

**Files:**
- Modify: `extensions/molecule/pxelinux_render/converge.yml` (no changes — current file already invokes the role correctly)
- Modify: `extensions/molecule/pxelinux_render/verify.yml` (no changes)

- [ ] **Step 1: Confirm no changes are needed**

Run `git diff HEAD -- extensions/molecule/pxelinux_render/converge.yml extensions/molecule/pxelinux_render/verify.yml`. Expected: empty (these files were unaffected by the boilerplate rewrite).

### Task 1.5: Run the scenario end-to-end and confirm it passes

- [ ] **Step 1: Re-install collections (picks up the molecule_provisioners install)**

```bash
ansible-galaxy collection install -r requirements.yml --force
```

- [ ] **Step 2: Run molecule test**

```bash
cd extensions/molecule/pxelinux_render && molecule test
```

Expected: full lifecycle completes (`dependency` / `syntax` / `create` / `prepare` / `converge` / `verify` / `destroy`) without errors. The verify play asserts on the content of the rendered pxelinux.cfg files.

- [ ] **Step 3: Commit**

```bash
git add extensions/molecule/pxelinux_render
git commit -m "molecule(pxelinux_render): port to molecule_provisioners podman backend"
```

---

## Phase 2: Remaining podman migrations

Each scenario in this phase mirrors the Phase 1 boilerplate, with scenario-specific prepare/converge/verify content carried over from the existing files.

### Task 2.1: Migrate `rootfs_clone` to molecule_provisioners.podman

**Files:**
- Modify: `extensions/molecule/rootfs_clone/molecule.yml`
- Create: `extensions/molecule/rootfs_clone/create.yml`
- Create: `extensions/molecule/rootfs_clone/destroy.yml`
- Modify: `extensions/molecule/rootfs_clone/prepare.yml` (existing prepare has the synthetic-template build — keep the body, prepend the provisioner import as a separate play)
- Create: `extensions/molecule/rootfs_clone/inventory/hosts.yml`
- Create: `extensions/molecule/rootfs_clone/inventory/group_vars/molecule.yml`

- [ ] **Step 1: `molecule.yml` (same shape as pxelinux_render with name=rootfs_clone)**

Use the Phase 1 Task 1.1 template, change `scenario.name` to `rootfs_clone`.

- [ ] **Step 2: `create.yml` / `destroy.yml`**

Same one-liners as Phase 1 Task 1.2.

- [ ] **Step 3: `prepare.yml` — two plays (provisioner first, fixture build second)**

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

- name: Prepare — build a synthetic rootfs template in the container
  hosts: all
  gather_facts: false
  become: true

  tasks:
    - name: Ensure sudo and openssh-client are installed
      ansible.builtin.apt:
        name:
          - sudo
          - openssh-client
        state: present
        update_cache: true

    - name: Create synthetic template directory tree
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0755"
      loop:
        - /tmp/fixture/template/bin
        - /tmp/fixture/template/etc
        - /tmp/fixture/template/etc/ssh
        - /tmp/fixture/template/root
        - /tmp/fixture/template/var/lib/dbus

    - name: Drop a placeholder /bin/bash (rootfs_clone uses this as the "template populated" sentinel)
      ansible.builtin.copy:
        dest: /tmp/fixture/template/bin/bash
        content: "#!/bin/sh\nexit 0\n"
        mode: "0755"

    - name: Pre-populate the identity files that rootfs_clone resets
      ansible.builtin.copy:
        dest: "{{ item.path }}"
        content: "{{ item.content }}"
        mode: "0644"
      loop:
        - { path: /tmp/fixture/template/etc/hostname, content: "fixture-original\n" }
        - { path: /tmp/fixture/template/etc/hosts, content: "127.0.0.1\tlocalhost\n127.0.1.1\tfixture-original\n" }
        - { path: /tmp/fixture/template/etc/machine-id, content: "0123456789abcdef0123456789abcdef\n" }
        - { path: /tmp/fixture/template/var/lib/dbus/machine-id, content: "0123456789abcdef0123456789abcdef\n" }
        - { path: /tmp/fixture/template/etc/ssh/ssh_host_rsa_key, content: "STALE-KEY-FIXTURE\n" }
        - { path: /tmp/fixture/template/etc/ssh/ssh_host_ed25519_key, content: "STALE-KEY-FIXTURE\n" }
```

- [ ] **Step 4: `inventory/hosts.yml`** (same as Phase 1 Task 1.3 Step 1)

- [ ] **Step 5: `inventory/group_vars/molecule.yml`** (same as Phase 1 Task 1.3 Step 2)

- [ ] **Step 6: Verify `converge.yml`/`verify.yml` are unchanged from current state**

```bash
git diff HEAD -- extensions/molecule/rootfs_clone/converge.yml extensions/molecule/rootfs_clone/verify.yml
```

Expected: empty.

- [ ] **Step 7: Run and commit**

```bash
cd extensions/molecule/rootfs_clone && molecule test
```

Expected: full lifecycle passes. Then:

```bash
git add extensions/molecule/rootfs_clone
git commit -m "molecule(rootfs_clone): port to molecule_provisioners podman backend"
```

### Task 2.2: Migrate `local_kernel_render` to molecule_provisioners.podman

**Files:**
- Modify: `extensions/molecule/local_kernel_render/molecule.yml`
- Create: `extensions/molecule/local_kernel_render/create.yml`
- Create: `extensions/molecule/local_kernel_render/destroy.yml`
- Create: `extensions/molecule/local_kernel_render/prepare.yml` (currently doesn't exist — pure provisioner import)
- Create: `extensions/molecule/local_kernel_render/inventory/hosts.yml`
- Create: `extensions/molecule/local_kernel_render/inventory/group_vars/molecule.yml`

- [ ] **Step 1: `molecule.yml`** (same as Phase 1 Task 1.1, name=local_kernel_render)
- [ ] **Step 2: `create.yml` / `destroy.yml` / `prepare.yml`** (all one-liners — Phase 1 Task 1.2)
- [ ] **Step 3: `inventory/hosts.yml`** (Phase 1 Task 1.3 Step 1 verbatim)
- [ ] **Step 4: `inventory/group_vars/molecule.yml`** (Phase 1 Task 1.3 Step 2 verbatim)

- [ ] **Step 5: Verify `converge.yml`/`verify.yml`/`templates/` symlink are unchanged**

The existing scenario carries a symlink:

```
extensions/molecule/local_kernel_render/templates/render_localcmd_chain.j2 ->
  ../../../../roles/image_build/templates/render_localcmd_chain.j2
```

Confirm it still resolves: `ls -l extensions/molecule/local_kernel_render/templates/`. Expected: arrow points at the role's template.

- [ ] **Step 6: Run and commit**

```bash
cd extensions/molecule/local_kernel_render && molecule test
```

Expected: full lifecycle passes.

```bash
git add extensions/molecule/local_kernel_render
git commit -m "molecule(local_kernel_render): port to molecule_provisioners podman backend"
```

### Task 2.3: Migrate `persist_uboot_env` to molecule_provisioners.podman

**Files:** identical pattern to Task 2.2.

- [ ] **Step 1: `molecule.yml`** (Phase 1 Task 1.1, name=persist_uboot_env)
- [ ] **Step 2: `create.yml` / `destroy.yml` / `prepare.yml`** (Phase 1 Task 1.2 one-liners)
- [ ] **Step 3: `inventory/hosts.yml`** (Phase 1 Task 1.3 Step 1)
- [ ] **Step 4: `inventory/group_vars/molecule.yml`** (Phase 1 Task 1.3 Step 2)
- [ ] **Step 5: Verify `converge.yml`/`verify.yml` are unchanged**: `git diff HEAD -- extensions/molecule/persist_uboot_env/converge.yml extensions/molecule/persist_uboot_env/verify.yml`. Expected: empty.

- [ ] **Step 6: Run and commit**

```bash
cd extensions/molecule/persist_uboot_env && molecule test
```

```bash
git add extensions/molecule/persist_uboot_env
git commit -m "molecule(persist_uboot_env): port to molecule_provisioners podman backend"
```

---

## Phase 3: qemu scenarios

Each scenario in this phase runs on the Armbian UEFI x86 Trixie cloud-minimal qcow2 (`https://dl.armbian.com/uefi-x86/Trixie_cloud_minimal-qcow2`). The image is downloaded once on first run and cached under `${XDG_CACHE_HOME:-$HOME/.cache}/molecule-qemu/<sha256>/disk.qcow2`.

**Controller prerequisites** for these scenarios (already present in `/workspace/igou-devenv`):
- `qemu-system-x86_64`
- `qemu-img`
- `cloud-localds` (or `genisoimage`)
- `/dev/kvm` — optional; falls back to TCG (slower but fine)

### Task 3.1: Migrate `disk_image` from podman to qemu

**Files:**
- Modify: `extensions/molecule/disk_image/molecule.yml`
- Create: `extensions/molecule/disk_image/create.yml`
- Create: `extensions/molecule/disk_image/destroy.yml`
- Modify: `extensions/molecule/disk_image/prepare.yml`
- Create: `extensions/molecule/disk_image/inventory/hosts.yml`
- Create: `extensions/molecule/disk_image/inventory/group_vars/molecule.yml`

- [ ] **Step 1: `molecule.yml`** (Phase 1 Task 1.1 template, name=disk_image)

- [ ] **Step 2: `create.yml` / `destroy.yml`** (Phase 1 Task 1.2 one-liners)

- [ ] **Step 3: `inventory/hosts.yml`**

```yaml
---
all:
  children:
    molecule:
      hosts:
        instance:
          mp:
            qemu:
              image: https://dl.armbian.com/uefi-x86/Trixie_cloud_minimal-qcow2
              disk_size: 4G
```

The `disk_size: 4G` triggers `qemu-img resize` on the overlay so there's room for the 1 GiB loop file + the xz-compressed fixture.

- [ ] **Step 4: `inventory/group_vars/molecule.yml`**

```yaml
---
mp_backend: "{{ lookup('env', 'PROVISIONER') | default('qemu', true) }}"

mp_defaults:
  qemu:
    cpus: 2
    memory: 2048
    ssh_user: cloud-user
```

- [ ] **Step 5: `prepare.yml`** — two plays (provisioner import + in-VM fixture build)

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

- name: Build the loop-device fixture inside the VM
  hosts: all
  gather_facts: true
  become: true

  tasks:
    - name: Ensure xz-utils, util-linux, parted are installed
      ansible.builtin.apt:
        name: [xz-utils, util-linux, parted]
        state: present
        update_cache: true

    - name: Write a 64 MiB random fixture image
      ansible.builtin.command: "dd if=/dev/urandom of=/tmp/test.img bs=1M count=64"
      changed_when: true

    - name: Compress the fixture to test.img.xz
      ansible.builtin.command: "xz -9 -f /tmp/test.img"
      changed_when: true

    - name: Create the 1 GiB sparse target
      ansible.builtin.command: "truncate -s 1G /tmp/target.img"
      changed_when: true

    - name: Attach the sparse file as a loop device
      ansible.builtin.command: "losetup -f --show /tmp/target.img"
      register: _loop
      changed_when: true

    - name: Persist the loop device path
      ansible.builtin.copy:
        dest: /tmp/target_loop
        content: "{{ _loop.stdout }}\n"
        mode: "0644"
```

Note: `xz -9 /tmp/test.img` *removes* `/tmp/test.img` and creates `/tmp/test.img.xz`. The role accepts that; verify decompresses back.

- [ ] **Step 6: `converge.yml`** — no functional change from the current scenario; reproduced here for completeness because the current scenario assumes podman semantics that are identical to qemu semantics (an absolute path to a loop device).

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

    - name: "Converge: invoke full role on a clean (unmounted) target"
      ansible.builtin.include_role:
        name: disk_image
      vars:
        image_source: "/tmp/test.img.xz"
        target_device: "{{ _target_loop }}"
```

- [ ] **Step 7: `verify.yml`** — replace the body with the spec's verify plan: cmp the loop device against the original fixture (which xz removed, so we decompress to a temp), plus the four negative-case asserts.

```yaml
---
- hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: "Read target loop device path"
      ansible.builtin.slurp:
        src: /tmp/target_loop
      register: _target_b64

    - name: "Set target loop fact"
      ansible.builtin.set_fact:
        _target_loop: "{{ (_target_b64.content | b64decode).strip() }}"

    - name: "Decompress the source fixture to /tmp/source.img for cmp"
      ansible.builtin.command:
        cmd: "xz -dkc /tmp/test.img.xz"
      register: _source_decompressed
      changed_when: false

    - name: "Write the decompressed source to /tmp/source.img"
      ansible.builtin.copy:
        dest: /tmp/source.img
        content: "{{ _source_decompressed.stdout }}"
        mode: "0644"

    - name: "cmp the first 64 MiB of the loop device against the source"
      ansible.builtin.command:
        cmd: "cmp -n 67108864 /tmp/source.img {{ _target_loop }}"
      changed_when: false

    # --- Negative tests (mirror current scenario) ---
    - name: "Block A — reject: target is a partition node"
      block:
        - name: "Create a child partition to use as a bad target"
          ansible.builtin.shell: |
            set -euo pipefail
            parted -s {{ _target_loop }} mklabel msdos
            parted -s {{ _target_loop }} mkpart primary ext4 1MiB 100%
            partprobe {{ _target_loop }}
            sleep 1
          args:
            executable: /bin/bash
          changed_when: true

        - name: "Call role with the partition as target_device — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/test.img.xz"
            target_device: "{{ _target_loop }}p1"
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
            image_source: "not-a-url-and-not-a-path"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed because image_source is invalid"
          ansible.builtin.assert:
            that:
              - ansible_failed_result.msg is defined
              - "'image_source' in ansible_failed_result.msg"
            fail_msg: >-
              Expected failure mentioning 'image_source'; got:
              {{ ansible_failed_result | default({}) }}

    - name: "Block A — reject: mismatched extension"
      block:
        - name: "Create a non-xz file that ends in .img.xz"
          ansible.builtin.copy:
            dest: /tmp/not_really_xz.img.xz
            content: "this is not xz\n"
            mode: "0644"

        - name: "Call role with the bad file — must fail"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "/tmp/not_really_xz.img.xz"
            target_device: "{{ _target_loop }}"
      rescue:
        - name: "Confirm role failed during xz stream (output capture)"
          ansible.builtin.assert:
            that:
              - ansible_failed_result is defined
            fail_msg: "Expected role failure on bad xz content."
```

- [ ] **Step 8: Run and commit**

```bash
cd extensions/molecule/disk_image && molecule test
```

Expected: full lifecycle passes. First run downloads the qcow2 (~184 MiB, one-time). Subsequent runs reuse the cache.

```bash
git add extensions/molecule/disk_image
git commit -m "molecule(disk_image): migrate from podman to qemu (Trixie x86 qcow2)"
```

### Task 3.2: Create `disk_provision` (consolidates `_loopback` + `_render`)

**Files:**
- Create: `extensions/molecule/disk_provision/molecule.yml`
- Create: `extensions/molecule/disk_provision/create.yml`
- Create: `extensions/molecule/disk_provision/destroy.yml`
- Create: `extensions/molecule/disk_provision/prepare.yml`
- Create: `extensions/molecule/disk_provision/converge.yml`
- Create: `extensions/molecule/disk_provision/verify.yml`
- Create: `extensions/molecule/disk_provision/inventory/hosts.yml`
- Create: `extensions/molecule/disk_provision/inventory/group_vars/molecule.yml`

- [ ] **Step 1: Standard boilerplate**

`molecule.yml` (Phase 1 Task 1.1, name=disk_provision), `create.yml` / `destroy.yml` (Phase 1 Task 1.2 one-liners), `inventory/hosts.yml` (Task 3.1 Step 3 with `disk_size: 4G`), `inventory/group_vars/molecule.yml` (Task 3.1 Step 4).

- [ ] **Step 2: `prepare.yml`** — provisioner + loop fixture (same shape as Task 3.1 Step 5, smaller fixture)

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

- name: Build the loop-device fixture inside the VM
  hosts: all
  gather_facts: true
  become: true

  tasks:
    - name: "Install systemd, util-linux, rsync, e2fsprogs, dosfstools"
      ansible.builtin.apt:
        name: [systemd, util-linux, rsync, e2fsprogs, dosfstools]
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

- [ ] **Step 3: `converge.yml`** — three include_role invocations (initial layout, preserve-rerun, render-only)

```yaml
---
- hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: "Read loop device path"
      ansible.builtin.slurp:
        src: /tmp/loop_device
      register: _loop_b64

    - name: "Set loop device fact"
      ansible.builtin.set_fact:
        _loop: "{{ (_loop_b64.content | b64decode).strip() }}"

    - name: "Pass 1: initial provision — full layout, no preserves yet"
      ansible.builtin.include_role:
        name: disk_provision
      vars:
        source: "/usr"
        disk_binding:
          device: "{{ _loop }}"
          wipe: true
          layout:
            - id: boot
              size: 256MiB
              type: linux
              format: ext4
              label: lp_boot
              mount: /boot
            - id: var
              size: 512MiB
              type: var
              format: ext4
              label: lp_var
              mount: /var
              preserve_on_reprovision: true
            - id: root
              size: grow
              type: root
              format: ext4
              label: lp_root
              mount: /

    - name: "Write a sentinel into /var on the loop disk"
      ansible.builtin.shell: |
        set -euo pipefail
        mount LABEL=lp_var /mnt
        echo SENTINEL > /mnt/preserve_test
        sync
        umount /mnt
      args:
        executable: /bin/bash
      changed_when: true

    - name: "Pass 2: re-provision — preserve_on_reprovision=true should keep /var sentinel intact"
      ansible.builtin.include_role:
        name: disk_provision
      vars:
        source: "/usr"
        disk_binding:
          device: "{{ _loop }}"
          wipe: true
          layout:
            - id: boot
              size: 256MiB
              type: linux
              format: ext4
              label: lp_boot
              mount: /boot
            - id: var
              size: 512MiB
              type: var
              format: ext4
              label: lp_var
              mount: /var
              preserve_on_reprovision: true
            - id: root
              size: grow
              type: root
              format: ext4
              label: lp_root
              mount: /

    - name: "Pass 3: render-only mode — write .repart.d files but don't apply"
      ansible.builtin.include_role:
        name: david_igou.armbian.disk_provision
      vars:
        render_only: true
        disk_binding:
          device: /dev/loop0
          wipe: true
          layout:
            - { id: esp,  size: 512MiB, type: esp,   format: vfat, label: armbi_esp,        mount: /boot/efi }
            - { id: boot, size: 1GiB,   type: linux, format: ext4, label: armbi_boot,       mount: /boot }
            - { id: var,  size: 20GiB,  type: var,   format: ext4, label: armbi_var,        mount: /var, preserve_on_reprovision: true }
            - { id: root, size: grow,   type: root,  format: ext4, label: armbi_root_local, mount: / }
```

- [ ] **Step 4: `verify.yml`** — assertions for all three passes

```yaml
---
- hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: "Read loop device path"
      ansible.builtin.slurp:
        src: /tmp/loop_device
      register: _loop_b64

    - name: "Set loop device fact"
      ansible.builtin.set_fact:
        _loop: "{{ (_loop_b64.content | b64decode).strip() }}"

    # ----- Pass 1 + 2 assertions -----
    - name: "lsblk -no NAME,FSTYPE,LABEL on the loop device"
      ansible.builtin.command: "lsblk -no NAME,FSTYPE,LABEL {{ _loop }}"
      register: _lsblk
      changed_when: false

    - name: "Three labelled ext4 partitions exist"
      ansible.builtin.assert:
        that:
          - "'lp_boot' in _lsblk.stdout"
          - "'lp_var'  in _lsblk.stdout"
          - "'lp_root' in _lsblk.stdout"
          - _lsblk.stdout.count('ext4') == 3
        fail_msg: "Unexpected lsblk output:\n{{ _lsblk.stdout }}"

    - name: "Mount /var and verify the sentinel was preserved across the re-provision"
      ansible.builtin.shell: |
        set -euo pipefail
        mount LABEL=lp_var /mnt
        cat /mnt/preserve_test
        umount /mnt
      args:
        executable: /bin/bash
      register: _sentinel
      changed_when: false

    - name: "Sentinel content matches what Pass 1 wrote"
      ansible.builtin.assert:
        that: _sentinel.stdout.strip() == 'SENTINEL'
        fail_msg: "/var was reformatted across passes; preserve_on_reprovision is broken."

    # ----- Pass 3 (render-only) assertions -----
    - name: "Render-only dropped four .repart.d files for /dev/loop0"
      ansible.builtin.find:
        paths: "/run/disk_provision/loop0/repart.d"
        patterns: "*.conf"
      register: _confs

    - name: "Four ordered .conf files present"
      ansible.builtin.assert:
        that:
          - (_confs.files | map(attribute='path') | map('basename') | sort) ==
              ['10-esp.conf', '20-boot.conf', '30-var.conf', '40-root.conf']
        fail_msg: "Expected 10-esp / 20-boot / 30-var / 40-root, got: {{ _confs.files | map(attribute='path') | map('basename') | sort }}"

    - name: "Read 10-esp.conf for ESP-specific assertions"
      ansible.builtin.slurp:
        src: "/run/disk_provision/loop0/repart.d/10-esp.conf"
      register: _esp

    - name: "ESP config has Type=esp, Label=armbi_esp, Format=vfat, 512M size"
      ansible.builtin.assert:
        that:
          - (_esp.content | b64decode) is search('Type=esp')
          - (_esp.content | b64decode) is search('Label=armbi_esp')
          - (_esp.content | b64decode) is search('Format=vfat')
          - (_esp.content | b64decode) is search('SizeMinBytes=512M')
          - (_esp.content | b64decode) is search('SizeMaxBytes=512M')

    - name: "Read 40-root.conf for root-specific (grow) assertions"
      ansible.builtin.slurp:
        src: "/run/disk_provision/loop0/repart.d/40-root.conf"
      register: _root

    - name: "Root config has Type=root and no SizeMaxBytes (grow)"
      ansible.builtin.assert:
        that:
          - (_root.content | b64decode) is search('Type=root')
          - (_root.content | b64decode) is not search('SizeMaxBytes=')
```

- [ ] **Step 5: Run and commit**

```bash
cd extensions/molecule/disk_provision && molecule test
```

Expected: full lifecycle passes.

```bash
git add extensions/molecule/disk_provision
git commit -m "molecule(disk_provision): new qemu scenario consolidating loopback + render"
```

### Task 3.3: Create `image_extract` scenario (NEW)

**Files:**
- Create: `extensions/molecule/image_extract/molecule.yml`
- Create: `extensions/molecule/image_extract/create.yml`
- Create: `extensions/molecule/image_extract/destroy.yml`
- Create: `extensions/molecule/image_extract/prepare.yml`
- Create: `extensions/molecule/image_extract/converge.yml`
- Create: `extensions/molecule/image_extract/verify.yml`
- Create: `extensions/molecule/image_extract/inventory/hosts.yml`
- Create: `extensions/molecule/image_extract/inventory/group_vars/molecule.yml`

The role needs a real Armbian SBC `.img.xz` (the role parses `/boot/dtb/` and rsyncs an Armbian-shaped rootfs). The fixture: latest stable `Armbian_*_Orangepi5-pro_bookworm_current_*.img.xz` from `dl.armbian.com/orangepi-5-pro/archive/`. ~400 MiB. Downloaded on the controller and pushed into the VM with `ansible.posix.synchronize`.

- [ ] **Step 1: Standard boilerplate**

`molecule.yml` (Phase 1 Task 1.1, name=image_extract), `create.yml` / `destroy.yml` (Phase 1 Task 1.2 one-liners), `inventory/hosts.yml` (Task 3.1 Step 3 with `disk_size: 8G` — Armbian SBC image extracts to ~2.5 GiB rootfs, plus the .img.xz, plus headroom), `inventory/group_vars/molecule.yml` (Task 3.1 Step 4).

- [ ] **Step 2: `prepare.yml`** — provisioner + controller-side fetch + push to VM

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

- name: Cache the Armbian SBC fixture on the controller
  hosts: localhost
  connection: local
  gather_facts: false

  vars:
    _fixture_url: https://redirect.armbian.com/region/EU/orangepi-5-pro/archive/Armbian_25.5.1_Orangepi-5-pro_bookworm_current_6.12.27.img.xz
    _fixture_cache: "{{ lookup('env', 'XDG_CACHE_HOME') | default(lookup('env', 'HOME') ~ '/.cache', true) }}/armbian-netboot-molecule"

  tasks:
    - name: Ensure the fixture cache dir exists
      ansible.builtin.file:
        path: "{{ _fixture_cache }}"
        state: directory
        mode: "0755"

    - name: Download the Armbian SBC fixture (idempotent)
      ansible.builtin.get_url:
        url: "{{ _fixture_url }}"
        dest: "{{ _fixture_cache }}/orange-pi-5-pro.img.xz"
        mode: "0644"
      register: _fixture

    - name: Expose the fixture path for the next play
      ansible.builtin.add_host:
        name: localhost
        ansible_facts:
          _armbian_fixture_path: "{{ _fixture_cache }}/orange-pi-5-pro.img.xz"

- name: Push the fixture into the VM
  hosts: all
  gather_facts: true
  become: true

  tasks:
    - name: Ensure rsync is installed in the VM (synchronize requires it)
      ansible.builtin.apt:
        name: rsync
        state: present
        update_cache: true

    - name: Synchronize the .img.xz into the VM
      ansible.posix.synchronize:
        src: "{{ hostvars['localhost']._armbian_fixture_path }}"
        dest: /tmp/orange-pi-5-pro.img.xz
```

If `redirect.armbian.com` URL surfaces a stale or moved file at run time, replace `_fixture_url` with a current direct `dl.armbian.com/orangepi-5-pro/archive/...` URL. The role only cares that the input is a valid Armbian `.img.xz`.

- [ ] **Step 3: `converge.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: "Extract the Armbian fixture into template + tftp dirs"
      ansible.builtin.include_role:
        name: david_igou.armbian.image_extract
      vars:
        armbian_image_src: /tmp/orange-pi-5-pro.img.xz
        model_name: orange-pi-5-pro
        template_dir: /tmp/template
        tftp_dir: /tmp/tftp
        image_cache_dir: /tmp/image_cache
        image_mount_dir: /tmp/image_mount
        board_dtb: rk3588s-orangepi-5-pro.dtb
```

- [ ] **Step 4: `verify.yml`**

```yaml
---
- hosts: all
  gather_facts: true
  become: true
  tasks:
    - name: "Template /bin/bash exists (rootfs rsync ran)"
      ansible.builtin.stat:
        path: /tmp/template/bin/bash
      register: _template_bash

    - name: "Assert /bin/bash in extracted template"
      ansible.builtin.assert:
        that: _template_bash.stat.exists
        fail_msg: "image_extract finished but template_dir is empty"

    - name: "Sentinel marker written at end of successful run"
      ansible.builtin.stat:
        path: /tmp/template/.armbian_extract_complete
      register: _sentinel

    - name: "Assert sentinel exists"
      ansible.builtin.assert:
        that: _sentinel.stat.exists
        fail_msg: "image_extract sentinel missing — extraction likely failed mid-run"

    - name: "Stat the three TFTP artifacts"
      ansible.builtin.stat:
        path: "{{ item }}"
      register: _tftp_stats
      loop:
        - /tmp/tftp/vmlinuz
        - /tmp/tftp/initrd.img
        - /tmp/tftp/board.dtb

    - name: "All three TFTP artifacts present"
      ansible.builtin.assert:
        that: item.stat.exists
        fail_msg: "{{ item.item }} missing from tftp_dir"
      loop: "{{ _tftp_stats.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: "Re-run image_extract — sentinel must short-circuit (idempotent)"
      ansible.builtin.include_role:
        name: david_igou.armbian.image_extract
      vars:
        armbian_image_src: /tmp/orange-pi-5-pro.img.xz
        model_name: orange-pi-5-pro
        template_dir: /tmp/template
        tftp_dir: /tmp/tftp
        image_cache_dir: /tmp/image_cache
        image_mount_dir: /tmp/image_mount
        board_dtb: rk3588s-orangepi-5-pro.dtb
      register: _second_run

    - name: "Second run shows no changes (sentinel short-circuit)"
      ansible.builtin.assert:
        that: _second_run is not changed
        fail_msg: "image_extract is not idempotent; second run reported changes."
```

- [ ] **Step 5: Run and commit**

```bash
cd extensions/molecule/image_extract && molecule test
```

Expected: full lifecycle passes. First run is slow (~400 MiB fixture download + synchronize into VM). Subsequent runs cache both the qcow2 and the Armbian fixture.

```bash
git add extensions/molecule/image_extract
git commit -m "molecule(image_extract): new qemu scenario covering losetup + extract"
```

### Task 3.4: Create `bootstrap_armbian` scenario (NEW)

This scenario needs to test the role's contract: connect as `root` over SSH with the Armbian default password (`1234`), provision an unprivileged user, drop a sudoers file, disable `PasswordAuthentication`, etc.

The Trixie cloud-minimal image's stock cloud-init creates the `cloud-user` user and locks root. The scenario ships a custom `user-data.j2` that overrides this: sets `root` password to `1234`, enables `PermitRootLogin` and `PasswordAuthentication`, and *additionally* creates `cloud-user` (so molecule_provisioners' SSH handshake succeeds; we ignore that user during converge and target root directly).

**Files:**
- Create: `extensions/molecule/bootstrap_armbian/molecule.yml`
- Create: `extensions/molecule/bootstrap_armbian/create.yml`
- Create: `extensions/molecule/bootstrap_armbian/destroy.yml`
- Create: `extensions/molecule/bootstrap_armbian/prepare.yml`
- Create: `extensions/molecule/bootstrap_armbian/converge.yml`
- Create: `extensions/molecule/bootstrap_armbian/verify.yml`
- Create: `extensions/molecule/bootstrap_armbian/inventory/hosts.yml`
- Create: `extensions/molecule/bootstrap_armbian/inventory/group_vars/molecule.yml`
- Create: `extensions/molecule/bootstrap_armbian/templates/user-data.j2`
- Create: `extensions/molecule/bootstrap_armbian/templates/meta-data.j2`

- [ ] **Step 1: Standard boilerplate**

`molecule.yml` (Phase 1 Task 1.1, name=bootstrap_armbian), `create.yml` / `destroy.yml` (Phase 1 Task 1.2 one-liners), `inventory/hosts.yml` (Task 3.1 Step 3 — no disk_size override needed; default 2 GiB suffices).

- [ ] **Step 2: `inventory/group_vars/molecule.yml` — override the qemu role's template dir**

```yaml
---
mp_backend: "{{ lookup('env', 'PROVISIONER') | default('qemu', true) }}"

mp_defaults:
  qemu:
    cpus: 2
    memory: 2048
    ssh_user: cloud-user

# Point _seed_iso.yml's template-dir lookup at this scenario's templates/
# so user-data.j2 / meta-data.j2 here win over the stock ones in
# david_igou.molecule_provisioners.qemu.
mp_qemu_template_dir_override: "{{ inventory_dir }}/../templates"
```

`inventory_dir` resolves to the scenario's `inventory/` at runtime; `../templates` lands at `extensions/molecule/bootstrap_armbian/templates/`.

- [ ] **Step 3: `templates/meta-data.j2`** — match the stock template

The stock template is in `roles/qemu/templates/meta-data.j2` of molecule_provisioners. Re-read it before writing this file to verify it's still just `instance-id` + `local-hostname`. As of v1.1:

```
instance-id: iid-{{ _seed_iso_host }}
local-hostname: {{ _seed_iso_host }}
```

Copy that content verbatim.

- [ ] **Step 4: `templates/user-data.j2`** — Armbian-flash simulator

```
#cloud-config
users:
  - name: "{{ _mp_specs[_host].ssh_user }}"
    ssh_authorized_keys:
      - "{{ temporary_ssh_public_key }}"
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
chpasswd:
  expire: false
  list: |
    root:1234
ssh_pwauth: true
runcmd:
  - sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - touch /root/.not_logged_in_yet
```

The `users:` block keeps `cloud-user` SSH-keyed so molecule_provisioners' prepare-phase `wait_for_connection` succeeds. The `chpasswd`/`ssh_pwauth`/`runcmd` block restores the "fresh Armbian" state the role expects.

- [ ] **Step 5: `prepare.yml`** — provisioner + write override inventory

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

- name: Write root-as-ssh-user override inventory for converge
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Read the molecule_provisioners runtime inventory to get the SSH port
      ansible.builtin.slurp:
        src: "{{ lookup('env', 'MOLECULE_EPHEMERAL_DIRECTORY') }}/inventory/molecule_runtime.yml"
      register: _runtime_raw

    - name: Parse runtime inventory
      ansible.builtin.set_fact:
        _runtime: "{{ _runtime_raw.content | b64decode | from_yaml }}"

    - name: Extract instance's ansible_port (slirp host-forward port)
      ansible.builtin.set_fact:
        _instance_port: "{{ _runtime.all.hosts.instance.ansible_port }}"

    - name: Write bootstrap_inventory.yml that targets root with the default Armbian password
      ansible.builtin.copy:
        dest: "{{ lookup('env', 'MOLECULE_EPHEMERAL_DIRECTORY') }}/inventory/bootstrap_inventory.yml"
        mode: "0600"
        content: |
          all:
            hosts:
              instance:
                ansible_host: 127.0.0.1
                ansible_port: {{ _instance_port }}
                ansible_user: root
                ansible_password: '1234'
                ansible_connection: ssh
                ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no'
                ansible_python_interpreter: /usr/bin/python3
```

Molecule's `--inventory=${MOLECULE_EPHEMERAL_DIRECTORY}/inventory/` glob picks this file up next to `molecule_runtime.yml`. Last inventory wins on conflicts; this override replaces the runtime entry for `instance`.

- [ ] **Step 6: `converge.yml`**

```yaml
---
- name: Bootstrap a fresh Armbian board
  hosts: all
  gather_facts: true
  become: false   # already root via ansible_user=root

  vars:
    armbian_bootstrap_user: ansibletest
    armbian_bootstrap_ssh_keys:
      # Inline fixture pubkey — a known-bad ed25519 we use only inside this scenario.
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJZ7Y8s1m4Yk5zG8oR7q7Yy3l9rN6F4xZ8t1jW2pV5x9 fixture@bootstrap_armbian"

  tasks:
    - name: Invoke bootstrap_armbian role
      ansible.builtin.include_role:
        name: david_igou.armbian.bootstrap_armbian
```

- [ ] **Step 7: `verify.yml`** — assert role outputs

```yaml
---
- name: Verify the role made the expected changes
  hosts: all
  gather_facts: false
  become: false   # still root from converge

  tasks:
    - name: User ansibletest exists
      ansible.builtin.command: id -un ansibletest
      register: _id
      changed_when: false

    - name: Sudoers drop-in exists with NOPASSWD line
      ansible.builtin.slurp:
        src: /etc/sudoers.d/ansibletest
      register: _sudoers

    - name: Assert sudoers content
      ansible.builtin.assert:
        that:
          - "(_sudoers.content | b64decode) is search('^ansibletest ALL=\\(ALL\\) NOPASSWD: ALL')"
        fail_msg: "sudoers drop-in content unexpected:\n{{ _sudoers.content | b64decode }}"

    - name: Read /etc/ssh/sshd_config
      ansible.builtin.slurp:
        src: /etc/ssh/sshd_config
      register: _sshd

    - name: Assert PasswordAuthentication is no
      ansible.builtin.assert:
        that:
          - "(_sshd.content | b64decode) is search('(?m)^PasswordAuthentication no')"
        fail_msg: "sshd_config does not have PasswordAuthentication no"

    - name: First-login sentinel removed
      ansible.builtin.stat:
        path: /root/.not_logged_in_yet
      register: _sentinel

    - name: Assert sentinel gone
      ansible.builtin.assert:
        that: not _sentinel.stat.exists
        fail_msg: "/root/.not_logged_in_yet still exists — role did not remove the Armbian first-login marker."

    - name: Read /home/ansibletest/.ssh/authorized_keys
      ansible.builtin.slurp:
        src: /home/ansibletest/.ssh/authorized_keys
      register: _auth_keys

    - name: Assert fixture pubkey present
      ansible.builtin.assert:
        that:
          - "(_auth_keys.content | b64decode) is search('fixture@bootstrap_armbian')"
        fail_msg: "Fixture pubkey not authorised for ansibletest."
```

- [ ] **Step 8: Run end-to-end**

```bash
cd extensions/molecule/bootstrap_armbian && molecule test
```

Expected: full lifecycle passes.

- [ ] **Step 9: If `mp_qemu_template_dir_override` resolution fails, switch to molecule_provisioners enhancement**

If Step 8 fails with `_seed_iso.yml` loading the stock `user-data.j2` instead of the scenario's override, the `inventory_dir`-based path didn't resolve. Workaround: hardcode the absolute path. Confirmed-broken path: add `extra_user_data` schema field to `roles/qemu/`:

1. In `/workspace/ansible-collection-molecule_provisioners`, edit `roles/qemu/templates/user-data.j2` to append:

   ```jinja
   {% if _mp_specs[_host].extra_user_data is defined %}
   {{ _mp_specs[_host].extra_user_data }}
   {% endif %}
   ```

2. Document `mp.qemu.extra_user_data` in `README.md` schema section.
3. Bump `galaxy.yml` version to 1.2.0; add changelog fragment.
4. Commit + push to molecule_provisioners.
5. Update this scenario's `inventory/hosts.yml` to use `mp.qemu.extra_user_data` instead of `mp_qemu_template_dir_override`.
6. Bump `requirements.yml`'s `version: main` is unchanged (we pull HEAD).

- [ ] **Step 10: Commit**

```bash
git add extensions/molecule/bootstrap_armbian
git commit -m "molecule(bootstrap_armbian): new qemu scenario with custom user-data"
```

---

## Phase 4: kubevirt port + finalize

### Task 4.1: Migrate `image_build` to molecule_provisioners.kubevirt

**Files:**
- Modify: `extensions/molecule/image_build/molecule.yml`
- Create: `extensions/molecule/image_build/create.yml`
- Create: `extensions/molecule/image_build/destroy.yml`
- Modify: `extensions/molecule/image_build/prepare.yml`
- Create: `extensions/molecule/image_build/inventory/hosts.yml`
- Create: `extensions/molecule/image_build/inventory/group_vars/molecule.yml`

- [ ] **Step 1: `molecule.yml`** (Phase 1 Task 1.1 template, name=image_build)

- [ ] **Step 2: `create.yml` / `destroy.yml`** (Phase 1 Task 1.2 one-liners)

- [ ] **Step 3: `inventory/hosts.yml`** (kubevirt block instead of podman/qemu)

```yaml
---
all:
  children:
    molecule:
      hosts:
        armbian-builder:
          mp:
            kubevirt:
              image: quay.io/containerdisks/centos-stream:10
              namespace: molecule
              ssh_user: cloud-user
              memory: 16Gi
              ssh_service:
                type: NodePort
```

Note: molecule_provisioners v1.1's kubevirt role schema is documented in its `roles/kubevirt/meta/argument_specs.yml` and `docs/examples/inventory/hosts.yml`. If `scratch_disk_size` + `scratch_mount` (used by the legacy in-repo scenario for the `/var/lib/armbian_build` working dir) aren't supported by molecule_provisioners v1.1, that's a v1.2 enhancement — for now the build runs against the container's ephemeral root.

- [ ] **Step 4: `inventory/group_vars/molecule.yml`**

```yaml
---
mp_backend: "{{ lookup('env', 'PROVISIONER') | default('kubevirt', true) }}"

mp_defaults:
  kubevirt:
    namespace: molecule
    memory: 16Gi
    ssh_user: cloud-user
```

- [ ] **Step 5: `prepare.yml`** — keep existing prepare body, prepend the provisioner import

If the existing prepare already does Docker install / disk prep on the kubevirt VM, prepend the provisioner import as the first play and leave the rest unchanged:

```yaml
---
- name: Prepare molecule instances
  import_playbook: david_igou.molecule_provisioners.prepare

# Existing per-scenario prepare plays follow below — keep as-is.
```

(Read `extensions/molecule/image_build/prepare.yml` first to see the current content; only the import prepend is new.)

- [ ] **Step 6: Verify `converge.yml`/`verify.yml` are unchanged**

```bash
git diff HEAD -- extensions/molecule/image_build/converge.yml extensions/molecule/image_build/verify.yml
```

Expected: empty.

- [ ] **Step 7: Optional smoke (skip if no kubevirt cluster available)**

```bash
cd extensions/molecule/image_build && molecule test
```

This is the heavy scenario. Run only if `$KUBECONFIG` points at a KubeVirt-enabled cluster with the `molecule` namespace.

- [ ] **Step 8: Commit (even without smoke if no cluster)**

```bash
git add extensions/molecule/image_build
git commit -m "molecule(image_build): port to molecule_provisioners kubevirt backend"
```

### Task 4.2: Delete old infrastructure

**Files:**
- Delete: `extensions/molecule/provisioners/` (whole dir)
- Delete: `extensions/molecule/disk_provision_loopback/` (replaced by `disk_provision/`)
- Delete: `extensions/molecule/disk_provision_render/` (replaced by `disk_provision/`)

- [ ] **Step 1: Remove the directories**

```bash
rm -r extensions/molecule/provisioners
rm -r extensions/molecule/disk_provision_loopback
rm -r extensions/molecule/disk_provision_render
```

- [ ] **Step 2: Confirm no scenarios still reference the deleted paths**

```bash
grep -r 'provisioners/' extensions/molecule || echo "OK — no references"
grep -r 'disk_provision_loopback\|disk_provision_render' extensions/molecule .github || echo "OK — no references"
```

Expected: both `OK — no references` outputs.

- [ ] **Step 3: Commit**

```bash
git add extensions/molecule
git commit -m "molecule: delete in-repo provisioners + consolidated disk_provision scenarios"
```

### Task 4.3: Rewrite `extensions/molecule/README.md`

**Files:**
- Modify: `extensions/molecule/README.md`

- [ ] **Step 1: Replace the file entirely**

```markdown
# Molecule scenarios

Each scenario lives in its own subdirectory and is invoked via
`cd extensions/molecule/<scenario> && molecule test`. Backends are
provided by [`david_igou.molecule_provisioners`](https://github.com/david-igou/ansible-collection-molecule_provisioners)
(installed via `requirements.yml`).

| Scenario | Role exercised | Default backend |
|---|---|---|
| `bootstrap_armbian` | `bootstrap_armbian` | qemu |
| `disk_image` | `disk_image` | qemu |
| `disk_provision` | `disk_provision` | qemu |
| `image_extract` | `image_extract` | qemu |
| `rootfs_clone` | `rootfs_clone` | podman |
| `pxelinux_render` | `pxelinux_render` | podman |
| `local_kernel_render` | `image_build` (template macro) | podman |
| `persist_uboot_env` | `compose_uboot_env_vars.yml` workflow task | podman |
| `image_build` | `image_build` | kubevirt |

Switch backend (only meaningful when the scenario's inventory ships
multiple `mp.<backend>` blocks):

```bash
PROVISIONER=podman molecule test
```

## Backend prerequisites on the molecule controller

| Backend | Required tools |
|---|---|
| podman | `podman` |
| qemu | `qemu-system-x86_64`, `qemu-img`, `cloud-localds` (or `genisoimage`); `/dev/kvm` optional (falls back to TCG) |
| kubevirt | `kubectl` + a kubeconfig pointing at a KubeVirt-enabled cluster |

The devcontainer (`/workspace/igou-devenv`) ships all of the above.

## Not covered by molecule (by design)

- **`board_boot_wait`** — a thin wrapper around `wait_for` + `wait_for_connection`. Asserting that the wrapper works asserts that Ansible's own modules work. `playbooks/test_hardware_e2e.yml` exercises the real concern (board comes up after a cold boot).
- **`board_boot_verify`** — asserts `ansible_mounts['/']` matches the declared boot mode. Meaningful only against a real PXE-booted board; a stock cloud-image VM can't produce that state without standing up an NFS sidecar (and at that point we're testing the sidecar, not the role). `playbooks/test_hardware_e2e.yml` covers both NFS and local modes on real hardware.
```

- [ ] **Step 2: Commit**

```bash
git add extensions/molecule/README.md
git commit -m "docs: rewrite molecule README for new scenario layout"
```

### Task 4.4: Expand the CI molecule matrix

**Files:**
- Modify: `.github/workflows/tests.yml`

- [ ] **Step 1: Expand the `molecule` job's matrix**

Locate the `molecule:` job (currently lines 60-80 in the workflow). Update the matrix:

```yaml
  molecule-podman:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        scenario:
          - rootfs_clone
          - pxelinux_render
          - local_kernel_render
          - persist_uboot_env
    steps:
      - name: Check out repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Set up Python
        uses: actions/setup-python@a309ff8b426b58ec0e2a45f0f869d46889d02405 # v6
        with:
          python-version: "3.14"

      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install ansible-core molecule
          ansible-galaxy collection install -r requirements.yml --force

      - name: Run molecule ${{ matrix.scenario }}
        run: cd extensions/molecule/${{ matrix.scenario }} && molecule test

  molecule-qemu:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        scenario:
          - disk_image
          - disk_provision
          - image_extract
          - bootstrap_armbian
    steps:
      - name: Check out repository
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Set up Python
        uses: actions/setup-python@a309ff8b426b58ec0e2a45f0f869d46889d02405 # v6
        with:
          python-version: "3.14"

      - name: Install host qemu tools
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils

      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install ansible-core molecule
          ansible-galaxy collection install -r requirements.yml --force

      - name: Run molecule ${{ matrix.scenario }}
        run: cd extensions/molecule/${{ matrix.scenario }} && molecule test
```

Update `all_green.needs` to drop `molecule` and add `molecule-podman` + `molecule-qemu`. `image_build` is intentionally not in CI (manual / KubeVirt-only).

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/tests.yml
git commit -m "ci: expand molecule matrix for per-role scenarios"
```

---

## Self-review

### Spec coverage

| Spec section | Plan coverage |
|---|---|
| `bootstrap_armbian` scenario | Task 3.4 |
| `disk_image` scenario | Task 3.1 |
| `disk_provision` scenario | Task 3.2 |
| `image_extract` scenario | Task 3.3 |
| `rootfs_clone` scenario | Task 2.1 |
| `pxelinux_render` scenario | Task 1.1–1.5 |
| `image_build` scenario | Task 4.1 |
| `local_kernel_render` scenario | Task 2.2 |
| `persist_uboot_env` scenario | Task 2.3 |
| `board_boot_wait` / `board_boot_verify` skip rationale | Task 4.3 README |
| Shared infra (molecule.yml + create/destroy/prepare + inventory) | Phase 1 establishes template; Phases 2-3 apply |
| `requirements.yml` git install | Task 0.1 |
| Delete `provisioners/` | Task 4.2 |
| Rewrite README | Task 4.3 |
| CI matrix update | Task 0.2 (drops `default`) + Task 4.4 (expands) |
| Modifiable provisioner fallback (`extra_user_data`) | Task 3.4 Step 9 |

No spec section is uncovered.

### Placeholder scan

- No "TBD", "TODO", "implement later" in any task body.
- One conditional branch flagged with a complete fallback path (Task 3.4 Step 9), not a placeholder.
- One run-time URL hint in Task 3.3 ("if `redirect.armbian.com` URL surfaces a stale or moved file at run time, replace `_fixture_url`") — the URL is concrete; the note exists because the upstream redirect host *can* change. Acceptable.

### Type / name consistency

- `mp_backend`, `mp_defaults.<backend>`, `mp.<backend>.<field>` — schema verbatim from the molecule_provisioners README. Consistent across all scenarios.
- `_target_loop`, `_loop` — loop-device fact names match between `prepare.yml` (sets) and `converge.yml`/`verify.yml` (reads) per scenario.
- `armbian_bootstrap_user` / `armbian_bootstrap_ssh_keys` — `bootstrap_armbian` role's documented option names (matches `roles/bootstrap_armbian/meta/argument_specs.yml`).
- `armbian_image_src`, `model_name`, `template_dir`, `tftp_dir`, `board_dtb`, `image_cache_dir`, `image_mount_dir` — `image_extract` role's option names (matches `roles/image_extract/meta/argument_specs.yml`).
- `disk_binding`, `source`, `render_only` — `disk_provision` role's option names (matches `roles/disk_provision/meta/argument_specs.yml`).
- `image_source`, `target_device` — `disk_image` role's option names (matches `roles/disk_image/meta/argument_specs.yml`).
- Scenario names (`bootstrap_armbian`, `disk_image`, `disk_provision`, `image_extract`, `rootfs_clone`, `pxelinux_render`, `local_kernel_render`, `persist_uboot_env`, `image_build`) — consistent in directory paths, `scenario.name` fields, CI matrix entries, and README table.

All references consistent.
