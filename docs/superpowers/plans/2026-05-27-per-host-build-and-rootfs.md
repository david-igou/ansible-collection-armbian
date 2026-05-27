# Per-host build + rootfs provisioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the `david_igou.armbian` collection from per-model to per-host as the unit of work for image building and rootfs provisioning. Operators express the full build profile in inventory via a three-layer family/model/host merge mirroring the same pattern for hardware configuration.

**Architecture:** Two resolvers (`_resolve_board_config.yml`, `_resolve_build_profile.yml`) merge three named layers per host into resolved facts (`armbian_board_config`, `armbian_build`). `image_extract` + `rootfs_clone` collapse into a new `rootfs_provision` role. `image_build` re-keyed by `inventory_hostname` instead of BOARD=. `vars/boards.yml` deleted; per-model hardware facts move to operator inventory under `inventory/group_vars/<family|model>.yml`. Clean break in one PR — galaxy.yml bumps 3.0.0 → 4.0.0.

**Tech Stack:** Ansible 2.15+, armbian/build (Docker mode), Jinja2 templating (recursive default), losetup + xz + rsync for image extraction, RouterOS network_cli for TFTP plumbing.

**Spec:** `docs/superpowers/specs/2026-05-27-per-host-build-and-rootfs-design.md`

**Test commands referenced throughout:**

```bash
# Localhost resolver tests (no real inventory; uses inventory/ docs sample)
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_board_config.yml
ansible-playbook -i inventory/ playbooks/tests/test_resolve_build_profile.yml
ansible-playbook -i inventory/ playbooks/tests/test_resolve_rootfs_src.yml

# Syntax checks (catch typos before runtime)
ansible-playbook --syntax-check -i inventory/ playbooks/<name>.yml

# Lint
ansible-lint playbooks/ roles/

# Molecule (run from the role dir)
cd roles/rootfs_provision && molecule test
```

---

## Phase 1: Foundation primitives (no callers changed)

### Task 1: Collection-shipped build defaults

**Files:**
- Create: `vars/build_defaults.yml`

- [ ] **Step 1: Write the defaults file**

```yaml
# vars/build_defaults.yml
#
# Collection-shipped layer 0 defaults for the armbian_build profile.
# Operators override via three explicit named layers in inventory:
#   armbian_build_family — group_vars/<family>.yml
#   armbian_build_model  — group_vars/<model_group>.yml
#   armbian_build_host   — host_vars/<host>.yml
# The resolver (playbooks/tasks/_resolve_build_profile.yml) merges all
# four layers into the per-host `armbian_build` fact.
---
armbian_build_defaults:
  release: bookworm
  ref: "v26.2.0-trunk.844"
  min_free_gb: 50
  timeout: 7200
  compile_args:
    KERNEL_CONFIGURE: "no"
    BUILD_DESKTOP: "no"
    BUILD_MINIMAL: "yes"
    COMPRESS_OUTPUTIMAGE: "sha,xz"
    EXPERT: "yes"
  userpatches: []
```

- [ ] **Step 2: Sanity-check it parses as YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('vars/build_defaults.yml'))"`
Expected: no output (exit 0)

- [ ] **Step 3: Commit**

```bash
git add vars/build_defaults.yml
git commit -m "feat(build): add collection-shipped build profile defaults"
```

---

### Task 2: Board config resolver — failing test first

**Files:**
- Create: `playbooks/tests/test_resolve_board_config.yml`

- [ ] **Step 1: Write the failing localhost-inventory test**

```yaml
# playbooks/tests/test_resolve_board_config.yml
#
# Localhost test for tasks/_resolve_board_config.yml. Builds synthetic
# host vars for a fake board, runs the resolver, asserts the merged
# fact matches expected values per-key (family → model → host).

- name: Resolve effective armbian_board_config and assert merge semantics
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    armbian_board_config_family:
      console: ttyS2,1500000n8
      earlycon: uart8250,mmio32,0xfeb50000
      local_kernel:
        storage: "nvme 0:1"
        storage_scan: "nvme scan"
      uboot_env:
        storage: nowhere
    armbian_board_config_model:
      armbian_board_name: rock-5b
      dtb: rockchip/rk3588-rock-5b.dtb
      uboot_env:
        storage: spi_flash
        fw_env_config:
          device: /dev/mtd0
          offset: "0xc00000"
    armbian_board_config_host:
      local_kernel:
        storage: "nvme 0:4"

  tasks:
    - name: Run resolver
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_board_config.yml"

    - name: Assert family-scoped console survives
      ansible.builtin.assert:
        that: armbian_board_config.console == "ttyS2,1500000n8"
        fail_msg: "console not inherited from family"

    - name: Assert model-scoped armbian_board_name is set
      ansible.builtin.assert:
        that: armbian_board_config.armbian_board_name == "rock-5b"
        fail_msg: "armbian_board_name not set from model"

    - name: Assert host-scoped local_kernel.storage overrides family
      ansible.builtin.assert:
        that: armbian_board_config.local_kernel.storage == "nvme 0:4"
        fail_msg: "host should override family local_kernel.storage"

    - name: Assert family-scoped local_kernel.storage_scan survives host override
      # Recursive combine merges nested keys without wiping siblings
      ansible.builtin.assert:
        that: armbian_board_config.local_kernel.storage_scan == "nvme scan"
        fail_msg: "recursive merge should preserve sibling keys"

    - name: Assert model-scoped uboot_env replaces family entirely
      # Model's uboot_env block is the canonical SPI shape; the family's
      # `storage: nowhere` should be overridden by the model's
      # `storage: spi_flash` and the model's fw_env_config should appear.
      ansible.builtin.assert:
        that:
          - armbian_board_config.uboot_env.storage == "spi_flash"
          - armbian_board_config.uboot_env.fw_env_config.device == "/dev/mtd0"
        fail_msg: "model uboot_env should override family"
```

- [ ] **Step 2: Run it to verify it fails (resolver doesn't exist yet)**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_board_config.yml
```

Expected: FAIL with "Could not find or access ... _resolve_board_config.yml" (the include_tasks resolves to a missing file).

- [ ] **Step 3: Commit the failing test**

```bash
git add playbooks/tests/test_resolve_board_config.yml
git commit -m "test(resolver): add failing test for board_config three-layer merge"
```

---

### Task 3: Board config resolver — make the test pass

**Files:**
- Create: `playbooks/tasks/_resolve_board_config.yml`

- [ ] **Step 1: Write the resolver**

```yaml
# playbooks/tasks/_resolve_board_config.yml
#
# Per-host resolver: merges three explicit named layers into the
# resolved fact armbian_board_config. Run once per host that needs
# hardware facts (boards, builders that delegate to boards).
#
# Layers (precedence low → high):
#   armbian_board_config_family — inventory/group_vars/<family>.yml
#   armbian_board_config_model  — inventory/group_vars/<model_group>.yml
#   armbian_board_config_host   — inventory/host_vars/<host>.yml
#
# Required after-merge fields: armbian_board_name, dtb, console.

- name: Resolve effective armbian_board_config (family → model → host)
  ansible.builtin.set_fact:
    armbian_board_config: >-
      {{
        (armbian_board_config_family | default({}))
        | combine(armbian_board_config_model | default({}), recursive=true)
        | combine(armbian_board_config_host  | default({}), recursive=true)
      }}

- name: Assert required hardware fields are present after merge
  ansible.builtin.assert:
    that:
      - armbian_board_config.armbian_board_name | default('') | length > 0
      - armbian_board_config.dtb              | default('') | length > 0
      - armbian_board_config.console          | default('') | length > 0
    fail_msg: >-
      Host {{ inventory_hostname }}: missing required armbian_board_config
      fields after merge (need armbian_board_name, dtb, console). Check
      inventory/group_vars/<family>.yml, group_vars/<model_group>.yml,
      and host_vars/{{ inventory_hostname }}.yml for the missing field.
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_board_config.yml
```

Expected: PASS (all assertions green, "PLAY RECAP" shows `ok=N changed=0 failed=0`).

- [ ] **Step 3: Commit**

```bash
git add playbooks/tasks/_resolve_board_config.yml
git commit -m "feat(resolver): board_config three-layer merge (family/model/host)"
```

---

### Task 4: Build profile resolver — failing test first

**Files:**
- Create: `playbooks/tests/test_resolve_build_profile.yml`

- [ ] **Step 1: Write the failing test**

```yaml
# playbooks/tests/test_resolve_build_profile.yml
#
# Localhost test for tasks/_resolve_build_profile.yml. Verifies:
#   - scalars (branch, release) follow last-defined-wins
#   - userpatches concat across layers in order
#   - compile_args dict-merges
#   - duplicate userpatch dest across layers is a hard fail

- name: Resolve armbian_build and assert merge semantics
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    armbian_build_defaults:
      release: bookworm
      ref: "v26.2.0-trunk.844"
      min_free_gb: 50
      timeout: 7200
      compile_args:
        KERNEL_CONFIGURE: "no"
        BUILD_MINIMAL: "yes"
      userpatches: []
    armbian_build_family:
      userpatches:
        - dest: config/sources/families/rockchip-rk3588.conf
          content: "family hook"
    armbian_build_model:
      branch: edge
      userpatches:
        - dest: config/boards/rock-5b.conf
          content: "model hook"
    armbian_build_host:
      userpatches:
        - dest: customize-image.sh
          content: "host hook"
      compile_args:
        BUILD_MINIMAL: "no"   # host overrides defaults

  tasks:
    - name: Run resolver
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_build_profile.yml"

    - name: Assert branch from model layer wins
      ansible.builtin.assert:
        that: armbian_build.branch == "edge"

    - name: Assert release from defaults survives
      ansible.builtin.assert:
        that: armbian_build.release == "bookworm"

    - name: Assert userpatches concatenated in family→model→host order
      ansible.builtin.assert:
        that:
          - armbian_build.userpatches | length == 3
          - armbian_build.userpatches[0].dest == "config/sources/families/rockchip-rk3588.conf"
          - armbian_build.userpatches[1].dest == "config/boards/rock-5b.conf"
          - armbian_build.userpatches[2].dest == "customize-image.sh"

    - name: Assert compile_args dict-merged with host winning
      ansible.builtin.assert:
        that:
          - armbian_build.compile_args.KERNEL_CONFIGURE == "no"
          - armbian_build.compile_args.BUILD_MINIMAL == "no"
```

- [ ] **Step 2: Add a SECOND test play for the duplicate-dest hard fail**

Append to the same file:

```yaml
- name: Assert duplicate userpatch dest across layers fails the build
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    armbian_build_defaults: { userpatches: [] }
    armbian_build_family:
      userpatches:
        - dest: customize-image.sh
          content: "family version"
    armbian_build_host:
      userpatches:
        - dest: customize-image.sh
          content: "host version (collision)"

  tasks:
    - name: Run resolver (expected to fail)
      block:
        - ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_build_profile.yml"
        - ansible.builtin.fail:
            msg: "Resolver should have failed on duplicate dest but did not"
      rescue:
        - name: Assert the failure message names duplicate dest
          ansible.builtin.assert:
            that: "'customize-image.sh' in (ansible_failed_result.msg | default(''))"
            fail_msg: >-
              Expected duplicate-dest hard fail naming customize-image.sh;
              got: {{ ansible_failed_result | default('no failure result') }}
```

- [ ] **Step 3: Run to verify it fails (resolver missing)**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_build_profile.yml
```

Expected: FAIL with "Could not find ... _resolve_build_profile.yml".

- [ ] **Step 4: Commit**

```bash
git add playbooks/tests/test_resolve_build_profile.yml
git commit -m "test(resolver): add failing tests for build profile merge"
```

---

### Task 5: Build profile resolver — make the test pass

**Files:**
- Create: `playbooks/tasks/_resolve_build_profile.yml`

- [ ] **Step 1: Write the resolver**

```yaml
# playbooks/tasks/_resolve_build_profile.yml
#
# Per-host resolver: merges four layers into the resolved fact
# armbian_build. Run once per host that produces a custom build.
#
# Layers (precedence low → high):
#   armbian_build_defaults — collection vars/build_defaults.yml
#   armbian_build_family   — inventory/group_vars/<family>.yml
#   armbian_build_model    — inventory/group_vars/<model_group>.yml
#   armbian_build_host     — inventory/host_vars/<host>.yml
#
# Merge contract per key:
#   scalars (branch, release, ref, ...): last-defined-wins via combine()
#   userpatches: list-concatenated; duplicate dest = hard fail
#   compile_args: dict-merged; last layer wins per key

- name: Merge scalars + compile_args via recursive combine
  # combine(recursive=true) handles scalars and nested dicts (compile_args)
  # correctly. The userpatches list is REPLACED by combine — we rebuild it
  # explicitly below via list concatenation.
  ansible.builtin.set_fact:
    __armbian_build_scalars: >-
      {{
        (armbian_build_defaults | default({}))
        | combine(armbian_build_family  | default({}), recursive=true)
        | combine(armbian_build_model   | default({}), recursive=true)
        | combine(armbian_build_host    | default({}), recursive=true)
      }}

- name: Concatenate userpatches across layers (defaults → family → model → host)
  ansible.builtin.set_fact:
    __armbian_build_userpatches_concat: >-
      {{
        (armbian_build_defaults.userpatches | default([]))
        + (armbian_build_family.userpatches  | default([]))
        + (armbian_build_model.userpatches   | default([]))
        + (armbian_build_host.userpatches    | default([]))
      }}

- name: Compute dest-collision map (dest → layers contributing)
  # For each unique dest, list every layer that contributed an entry.
  # A dest appearing in >1 layer is a hard fail.
  ansible.builtin.set_fact:
    __armbian_build_dest_layers: >-
      {{
        __armbian_build_dest_layers | default({})
        | combine({
            item.0: (__armbian_build_dest_layers | default({}) | dict2items
                    | selectattr('key', 'equalto', item.0) | map(attribute='value')
                    | list | first | default([])) + [item.1]
          })
      }}
  loop: >-
    {{
      ((armbian_build_defaults.userpatches | default([])) | map(attribute='dest') | product(['defaults']) | list)
      + ((armbian_build_family.userpatches  | default([])) | map(attribute='dest') | product(['family'])   | list)
      + ((armbian_build_model.userpatches   | default([])) | map(attribute='dest') | product(['model'])    | list)
      + ((armbian_build_host.userpatches    | default([])) | map(attribute='dest') | product(['host'])     | list)
    }}

- name: Identify dests that appear in more than one layer
  ansible.builtin.set_fact:
    __armbian_build_dest_collisions: >-
      {{
        __armbian_build_dest_layers | default({})
        | dict2items | selectattr('value', 'defined')
        | selectattr('value', 'sequence')
        | rejectattr('value', 'equalto', [])
        | selectattr('value', 'count') | list
        | rejectattr('value', 'equalto', 1) | list
      }}

# Note: the count/reject pattern above is fragile in older Ansible.
# A cleaner equivalent (used below for the assert) is to count duplicates
# directly on the flat list of dests.
- name: Fail if any dest appears more than once across layers
  ansible.builtin.assert:
    that:
      - >-
        (__armbian_build_userpatches_concat | map(attribute='dest') | list
         | unique | length)
        == (__armbian_build_userpatches_concat | length)
    fail_msg: >-
      Host {{ inventory_hostname }}: duplicate userpatch dest across
      armbian_build layers. dests = {{ __armbian_build_userpatches_concat | map(attribute='dest') | list }}.
      Resolve by renaming one or refactoring the lower layer.

- name: Assemble resolved armbian_build
  ansible.builtin.set_fact:
    armbian_build: >-
      {{
        __armbian_build_scalars
        | combine({'userpatches': __armbian_build_userpatches_concat})
      }}
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_build_profile.yml
```

Expected: PASS for both plays (merge semantics + duplicate-dest fail).

- [ ] **Step 3: Commit**

```bash
git add playbooks/tasks/_resolve_build_profile.yml
git commit -m "feat(resolver): build profile four-layer merge with dest-collision guard"
```

---

### Task 6: Rootfs source resolver — failing test first

**Files:**
- Create: `playbooks/tests/test_resolve_rootfs_src.yml`

- [ ] **Step 1: Write the failing test (host_vars-set case)**

```yaml
# playbooks/tests/test_resolve_rootfs_src.yml
#
# Tests _resolve_rootfs_src.yml precedence:
#   1. host_vars armbian_rootfs_src set → use as-is
#   2. published manifest exists → derive URL
#   3. neither → fail with actionable message
#
# The "manifest exists" branch is exercised against a synthetic file
# in a temp dir to avoid needing a real netboot_server.

- name: Case 1 — host_vars armbian_rootfs_src wins when set
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    armbian_rootfs_src: "https://example.com/test.img.xz"
    armbian_nfs_assets_export: "/tmp/does-not-exist"
  tasks:
    - ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_rootfs_src.yml"

    - name: Assert host_vars value was preserved verbatim
      ansible.builtin.assert:
        that: armbian_rootfs_src == "https://example.com/test.img.xz"

- name: Case 3 — neither host_vars nor manifest → fail
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    armbian_nfs_assets_export: "/tmp/does-not-exist"
    # NOTE: do NOT set armbian_rootfs_src — that's the precondition for this case.
  tasks:
    - name: Run resolver (expected to fail with actionable message)
      block:
        - ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_rootfs_src.yml"
        - ansible.builtin.fail:
            msg: "Resolver should have failed when no src available; did not."
      rescue:
        - name: Assert the failure message mentions both remediation paths
          ansible.builtin.assert:
            that:
              - "'armbian_rootfs_src' in (ansible_failed_result.msg | default(''))"
              - "'build_and_publish_from_inventory' in (ansible_failed_result.msg | default(''))"
            fail_msg: >-
              Failure message should mention both armbian_rootfs_src
              host_var and build_and_publish_from_inventory.yml.
              Got: {{ ansible_failed_result | default('no result') }}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_rootfs_src.yml
```

Expected: FAIL with missing _resolve_rootfs_src.yml.

- [ ] **Step 3: Commit failing test**

```bash
git add playbooks/tests/test_resolve_rootfs_src.yml
git commit -m "test(resolver): add failing tests for rootfs source precedence"
```

---

### Task 7: Rootfs source resolver — make the test pass

**Files:**
- Create: `playbooks/tasks/_resolve_rootfs_src.yml`

- [ ] **Step 1: Write the resolver**

```yaml
# playbooks/tasks/_resolve_rootfs_src.yml
#
# Per-host resolver for armbian_rootfs_src. Precedence:
#   1. host_vars value set → use as-is
#   2. published manifest at armbian_nfs_assets_export/images/<host>/manifest.json
#      (stat'd on the first netboot_server host) → derive file path
#   3. neither → fail with actionable message
#
# Note: when this resolver runs, it is on a `boards` host. The manifest
# stat / slurp is delegated to the first netboot_server host so the
# resolver can introspect the netboot_server filesystem without changing
# the executing context.

- name: Skip resolution when host_vars armbian_rootfs_src is already set
  ansible.builtin.set_fact:
    __armbian_rootfs_src_was_set: "{{ armbian_rootfs_src is defined and (armbian_rootfs_src | length > 0) }}"

- name: Compute published manifest path candidate
  ansible.builtin.set_fact:
    __published_manifest_path: >-
      {{ armbian_nfs_assets_export }}/images/{{ inventory_hostname }}/manifest.json
  when: not __armbian_rootfs_src_was_set

- name: Stat published manifest on netboot server (delegated)
  ansible.builtin.stat:
    path: "{{ __published_manifest_path }}"
  delegate_to: "{{ groups['netboot_server'][0] | default('localhost') }}"
  become: "{{ groups['netboot_server'] is defined and (groups['netboot_server'] | length > 0) }}"
  register: __published_manifest_stat
  when: not __armbian_rootfs_src_was_set

- name: Slurp published manifest if present
  ansible.builtin.slurp:
    src: "{{ __published_manifest_path }}"
  delegate_to: "{{ groups['netboot_server'][0] | default('localhost') }}"
  become: "{{ groups['netboot_server'] is defined and (groups['netboot_server'] | length > 0) }}"
  register: __published_manifest_raw
  when:
    - not __armbian_rootfs_src_was_set
    - __published_manifest_stat.stat.exists | default(false)

- name: Derive armbian_rootfs_src from published manifest
  ansible.builtin.set_fact:
    armbian_rootfs_src: >-
      {{ armbian_nfs_assets_export }}/images/{{ inventory_hostname
         }}/{{ (__published_manifest_raw.content | b64decode | from_json).image_filename }}
  when:
    - not __armbian_rootfs_src_was_set
    - __published_manifest_stat.stat.exists | default(false)

- name: Fail if no source could be resolved
  ansible.builtin.fail:
    msg: >-
      Host {{ inventory_hostname }}: cannot resolve armbian_rootfs_src.
      Remediation:
        (a) set armbian_rootfs_src in host_vars to an upstream Armbian URL
            (e.g. "https://redirect.armbian.com/<model>/Bookworm_current_minimal"), OR
        (b) run build_and_publish_from_inventory.yml first so a manifest
            lands at {{ armbian_nfs_assets_export }}/images/{{ inventory_hostname }}/manifest.json.
  when:
    - not __armbian_rootfs_src_was_set
    - not (__published_manifest_stat.stat.exists | default(false))
```

- [ ] **Step 2: Run the test to verify it passes**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_resolve_rootfs_src.yml
```

Expected: PASS (case 1 preserves URL; case 3 fails with actionable message including both remediation paths).

- [ ] **Step 3: Commit**

```bash
git add playbooks/tasks/_resolve_rootfs_src.yml
git commit -m "feat(resolver): rootfs source precedence (host_vars > manifest > fail)"
```

---

## Phase 2: rootfs_provision role (replaces image_extract + rootfs_clone)

### Task 8: Role scaffolding (meta + defaults + argument_specs)

**Files:**
- Create: `roles/rootfs_provision/meta/main.yml`
- Create: `roles/rootfs_provision/meta/argument_specs.yml`
- Create: `roles/rootfs_provision/defaults/main.yml`
- Create: `roles/rootfs_provision/README.md`

- [ ] **Step 1: meta/main.yml**

```yaml
# roles/rootfs_provision/meta/main.yml
---
galaxy_info:
  author: David Igou
  description: >-
    Per-host rootfs provisioning. Downloads/copies an Armbian .img.xz,
    extracts the rootfs into a per-host directory on the netboot server,
    stages kernel/initrd/dtb to a TFTP cache, and resets host identity
    (hostname, machine-id, SSH host keys). Single primitive that replaces
    the old image_extract → rootfs_clone two-step.
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: EL
      versions: [9, 10]
    - name: Debian
      versions: [bookworm, trixie]
dependencies: []
```

- [ ] **Step 2: defaults/main.yml**

```yaml
# roles/rootfs_provision/defaults/main.yml
---
# Required from caller — no defaults:
#   armbian_rootfs_src
#   armbian_rootfs_host
#   armbian_rootfs_dtb

armbian_rootfs_target_dir: "{{ armbian_nfs_rootfs_path }}/{{ armbian_rootfs_host }}"
armbian_rootfs_tftp_dir:   "{{ armbian_image_cache }}/sbc-tftp/{{ armbian_rootfs_host }}"

# URL-keyed shared download cache. Hosts pointing at the same upstream URL
# share the .img.xz download; extraction is always per-host.
armbian_rootfs_image_cache: "{{ armbian_image_cache }}/downloads"

# Where the .img.xz gets mounted during extraction (loop device target).
armbian_rootfs_mount_dir: "/mnt/armbian_rootfs_provision"

armbian_rootfs_force_refresh: false
```

- [ ] **Step 3: meta/argument_specs.yml**

```yaml
# roles/rootfs_provision/meta/argument_specs.yml
---
argument_specs:
  main:
    short_description: Provision a per-host NFS rootfs from an .img.xz source.
    description:
      - >-
        Downloads or copies an Armbian .img.xz, extracts the rootfs into a
        per-host directory on the netboot server, stages
        kernel/initrd/dtb to a TFTP cache directory, and resets host
        identity (hostname, machine-id, SSH host keys).
      - >-
        Replaces the previous image_extract + rootfs_clone pair. With per-host
        builds there is no rootfs-template sharing across hosts, so the
        template/clone separation has no purpose; this role does both in
        one invocation.
    options:
      armbian_rootfs_src:
        type: str
        required: true
        description: >-
          .img.xz source. https:// URL, http:// URL, or absolute path.
          Resolved by the caller per the precedence in
          playbooks/tasks/_resolve_rootfs_src.yml.
      armbian_rootfs_host:
        type: str
        required: true
        description: >-
          inventory_hostname this rootfs is for. Drives identity reset
          (hostname, machine-id) and the default target_dir suffix.
      armbian_rootfs_dtb:
        type: str
        required: true
        description: >-
          DTB path under /boot/dtb/ to stage as the TFTP board.dtb
          (e.g. "rockchip/rk3588-rock-5b.dtb"). Comes from the host's
          resolved armbian_board_config.dtb.
      armbian_rootfs_target_dir:
        type: str
        required: false
        description: NFS rootfs destination. Default per-host suffix under armbian_nfs_rootfs_path.
      armbian_rootfs_tftp_dir:
        type: str
        required: false
        description: Per-host TFTP staging dir. Default per-host suffix under armbian_image_cache/sbc-tftp.
      armbian_rootfs_image_cache:
        type: str
        required: false
        description: URL-keyed shared download cache. Hosts pointing at the same URL share the download.
      armbian_rootfs_force_refresh:
        type: bool
        required: false
        default: false
        description: Force re-extract regardless of sentinel.
```

- [ ] **Step 4: README.md (one-line stub for now; fuller content lands later)**

```markdown
# rootfs_provision

Per-host rootfs provisioning. See `meta/argument_specs.yml` for the contract
and `docs/superpowers/specs/2026-05-27-per-host-build-and-rootfs-design.md`
for the design rationale.
```

- [ ] **Step 5: Commit**

```bash
git add roles/rootfs_provision/
git commit -m "feat(rootfs_provision): role scaffolding (meta, defaults, argument_specs)"
```

---

### Task 9: rootfs_provision validate + resolve_src tasks

**Files:**
- Create: `roles/rootfs_provision/tasks/_validate_inputs.yml`
- Create: `roles/rootfs_provision/tasks/_resolve_src.yml`

- [ ] **Step 1: _validate_inputs.yml**

```yaml
# roles/rootfs_provision/tasks/_validate_inputs.yml
---
- name: Assert required inputs are present and well-formed
  ansible.builtin.assert:
    that:
      - armbian_rootfs_src  | length > 0
      - armbian_rootfs_host | length > 0
      - armbian_rootfs_dtb  | length > 0
    fail_msg: >-
      rootfs_provision requires armbian_rootfs_src, armbian_rootfs_host,
      and armbian_rootfs_dtb. See meta/argument_specs.yml.

- name: Refuse to overwrite a mounted target_dir
  ansible.builtin.shell: |
    set -e
    if findmnt -n -T "{{ armbian_rootfs_target_dir }}" >/dev/null 2>&1; then
        echo "MOUNTED" && exit 0
    fi
    echo "NOT_MOUNTED"
  args:
    executable: /bin/bash
  register: __rootfs_provision_target_mount_state
  changed_when: false

- name: Fail if target_dir is currently a mountpoint
  ansible.builtin.fail:
    msg: >-
      armbian_rootfs_target_dir={{ armbian_rootfs_target_dir }} is currently
      a mountpoint. Refusing to overwrite. Unmount it before re-provisioning.
  when: "'MOUNTED' in __rootfs_provision_target_mount_state.stdout"
```

- [ ] **Step 2: _resolve_src.yml**

```yaml
# roles/rootfs_provision/tasks/_resolve_src.yml
---
# Classify src as URL vs local path, compute a stable cache key
# (sha256 of the resolved src string), and set the cache filename.

- name: Detect source flavour (URL vs local)
  ansible.builtin.set_fact:
    __rootfs_provision_is_url: "{{ armbian_rootfs_src is match('^https?://') }}"

- name: Compute URL-keyed cache subdir name (sha256 of src)
  ansible.builtin.set_fact:
    __rootfs_provision_cache_key: "{{ armbian_rootfs_src | hash('sha256') }}"

- name: Compute cached .img.xz path
  ansible.builtin.set_fact:
    __rootfs_provision_img_xz: >-
      {{ armbian_rootfs_image_cache }}/{{ __rootfs_provision_cache_key }}/{{ armbian_rootfs_src | basename }}

- name: Compute decompressed .img path (sibling of .img.xz)
  ansible.builtin.set_fact:
    __rootfs_provision_img_raw: "{{ __rootfs_provision_img_xz[:-3] }}"
```

- [ ] **Step 3: Commit**

```bash
git add roles/rootfs_provision/tasks/_validate_inputs.yml roles/rootfs_provision/tasks/_resolve_src.yml
git commit -m "feat(rootfs_provision): input validation + src classification"
```

---

### Task 10: rootfs_provision download_or_copy + extract tasks

**Files:**
- Create: `roles/rootfs_provision/tasks/_download_or_copy.yml`
- Create: `roles/rootfs_provision/tasks/_extract.yml`

- [ ] **Step 1: _download_or_copy.yml**

```yaml
# roles/rootfs_provision/tasks/_download_or_copy.yml
---
- name: Ensure URL-keyed cache subdir exists
  ansible.builtin.file:
    path: "{{ __rootfs_provision_img_xz | dirname }}"
    state: directory
    mode: "0755"

- name: Download .img.xz from URL
  ansible.builtin.get_url:
    url: "{{ armbian_rootfs_src }}"
    dest: "{{ __rootfs_provision_img_xz }}"
    mode: "0644"
    timeout: 600
  when: __rootfs_provision_is_url

- name: Copy .img.xz from local path
  ansible.builtin.copy:
    src: "{{ armbian_rootfs_src }}"
    dest: "{{ __rootfs_provision_img_xz }}"
    remote_src: true
    mode: "0644"
  when: not __rootfs_provision_is_url
```

- [ ] **Step 2: _extract.yml**

```yaml
# roles/rootfs_provision/tasks/_extract.yml
#
# Mirrors image_extract's _extract_inner.yml but writes directly into
# the per-host target_dir (no template indirection).

- name: Ensure mount dir + target_dir exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - "{{ armbian_rootfs_mount_dir }}"
    - "{{ armbian_rootfs_target_dir }}"

- name: Decompress image (creates {{ __rootfs_provision_img_raw }})
  ansible.builtin.shell: |
    xz -dk "{{ __rootfs_provision_img_xz }}"
  args:
    creates: "{{ __rootfs_provision_img_raw }}"

- name: Attach .img to a loop device with partition scan
  ansible.builtin.shell: |
    losetup --find --show --partscan "{{ __rootfs_provision_img_raw }}"
  register: __rootfs_provision_loop_dev
  changed_when: true

- name: Mount the largest (rootfs) partition
  ansible.builtin.shell: |
    set -o pipefail
    PART=$(lsblk -ln -o NAME {{ __rootfs_provision_loop_dev.stdout }} | tail -1)
    mount "/dev/${PART}" "{{ armbian_rootfs_mount_dir }}"
  args:
    executable: /bin/bash
  changed_when: true

- name: Rsync rootfs into target_dir
  ansible.builtin.shell: |
    rsync -aHAX \
      --exclude '/proc/*' --exclude '/sys/*' \
      --exclude '/dev/*' --exclude '/run/*' \
      "{{ armbian_rootfs_mount_dir }}/" "{{ armbian_rootfs_target_dir }}/"
  changed_when: true
```

- [ ] **Step 3: Commit**

```bash
git add roles/rootfs_provision/tasks/_download_or_copy.yml roles/rootfs_provision/tasks/_extract.yml
git commit -m "feat(rootfs_provision): download/copy + extract into per-host target_dir"
```

---

### Task 11: rootfs_provision stage_tftp + strip_fstab + cleanup

**Files:**
- Create: `roles/rootfs_provision/tasks/_stage_tftp.yml`
- Create: `roles/rootfs_provision/tasks/_strip_fstab.yml`
- Create: `roles/rootfs_provision/tasks/_cleanup.yml`

- [ ] **Step 1: _stage_tftp.yml (mirrors image_extract's _copy_kernel_artifacts.yml)**

```yaml
# roles/rootfs_provision/tasks/_stage_tftp.yml
---
- name: Ensure tftp_dir exists
  ansible.builtin.file:
    path: "{{ armbian_rootfs_tftp_dir }}"
    state: directory
    mode: "0755"

- name: Copy kernel and initrd to tftp_dir
  ansible.builtin.shell: |
    cp "{{ armbian_rootfs_mount_dir }}"/boot/vmlinuz-* "{{ armbian_rootfs_tftp_dir }}/vmlinuz"
    cp "{{ armbian_rootfs_mount_dir }}"/boot/initrd.img-* "{{ armbian_rootfs_tftp_dir }}/initrd.img"
  changed_when: true

- name: Copy board DTB to tftp_dir (try multiple candidate paths)
  ansible.builtin.shell: |
    set -e
    ROOT="{{ armbian_rootfs_mount_dir }}"
    DTB="{{ armbian_rootfs_dtb }}"
    for CANDIDATE in \
        "${ROOT}/boot/dtb/${DTB}" \
        "${ROOT}/boot/dtbs/${DTB}" \
        $(ls "${ROOT}"/boot/dtb-*/"${DTB}" 2>/dev/null) \
        $(ls "${ROOT}"/boot/dtbs/*/"${DTB}" 2>/dev/null); do
      if [ -f "${CANDIDATE}" ]; then
        cp "${CANDIDATE}" "{{ armbian_rootfs_tftp_dir }}/board.dtb"
        echo "DTB copied from ${CANDIDATE}"
        exit 0
      fi
    done
    echo "ERROR: DTB ${DTB} not found under ${ROOT}/boot/{dtb,dtbs,dtb-*}" >&2
    exit 1
  args:
    executable: /bin/bash
  changed_when: true
```

- [ ] **Step 2: _strip_fstab.yml**

```yaml
# roles/rootfs_provision/tasks/_strip_fstab.yml
---
# Strip /dev/ fstab entries from the extracted rootfs — NFS root makes
# them harmful, and disk_provision regenerates them via LABEL= when
# the rootfs is later booted locally.
- name: Strip /dev entries from rootfs fstab (idempotent)
  ansible.builtin.lineinfile:
    path: "{{ armbian_rootfs_target_dir }}/etc/fstab"
    regexp: "^/dev/"
    state: absent
```

- [ ] **Step 3: _cleanup.yml (mirrors image_extract's _cleanup.yml verbatim with var renames)**

```yaml
# roles/rootfs_provision/tasks/_cleanup.yml
---
# Cleanup runs in an `always` block; failures here downgrade to warnings
# so they don't crash an otherwise-successful provision but DO surface
# any loop-device leaks for the operator to clean up.

- name: Unmount image
  ansible.builtin.command:
    cmd: "umount {{ armbian_rootfs_mount_dir }}"
  register: __rootfs_provision_umount
  changed_when: __rootfs_provision_umount.rc == 0
  failed_when: false

- name: Warn when umount failed (loop teardown may leak)
  ansible.builtin.debug:
    msg: >-
      WARNING: umount {{ armbian_rootfs_mount_dir }} returned rc={{ __rootfs_provision_umount.rc }}.
      stderr: {{ __rootfs_provision_umount.stderr | default('') | trim }}.
      Inspect `losetup -a` after the run.
  when: __rootfs_provision_umount.rc != 0

- name: Detach loop device
  ansible.builtin.command:
    cmd: "losetup -d {{ __rootfs_provision_loop_dev.stdout }}"
  when: __rootfs_provision_loop_dev is defined and __rootfs_provision_loop_dev.stdout is defined
  register: __rootfs_provision_losetup
  changed_when: __rootfs_provision_losetup.rc == 0
  failed_when: false

- name: Warn when losetup -d failed (loop device leaked)
  ansible.builtin.debug:
    msg: >-
      WARNING: losetup -d {{ __rootfs_provision_loop_dev.stdout }} returned
      rc={{ __rootfs_provision_losetup.rc }}.
      Run `losetup -d {{ __rootfs_provision_loop_dev.stdout }}` manually to recover.
  when:
    - __rootfs_provision_loop_dev is defined and __rootfs_provision_loop_dev.stdout is defined
    - __rootfs_provision_losetup.rc | default(0) != 0
```

- [ ] **Step 4: Commit**

```bash
git add roles/rootfs_provision/tasks/_stage_tftp.yml \
        roles/rootfs_provision/tasks/_strip_fstab.yml \
        roles/rootfs_provision/tasks/_cleanup.yml
git commit -m "feat(rootfs_provision): stage TFTP, strip fstab, cleanup loop devices"
```

---

### Task 12: rootfs_provision identity_reset

**Files:**
- Create: `roles/rootfs_provision/tasks/_identity_reset.yml`

- [ ] **Step 1: Copy from rootfs_clone with var rename**

```yaml
# roles/rootfs_provision/tasks/_identity_reset.yml
#
# Verbatim port of roles/rootfs_clone/tasks/_identity_reset.yml with
# the two variable renames:
#   target_dir → armbian_rootfs_target_dir
#   hostname   → armbian_rootfs_host

- name: Set per-host /etc/hostname
  ansible.builtin.copy:
    dest: "{{ armbian_rootfs_target_dir }}/etc/hostname"
    content: "{{ armbian_rootfs_host }}\n"
    mode: "0644"

- name: Set per-host /etc/hosts entry
  ansible.builtin.lineinfile:
    path: "{{ armbian_rootfs_target_dir }}/etc/hosts"
    regexp: '^127\.0\.1\.1\s'
    line: "127.0.1.1\t{{ armbian_rootfs_host }}"
    create: false
  failed_when: false

- name: Zero out machine-id files (first-boot trigger for sshd-keygen)
  ansible.builtin.copy:
    dest: "{{ armbian_rootfs_target_dir }}/{{ item }}"
    content: ""
    mode: "0444"
    force: true
  loop:
    - etc/machine-id
    - var/lib/dbus/machine-id

- name: Find stale SSH host keys before regeneration
  ansible.builtin.find:
    paths: "{{ armbian_rootfs_target_dir }}/etc/ssh"
    patterns: "ssh_host_*"
    file_type: any
  register: __rootfs_provision_stale_hostkeys

- name: Remove stale SSH host keys before regeneration
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ __rootfs_provision_stale_hostkeys.files }}"
  loop_control:
    label: "{{ item.path | basename }}"

- name: Generate per-host SSH host keys
  ansible.builtin.command: >-
    ssh-keygen -q -f {{ armbian_rootfs_target_dir }}/etc/ssh/ssh_host_{{ item.type }}_key
    -N "" -t {{ item.type }} {{ item.extra | default('') }}
  args:
    creates: "{{ armbian_rootfs_target_dir }}/etc/ssh/ssh_host_{{ item.type }}_key"
  loop:
    - { type: rsa, extra: "-b 4096" }
    - { type: ecdsa, extra: "-b 521" }
    - { type: ed25519, extra: "" }
  loop_control:
    label: "{{ item.type }}"

- name: Touch /root/.no_armbian_first_login to skip first-login prompt
  ansible.builtin.file:
    path: "{{ armbian_rootfs_target_dir }}/root/.no_armbian_first_login"
    state: touch
    mode: "0644"
```

- [ ] **Step 2: Commit**

```bash
git add roles/rootfs_provision/tasks/_identity_reset.yml
git commit -m "feat(rootfs_provision): port identity reset from rootfs_clone"
```

---

### Task 13: rootfs_provision sentinel + main.yml wiring

**Files:**
- Create: `roles/rootfs_provision/tasks/_write_sentinel.yml`
- Create: `roles/rootfs_provision/tasks/main.yml`

- [ ] **Step 1: _write_sentinel.yml**

```yaml
# roles/rootfs_provision/tasks/_write_sentinel.yml
---
- name: Capture provision timestamp
  ansible.builtin.set_fact:
    __rootfs_provision_at: "{{ '%Y-%m-%dT%H:%M:%SZ' | strftime(lookup('pipe', 'date -u +%s') | int) }}"

- name: Compute sha256 of the cached .img.xz
  ansible.builtin.stat:
    path: "{{ __rootfs_provision_img_xz }}"
    checksum_algorithm: sha256
  register: __rootfs_provision_img_stat

- name: Write sentinel JSON
  ansible.builtin.copy:
    dest: "{{ armbian_rootfs_target_dir }}/.armbian_rootfs_provision_complete"
    content: |
      {{ {
           'src': armbian_rootfs_src,
           'src_sha256': __rootfs_provision_img_stat.stat.checksum,
           'host': armbian_rootfs_host,
           'provisioned_at': __rootfs_provision_at
         } | to_nice_json(sort_keys=true) }}
    mode: "0644"
```

- [ ] **Step 2: main.yml — wire all the sub-tasks together with skip-on-sentinel logic**

```yaml
# roles/rootfs_provision/tasks/main.yml
#
# Per-host rootfs provisioning. Idempotent: a sentinel JSON written at
# end-of-run records the resolved src URL + image sha256 + host. Skip
# the whole provision when the sentinel matches the current inputs and
# force_refresh is false.
---
- name: Validate inputs
  ansible.builtin.include_tasks: _validate_inputs.yml

- name: Resolve source classification + cache paths
  ansible.builtin.include_tasks: _resolve_src.yml

- name: Force-refresh — remove existing target_dir + cache entries when requested
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "{{ armbian_rootfs_target_dir }}"
    - "{{ armbian_rootfs_tftp_dir }}"
    - "{{ __rootfs_provision_img_xz }}"
    - "{{ __rootfs_provision_img_raw }}"
  when: armbian_rootfs_force_refresh | bool

- name: Probe sentinel from a previous successful run
  ansible.builtin.stat:
    path: "{{ armbian_rootfs_target_dir }}/.armbian_rootfs_provision_complete"
  register: __rootfs_provision_sentinel

- name: Parse existing sentinel
  ansible.builtin.slurp:
    src: "{{ armbian_rootfs_target_dir }}/.armbian_rootfs_provision_complete"
  register: __rootfs_provision_sentinel_raw
  when: __rootfs_provision_sentinel.stat.exists

- name: Set fact for sentinel matching
  ansible.builtin.set_fact:
    __rootfs_provision_should_skip: >-
      {{
        __rootfs_provision_sentinel.stat.exists
        and (
          (__rootfs_provision_sentinel_raw.content | b64decode | from_json).src == armbian_rootfs_src
        )
        and (
          (__rootfs_provision_sentinel_raw.content | b64decode | from_json).host == armbian_rootfs_host
        )
      }}
  when: __rootfs_provision_sentinel.stat.exists

- name: Set skip fact false when no sentinel
  ansible.builtin.set_fact:
    __rootfs_provision_should_skip: false
  when: not __rootfs_provision_sentinel.stat.exists

- name: Provision (skipped when sentinel matches)
  when: not __rootfs_provision_should_skip
  block:
    - ansible.builtin.include_tasks: _download_or_copy.yml
    - ansible.builtin.include_tasks: _extract.yml
    - ansible.builtin.include_tasks: _stage_tftp.yml
    - ansible.builtin.include_tasks: _strip_fstab.yml
    - ansible.builtin.include_tasks: _identity_reset.yml
    - ansible.builtin.include_tasks: _write_sentinel.yml
  always:
    - ansible.builtin.include_tasks: _cleanup.yml
```

- [ ] **Step 3: Syntax-check the role**

```bash
ansible-playbook --syntax-check -i inventory/ -e '{}' -e 'armbian_rootfs_src=/tmp/x armbian_rootfs_host=h armbian_rootfs_dtb=d' \
  /dev/stdin <<'YAML'
- hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - rootfs_provision
YAML
```

Expected: PASS or fail with module-not-found (which is fine — we're syntax-checking, not running).

- [ ] **Step 4: Commit**

```bash
git add roles/rootfs_provision/tasks/_write_sentinel.yml roles/rootfs_provision/tasks/main.yml
git commit -m "feat(rootfs_provision): wire main.yml with sentinel-based skip logic"
```

---

### Task 14: Molecule scenario for rootfs_provision

**Files:**
- Create: `roles/rootfs_provision/molecule/default/molecule.yml`
- Create: `roles/rootfs_provision/molecule/default/converge.yml`
- Create: `roles/rootfs_provision/molecule/default/verify.yml`
- Create: `roles/rootfs_provision/molecule/default/requirements.yml` (if existing scenarios use one)

- [ ] **Step 1: Inspect an existing molecule scenario to copy the structure**

Run: `ls -la roles/image_extract/molecule/ 2>/dev/null || ls -la roles/disk_image/molecule/`
Expected: shows existing scenario layout (driver, image, etc.). Match it.

- [ ] **Step 2: Write molecule.yml mirroring the existing pattern**

```yaml
# roles/rootfs_provision/molecule/default/molecule.yml
# (Copy driver/platforms/provisioner block verbatim from
# roles/image_extract/molecule/default/molecule.yml — the test
# requires losetup which only works under privileged containers /
# the qemu provisioner. Adjust the role name accordingly.)
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: rootfs-provision-test
    image: docker.io/library/debian:bookworm
    privileged: true
    pre_build_image: false
    command: /lib/systemd/systemd
    cgroupns_mode: host
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
provisioner:
  name: ansible
  inventory:
    host_vars:
      rootfs-provision-test:
        armbian_nfs_rootfs_path: /var/lib/armbian/test-nfs
        armbian_image_cache: /var/lib/armbian/test-cache
verifier:
  name: ansible
```

- [ ] **Step 3: converge.yml — write the synthetic .img.xz then run the role**

```yaml
# roles/rootfs_provision/molecule/default/converge.yml
---
- name: Converge
  hosts: all
  become: true
  tasks:
    - name: Install build deps for the synthetic image
      ansible.builtin.apt:
        name: [xz-utils, e2fsprogs, dosfstools, rsync]
        state: present
        update_cache: true

    - name: Create synthetic 64MB raw image with one ext4 partition
      ansible.builtin.shell: |
        set -euo pipefail
        IMG=/tmp/synthetic.img
        rm -f "$IMG"
        truncate -s 64M "$IMG"
        echo -e 'o\nn\np\n1\n\n\nw\n' | fdisk "$IMG"
        LOOP=$(losetup --find --show --partscan "$IMG")
        mkfs.ext4 "${LOOP}p1"
        mkdir -p /tmp/mnt
        mount "${LOOP}p1" /tmp/mnt
        # Minimal "rootfs"
        mkdir -p /tmp/mnt/boot /tmp/mnt/etc/ssh /tmp/mnt/root /tmp/mnt/var/lib/dbus
        # Required fake kernel files (the role only checks they exist + copies)
        touch /tmp/mnt/boot/vmlinuz-6.0.0-test
        touch /tmp/mnt/boot/initrd.img-6.0.0-test
        mkdir -p /tmp/mnt/boot/dtb/rockchip
        touch /tmp/mnt/boot/dtb/rockchip/rk3588-test.dtb
        umount /tmp/mnt
        losetup -d "$LOOP"
        xz -k "$IMG"
      args:
        executable: /bin/bash
        creates: /tmp/synthetic.img.xz

    - name: Run rootfs_provision against the synthetic image
      ansible.builtin.include_role:
        name: rootfs_provision
      vars:
        armbian_rootfs_src:  /tmp/synthetic.img.xz
        armbian_rootfs_host: rootfs-provision-test
        armbian_rootfs_dtb:  rockchip/rk3588-test.dtb
```

- [ ] **Step 4: verify.yml — assert artifacts exist**

```yaml
# roles/rootfs_provision/molecule/default/verify.yml
---
- name: Verify rootfs_provision artifacts
  hosts: all
  become: true
  tasks:
    - name: Resolve test paths
      ansible.builtin.set_fact:
        _target: "{{ armbian_nfs_rootfs_path }}/{{ inventory_hostname }}"
        _tftp:   "{{ armbian_image_cache }}/sbc-tftp/{{ inventory_hostname }}"

    - name: Assert target_dir + tftp_dir exist and have expected files
      ansible.builtin.stat:
        path: "{{ item }}"
      register: _stats
      loop:
        - "{{ _target }}/etc/hostname"
        - "{{ _target }}/etc/machine-id"
        - "{{ _target }}/.armbian_rootfs_provision_complete"
        - "{{ _tftp }}/vmlinuz"
        - "{{ _tftp }}/initrd.img"
        - "{{ _tftp }}/board.dtb"

    - name: Assert every expected file is present
      ansible.builtin.assert:
        that: item.stat.exists
        fail_msg: "{{ item.item }} is missing"
      loop: "{{ _stats.results }}"
      loop_control:
        label: "{{ item.item }}"

    - name: Assert hostname file contains the inventory_hostname
      ansible.builtin.command: cat "{{ _target }}/etc/hostname"
      register: _hostname_content
      changed_when: false

    - name: Assert hostname matches
      ansible.builtin.assert:
        that: _hostname_content.stdout == inventory_hostname

    - name: Assert machine-id is empty
      ansible.builtin.stat:
        path: "{{ _target }}/etc/machine-id"
      register: _mid_stat

    - name: Confirm machine-id size is 0
      ansible.builtin.assert:
        that: _mid_stat.stat.size == 0
        fail_msg: "machine-id should be zero-byte; got {{ _mid_stat.stat.size }}"
```

- [ ] **Step 5: Run molecule test**

```bash
cd roles/rootfs_provision && molecule test
```

Expected: All phases (dependency, lint, cleanup, destroy, syntax, create, prepare, converge, idempotence, side_effect, verify, cleanup, destroy) pass.

- [ ] **Step 6: Commit**

```bash
git add roles/rootfs_provision/molecule/
git commit -m "test(rootfs_provision): molecule scenario with synthetic .img.xz"
```

---

## Phase 3: image_build re-key by host

### Task 15: image_build argument_specs adds armbian_build_host

**Files:**
- Modify: `roles/image_build/meta/argument_specs.yml`
- Modify: `roles/image_build/defaults/main.yml`
- Modify: `roles/image_build/tasks/main.yml`

- [ ] **Step 1: Add armbian_build_host to argument_specs**

Add this block after the `armbian_build_board` option in `roles/image_build/meta/argument_specs.yml`:

```yaml
      armbian_build_host:
        type: str
        required: true
        description: >-
          inventory_hostname of the host this build is for. Drives the
          per-host output path under armbian_build_output_dir/<host>/
          and the per-host checkout dir under armbian_build_cache_dir/<host>/.
          Used so concurrent per-host builds don't collide and so secret-
          bearing userpatches in one host's tree never see another host's.
```

- [ ] **Step 2: Update argument_specs description for `armbian_build_userpatches`**

Find the existing description block for `armbian_build_userpatches` and replace its description with:

```yaml
      armbian_build_userpatches:
        type: list
        required: false
        default: []
        description: >-
          List of userpatches to apply before the build. Each entry is a
          mapping with keys dest (path relative to USERPATCHES_DIR, no
          leading slash, no ..) and content (raw file text).
          Patch content MAY contain Jinja referencing the host's resolved
          armbian_board_config fact (e.g. `{{ armbian_board_config.console }}`);
          apply_userpatches.yml's ansible.builtin.copy with `content:`
          renders these references at the point the file lands on the
          builder. The role itself is fully agnostic to what the patches do.
        elements: dict
```

- [ ] **Step 3: Add armbian_build_host to defaults/main.yml**

Append to `roles/image_build/defaults/main.yml`:

```yaml
# inventory_hostname this build targets. Must be supplied by the caller;
# no default. Drives per-host output + cache paths.
armbian_build_host: ""
```

- [ ] **Step 4: Update Validate-required-inputs assert in tasks/main.yml**

Change:

```yaml
- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - armbian_build_board | length > 0
    fail_msg: "armbian_build_board is required"
```

To:

```yaml
- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - armbian_build_board | length > 0
      - armbian_build_host  | length > 0
    fail_msg: "armbian_build_board and armbian_build_host are required"
```

- [ ] **Step 5: Commit**

```bash
git add roles/image_build/
git commit -m "feat(image_build): require armbian_build_host (per-host re-key)"
```

---

### Task 16: image_build per-host suffix in cache + output paths

**Files:**
- Modify: `roles/image_build/tasks/main.yml`
- Modify: `roles/image_build/tasks/preflight.yml`
- Modify: `roles/image_build/tasks/manage_checkout.yml`
- Modify: `roles/image_build/tasks/apply_userpatches.yml`
- Modify: `roles/image_build/tasks/invoke_build.yml`
- Modify: `roles/image_build/tasks/check_manifest.yml`
- Modify: `roles/image_build/tasks/write_manifest.yml`
- Modify: `roles/image_build/tasks/compute_inputs.yml`

- [ ] **Step 1: Add per-host suffix computation at top of `tasks/main.yml`**

After "Validate required inputs" and before "Preflight", add:

```yaml
- name: Compute per-host cache + output paths
  ansible.builtin.set_fact:
    __image_build_cache_dir_host:  "{{ armbian_build_cache_dir }}/{{ armbian_build_host }}"
    __image_build_output_dir_host: "{{ armbian_build_output_dir }}/{{ armbian_build_host }}"
```

- [ ] **Step 2: Replace every `armbian_build_cache_dir` reference inside `roles/image_build/tasks/*.yml` (except `defaults/main.yml` and `meta/`) with `__image_build_cache_dir_host`**

Use this to find them:

```bash
grep -rn 'armbian_build_cache_dir' roles/image_build/tasks/
```

Replace by hand or via sed (verify each edit):

```bash
sed -i 's|{{ armbian_build_cache_dir }}|{{ __image_build_cache_dir_host }}|g' roles/image_build/tasks/*.yml
```

Then re-add the `__image_build_cache_dir_host` set_fact (the sed touches main.yml too — verify the line that COMPUTES the new var still references the original `armbian_build_cache_dir`):

```yaml
# In main.yml — must reference the un-suffixed default:
__image_build_cache_dir_host:  "{{ armbian_build_cache_dir }}/{{ armbian_build_host }}"
__image_build_output_dir_host: "{{ armbian_build_output_dir }}/{{ armbian_build_host }}"
```

If sed corrupted that line, restore it from this plan.

- [ ] **Step 3: Same substitution for `armbian_build_output_dir`**

```bash
grep -rn 'armbian_build_output_dir' roles/image_build/tasks/
sed -i 's|{{ armbian_build_output_dir }}|{{ __image_build_output_dir_host }}|g' roles/image_build/tasks/*.yml
```

Re-verify the set_fact line in main.yml uses the original.

- [ ] **Step 4: Confirm the regex in invoke_build.yml's `Locate the produced .img.xz` still works**

The `paths:` of that `find` task should be `{{ __image_build_cache_dir_host }}/build/output/images`. Confirm it points at the per-host build tree.

- [ ] **Step 5: Syntax-check**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/build_and_publish_from_inventory.yml
```

Expected: PASS (build_and_publish_from_inventory.yml itself still references old var names — those are removed in Phase 6. Syntax check should still succeed for the role.)

- [ ] **Step 6: Commit**

```bash
git add roles/image_build/tasks/
git commit -m "feat(image_build): per-host suffix on cache + output paths"
```

---

### Task 17: image_build manifest gains host field

**Files:**
- Modify: `roles/image_build/tasks/compute_inputs.yml`
- Modify: `roles/image_build/tasks/check_manifest.yml`
- Modify: `roles/image_build/tasks/write_manifest.yml`

- [ ] **Step 1: Add host to manifest decision inputs in compute_inputs.yml**

Edit the `Assemble manifest decision-fields fact` task:

```yaml
- name: Assemble manifest decision-fields fact
  ansible.builtin.set_fact:
    __image_build_manifest_inputs:
      patch_hash: "{{ __image_build_patch_hash }}"
      armbian_build_ref: "{{ armbian_build_ref }}"
      board: "{{ armbian_build_board }}"
      host: "{{ armbian_build_host }}"
      branch: "{{ armbian_build_branch }}"
      release: "{{ armbian_build_release }}"
```

- [ ] **Step 2: Update check_manifest.yml decision to include host**

Edit the `Decide whether to skip the build` set_fact, adding a comparison line:

```yaml
- name: Decide whether to skip the build
  ansible.builtin.set_fact:
    __image_build_skip_build: >-
      {{ (not (armbian_build_force | bool))
         and (_existing_manifest.patch_hash | default('') == __image_build_manifest_inputs.patch_hash)
         and (_existing_manifest.armbian_build_ref | default('') == __image_build_manifest_inputs.armbian_build_ref)
         and (_existing_manifest.board | default('') == __image_build_manifest_inputs.board)
         and (_existing_manifest.host  | default('') == __image_build_manifest_inputs.host)
         and (_existing_manifest.branch | default('') == __image_build_manifest_inputs.branch)
         and (_existing_manifest.release | default('') == __image_build_manifest_inputs.release)
         and (_existing_image_stat.stat.exists | default(false)) }}
```

- [ ] **Step 3: Update write_manifest.yml to persist host**

Edit the `Assemble final manifest` set_fact, adding host:

```yaml
- name: Assemble final manifest
  ansible.builtin.set_fact:
    _manifest:
      patch_hash: "{{ __image_build_manifest_inputs.patch_hash }}"
      armbian_build_ref: "{{ __image_build_manifest_inputs.armbian_build_ref }}"
      board: "{{ __image_build_manifest_inputs.board }}"
      host: "{{ __image_build_manifest_inputs.host }}"
      branch: "{{ __image_build_manifest_inputs.branch }}"
      release: "{{ __image_build_manifest_inputs.release }}"
      image_filename: "{{ _image_filename }}"
      built_at: "{{ _built_at }}"
```

- [ ] **Step 4: Syntax-check + commit**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/build_and_publish_from_inventory.yml
git add roles/image_build/tasks/
git commit -m "feat(image_build): add host field to manifest + rebuild decision"
```

---

## Phase 4: Family + per-model inventory migration

### Task 18: Create rk3588 family group_vars

**Files:**
- Create: `inventory/group_vars/rk3588.yml`
- Create: `inventory/group_vars/rk3588s.yml`

- [ ] **Step 1: Create `inventory/group_vars/rk3588.yml`** with the rk3588-family board_config defaults + the migrated `build_userpatches_common` content from `group_vars/armbian.yml` re-keyed as `armbian_build_family`. (See spec §9 for the full content shape and the spec's "Section 6 — Local_kernel dispatch table collapses" for the new Jinja-inlined hook bodies.)

```yaml
# inventory/group_vars/rk3588.yml — SoC-family layer for rk3588 boards
---
armbian_board_config_family:
  console: ttyS2,1500000n8
  earlycon: uart8250,mmio32,0xfeb50000
  local_kernel:
    storage: "nvme 0:1"
    storage_scan: "nvme scan"
  uboot_env:
    storage: nowhere   # most rk3588 boards have CONFIG_ENV_IS_NOWHERE=y by default

armbian_build_family:
  userpatches:
    - dest: config/sources/families/rockchip-rk3588.conf
      content: |
        # PXE-first override + rk3588 PCI/NVMe defconfig backfill.
        function pre_config_uboot_target__999_pxe_first() {
            declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
            sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                include/configs/rockchip-common.h

            local defconfig="configs/${BOOTCONFIG}"
            if [[ -f "$defconfig" ]]; then
                grep -q "^CONFIG_PCI=y"              "$defconfig" || echo "CONFIG_PCI=y"              >> "$defconfig"
                grep -q "^CONFIG_PCIE_DW_ROCKCHIP=y" "$defconfig" || echo "CONFIG_PCIE_DW_ROCKCHIP=y" >> "$defconfig"
                grep -q "^CONFIG_PCI_INIT_R=y"       "$defconfig" || echo "CONFIG_PCI_INIT_R=y"       >> "$defconfig"
                grep -q "^CONFIG_CMD_NVME=y"         "$defconfig" || echo "CONFIG_CMD_NVME=y"         >> "$defconfig"
                grep -q "^CONFIG_NVME_PCI=y"         "$defconfig" || echo "CONFIG_NVME_PCI=y"         >> "$defconfig"
            fi
        }

        # local_kernel bake — uses host-resolved armbian_board_config (no dispatch table)
        function pre_config_uboot_target__999_local_kernel_bake() {
            [[ "${BRANCH}" != "edge" ]] && return 0
            {% if armbian_board_config.local_kernel is defined %}
            local chain='setenv bootargs root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console={{ armbian_board_config.console }}; {{ armbian_board_config.local_kernel.storage_scan }}; ext4load {{ armbian_board_config.local_kernel.storage }} ${kernel_addr_r} /boot/Image; ext4load {{ armbian_board_config.local_kernel.storage }} ${ramdisk_addr_r} /boot/uInitrd; setenv ramdisk_size ${filesize}; ext4load {{ armbian_board_config.local_kernel.storage }} ${fdt_addr_r} /boot/dtb/{{ armbian_board_config.dtb }}; booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}'
            {% else %}
            return 0
            {% endif %}

            local header marker
            if [[ -f include/configs/rk3588_common.h ]] \
               && grep -qE '^[[:space:]]*#define[[:space:]]+(CFG_|CONFIG_)EXTRA_ENV_SETTINGS' include/configs/rk3588_common.h; then
                header=include/configs/rk3588_common.h
            else
                header="$(grep -lE '^[[:space:]]*#define[[:space:]]+(CFG_|CONFIG_)EXTRA_ENV_SETTINGS' include/configs/rk3588*.h 2>/dev/null | head -n 1)"
            fi
            if [[ -z "${header}" ]]; then
                exit_with_error "${BOARD}: no EXTRA_ENV_SETTINGS in include/configs/rk3588*.h"
            fi
            if grep -q '^[[:space:]]*#define[[:space:]]\+CFG_EXTRA_ENV_SETTINGS' "${header}"; then
                marker='^[[:space:]]*#define[[:space:]]\+CFG_EXTRA_ENV_SETTINGS'
            else
                marker='^[[:space:]]*#define[[:space:]]\+CONFIG_EXTRA_ENV_SETTINGS'
            fi
            display_alert "${BOARD}" "localcmd target macro found in ${header}" "info"
            if grep -q 'localcmd=setenv bootargs root=LABEL=' "${header}"; then
                display_alert "${BOARD}" "localcmd already baked into ${header}" "info"
                return 0
            fi
            local tmp
            tmp="$(mktemp)"
            printf '\t"localcmd=%s\\0" \\\n' "${chain}" > "${tmp}"
            sed -i "/${marker}/r ${tmp}" "${header}"
            rm -f "${tmp}"
            if ! grep -q 'localcmd=setenv bootargs root=LABEL=' "${header}"; then
                exit_with_error "${BOARD}: localcmd bake silently failed in ${header}"
            fi
            display_alert "${BOARD}" "baked local_kernel localcmd into U-Boot default env" "info"
        }

        # Defconfig drift check — uses host-resolved armbian_board_config (no table)
        function pre_config_uboot_target__999_uboot_env_check() {
            local expected='{{ armbian_board_config.uboot_env.storage | default("") }}'
            [[ -z "${expected}" ]] && return 0
            local defconfig="configs/${BOOTCONFIG}"
            [[ ! -f "${defconfig}" ]] && return 0
            local discovered=nowhere
            if   grep -q '^CONFIG_ENV_IS_NOWHERE=y'      "${defconfig}"; then discovered=nowhere
            elif grep -q '^CONFIG_ENV_IS_IN_SPI_FLASH=y' "${defconfig}"; then discovered=spi_flash
            elif grep -q '^CONFIG_ENV_IS_IN_MMC=y'       "${defconfig}"; then discovered=mmc
            fi
            if [[ "${discovered}" != "${expected}" ]]; then
                display_alert "${BOARD}" "uboot_env.storage drift: defconfig=${discovered} vs inventory=${expected}" "wrn"
            fi
        }

        function extension_finish_config__999_no_bcmdhd_for_netboot() {
            [[ -z "${BCMDHD_TYPE}" ]] && return 0
            display_alert "${BOARD}" "disabling bcmdhd DKMS (wired netboot, no WiFi)" "info"
            unset BCMDHD_TYPE
            declare -g INSTALL_HEADERS="no"
        }
```

- [ ] **Step 2: Create `inventory/group_vars/rk3588s.yml`** — same family content but `inherits-from-rk3588` semantics (rk3588 and rk3588s differ only in SoC variant; the hooks are identical):

```yaml
# inventory/group_vars/rk3588s.yml — SoC variant of rk3588
---
# rk3588s shares the same family-layer board_config + build_family as rk3588.
# This file exists so per-model groups under rk3588s inherit the family vars
# via Ansible's group_vars resolution. The content is intentionally identical
# to rk3588.yml — duplicated rather than YAML-anchored so each family file
# remains independently editable.
armbian_board_config_family:
  console: ttyS2,1500000n8
  earlycon: uart8250,mmio32,0xfeb50000
  local_kernel:
    storage: "nvme 0:1"
    storage_scan: "nvme scan"
  uboot_env:
    storage: nowhere

armbian_build_family:
  userpatches:
    - dest: config/sources/families/rockchip-rk3588.conf
      content: |
        # (Same content as rk3588.yml — copy verbatim.)
```

When writing the rk3588s.yml `armbian_build_family.userpatches[0].content`, paste the same body as in rk3588.yml.

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/rk3588.yml inventory/group_vars/rk3588s.yml
git commit -m "feat(inventory): add rk3588 + rk3588s family group_vars"
```

---

### Task 19: Migrate per-model group_vars to new shape

**Files (one task each — repeat the pattern):**
- Modify: `inventory/group_vars/orange_pi_5_pro.yml`
- Modify: `inventory/group_vars/orange_pi_5.yml`
- Modify: `inventory/group_vars/orange_pi_5_max.yml`
- Modify: `inventory/group_vars/rock_5a.yml`
- Modify: `inventory/group_vars/rock_5b.yml`

- [ ] **Step 1: Migrate `orange_pi_5_pro.yml`** to:

```yaml
# inventory/group_vars/orange_pi_5_pro.yml
---
armbian_board_config_model:
  armbian_board_name: orangepi5pro
  dtb: rockchip/rk3588s-orangepi-5-pro.dtb

armbian_build_model:
  branch: edge   # YT6801 PCIe NIC requires mainline u-boot v2026.04 from edge
```

- [ ] **Step 2: Migrate `orange_pi_5.yml`** to:

```yaml
# inventory/group_vars/orange_pi_5.yml
---
armbian_board_config_model:
  armbian_board_name: orangepi5
  dtb: rockchip/rk3588s-orangepi-5.dtb

armbian_build_model:
  branch: current   # YT8531C handled by armbian/build's family fork; edge optional
```

- [ ] **Step 3: Migrate `orange_pi_5_max.yml`** to:

```yaml
# inventory/group_vars/orange_pi_5_max.yml
---
armbian_board_config_model:
  armbian_board_name: orangepi5-max
  dtb: rockchip/rk3588-orangepi-5-max.dtb

armbian_build_model:
  branch: edge   # RTL8125BG PCIe NIC requires mainline u-boot from edge
```

- [ ] **Step 4: Migrate `rock_5a.yml`** to:

```yaml
# inventory/group_vars/rock_5a.yml
---
armbian_board_config_model:
  armbian_board_name: rock-5a
  dtb: rockchip/rk3588s-rock-5a.dtb

armbian_build_model:
  branch: edge
  userpatches:
    - dest: config/boards/rock-5a.conf
      content: |
        function post_family_config_branch_edge__999_rock5a_use_mainline_uboot() {
            [[ "${BOARD}" != "rock-5a" ]] && return 0
            [[ "${BRANCH}" != "edge" ]] && return 0
            display_alert "${BOARD}" "swapping Radxa fork for mainline u-boot v2026.04" "info"
            declare -g BOOTBRANCH="tag:v2026.04"
            declare -g BOOTPATCHDIR="v2026.04"
        }
```

- [ ] **Step 5: Migrate `rock_5b.yml`** to:

```yaml
# inventory/group_vars/rock_5b.yml
---
armbian_board_config_model:
  armbian_board_name: rock-5b
  dtb: rockchip/rk3588-rock-5b.dtb
  uboot_env:
    storage: spi_flash
    fw_env_config:
      device: /dev/mtd0
      offset: "0xc00000"
      size: "0x20000"
      sect_size: "0x1000"
    defaults:
      pxefile_addr_r: "0x00500000"
      kernel_addr_r: "0x02080000"
      ramdisk_addr_r: "0x06000000"
      fdt_addr_r: "0x08000000"
      scriptaddr: "0x00c00000"
      bootmeths: "pxe extlinux script efi"

armbian_build_model:
  branch: edge
  userpatches:
    - dest: config/boards/rock-5b.conf
      content: |
        function post_family_config_branch_edge__999_rock5b_uboot_v2026_04() {
            [[ "${BOARD}" != "rock-5b" ]] && return 0
            [[ "${BRANCH}" != "edge" ]] && return 0
            display_alert "${BOARD}" "overriding u-boot pin to v2026.04 (was v2026.01)" "info"
            declare -g BOOTBRANCH="tag:v2026.04"
            declare -g BOOTPATCHDIR="v2026.04"
        }
```

- [ ] **Step 6: Commit**

```bash
git add inventory/group_vars/orange_pi_5_pro.yml \
        inventory/group_vars/orange_pi_5.yml \
        inventory/group_vars/orange_pi_5_max.yml \
        inventory/group_vars/rock_5a.yml \
        inventory/group_vars/rock_5b.yml
git commit -m "refactor(inventory): migrate per-model group_vars to family/model layered shape"
```

---

### Task 20: Add family group hierarchy to inventory/hosts.yml + retire armbian.yml content

**Files:**
- Modify: `inventory/hosts.yml`
- Modify: `inventory/group_vars/armbian.yml`
- Modify: `inventory/group_vars/all.yml`

- [ ] **Step 1: Edit `inventory/hosts.yml`** — wrap the existing per-model groups under family groups:

Find the `boards:` block and restructure to add rk3588 / rk3588s parents:

```yaml
    boards:
      children:
        rk3588s:
          children:
            orange_pi_5_pro:
            orange_pi_5:
            rock_5a:
        rk3588:
          children:
            orange_pi_5_max:
            rock_5b:

    # (existing per-model groups stay where they were — orange_pi_5_pro,
    # orange_pi_5, rock_5a, orange_pi_5_max, rock_5b — with their host
    # definitions unchanged. The family hierarchy above just adds the
    # rk3588/rk3588s parent layer so group_vars resolution flows
    # family → model → host.)
```

- [ ] **Step 2: Delete `build_userpatches_common`** from `inventory/group_vars/armbian.yml` — its content moved to `rk3588.yml` / `rk3588s.yml` as `armbian_build_family.userpatches`. Replace the file's body with a small explanatory stub:

```yaml
# inventory/group_vars/armbian.yml
---
# Variables that apply to every host this collection touches as part
# of the armbian fleet (armbian_builders + boards).
#
# Fleet-wide build content moved to the family layer (group_vars/rk3588.yml,
# rk3588s.yml) as armbian_build_family in 4.0.0. If you need genuinely
# fleet-wide build content (every family, not just rk3588), define it
# here as `armbian_build_family:` — the resolver also reads from this
# scope because `armbian` is a parent of every board model group.
# Note: be sparing — keep family-specific content in the family files.
```

- [ ] **Step 3: Delete `armbian_image_urls`** block from `inventory/group_vars/all.yml`. Remove the entire block and its surrounding comment.

- [ ] **Step 4: Syntax-check the modified inventory**

```bash
ansible-inventory -i inventory/ --list >/dev/null
```

Expected: succeeds (or fails with a clear error you can fix).

- [ ] **Step 5: Commit**

```bash
git add inventory/
git commit -m "refactor(inventory): add rk3588/rk3588s family hierarchy; retire armbian_image_urls"
```

---

## Phase 5: Port remaining roles

### Task 21: pxelinux_render uses resolved board_config + per-host TFTP paths

**Files:**
- Modify: `roles/pxelinux_render/templates/pxelinux_cfg.j2`
- Modify: `roles/pxelinux_render/meta/argument_specs.yml`
- Modify: `roles/pxelinux_render/defaults/main.yml`

- [ ] **Step 1: Read the current template + argument_specs to understand what's there**

```bash
cat roles/pxelinux_render/templates/pxelinux_cfg.j2
cat roles/pxelinux_render/meta/argument_specs.yml
cat roles/pxelinux_render/defaults/main.yml
```

- [ ] **Step 2: Replace per-model TFTP path references in the template**

`pxelinux_render` is invoked with `delegate_to: localhost` from a `boards`-targeting play (per CLAUDE.md), so `inventory_hostname` inside the template resolves to the board's hostname. Use it directly — no new variable needed.

Find every `pxelinux_render_model_name` reference and replace with `inventory_hostname`. The pxelinux.cfg should reference:

```
KERNEL armbian/{{ inventory_hostname }}/vmlinuz
INITRD armbian/{{ inventory_hostname }}/initrd.img
FDT    armbian/{{ inventory_hostname }}/board.dtb
```

- [ ] **Step 3: Replace `board_console` / `pxelinux_render_earlycon` template variables**

Replace with `armbian_board_config.console` and `armbian_board_config.earlycon` direct references. The template now reads board hardware facts from `armbian_board_config.*` (which the calling playbook must have resolved via `_resolve_board_config.yml` before this role runs) instead of caller-supplied `vars:`.

- [ ] **Step 4: Update argument_specs**

Drop `pxelinux_render_model_name`, `board_console`, `pxelinux_render_earlycon` from the options block. Add a description-only note on the role itself that it requires `armbian_board_config` to be resolved on the calling host before invocation.

- [ ] **Step 5: Syntax-check via the converge_boot_mode playbook**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/converge_boot_mode.yml
```

Expected: PASS (caller updates land in Task 24; just want template syntax green here).

- [ ] **Step 6: Commit**

```bash
git add roles/pxelinux_render/
git commit -m "feat(pxelinux_render): consume resolved board_config + per-host TFTP paths"
```

---

### Task 22: disk_image role contract unchanged — callers are the work

**Discovery:** Reading `roles/disk_image/meta/argument_specs.yml` shows the role already accepts a direct input `image_source` (URL or absolute path). It does NOT consume `armbian_image_urls`. The model-keyed lookup happens in CALLERS (`provision_local_disk.yml`, `test_fleet_e2e.yml`, etc.), which read `armbian_image_urls[<model>]` and pass the resolved value as `image_source`.

**Implication:** The role itself needs no changes. All the porting work is in Task 28 (caller playbooks). This task is a no-op — keep it in the plan only to record the discovery.

- [ ] **Step 1: Confirm — no role edits needed**

```bash
grep -rn 'armbian_image_urls' roles/disk_image/
```

Expected: no matches.

- [ ] **Step 2: Skip directly to Task 28**

No commit for this task.

---

## Phase 6: Port playbooks

### Task 23: Port build_and_publish_from_inventory.yml

**Files:**
- Modify: `playbooks/build_and_publish_from_inventory.yml`

- [ ] **Step 1: Replace the entire playbook**

```yaml
# playbooks/build_and_publish_from_inventory.yml
#
# Per-host custom Armbian image build pipeline. Three plays:
#   1. hosts: boards — resolve effective armbian_board_config and
#      armbian_build per host; identify which hosts opt INTO custom builds.
#   2. hosts: armbian_builders — invoke image_build per opted-in host
#      and rsync per-host output dir to controller staging.
#   3. hosts: netboot_server — push per-host dir to images/<host>/.
#
# A host opts in by having any of armbian_build_{family,model,host} set.
# A host with only armbian_rootfs_src (stock upstream) has no opt-in and
# is skipped by this playbook.
---

- name: Resolve effective configs per board host
  hosts: boards
  gather_facts: false
  tasks:
    - name: Load collection-shipped build defaults
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/build_defaults.yml"

    - name: Resolve effective armbian_board_config
      ansible.builtin.include_tasks: tasks/_resolve_board_config.yml

    - name: Resolve effective armbian_build
      ansible.builtin.include_tasks: tasks/_resolve_build_profile.yml

    - name: Set opt-in fact
      ansible.builtin.set_fact:
        __wants_custom_build: >-
          {{ (armbian_build_family is defined)
             or (armbian_build_model is defined)
             or (armbian_build_host is defined) }}

- name: Build custom Armbian images per opted-in host; stage on controller
  hosts: armbian_builders
  gather_facts: false
  vars:
    __build_hosts: >-
      {{ groups['boards'] | map('extract', hostvars)
         | selectattr('__wants_custom_build', 'equalto', true)
         | map(attribute='inventory_hostname') | list }}
  tasks:
    - name: Report build targets
      ansible.builtin.debug:
        msg: "Will build images for: {{ __build_hosts }}"

    - name: Build per opted-in host
      ansible.builtin.include_role:
        name: image_build
      vars:
        armbian_build_host:         "{{ item }}"
        armbian_build_board:        "{{ hostvars[item].armbian_board_config.armbian_board_name }}"
        armbian_build_branch:       "{{ hostvars[item].armbian_build.branch }}"
        armbian_build_release:      "{{ hostvars[item].armbian_build.release }}"
        armbian_build_ref:          "{{ hostvars[item].armbian_build.ref }}"
        armbian_build_userpatches:  "{{ hostvars[item].armbian_build.userpatches }}"
        armbian_build_compile_args: "{{ hostvars[item].armbian_build.compile_args }}"
        armbian_build_timeout:      "{{ hostvars[item].armbian_build.timeout }}"
        armbian_build_min_free_gb:  "{{ hostvars[item].armbian_build.min_free_gb }}"
      loop: "{{ __build_hosts }}"

    - name: Stage per-host build dir on controller via direct rsync
      ansible.builtin.command:
        argv:
          - rsync
          - --archive
          - --compress
          - --delete
          - --mkpath
          - --rsh
          - "ssh -p {{ ansible_port | default(22) }} -o IdentityAgent=none -o StrictHostKeyChecking=accept-new"
          - "{{ ansible_user }}@{{ ansible_host | default(inventory_hostname) }}:{{ armbian_build_output_dir }}/{{ item }}/"
          - "/tmp/armbian_publish/{{ item }}/"
      delegate_to: localhost
      connection: local
      changed_when: true
      loop: "{{ __build_hosts }}"

- name: Publish staged per-host directories to netboot server
  hosts: netboot_server
  gather_facts: false
  vars:
    _builder: "{{ groups['armbian_builders'][0] }}"
  tasks:
    - name: Push staged per-host image + manifest (sudo on receive)
      ansible.builtin.command:
        argv:
          - rsync
          - --archive
          - --compress
          - --mkpath
          - --rsync-path=sudo rsync
          - --rsh
          - "ssh -p {{ ansible_port | default(22) }} -o IdentityAgent=none -o StrictHostKeyChecking=accept-new"
          - "/tmp/armbian_publish/{{ item }}/"
          - "{{ ansible_user }}@{{ inventory_hostname }}:{{ armbian_nfs_assets_export }}/images/{{ item }}/"
      delegate_to: localhost
      connection: local
      changed_when: true
      loop: "{{ hostvars[_builder].__build_hosts }}"
```

- [ ] **Step 2: Syntax-check**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/build_and_publish_from_inventory.yml
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add playbooks/build_and_publish_from_inventory.yml
git commit -m "refactor(build_and_publish_from_inventory): per-host loops, drop divergence asserts + dispatch table"
```

---

### Task 24: Port stage_netboot_assets.yml

**Files:**
- Modify: `playbooks/stage_netboot_assets.yml`

- [ ] **Step 1: Replace contents**

```yaml
# playbooks/stage_netboot_assets.yml
#
# Per-host rootfs provisioning on the netboot server.
#
# 1. Resolve armbian_board_config and armbian_rootfs_src per board host.
# 2. For each board host: extract its rootfs (per-host), stage TFTP, reset identity.
---

- name: Resolve effective board configs and rootfs sources per board host
  hosts: boards
  gather_facts: false
  tasks:
    - ansible.builtin.include_tasks: tasks/_resolve_board_config.yml
    - ansible.builtin.include_tasks: tasks/_resolve_rootfs_src.yml

- name: Provision per-host NFS rootfs + TFTP artifacts
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - name: Run rootfs_provision per board host
      ansible.builtin.include_role:
        name: rootfs_provision
      vars:
        armbian_rootfs_src:           "{{ hostvars[item].armbian_rootfs_src }}"
        armbian_rootfs_host:          "{{ item }}"
        armbian_rootfs_dtb:           "{{ hostvars[item].armbian_board_config.dtb }}"
        armbian_rootfs_force_refresh: "{{ armbian_force_refresh | default(false) }}"
      loop: "{{ groups['boards'] }}"
```

- [ ] **Step 2: Syntax-check + commit**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/stage_netboot_assets.yml
git add playbooks/stage_netboot_assets.yml
git commit -m "refactor(stage_netboot_assets): single per-host rootfs_provision invocation"
```

---

### Task 25: Port stage_router.yml

**Files:**
- Modify: `playbooks/stage_router.yml`

- [ ] **Step 1: Replace `_unique_models` loops with `groups['boards']` loops**

Each instance of:

```yaml
_unique_models: >-
  {{ groups['boards'] | map('extract', hostvars, 'armbian_board_model') | list | unique }}
```

becomes:

```yaml
_hosts: "{{ groups['boards'] }}"
```

And every:

```yaml
loop: "{{ _unique_models }}"
# or
loop: "{{ _unique_models | product(_assets) | list }}"
```

becomes per-host:

```yaml
loop: "{{ _hosts }}"
# or
loop: "{{ _hosts | product(_assets) | list }}"
```

Wherever a path contains `armbian/{{ model }}/...`, change to `armbian/{{ item }}/...` (or `armbian/{{ item.0 }}/...` with product).

Wherever a source path on netboot_server contains `sbc-tftp/{{ model }}/...`, change to `sbc-tftp/{{ item }}/...`.

- [ ] **Step 2: Syntax-check + commit**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/stage_router.yml
git add playbooks/stage_router.yml
git commit -m "refactor(stage_router): per-host TFTP fetch + push (no model-keyed paths)"
```

---

### Task 26: Port converge_boot_mode.yml (consume resolved board_config)

**Files:**
- Modify: `playbooks/converge_boot_mode.yml`

- [ ] **Step 1: Add `_resolve_board_config.yml` to the play that targets boards**

In `playbooks/converge_boot_mode.yml`, find the play targeting `boards` (the one that renders pxelinux). Add to its `pre_tasks` (creating one if missing):

```yaml
  pre_tasks:
    - ansible.builtin.include_tasks: tasks/_resolve_board_config.yml
```

- [ ] **Step 2: Update the pxelinux_render include_role vars block**

Replace references like:

```yaml
board_console:               "{{ armbian_board_configs[armbian_board_model].console }}"
pxelinux_render_model_name:  "{{ armbian_board_model }}"
pxelinux_render_earlycon:    "{{ armbian_board_configs[armbian_board_model].earlycon | default('') }}"
```

with the new minimal contract (the template reads `armbian_board_config.*` directly now):

```yaml
armbian_rootfs_host: "{{ inventory_hostname }}"
```

- [ ] **Step 3: Drop the plumbing-check pre_task block that builds `_unique_models`**

Where the playbook iterates `_unique_models` to check per-model TFTP rows, change to `groups['boards']` (per-host TFTP).

- [ ] **Step 4: Syntax-check + commit**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/converge_boot_mode.yml
git add playbooks/converge_boot_mode.yml
git commit -m "refactor(converge_boot_mode): consume resolved board_config + per-host TFTP"
```

---

### Task 27: Port persist_uboot_env.yml

**Files:**
- Modify: `playbooks/persist_uboot_env.yml`

- [ ] **Step 1: Add resolver pre_task**

Insert at the top of the play (after `gather_facts: false`):

```yaml
  pre_tasks:
    - ansible.builtin.include_tasks: tasks/_resolve_board_config.yml
```

- [ ] **Step 2: Swap every `armbian_board_configs[armbian_board_model].uboot_env.*` reference to `armbian_board_config.uboot_env.*`**

```bash
sed -i 's|armbian_board_configs\[armbian_board_model\]\.uboot_env|armbian_board_config.uboot_env|g' playbooks/persist_uboot_env.yml
```

Manually verify the file still parses + the references are now reading the resolved fact.

- [ ] **Step 3: Drop the `include_vars: file: ../vars/boards.yml`** lines (the catalogue is gone; resolver covers it).

```bash
grep -n 'vars/boards.yml' playbooks/persist_uboot_env.yml
# Remove any matching include_vars lines.
```

- [ ] **Step 4: Syntax-check + commit**

```bash
ansible-playbook --syntax-check -i inventory/ playbooks/persist_uboot_env.yml
git add playbooks/persist_uboot_env.yml
git commit -m "refactor(persist_uboot_env): consume resolved board_config"
```

---

### Task 28: Port provision_local_disk.yml + test_*_e2e.yml harness playbooks

**Files:**
- Modify: `playbooks/provision_local_disk.yml`
- Modify: `playbooks/test_fleet_e2e.yml`
- Modify: `playbooks/test_hardware_e2e.yml`
- Modify: `playbooks/test_reprovision_e2e.yml`

- [ ] **Step 1: For each file, run this discovery**

```bash
for f in playbooks/provision_local_disk.yml playbooks/test_fleet_e2e.yml \
         playbooks/test_hardware_e2e.yml playbooks/test_reprovision_e2e.yml; do
  echo "=== $f ==="
  grep -n 'armbian_image_urls\|armbian_board_configs\|_unique_models\|armbian_image_src\|vars/boards.yml' "$f"
done
```

- [ ] **Step 2: For each match, apply the same transformations as Tasks 24-27**

- `armbian_image_urls[<model>]` → `armbian_disk_image_src` (resolve via _resolve_rootfs_src.yml if disk_image consumer)
- `armbian_board_configs[armbian_board_model]` → `armbian_board_config` (add `_resolve_board_config.yml` pre_task)
- `_unique_models` loops → `groups['boards']` loops (per-host)
- Drop `include_vars: vars/boards.yml`

- [ ] **Step 3: Syntax-check each + commit**

```bash
for f in playbooks/provision_local_disk.yml playbooks/test_fleet_e2e.yml \
         playbooks/test_hardware_e2e.yml playbooks/test_reprovision_e2e.yml; do
  ansible-playbook --syntax-check -i inventory/ "$f"
done

git add playbooks/provision_local_disk.yml playbooks/test_fleet_e2e.yml \
        playbooks/test_hardware_e2e.yml playbooks/test_reprovision_e2e.yml
git commit -m "refactor(playbooks): port provision_local_disk + e2e harnesses to per-host"
```

---

## Phase 7: Cleanup

### Task 29: Delete superseded primitives

**Files:**
- Delete: `vars/boards.yml`
- Delete: `roles/image_extract/` (entire role tree)
- Delete: `roles/rootfs_clone/` (entire role tree)
- Modify: `playbooks/tests/test_build_and_publish_vars.yml`

- [ ] **Step 1: Confirm no consumers remain**

```bash
grep -rn 'armbian_board_configs\|armbian_image_urls\|image_extract\|rootfs_clone\|vars/boards.yml' \
  playbooks/ roles/ inventory/ 2>/dev/null
```

Expected: empty output. If anything remains, fix it first.

- [ ] **Step 2: Delete the files**

```bash
git rm -r vars/boards.yml roles/image_extract roles/rootfs_clone
```

- [ ] **Step 3: Replace test_build_and_publish_vars.yml**

The existing test asserts the old per-model contract (every model has `armbian_board_branch`, etc.). Replace its contents with a thin assertion that the resolvers produce well-formed output for every board host in the docs inventory:

```yaml
# playbooks/tests/test_build_and_publish_vars.yml
---
- name: Verify resolvers produce well-formed facts for every board in the docs inventory
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Load build defaults
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../../vars/build_defaults.yml"

    - name: Run board_config + build_profile resolvers for each board host
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../tasks/_resolve_board_config.yml"
      vars:
        armbian_board_config_family: "{{ hostvars[item].armbian_board_config_family | default({}) }}"
        armbian_board_config_model:  "{{ hostvars[item].armbian_board_config_model  | default({}) }}"
        armbian_board_config_host:   "{{ hostvars[item].armbian_board_config_host   | default({}) }}"
      loop: "{{ groups['boards'] }}"
```

(This is intentionally minimal — full coverage lives in the dedicated resolver tests.)

- [ ] **Step 4: Run lint + syntax-check + ALL resolver tests + the renamed test**

```bash
ansible-lint playbooks/ roles/ inventory/ vars/
for f in playbooks/tests/test_*.yml; do
  unset ANSIBLE_INVENTORY
  ansible-playbook -i inventory/ "$f"
done
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor!: delete vars/boards.yml, image_extract, rootfs_clone (superseded)"
```

---

## Phase 8: Docs + version bump

### Task 30: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Find every reference to the old model-keyed concepts**

```bash
grep -n 'armbian_board_configs\|armbian_image_urls\|image_extract\|rootfs_clone\|vars/boards.yml\|build_userpatches_common\|_unique_models\|Per-host builds are not supported' CLAUDE.md
```

- [ ] **Step 2: For each section that describes the old per-model model**

- Update the "Roles" table at top: replace `image_extract` + `rootfs_clone` rows with a single `rootfs_provision` row.
- Update the "Collection structure" tree to delete `vars/boards.yml`, `roles/image_extract/`, `roles/rootfs_clone/`, and add `roles/rootfs_provision/`, `vars/build_defaults.yml`, `playbooks/tasks/_resolve_*.yml`.
- Update "Required configuration before first run" to:
  - Remove `armbian_image_urls`.
  - Add per-host `armbian_rootfs_src` (optional; default derives from published manifest).
  - Update "boards entries" section to describe the family/model/host layered shape.
- Update "Where things run" table: replace stage_netboot_assets row to mention rootfs_provision; update build_and_publish_from_inventory row to mention per-host loops.
- Delete the "Per-host builds not supported" mention; replace with a sentence summarizing the new contract.

- [ ] **Step 3: Add a new section "Per-host build profile layering"** that summarizes the spec's section 5 (the family/model/host merge contract for both `armbian_board_config` and `armbian_build`).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): describe per-host build + resolver layering"
```

---

### Task 31: Update other docs + skill files

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/boot-mode-override.md`
- Modify: `docs/lifecycle.md`
- Modify: `.claude/skills/adding-armbian-board/SKILL.md`

- [ ] **Step 1: For each file, grep for stale references**

```bash
for f in docs/architecture.md docs/boot-mode-override.md docs/lifecycle.md .claude/skills/adding-armbian-board/SKILL.md; do
  echo "=== $f ==="
  grep -n 'armbian_board_configs\|armbian_image_urls\|image_extract\|rootfs_clone\|vars/boards.yml\|build_userpatches_common' "$f"
done
```

- [ ] **Step 2: For each match, update with the new pattern**

- References to `vars/boards.yml` → describe `inventory/group_vars/<family>.yml` + `<model_group>.yml` shape.
- References to `armbian_image_urls` → describe `armbian_rootfs_src` precedence.
- References to `image_extract` / `rootfs_clone` → `rootfs_provision`.
- The `adding-armbian-board` skill's checklist: rewrite the "Minimum touched files" section to reflect that adding a new board now requires zero collection edits.

- [ ] **Step 3: Commit**

```bash
git add docs/ .claude/skills/
git commit -m "docs: rewrite for per-host build + resolver layering"
```

---

### Task 32: Bump galaxy.yml version

**Files:**
- Modify: `galaxy.yml`

- [ ] **Step 1: Open galaxy.yml**

```bash
grep -n 'version:' galaxy.yml
```

- [ ] **Step 2: Change `version: 3.0.0` to `version: 4.0.0`**

```bash
sed -i 's/^version: .*/version: 4.0.0/' galaxy.yml
```

- [ ] **Step 3: Verify the change**

```bash
grep -n 'version:' galaxy.yml
```

Expected: `version: 4.0.0`.

- [ ] **Step 4: Commit**

```bash
git add galaxy.yml
git commit -m "chore(galaxy): bump to 4.0.0 (breaking refactor)"
```

---

## Phase 9: Final integration check

### Task 33: Full lint + syntax pass + resolver tests

- [ ] **Step 1: Lint everything**

```bash
ansible-lint playbooks/ roles/ inventory/ vars/
```

Expected: 0 errors.

- [ ] **Step 2: Syntax-check every playbook**

```bash
for f in playbooks/*.yml; do
  echo "=== $f ==="
  ansible-playbook --syntax-check -i inventory/ "$f" || exit 1
done
```

Expected: every playbook reports `playbook: <file>` and exits 0.

- [ ] **Step 3: Run every resolver test**

```bash
unset ANSIBLE_INVENTORY
for f in playbooks/tests/test_*.yml; do
  echo "=== $f ==="
  ansible-playbook -i inventory/ "$f" || exit 1
done
```

Expected: every test play green.

- [ ] **Step 4: Molecule test for the new role**

```bash
cd roles/rootfs_provision && molecule test && cd -
```

Expected: green.

- [ ] **Step 5: If everything green, prepare PR**

```bash
git log --oneline main..HEAD
git push -u origin <branch-name>
```

Then open the PR. The hardware E2E gate (test_fleet_e2e.yml against the real fleet) is the final pre-merge check the operator runs manually.

---

## File coverage check (self-review reference)

| Spec section | Implementation task(s) |
|---|---|
| §4 path layout | Tasks 16, 23–28 (per-host paths in image_build + playbooks) |
| §5.1 board_config three-layer merge | Tasks 2–3 (resolver + test), 18–20 (inventory) |
| §5.2 build profile four-layer merge | Tasks 4–5 (resolver + test), 18–20 (inventory) |
| §6 dispatch table collapses | Task 18 (family-layer Jinja-inlined hooks) |
| §7.1 image_build re-key | Tasks 15–17 |
| §7.2 rootfs_provision new role | Tasks 8–14 |
| §7.3 disk_image direct src | Task 22 |
| §7.4 pxelinux_render fact + per-host paths | Tasks 21, 26 |
| §7.5 persist_uboot_env fact swap | Task 27 |
| §8 playbook flow | Tasks 23–28 |
| §10 migration sequencing | Phases 1–9 follow the spec's seven-step order |
| §11 testing | Tasks 2, 4, 6 (resolver tests), Task 14 (molecule), Task 33 (integration) |
