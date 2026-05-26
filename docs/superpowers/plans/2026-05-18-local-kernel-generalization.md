# Local-Kernel Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the OPi5Max-only `local_kernel` boot mode mechanism (from PR #82) into a board-agnostic dispatch-table-driven design, add per-host SPI persistence with operator escape hatch, and roll all 4 currently-`nfs` hosts onto `local_kernel`.

**Architecture:** Lift OPi5Max-specific constants into `vars/boards.yml` per-board metadata. Replace the hardcoded `pre_config_uboot_target__999_orangepi5max_localcmd` U-Boot build hook with a generic one driven by an Ansible-rendered Bash dispatch table. Generalize `playbooks/persist_uboot_env.yml` to compose `uboot_env_vars` from three sources (board defaults, collection-managed keys, operator `_extra` override) with documented precedence. Wire it into `converge_boot_mode.yml` as step 3.5 with cycle ownership transferred to converge.

**Tech Stack:** Ansible 2.15+; molecule (podman provisioner for fast scenarios, kubevirt for the existing slow image_build scenario); armbian/build's extension manager (Bash); `u-boot-tools` for `fw_setenv`/`fw_printenv` on board.

**Spec:** [`docs/superpowers/specs/2026-05-18-local-kernel-generalization-design.md`](../specs/2026-05-18-local-kernel-generalization-design.md).

---

## Phase 1 — Mechanism (CI-verifiable, no hardware)

### Task 1: Add `local_kernel` + `uboot_env` metadata to `vars/boards.yml`

**Files:**
- Modify: `vars/boards.yml`

- [ ] **Step 1: Add `local_kernel` and `uboot_env` blocks to all 5 board entries**

Edit `vars/boards.yml`. After each board's existing `earlycon:` line, add the two new blocks. Final structure per board:

```yaml
  orange-pi-5-pro:
    armbian_dl_dir: orangepi5pro
    armbian_board_name: orangepi5pro
    armbian_support: community
    dtb: rockchip/rk3588s-orangepi-5-pro.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: nowhere

  rock-5b:
    armbian_dl_dir: rock-5b
    armbian_board_name: rock-5b
    armbian_support: standard
    dtb: rockchip/rk3588-rock-5b.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: spi_flash
      fw_env_config:
        device: /dev/mtd0
        offset:    "0xc00000"
        size:      "0x20000"
        sect_size: "0x1000"
      defaults:
        pxefile_addr_r: "0x00500000"
        kernel_addr_r:  "0x02080000"
        ramdisk_addr_r: "0x06000000"
        fdt_addr_r:     "0x08000000"
        scriptaddr:     "0x00c00000"
        bootmeths:      "pxe extlinux script efi"

  orange-pi-5:
    # ... existing ...
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: nowhere

  rock-5a:
    # ... existing ...
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: nowhere    # confirmed: rock-5a has no SPI flash

  orange-pi-5-max:
    # ... existing ...
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: nowhere    # CONFIG_ENV_IS_NOWHERE=y in defconfig
```

- [ ] **Step 2: Update the file-header comment block in `vars/boards.yml`**

Append to the existing field documentation:

```yaml
#   local_kernel         OPTIONAL. Board's local_kernel mechanism config.
#                        - storage: U-Boot device address (e.g. "nvme 0:4").
#                        - storage_scan: scan command (e.g. "nvme scan").
#                        Absent => board does not support local_kernel mode.
#   uboot_env            OPTIONAL. Board's U-Boot env storage characteristics.
#                        - storage: 'nowhere' | 'spi_flash' | 'mmc'.
#                        - fw_env_config: device/offset/size/sect_size for
#                          /etc/fw_env.config. Only when storage allows
#                          runtime read/write.
#                        - defaults: dict of env vars to keep in SPI
#                          (consumed by persist_uboot_env.yml when storage
#                          is spi_flash).
```

- [ ] **Step 3: Run yamllint and commit**

```bash
make yamllint
git add vars/boards.yml
git commit -m "vars/boards: add local_kernel + uboot_env metadata per board"
```

Expected: yamllint passes; one new commit.

---

### Task 2: Extract localcmd render macro

**Files:**
- Create: `roles/image_build/vars/local_kernel.yml`

The macro renders one U-Boot command chain from a board's `local_kernel` block plus collection defaults. Used by the build hook (Task 4) and the persist play (Task 9).

- [ ] **Step 1: Write the macro file**

Create `roles/image_build/vars/local_kernel.yml`:

```yaml
---
# Jinja macro: render_localcmd_chain(board_cfg, overrides)
# Used by playbooks/build_image.yml (build hook dispatch table) and
# playbooks/persist_uboot_env.yml (per-host SPI localcmd).
#
# Inputs:
#   board_cfg: an entry from armbian_board_configs (must have
#              local_kernel.{storage,storage_scan}, dtb, console).
#   overrides: optional dict with the same keys to override defaults;
#              empty dict if no per-host override.
#
# Output: single-line U-Boot command string ending in `booti`.
#
# Collection-level defaults (not overridable here — they're invariants
# of the Armbian rootfs layout):
#   kernel_path:  /boot/Image
#   initrd_path:  /boot/uInitrd
#   rootfstype:   ext4
#   root_label:   armbi_root_local  (matches pxelinux_render's default)

local_kernel_chain_macro: |
  {%- macro render_localcmd_chain(board_cfg, overrides={}) -%}
  {%- set lk = board_cfg.local_kernel -%}
  {%- set storage      = overrides.storage      | default(lk.storage) -%}
  {%- set storage_scan = overrides.storage_scan | default(lk.storage_scan) -%}
  {%- set root_label   = overrides.root_label   | default('armbi_root_local') -%}
  {%- set console      = overrides.console      | default(board_cfg.console) -%}
  {%- set dtb          = overrides.dtb          | default(board_cfg.dtb) -%}
  setenv bootargs root=LABEL={{ root_label }} rootfstype=ext4 rootwait rw console={{ console }};
  {{- ' ' }}{{ storage_scan }};
  {{- ' ' }}ext4load {{ storage }} ${kernel_addr_r} /boot/Image;
  {{- ' ' }}ext4load {{ storage }} ${ramdisk_addr_r} /boot/uInitrd;
  {{- ' ' }}setenv ramdisk_size ${filesize};
  {{- ' ' }}ext4load {{ storage }} ${fdt_addr_r} /boot/dtb/{{ dtb }};
  {{- ' ' }}booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
  {%- endmacro -%}
```

- [ ] **Step 2: Verify the macro renders the LK1-known-good OPi5Max string**

Spot-check by hand against the value already baked into `playbooks/build_image.yml`'s OPi5Max hook (it's the only thing that's hardware-verified). With inputs `board_cfg.local_kernel.storage = "nvme 0:4"`, `board_cfg.local_kernel.storage_scan = "nvme scan"`, `board_cfg.console = "ttyS2,1500000n8"`, `board_cfg.dtb = "rockchip/rk3588-orangepi-5-max.dtb"`, no overrides, the macro should produce:

```
setenv bootargs root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000n8; nvme scan; ext4load nvme 0:4 ${kernel_addr_r} /boot/Image; ext4load nvme 0:4 ${ramdisk_addr_r} /boot/uInitrd; setenv ramdisk_size ${filesize}; ext4load nvme 0:4 ${fdt_addr_r} /boot/dtb/rockchip/rk3588-orangepi-5-max.dtb; booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
```

This is verified mechanically by Task 3's molecule scenario; this step is just for the implementer to eyeball.

- [ ] **Step 3: Commit**

```bash
git add roles/image_build/vars/local_kernel.yml
git commit -m "image_build: extract render_localcmd_chain Jinja macro"
```

---

### Task 3: Molecule scenario — local_kernel dispatch rendering (Layer 2)

**Files:**
- Create: `extensions/molecule/local_kernel_render/molecule.yml`
- Create: `extensions/molecule/local_kernel_render/converge.yml`
- Create: `extensions/molecule/local_kernel_render/verify.yml`

Lightweight podman scenario that exercises the rendering logic without building U-Boot. Fixture inventory has two boards that opt in and one that doesn't; converge renders the dispatch table; verify asserts the rendered content.

- [ ] **Step 1: Write `molecule.yml`**

```yaml
---
# Verify the local_kernel build-hook dispatch table renders correctly
# for an inventory containing a mix of opted-in and not-opted-in boards.
# No real U-Boot build — just rendering verification.
dependency:
  name: galaxy
driver:
  name: default
  options:
    managed: true
    ansible_connection_options:
      connection: local
platforms:
  - name: local_kernel_render
    image: registry.fedoraproject.org/fedora:latest
    pre_build_image: true
provisioner:
  name: ansible
  playbooks:
    converge: converge.yml
    verify: verify.yml
verifier:
  name: ansible
scenario:
  name: local_kernel_render
  test_sequence:
    - dependency
    - syntax
    - create
    - converge
    - verify
    - destroy
```

- [ ] **Step 2: Write `converge.yml`**

```yaml
---
- name: Converge — render local_kernel dispatch table from fixture inventory
  hosts: all
  gather_facts: false
  become: false
  vars:
    # Fixture: three board configs, two opted in, one not.
    armbian_board_configs:
      orange-pi-5-max:
        armbian_dl_dir: orangepi5-max
        armbian_board_name: orangepi5-max
        armbian_support: community
        dtb: rockchip/rk3588-orangepi-5-max.dtb
        console: ttyS2,1500000n8
        earlycon: uart8250,mmio32,0xfeb50000
        local_kernel:
          storage: "nvme 0:4"
          storage_scan: "nvme scan"
        uboot_env:
          storage: nowhere
      rock-5b:
        armbian_dl_dir: rock-5b
        armbian_board_name: rock-5b
        armbian_support: standard
        dtb: rockchip/rk3588-rock-5b.dtb
        console: ttyS2,1500000n8
        earlycon: uart8250,mmio32,0xfeb50000
        local_kernel:
          storage: "nvme 0:4"
          storage_scan: "nvme scan"
        uboot_env:
          storage: spi_flash
      rock-5a:
        armbian_dl_dir: rock-5a
        armbian_board_name: rock-5a
        armbian_support: standard
        dtb: rockchip/rk3588s-rock-5a.dtb
        console: ttyS2,1500000n8
        earlycon: uart8250,mmio32,0xfeb50000
        # NO local_kernel block — expected to produce no dispatch row.
    _board_models:
      - orange-pi-5-max
      - rock-5b
      - rock-5a

  tasks:
    - name: Load the localcmd chain macro
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../../../roles/image_build/vars/local_kernel.yml"

    - name: Render the dispatch table fragment
      ansible.builtin.set_fact:
        _dispatch_table: |
          {% set macros = local_kernel_chain_macro %}
          {% from macros import render_localcmd_chain %}
          {% for board in _board_models %}
          {% set cfg = armbian_board_configs[board] %}
          {% if cfg.local_kernel is defined %}
          [{{ cfg.armbian_board_name }}]='{{ render_localcmd_chain(cfg) }}'
          {% endif %}
          {% endfor %}

    - name: Expose the rendered table as a fact for verify
      ansible.builtin.copy:
        content: "{{ _dispatch_table }}"
        dest: /tmp/dispatch_table.txt
        mode: "0644"
```

- [ ] **Step 3: Write `verify.yml`**

```yaml
---
- name: Verify — local_kernel dispatch table content
  hosts: all
  gather_facts: false
  become: false

  tasks:
    - name: Read the rendered dispatch table
      ansible.builtin.slurp:
        src: /tmp/dispatch_table.txt
      register: _table

    - name: Decode for readability in failures
      ansible.builtin.set_fact:
        _table_text: "{{ _table.content | b64decode }}"

    - name: Assert orangepi5-max row present with correct chain content
      ansible.builtin.assert:
        that:
          - "'[orangepi5-max]=' in _table_text"
          - "'rockchip/rk3588-orangepi-5-max.dtb' in _table_text"
          - "'nvme 0:4' in _table_text"
          - "'console=ttyS2,1500000n8' in _table_text"
        fail_msg: |
          Expected orangepi5-max row with its DTB / nvme 0:4 / ttyS2,1500000n8.
          Got: {{ _table_text }}

    - name: Assert rock-5b row present with correct chain content
      ansible.builtin.assert:
        that:
          - "'[rock-5b]=' in _table_text"
          - "'rockchip/rk3588-rock-5b.dtb' in _table_text"
        fail_msg: |
          Expected rock-5b row with its DTB.
          Got: {{ _table_text }}

    - name: Assert rock-5a row ABSENT (no local_kernel block in fixture)
      ansible.builtin.assert:
        that:
          - "'[rock-5a]=' not in _table_text"
        fail_msg: |
          rock-5a has no local_kernel block in the fixture; the dispatch
          table must not contain a row for it. Got: {{ _table_text }}

    - name: Assert no cross-contamination (opi5max DTB does not appear in rock-5b row context)
      vars:
        _rock5b_row: "{{ _table_text | regex_search('\\[rock-5b\\]=.*$', multiline=true) }}"
      ansible.builtin.assert:
        that:
          - "'rk3588-orangepi-5-max.dtb' not in _rock5b_row"
        fail_msg: |
          Cross-contamination: rock-5b's row contains opi5max's DTB.
          Row: {{ _rock5b_row }}
```

- [ ] **Step 4: Run molecule, expect failure (macro file used but the Task-2 macro returns single multi-line string until the import-macro syntax works against a `set_fact`)**

```bash
make molecule SCENARIO=local_kernel_render
```

Expected: converge fails. The Jinja `{% from macros import render_localcmd_chain %}` pattern doesn't work when `macros` is a string variable; you need either an actual template file or a different approach. Confirm the failure mode so the next step is informed.

- [ ] **Step 5: Refactor — store the macro as a template file instead of a yaml-embedded string**

Replace `roles/image_build/vars/local_kernel.yml` with `roles/image_build/templates/render_localcmd_chain.j2`:

```jinja2
{# Macro file for use with `import_tasks` + `template` lookup or
   `from 'path/to/this/file' import render_localcmd_chain` in callers.
   The set_fact pattern in molecule converge.yml uses a different
   technique — see Task 3 final converge.yml. #}
{%- macro render_localcmd_chain(board_cfg, overrides={}) -%}
{%- set lk = board_cfg.local_kernel -%}
{%- set storage      = overrides.storage      | default(lk.storage) -%}
{%- set storage_scan = overrides.storage_scan | default(lk.storage_scan) -%}
{%- set root_label   = overrides.root_label   | default('armbi_root_local') -%}
{%- set console      = overrides.console      | default(board_cfg.console) -%}
{%- set dtb          = overrides.dtb          | default(board_cfg.dtb) -%}
setenv bootargs root=LABEL={{ root_label }} rootfstype=ext4 rootwait rw console={{ console }};
{{- ' ' }}{{ storage_scan }};
{{- ' ' }}ext4load {{ storage }} ${kernel_addr_r} /boot/Image;
{{- ' ' }}ext4load {{ storage }} ${ramdisk_addr_r} /boot/uInitrd;
{{- ' ' }}setenv ramdisk_size ${filesize};
{{- ' ' }}ext4load {{ storage }} ${fdt_addr_r} /boot/dtb/{{ dtb }};
{{- ' ' }}booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
{%- endmacro -%}
```

Delete the original `roles/image_build/vars/local_kernel.yml`.

Update the molecule converge.yml's render task to use the new shape:

```yaml
    - name: Render the dispatch table fragment
      ansible.builtin.set_fact:
        _dispatch_table: |
          {%- from playbook_dir + '/../../../roles/image_build/templates/render_localcmd_chain.j2' import render_localcmd_chain -%}
          {% for board in _board_models %}
          {% set cfg = armbian_board_configs[board] %}
          {% if cfg.local_kernel is defined %}
          [{{ cfg.armbian_board_name }}]='{{ render_localcmd_chain(cfg) }}'
          {% endif %}
          {% endfor %}
```

- [ ] **Step 6: Run molecule, expect pass**

```bash
make molecule SCENARIO=local_kernel_render
```

Expected: all verify assertions pass.

- [ ] **Step 7: Update Makefile MOLECULE_SCENARIOS list**

Edit `Makefile`:

```makefile
MOLECULE_SCENARIOS := default rootfs_clone pxelinux_render image_build local_kernel_render
```

- [ ] **Step 8: Commit**

```bash
git add Makefile extensions/molecule/local_kernel_render/ \
        roles/image_build/templates/render_localcmd_chain.j2
git rm roles/image_build/vars/local_kernel.yml  # if it ended up there from Task 2
git commit -m "molecule: add local_kernel_render scenario; refactor macro into j2"
```

---

### Task 4: Replace OPi5Max-specific build hook with generic dispatch

**Files:**
- Modify: `playbooks/build_image.yml:91-220` (the `__999_orangepi5max_localcmd` block)

- [ ] **Step 1: Delete the OPi5Max-specific hook function block**

In `playbooks/build_image.yml`, remove the entire `pre_config_uboot_target__999_orangepi5max_localcmd` function definition (the `function ... {` to its closing `}`) AND the comment block above it (lines 91-220 in current state). Keep the rest of `build_userpatches_common`.

- [ ] **Step 2: Add pre_task that renders the dispatch table**

In the same play, in the `pre_tasks:` block (after the existing "Load board configs for board name lookup" task), add:

```yaml
    - name: Render local_kernel dispatch table for the build hook
      ansible.builtin.set_fact:
        _local_kernel_dispatch_table: |
          {%- from playbook_dir + '/../roles/image_build/templates/render_localcmd_chain.j2' import render_localcmd_chain -%}
          {% for board_model in _board_models %}
          {% set cfg = armbian_board_configs[board_model] %}
          {% if cfg.local_kernel is defined %}
              [{{ cfg.armbian_board_name }}]='{{ render_localcmd_chain(cfg) }}'
          {% endif %}
          {% endfor %}
```

This task must run AFTER `_board_models` is set (the existing "Resolve unique armbian_board_model values" task) and BEFORE `build_userpatches_common` is consumed by the include_role task. Place it right after "Resolve unique armbian_board_model values from groups['boards']".

- [ ] **Step 3: Add the generic build hook to `build_userpatches_common`**

In the same file, inside the `build_userpatches_common:` list (after the existing `__999_pxe_first` entry, before the rock-5b mainline-uboot entry), insert a new userpatch that contains the generic hook. The hook references `_local_kernel_dispatch_table` via Jinja templating (so the rendered table lands in the Bash function body):

```yaml
      - dest: "config/sources/families/rockchip-rk3588.conf"
        content: |
          # Generic local_kernel bake hook. Replaces the OPi5Max-specific
          # __999_orangepi5max_localcmd hook from #82. The dispatch table
          # below is templated by Ansible from vars/boards.yml at playbook
          # run time — adding a new board to local_kernel means adding a
          # local_kernel:{storage,storage_scan} block to its entry in
          # vars/boards.yml, not editing this hook.
          #
          # Approach B per #82's LK1 evidence — explicit ext4load + booti
          # because U-Boot bootstd's bootflow scan skips
          # disk_provision-generated GPT partitions carrying the systemd-
          # repart "GrowFs" attribute bit 59. See the closing notes in
          # docs/superpowers/specs/2026-05-17-localboot-nvme-kernel-design.md
          # for the rationale; this hook just makes the mechanism board-
          # agnostic.
          #
          # Idempotent: the literal `localcmd=setenv bootargs root=LABEL=`
          # substring is the marker; repeat builds against a cached tree
          # skip the insert. Post-condition grep defends against a silent
          # sed no-op (matched-0-lines).
          function pre_config_uboot_target__999_local_kernel_bake() {
              [[ "${BRANCH}" != "edge" ]] && return 0

              declare -A LOCAL_KERNEL_CHAIN=(
          {{ _local_kernel_dispatch_table | trim }}
              )

              local chain="${LOCAL_KERNEL_CHAIN[${BOARD}]:-}"
              [[ -z "${chain}" ]] && return 0   # board doesn't opt into local_kernel

              # Locate CFG_EXTRA_ENV_SETTINGS in rk3588_common.h (fall
              # back to CONFIG_-prefixed for pre-v2024.01 trees).
              local header marker
              if [[ -f include/configs/rk3588_common.h ]] \
                 && grep -qE '^[[:space:]]*#define[[:space:]]+(CFG_|CONFIG_)EXTRA_ENV_SETTINGS' include/configs/rk3588_common.h; then
                  header=include/configs/rk3588_common.h
              else
                  header="$(grep -lE '^[[:space:]]*#define[[:space:]]+(CFG_|CONFIG_)EXTRA_ENV_SETTINGS' include/configs/rk3588*.h 2>/dev/null | head -n 1)"
              fi
              if [[ -z "${header}" ]]; then
                  exit_with_error "${BOARD}: no EXTRA_ENV_SETTINGS in include/configs/rk3588*.h — upstream changed; fix __999_local_kernel_bake"
              fi
              if grep -q '^[[:space:]]*#define[[:space:]]\+CFG_EXTRA_ENV_SETTINGS' "${header}"; then
                  marker='^[[:space:]]*#define[[:space:]]\+CFG_EXTRA_ENV_SETTINGS'
              else
                  marker='^[[:space:]]*#define[[:space:]]\+CONFIG_EXTRA_ENV_SETTINGS'
              fi
              display_alert "${BOARD}" "localcmd target macro found in ${header}" "info"

              # Idempotency: skip if any localcmd marker is already present.
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
                  exit_with_error "${BOARD}: localcmd bake silently failed — marker matched 0 lines in ${header}"
              fi

              display_alert "${BOARD}" "baked local_kernel localcmd chain into U-Boot default env" "info"
          }
```

- [ ] **Step 4: Lint-check the playbook**

```bash
make yamllint
make ansible-lint
```

Expected: both pass. If ansible-lint complains about Jinja-in-Bash escaping, double-check that the `{{ _local_kernel_dispatch_table | trim }}` expression renders inside the YAML literal block scalar; the dispatch_table fact is a multi-line string that lands inside the Bash `declare -A` block.

- [ ] **Step 5: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "build_image: replace OPi5Max-specific hook with generic dispatch"
```

---

### Task 5: Add env-storage assertion hook

**Files:**
- Modify: `playbooks/build_image.yml` (extend `build_userpatches_common`)

The hook validates that the U-Boot defconfig's `CONFIG_ENV_IS_*=y` matches `vars/boards.yml`'s declared `uboot_env.storage` for the board, failing the build on drift.

- [ ] **Step 1: Add a render task for the expected-storage table**

In `playbooks/build_image.yml`'s `pre_tasks:`, after the dispatch table render (Task 4 Step 2), add:

```yaml
    - name: Render expected uboot_env.storage table for the assertion hook
      ansible.builtin.set_fact:
        _uboot_env_storage_table: |
          {% for board_model in _board_models %}
          {% set cfg = armbian_board_configs[board_model] %}
          {% if cfg.uboot_env is defined %}
              [{{ cfg.armbian_board_name }}]='{{ cfg.uboot_env.storage }}'
          {% endif %}
          {% endfor %}
```

- [ ] **Step 2: Add the assertion hook to `build_userpatches_common`**

After the generic local_kernel hook (Task 4 Step 3), inside the same `dest: "config/sources/families/rockchip-rk3588.conf"` content block, append:

```bash
          # Defconfig-vs-vars/boards.yml env-storage drift check.
          # Runs after defconfig is laid down. Greps the finalized
          # defconfig (configs/${BOOTCONFIG}) for CONFIG_ENV_IS_*=y,
          # maps the match to {nowhere, spi_flash, mmc}, compares to the
          # expected value from vars/boards.yml. Mismatch fails the build
          # loudly so drift can't ship silently.
          function pre_config_uboot_target__999_uboot_env_check() {
              declare -A EXPECTED_STORAGE=(
          {{ _uboot_env_storage_table | trim }}
              )
              local expected="${EXPECTED_STORAGE[${BOARD}]:-}"
              [[ -z "${expected}" ]] && return 0    # board has no uboot_env block; skip

              local defconfig="configs/${BOOTCONFIG}"
              if [[ ! -f "${defconfig}" ]]; then
                  display_alert "${BOARD}" "defconfig ${defconfig} not present; skip uboot_env check" "wrn"
                  return 0
              fi

              local discovered=""
              if grep -q '^CONFIG_ENV_IS_NOWHERE=y' "${defconfig}"; then
                  discovered=nowhere
              elif grep -q '^CONFIG_ENV_IS_IN_SPI_FLASH=y' "${defconfig}"; then
                  discovered=spi_flash
              elif grep -q '^CONFIG_ENV_IS_IN_MMC=y' "${defconfig}"; then
                  discovered=mmc
              fi

              if [[ -z "${discovered}" ]]; then
                  exit_with_error "${BOARD}: no CONFIG_ENV_IS_{NOWHERE,IN_SPI_FLASH,IN_MMC}=y in ${defconfig}; extend the check"
              fi

              if [[ "${discovered}" != "${expected}" ]]; then
                  exit_with_error "${BOARD}: defconfig reports CONFIG_ENV_IS_${discovered^^}=y but vars/boards.yml says uboot_env.storage=${expected}"
              fi

              display_alert "${BOARD}" "uboot_env.storage matches defconfig (${discovered})" "info"
          }
```

- [ ] **Step 3: Lint and commit**

```bash
make yamllint
make ansible-lint
git add playbooks/build_image.yml
git commit -m "build_image: assert uboot_env.storage matches defconfig"
```

---

### Task 6: Extract dict composition from `persist_uboot_env.yml`

**Files:**
- Create: `playbooks/tasks/compose_uboot_env_vars.yml`

The composition logic moves to a tasks-file include so it's callable from molecule for the precedence test (Task 7) without running `fw_setenv`.

- [ ] **Step 1: Write the composition tasks file**

Create `playbooks/tasks/compose_uboot_env_vars.yml`:

```yaml
---
# Compose the per-host uboot_env_vars dict from three sources in this
# precedence (low → high):
#   1. armbian_board_configs[<model>].uboot_env.defaults
#      (board static SPI defaults, e.g. rock-5b's addr_r vars)
#   2. Collection-managed keys: ethaddr (from armbian_board_mac),
#      and localcmd (rendered, only when persist_via == 'spi')
#   3. armbian_uboot_env_extra (operator escape hatch; wins)
#
# Output (registered fact): _uboot_env_vars — flat dict of name→value.
#
# Inputs (must be defined on the host before include):
#   armbian_board_model — model key for vars/boards.yml lookup
#   armbian_board_mac — colon-separated MAC
#   armbian_board_configs — usually from vars/boards.yml
#   armbian_boot_mode — 'local_kernel' triggers localcmd render
#   armbian_local_kernel — optional dict with .persist_via and overrides
#   armbian_uboot_env_extra — optional flat dict
- name: Pull board config for this host
  ansible.builtin.set_fact:
    _board_cfg: "{{ armbian_board_configs[armbian_board_model] }}"

- name: Source 1 — board defaults
  ansible.builtin.set_fact:
    _src1: "{{ _board_cfg.uboot_env.defaults | default({}) }}"

- name: Source 2a — collection-managed ethaddr
  ansible.builtin.set_fact:
    _src2_ethaddr:
      ethaddr: "{{ armbian_board_mac | lower }}"

- name: Source 2b — collection-managed localcmd (only when persist_via == spi)
  vars:
    _localcmd_chain: >-
      {%- from playbook_dir + '/../roles/image_build/templates/render_localcmd_chain.j2' import render_localcmd_chain -%}
      {{ render_localcmd_chain(_board_cfg, armbian_local_kernel | default({})) }}
  ansible.builtin.set_fact:
    _src2_localcmd:
      localcmd: "{{ _localcmd_chain }}"
  when:
    - armbian_boot_mode | default('') == 'local_kernel'
    - (armbian_local_kernel.persist_via | default('hook')) == 'spi'

- name: Source 2 — combined collection-managed keys
  ansible.builtin.set_fact:
    _src2: "{{ _src2_ethaddr | combine(_src2_localcmd | default({})) }}"

- name: Source 3 — operator escape hatch
  ansible.builtin.set_fact:
    _src3: "{{ armbian_uboot_env_extra | default({}) }}"

- name: Compose final dict in precedence order
  ansible.builtin.set_fact:
    _uboot_env_vars: "{{ _src1 | combine(_src2) | combine(_src3) }}"
```

- [ ] **Step 2: Commit**

```bash
git add playbooks/tasks/compose_uboot_env_vars.yml
git commit -m "playbooks/tasks: extract uboot_env_vars composition"
```

---

### Task 7: Molecule scenario — persist_uboot_env precedence (Layer 1)

**Files:**
- Create: `extensions/molecule/persist_uboot_env/molecule.yml`
- Create: `extensions/molecule/persist_uboot_env/converge.yml`
- Create: `extensions/molecule/persist_uboot_env/verify.yml`

Tests the dict-composition precedence requirement the user explicitly called for. Uses `compose_uboot_env_vars.yml` directly, so no real `fw_setenv` runs.

- [ ] **Step 1: Write `molecule.yml`**

```yaml
---
dependency:
  name: galaxy
driver:
  name: default
  options:
    managed: true
    ansible_connection_options:
      connection: local
platforms:
  - name: persist_uboot_env
    image: registry.fedoraproject.org/fedora:latest
    pre_build_image: true
provisioner:
  name: ansible
  playbooks:
    converge: converge.yml
    verify: verify.yml
verifier:
  name: ansible
scenario:
  name: persist_uboot_env
  test_sequence:
    - dependency
    - syntax
    - create
    - converge
    - verify
    - destroy
```

- [ ] **Step 2: Write `converge.yml`**

```yaml
---
- name: Converge — compose uboot_env_vars for three fixture hosts
  hosts: all
  gather_facts: false
  become: false
  vars:
    # Fixture: rock-5b-style board with full uboot_env block.
    armbian_board_configs:
      rock-5b:
        armbian_dl_dir: rock-5b
        armbian_board_name: rock-5b
        armbian_support: standard
        dtb: rockchip/rk3588-rock-5b.dtb
        console: ttyS2,1500000n8
        earlycon: uart8250,mmio32,0xfeb50000
        local_kernel:
          storage: "nvme 0:4"
          storage_scan: "nvme scan"
        uboot_env:
          storage: spi_flash
          fw_env_config:
            device: /dev/mtd0
            offset:    "0xc00000"
            size:      "0x20000"
            sect_size: "0x1000"
          defaults:
            pxefile_addr_r: "0x00500000"
            kernel_addr_r:  "0x02080000"
            ramdisk_addr_r: "0x06000000"
            fdt_addr_r:     "0x08000000"
            scriptaddr:     "0x00c00000"
            bootmeths:      "pxe extlinux script efi"
      # NOWHERE board (negative-path check)
      orange-pi-5-max:
        armbian_dl_dir: orangepi5-max
        armbian_board_name: orangepi5-max
        armbian_support: community
        dtb: rockchip/rk3588-orangepi-5-max.dtb
        console: ttyS2,1500000n8
        earlycon: uart8250,mmio32,0xfeb50000
        local_kernel:
          storage: "nvme 0:4"
          storage_scan: "nvme scan"
        uboot_env:
          storage: nowhere

  tasks:
    # ===== Host A: override host. _extra overrides bootmeths,
    #       ethaddr, and localcmd. =====
    - name: HOST A — set host vars (override)
      ansible.builtin.set_fact:
        armbian_board_model: rock-5b
        armbian_board_mac: "00:E0:4C:68:00:3B"
        armbian_boot_mode: local_kernel
        armbian_local_kernel:
          persist_via: spi
        armbian_uboot_env_extra:
          bootmeths: "pxe extlinux"           # override board default
          ethaddr: "aa:bb:cc:dd:ee:ff"        # override collection-managed
          localcmd: "echo custom localcmd"    # override structured render

    - name: HOST A — compose
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../../playbooks/tasks/compose_uboot_env_vars.yml"

    - name: HOST A — snapshot composed dict for verify
      ansible.builtin.copy:
        content: "{{ _uboot_env_vars | to_nice_yaml }}"
        dest: /tmp/host_a.yml
        mode: "0644"

    # ===== Host B: control. No _extra. =====
    - name: HOST B — reset host vars (control)
      ansible.builtin.set_fact:
        armbian_board_model: rock-5b
        armbian_board_mac: "00:E0:4C:68:00:3B"
        armbian_boot_mode: local_kernel
        armbian_local_kernel:
          persist_via: spi
        armbian_uboot_env_extra: {}
        # also clear any per-host previously-computed facts
        _uboot_env_vars: null
        _src2_localcmd: null

    - name: HOST B — compose
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../../playbooks/tasks/compose_uboot_env_vars.yml"

    - name: HOST B — snapshot
      ansible.builtin.copy:
        content: "{{ _uboot_env_vars | to_nice_yaml }}"
        dest: /tmp/host_b.yml
        mode: "0644"

    # ===== Host C: persist_via=hook on the same SPI board — no localcmd. =====
    - name: HOST C — reset host vars (hook persist)
      ansible.builtin.set_fact:
        armbian_board_model: rock-5b
        armbian_board_mac: "00:E0:4C:68:00:3B"
        armbian_boot_mode: local_kernel
        armbian_local_kernel:
          persist_via: hook
        armbian_uboot_env_extra: {}
        _uboot_env_vars: null
        _src2_localcmd: null

    - name: HOST C — compose
      ansible.builtin.include_tasks: "{{ playbook_dir }}/../../../playbooks/tasks/compose_uboot_env_vars.yml"

    - name: HOST C — snapshot
      ansible.builtin.copy:
        content: "{{ _uboot_env_vars | to_nice_yaml }}"
        dest: /tmp/host_c.yml
        mode: "0644"
```

- [ ] **Step 3: Write `verify.yml`**

```yaml
---
- name: Verify — precedence of uboot_env_vars composition
  hosts: all
  gather_facts: false
  become: false

  tasks:
    - name: Load Host A composed dict
      ansible.builtin.slurp:
        src: /tmp/host_a.yml
      register: _a_raw
    - name: Load Host B composed dict
      ansible.builtin.slurp:
        src: /tmp/host_b.yml
      register: _b_raw
    - name: Load Host C composed dict
      ansible.builtin.slurp:
        src: /tmp/host_c.yml
      register: _c_raw

    - name: Parse all three
      ansible.builtin.set_fact:
        _a: "{{ _a_raw.content | b64decode | from_yaml }}"
        _b: "{{ _b_raw.content | b64decode | from_yaml }}"
        _c: "{{ _c_raw.content | b64decode | from_yaml }}"

    # ===== HOST A: _extra overrides win =====
    - name: HOST A — _extra.bootmeths wins over board default
      ansible.builtin.assert:
        that:
          - _a.bootmeths == 'pxe extlinux'
        fail_msg: "_extra override of bootmeths did NOT win. Got: {{ _a.bootmeths }}"

    - name: HOST A — _extra.ethaddr wins over MAC-derived
      ansible.builtin.assert:
        that:
          - _a.ethaddr == 'aa:bb:cc:dd:ee:ff'
        fail_msg: "_extra override of ethaddr did NOT win. Got: {{ _a.ethaddr }}"

    - name: HOST A — _extra.localcmd wins over structured render
      ansible.builtin.assert:
        that:
          - _a.localcmd == 'echo custom localcmd'
        fail_msg: "_extra override of localcmd did NOT win. Got: {{ _a.localcmd }}"

    - name: HOST A — non-overridden board defaults still present
      ansible.builtin.assert:
        that:
          - _a.pxefile_addr_r == '0x00500000'
          - _a.kernel_addr_r == '0x02080000'

    # ===== HOST B: control — collection defaults + structured render =====
    - name: HOST B — ethaddr derived from board MAC (lowercased)
      ansible.builtin.assert:
        that:
          - _b.ethaddr == '00:e0:4c:68:00:3b'

    - name: HOST B — localcmd rendered from local_kernel block
      ansible.builtin.assert:
        that:
          - "'rockchip/rk3588-rock-5b.dtb' in _b.localcmd"
          - "'nvme 0:4' in _b.localcmd"
          - "'root=LABEL=armbi_root_local' in _b.localcmd"

    - name: HOST B — board defaults present, _extra absent
      ansible.builtin.assert:
        that:
          - _b.bootmeths == 'pxe extlinux script efi'   # board default
          - _b.pxefile_addr_r == '0x00500000'

    # ===== HOST C: persist_via=hook — NO localcmd key =====
    - name: HOST C — localcmd NOT present when persist_via=hook
      ansible.builtin.assert:
        that:
          - "'localcmd' not in _c"
        fail_msg: "Hook-mode host should not have a localcmd key in composed dict. Got: {{ _c }}"

    - name: HOST C — ethaddr + board defaults still present
      ansible.builtin.assert:
        that:
          - _c.ethaddr == '00:e0:4c:68:00:3b'
          - _c.bootmeths == 'pxe extlinux script efi'
```

- [ ] **Step 4: Run the scenario**

```bash
make molecule SCENARIO=persist_uboot_env
```

Expected: all assertions in verify pass. If any fail, the compose tasks file's precedence is wrong — fix `playbooks/tasks/compose_uboot_env_vars.yml` Step 1.

- [ ] **Step 5: Update Makefile MOLECULE_SCENARIOS list**

Edit `Makefile`:

```makefile
MOLECULE_SCENARIOS := default rootfs_clone pxelinux_render image_build local_kernel_render persist_uboot_env
```

- [ ] **Step 6: Commit**

```bash
git add Makefile extensions/molecule/persist_uboot_env/
git commit -m "molecule: persist_uboot_env precedence scenario"
```

---

### Task 8: Rewrite `persist_uboot_env.yml` for board-agnostic operation

**Files:**
- Modify: `playbooks/persist_uboot_env.yml`

- [ ] **Step 1: Rewrite the play header and skip-semantics**

Replace the existing playbook with:

```yaml
---
# Persist per-host U-Boot env state to SPI flash via fw_setenv. Generalized
# from the rock-5b-specific Approach B (per #82's design). Any board whose
# vars/boards.yml entry declares uboot_env.storage: spi_flash gets convergence;
# NOWHERE boards (e.g. opi5max) skip silently.
#
# Composes the per-host uboot_env_vars dict from three sources in precedence
# order (board defaults → collection-managed → operator _extra). See
# playbooks/tasks/compose_uboot_env_vars.yml.
#
# Cold-cycle ownership: when run standalone, this play cold-cycles on drift.
# When imported by converge_boot_mode.yml, the converge play sets
# armbian_persist_uboot_env_cycle: false and owns the cycle in step 4.
#
# Prerequisites:
#   - Board must boot to Linux (this play SSHes in to run fw_setenv).
#   - playbooks/bootstrap_armbian.yml must have run.
#   - inventory hostvars: armbian_board_mac (mandatory),
#     armbian_poe_switch + armbian_poe_port (mandatory for
#     the cold-cycle handler).
#
# Usage (standalone):
#   ansible-playbook playbooks/persist_uboot_env.yml
#   ansible-playbook playbooks/persist_uboot_env.yml --limit rock-5b-01
#   ansible-playbook playbooks/persist_uboot_env.yml --skip-tags cold_cycle

- name: Persist U-Boot env vars to SPI on SPI-flash boards
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    armbian_persist_uboot_env_cycle: true
    armbian_uboot_env_extra: "{{ armbian_uboot_env_extra | default({}) }}"

  pre_tasks:
    - name: Load board configs (needed for per-host lookups)
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

    - name: Skip hosts whose board has no SPI flash env
      ansible.builtin.meta: end_host
      when: >-
        armbian_board_configs[armbian_board_model].uboot_env.storage
        | default('nowhere') != 'spi_flash'

    - name: Validate persist_via against board env storage
      ansible.builtin.assert:
        that:
          - >-
            (armbian_local_kernel.persist_via | default('hook')) == 'hook'
            or armbian_board_configs[armbian_board_model].uboot_env.storage == 'spi_flash'
        fail_msg: >-
          {{ inventory_hostname }}: local_kernel.persist_via=spi but board
          {{ armbian_board_model }} uboot_env.storage={{
            armbian_board_configs[armbian_board_model].uboot_env.storage }};
          change persist_via to 'hook' or pick a board with SPI env.

    - name: Validate fw_env_config completeness when persist_via=spi
      ansible.builtin.assert:
        that:
          - >-
            armbian_board_configs[armbian_board_model].uboot_env.fw_env_config.device is defined
          - >-
            armbian_board_configs[armbian_board_model].uboot_env.fw_env_config.offset is defined
          - >-
            armbian_board_configs[armbian_board_model].uboot_env.fw_env_config.size is defined
          - >-
            armbian_board_configs[armbian_board_model].uboot_env.fw_env_config.sect_size is defined
        fail_msg: >-
          {{ inventory_hostname }}: uboot_env.fw_env_config missing required keys
          (device/offset/size/sect_size) for SPI persistence.

    - name: Assert per-host armbian_board_mac is defined and well-formed
      ansible.builtin.assert:
        that:
          - armbian_board_mac is defined
          - armbian_board_mac | length > 0
          - armbian_board_mac is match('^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
        fail_msg: >-
          armbian_board_mac must be set on {{ inventory_hostname }} as a
          colon-separated hex MAC (xx:xx:xx:xx:xx:xx). Got:
          '{{ armbian_board_mac | default("<undefined>") }}'.

    - name: Gather date facts for snapshot filename
      ansible.builtin.setup:
        gather_subset:
          - "!all"
          - "!min"
          - date_time

    - name: Compose per-host uboot_env_vars
      ansible.builtin.include_tasks: tasks/compose_uboot_env_vars.yml

    - name: Render per-host fw_env_config string
      ansible.builtin.set_fact:
        _fw_env_config_str: >-
          {{ _board_cfg.uboot_env.fw_env_config.device }}    {{
             _board_cfg.uboot_env.fw_env_config.offset }}    {{
             _board_cfg.uboot_env.fw_env_config.size }}    {{
             _board_cfg.uboot_env.fw_env_config.sect_size }}

  tasks:
    - name: Ensure u-boot-tools is installed
      become: true
      ansible.builtin.apt:
        name: u-boot-tools
        state: present

    - name: Ensure /etc/fw_env.config matches the board's SPI env layout
      become: true
      ansible.builtin.copy:
        dest: /etc/fw_env.config
        content: "{{ _fw_env_config_str }}\n"
        owner: root
        group: root
        mode: "0644"

    - name: Ensure /var/backups exists for env snapshot
      become: true
      ansible.builtin.file:
        path: /var/backups
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Snapshot current U-Boot env before mutating
      become: true
      ansible.builtin.shell:
        cmd: >-
          fw_printenv >
          /var/backups/uboot-env-{{ ansible_facts.date_time.iso8601_basic_short }}.bak
        creates: "/var/backups/uboot-env-{{ ansible_facts.date_time.iso8601_basic_short }}.bak"

    - name: Read each U-Boot env var currently in SPI
      become: true
      ansible.builtin.command:
        cmd: "fw_printenv -n {{ item.key }}"
      register: _current_env
      changed_when: false
      failed_when: false
      loop: "{{ _uboot_env_vars | dict2items }}"
      loop_control:
        label: "{{ item.key }}"

    - name: Persist each drifted U-Boot env var to SPI
      become: true
      ansible.builtin.command:
        argv:
          - fw_setenv
          - "{{ item.0.key }}"
          - "{{ item.0.value }}"
      when: (item.1.stdout | default('') | lower) != (item.0.value | lower)
      loop: "{{ _uboot_env_vars | dict2items | zip(_current_env.results) | list }}"
      loop_control:
        label: "{{ item.0.key }}"
      register: _set_results
      changed_when: true

    - name: Cold-cycle the board when any env var drifted (standalone only)
      ansible.builtin.include_tasks: "{{ armbian_poe_cycle_tasks_file | default('routeros/tasks/poe_cycle.yml') }}"
      when:
        - _set_results.results | selectattr('changed') | list | length > 0
        - armbian_persist_uboot_env_cycle | bool
      tags: cold_cycle
```

- [ ] **Step 2: Lint**

```bash
make yamllint
make ansible-lint
```

Expected: both pass.

- [ ] **Step 3: Re-run the precedence molecule scenario**

```bash
make molecule SCENARIO=persist_uboot_env
```

Expected: still passes (the scenario tests `compose_uboot_env_vars.yml` directly, but a smoke-syntax check on the play is good).

- [ ] **Step 4: Commit**

```bash
git add playbooks/persist_uboot_env.yml
git commit -m "persist_uboot_env: generalize to any spi_flash board"
```

---

### Task 9: Add boot-mode validation tasks file

**Files:**
- Create: `playbooks/tasks/validate_local_kernel.yml`

The Section-1 fail-fast validation gates an operator who declares `boot_mode: local_kernel` on a board that doesn't support it. Called by `converge_boot_mode.yml` at entry.

- [ ] **Step 1: Write the validation tasks file**

Create `playbooks/tasks/validate_local_kernel.yml`:

```yaml
---
# Validate per-host local_kernel inventory consistency. Called by
# converge_boot_mode.yml at entry (gated to hosts where boot_mode ==
# local_kernel). Fails fast with operator-friendly messages.

- name: Validate board supports local_kernel mode
  ansible.builtin.assert:
    that:
      - armbian_board_configs[armbian_board_model].local_kernel is defined
    fail_msg: >-
      {{ inventory_hostname }}: boot_mode=local_kernel but board
      {{ armbian_board_model }} has no local_kernel block in
      vars/boards.yml. Either pick a different boot_mode or add a
      local_kernel:{storage,storage_scan} block to vars/boards.yml.

- name: Validate persist_via against board env storage
  vars:
    _persist_via: "{{ armbian_local_kernel.persist_via | default('hook') }}"
    _env_storage: "{{ armbian_board_configs[armbian_board_model].uboot_env.storage | default('nowhere') }}"
  ansible.builtin.assert:
    that:
      - _persist_via != 'spi' or _env_storage == 'spi_flash'
    fail_msg: >-
      {{ inventory_hostname }}: local_kernel.persist_via=spi but board
      {{ armbian_board_model }} uboot_env.storage={{ _env_storage }};
      change persist_via to 'hook' or pick a board with SPI env.

- name: Validate fw_env_config is complete when persist_via=spi
  vars:
    _persist_via: "{{ armbian_local_kernel.persist_via | default('hook') }}"
    _fw: "{{ armbian_board_configs[armbian_board_model].uboot_env.fw_env_config | default({}) }}"
  ansible.builtin.assert:
    that:
      - _persist_via != 'spi' or (_fw.device is defined and _fw.offset is defined and _fw.size is defined and _fw.sect_size is defined)
    fail_msg: >-
      {{ inventory_hostname }}: uboot_env.fw_env_config missing required keys
      (device/offset/size/sect_size). Required when persist_via=spi.
```

- [ ] **Step 2: Lint and commit**

```bash
make yamllint
make ansible-lint
git add playbooks/tasks/validate_local_kernel.yml
git commit -m "playbooks/tasks: add local_kernel inventory validation"
```

---

### Task 10: Wire persist into `converge_boot_mode.yml`

**Files:**
- Modify: `playbooks/converge_boot_mode.yml`

- [ ] **Step 1: Read the current `converge_boot_mode.yml` to confirm its play structure**

```bash
cat playbooks/converge_boot_mode.yml | head -80
```

Confirm the existing four-play composition (plumbing-check, pxelinux render, upload, cycle+wait+verify). Section 4 of the spec lists step ordering; the new step 3.5 goes between upload (play 3) and cycle (play 4).

- [ ] **Step 2: Insert a validation play at the top (before plumbing-check)**

In `playbooks/converge_boot_mode.yml`, add a new play at the very start:

```yaml
- name: Validate local_kernel inventory consistency
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    armbian_local_kernel: "{{ armbian_local_kernel | default({}) }}"
  tasks:
    - name: Load board configs
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

    - name: Run local_kernel validation (gated to local_kernel hosts)
      ansible.builtin.include_tasks: tasks/validate_local_kernel.yml
      when: armbian_boot_mode == 'local_kernel'
```

- [ ] **Step 3: Insert the persist step between upload (play 3) and cold-boot (play 4)**

In `playbooks/converge_boot_mode.yml`, after the upload play and before the cold-boot/wait play, insert:

```yaml
- name: Persist U-Boot SPI env for local_kernel + spi hosts
  ansible.builtin.import_playbook: persist_uboot_env.yml
  vars:
    armbian_persist_uboot_env_cycle: false
  when: (armbian_persist_uboot_env | default('auto')) != 'never'
```

Note: `armbian_persist_uboot_env_cycle: false` transfers cycle ownership to converge's step 4. The persist play's own filter (`uboot_env.storage == spi_flash`) handles per-host skipping; the playbook-level `when:` is the global escape hatch.

- [ ] **Step 4: Lint**

```bash
make yamllint
make ansible-lint
```

Expected: both pass.

- [ ] **Step 5: Smoke-test against current inventory (no hardware change yet)**

Run the play in `--check` mode against opi5max-01 (still on `local_kernel + hook`):

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-max-01 --check
```

Expected: no validation failures; persist step is silently skipped for the opi5max host (NOWHERE board, `meta: end_host` fires).

- [ ] **Step 6: Commit**

```bash
git add playbooks/converge_boot_mode.yml
git commit -m "converge_boot_mode: validate + persist as pre-steps to cold-boot"
```

---

### Task 11: Update `inventory/group_vars/all.yml` documentation

**Files:**
- Modify: `inventory/group_vars/all.yml`

- [ ] **Step 1: Read the current file**

```bash
cat inventory/group_vars/all.yml
```

- [ ] **Step 2: Append documentation for the new variables**

At the end of `inventory/group_vars/all.yml`, append:

```yaml
# ---------------------------------------------------------------------
# local_kernel mode (per host)
# ---------------------------------------------------------------------
# Opt a host into local_kernel mode by setting:
#   armbian_boot_mode: local_kernel
# and an optional override block:
#   armbian_local_kernel:
#     persist_via: hook       # 'hook' (default) | 'spi'
#     # storage: "nvme 0:4"   # default from vars/boards.yml's local_kernel.storage
#     # storage_scan: "nvme scan"
#     # root_label: armbi_root_local
#
# persist_via:
#   hook — use the U-Boot binary's compile-time default localcmd (baked
#          by playbooks/build_image.yml's __999_local_kernel_bake hook).
#          No runtime fw_setenv step. Default.
#   spi  — write per-host localcmd to SPI via fw_setenv at convergence
#          time. Only valid on boards with uboot_env.storage: spi_flash.
#
# armbian_uboot_env_extra (escape hatch, host or group scope):
#   Flat dict of arbitrary U-Boot env vars merged into the converged
#   set with highest precedence. Can override anything in
#   uboot_env.defaults, ethaddr derived from board_mac, or the
#   collection-rendered localcmd. Documented as "you own what you
#   override."
#
# armbian_persist_uboot_env (playbook-level knob):
#   auto    — default; run step 3.5 for hosts where uboot_env.storage
#             == spi_flash.
#   always  — run step 3.5 unconditionally (no-op on NOWHERE hosts).
#   never   — skip step 3.5 entirely.
```

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/all.yml
git commit -m "inventory: document local_kernel + uboot_env_extra variables"
```

---

### Task 12: Update `roles/image_build/meta/argument_specs.yml`

**Files:**
- Modify: `roles/image_build/meta/argument_specs.yml`

- [ ] **Step 1: Check the current schema**

```bash
cat roles/image_build/meta/argument_specs.yml
```

- [ ] **Step 2: Document the per-board `local_kernel` and `uboot_env` blocks**

The role doesn't directly consume these blocks (they're consumed by `playbooks/build_image.yml`'s pre_tasks), but document them in the role's schema as expected inputs for the playbook-level wrapper. Append a "Notes" section or a free-text description block to the existing options describing the new fields.

If `argument_specs.yml` doesn't have a natural slot for free-text docs, add a top-of-file YAML comment block:

```yaml
---
# image_build expects callers to pre-render the local_kernel dispatch
# table into _local_kernel_dispatch_table and _uboot_env_storage_table
# (see playbooks/build_image.yml's pre_tasks). These facts are
# templated into build_userpatches_common's __999_local_kernel_bake
# and __999_uboot_env_check hooks at playbook run time. See the spec
# at docs/superpowers/specs/2026-05-18-local-kernel-generalization-design.md.
```

- [ ] **Step 3: Commit**

```bash
git add roles/image_build/meta/argument_specs.yml
git commit -m "image_build: document local_kernel/uboot_env preconditions"
```

---

### Task 13: Update `inventory/hosts.yml` sample to match real inventory shape

**Files:**
- Modify: `inventory/hosts.yml`

The doc-only inventory must illustrate the new shape (`armbian_local_kernel` + `armbian_local_disks`) so a new user reading the example knows what to declare.

- [ ] **Step 1: Update the existing example host**

Edit `inventory/hosts.yml`. For the `orange-pi-5-pro` example host, set `armbian_boot_mode: local_kernel`, add `armbian_local_kernel: { persist_via: hook }`, and add the `armbian_local_disks` block (same shape as real inventory uses for opi5max-01 in `.inventory/inventory.yaml`).

- [ ] **Step 2: Run yamllint and commit**

```bash
make yamllint
git add inventory/hosts.yml
git commit -m "inventory(sample): show local_kernel + local_disks shape"
```

---

### Task 14: Phase 1 end-to-end lint + molecule

**Files:** (none — verification only)

- [ ] **Step 1: Full lint pass**

```bash
make lint
```

Expected: yamllint + ansible-lint both green across `roles/`, `playbooks/`, `inventory/`.

- [ ] **Step 2: Full molecule pass (skip slow image_build kubevirt scenario)**

```bash
for s in default rootfs_clone pxelinux_render local_kernel_render persist_uboot_env; do
  make molecule SCENARIO=$s || { echo "FAIL: $s"; exit 1; }
done
```

Expected: all five scenarios pass. (The slow `image_build` kubevirt scenario is not part of standard CI; run it manually if there's any concern that the renamed hook breaks a real build — but Task 4's lint pass should already catch that.)

- [ ] **Step 3: Tag Phase 1 complete**

```bash
git tag -a phase1-mechanism-complete -m "local_kernel generalization: mechanism phase complete (no hardware verified yet)"
```

Phase 1 is complete. Mechanism is fully verified in CI; hardware bring-up follows in Phase 2.

---

## Phase 2 — Inventory rollout + hardware bring-up

Each board in Phase 2 follows this sequence: inventory edit → build image → reflash → bring up on existing mode (usually `nfs`) → run `reprovision_to_local.yml` → converge to `local_kernel` → verify. Use the `testing-armbian-board-hardware` skill for per-iteration evidence capture on the board-tracker issues.

### Task 15: Update real inventory for all 4 boards

**Files:**
- Modify: `.inventory/inventory.yaml`

Update all four hosts in one edit so subsequent build steps pick up the full target state.

- [ ] **Step 1: Verify ANSIBLE_INVENTORY is pointing at `.inventory/`**

```bash
echo "$ANSIBLE_INVENTORY"
test -f /workspace/ansible-collection-armbian_netboot/.inventory/inventory.yaml && echo OK
```

Expected: prints `.inventory` (or absolute path to it); file exists.

- [ ] **Step 2: Add `armbian_local_kernel` + `armbian_local_disks` to opi5pro-01**

Edit `.inventory/inventory.yaml`. Replace the existing opi5pro-01 entry (currently lines ~88-96) with:

```yaml
    orange_pi_5_pro:
      hosts:
        opi5pro-01.igou.systems:
          ansible_host: opi5pro-01.igou.systems
          armbian_board_mac: "C0:74:2B:FB:4D:FD"
          armbian_board_model: orange-pi-5-pro
          armbian_boot_mode: local_kernel
          armbian_local_kernel:
            persist_via: hook
          armbian_poe_switch: crs328.igou.systems
          armbian_poe_port: ether7
          armbian_local_disks:
            - device: /dev/nvme0n1
              wipe: true
              layout:
                - id: var
                  size: 20GiB
                  type: var
                  format: ext4
                  label: armbi_var
                  mount: /var
                  preserve_on_reprovision: true
                - id: root
                  size: grow
                  type: root
                  format: ext4
                  label: armbi_root_local
                  mount: /
```

- [ ] **Step 3: Apply the same shape to rock-5b-01 with `persist_via: spi`**

Replace the rock-5b-01 entry. Note the `persist_via: spi`:

```yaml
    rock_5b:
      hosts:
        rock-5b-01.igou.systems:
          ansible_host: rock-5b-01.igou.systems
          armbian_board_mac: "00:E0:4C:68:00:3B"
          armbian_board_model: rock-5b
          armbian_boot_mode: local_kernel
          armbian_local_kernel:
            persist_via: spi
          armbian_poe_switch: crs328.igou.systems
          armbian_poe_port: ether9
          armbian_local_disks:
            - device: /dev/nvme0n1
              wipe: true
              layout:
                - id: var
                  size: 20GiB
                  type: var
                  format: ext4
                  label: armbi_var
                  mount: /var
                  preserve_on_reprovision: true
                - id: root
                  size: grow
                  type: root
                  format: ext4
                  label: armbi_root_local
                  mount: /
```

- [ ] **Step 4: Apply the hook shape to orange-pi-5-01 and rock-5a-01**

Replace both, identical shape to opi5pro-01 except for `ansible_host`, MAC, `armbian_board_model`, PoE port. The four hosts all get `persist_via: hook` except rock-5b-01.

orange-pi-5-01 keeps MAC `D2:9C:F7:AB:F9:B0`, model `orange-pi-5`, port `ether13`.
rock-5a-01 keeps MAC `BA:50:E3:A1:44:1C`, model `rock-5a`, port `ether11`.

- [ ] **Step 5: Verify validation passes against the new inventory**

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-max-01 --check
ansible-playbook playbooks/converge_boot_mode.yml --limit opi5pro-01.igou.systems --check
ansible-playbook playbooks/converge_boot_mode.yml --limit rock-5b-01.igou.systems --check
ansible-playbook playbooks/converge_boot_mode.yml --limit rock-5a-01.igou.systems --check
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-01.igou.systems --check
```

Expected: each runs through the validation play without failure. Most subsequent steps may show changes (pxelinux to be uploaded, etc.); that's normal for `--check`. What matters: the validation play returns ok for every host, confirming inventory shape is internally consistent with `vars/boards.yml`.

- [ ] **Step 6: Commit (real inventory is gitignored, so this is a no-op in this repo; if it's tracked elsewhere, commit there)**

`.inventory/` is gitignored per CLAUDE.md. Skip git operations; just confirm the file is saved.

---

### Task 16: Build images for the four newly-onboarded boards

**Files:** (none — runs `playbooks/build_image.yml`)

- [ ] **Step 1: Run the full image build**

```bash
ansible-playbook playbooks/build_image.yml
```

Expected wall time: hours per board (real Armbian builds). The playbook iterates over `_build_targets` (all unique board models in `groups['boards']`). The new generic local_kernel bake hook fires once per build, baking that board's chain from the dispatch table. The new env-storage assertion hook also fires once per build.

Watch for `display_alert` lines containing:
- `"localcmd target macro found in include/configs/rk3588_common.h"` (per build)
- `"baked local_kernel localcmd chain into U-Boot default env"` (per build with a local_kernel row)
- `"uboot_env.storage matches defconfig (nowhere)"` or `(spi_flash)` (per build with a uboot_env row)

If the env-storage assertion fails for any board, `exit_with_error` halts the build with the mismatch message. Fix `vars/boards.yml` to match what the defconfig actually declares.

- [ ] **Step 2: Confirm images published to TrueNAS**

```bash
ssh truenas-admin@truenas.igou.systems \
  ls /mnt/ssd/public/boot-files/images/
```

Expected: 5 board directories, each containing a fresh `.img.xz`.

This is a long-running step; the user runs it out of band. No commit.

---

### Task 17: Stage netboot assets

**Files:** (none)

After new images land, the per-host NFS rootfs clones must be regenerated. Stage TFTP cache + per-host clones in one play.

- [ ] **Step 1: Run staging**

```bash
ansible-playbook playbooks/stage_netboot_assets.yml
ansible-playbook playbooks/stage_router.yml
```

Expected: per-host NFS rootfs clones refreshed with the new images. TFTP cache + router rows for kernel/initrd/dtb updated.

No commit.

---

### Task 18: Hardware bring-up — opi5max-01 regression

**Files:** (none — hardware iteration, evidence on the board-tracker issue)

opi5max-01 is already on `local_kernel`. After Task 16 rebuilds the image with the generic dispatch hook (replacing the OPi5Max-specific one), confirm the board still works.

- [ ] **Step 1: Live-dd the new image to the SD card via NFS boot**

Boot the board on `nfs` first (if not already), then from the NFS-rooted board, fetch the freshly-built image from `public.igou.systems` and `dd` it to the SD card. The board's pxelinux.cfg + U-Boot PXE-first ordering mean the next cycle still lands on PXE/NFS but using the NEW U-Boot binary (which now carries the baked localcmd).

For opi5max-01 specifically — already on `local_kernel`, so temporarily flip to `nfs`:

```bash
# Temporarily flip boot_mode in .inventory/inventory.yaml — change
# orange-pi-5-max-01's armbian_boot_mode from local_kernel to nfs,
# run converge, then SSH in to dd the new image.
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-max-01.igou.systems

ssh orange-pi-5-max-01.igou.systems \
  'curl -sSL https://public.igou.systems/boot-files/images/orange-pi-5-max/Armbian_latest.img.xz \
     | xz -dc | sudo dd of=/dev/mmcblk0 bs=4M status=progress conv=fsync'
```

Adjust the URL to the actual filename produced by Task 16 (the `latest` symlink pattern depends on how the publish step is structured — check `/mnt/ssd/public/boot-files/images/orange-pi-5-max/` for the exact path).

If `dd` fails for any reason (write error, network blip, image not where expected), fall back to a manual reflash of the SD card and continue with Step 2.

After `dd` completes, flip `boot_mode` back to `local_kernel` in inventory (for opi5max-01) before running Step 2.

- [ ] **Step 2: Boot opi5max-01 and run converge**

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit orange-pi-5-max-01.igou.systems
```

- [ ] **Step 3: Verify per `testing-armbian-board-hardware` skill**

Capture UART, `findmnt /`, `/proc/cmdline`, `uname -r`. Acceptance: matches LK1/LK2 evidence from #82's spec. Post a comment to the opi5max board-tracker issue.

- [ ] **Step 4: Optionally do an apt kernel-update sanity test**

On the running board: `sudo apt update && sudo apt install --upgrade linux-image-edge-rockchip-rk3588`. Then PoE-cycle and confirm `uname -r` reports the new version. This is the strategic acceptance criterion — verifies no regression in the "apt is the kernel update mechanism" property.

No commit.

---

### Task 19: Hardware bring-up — opi5pro-01

**Files:** (none — hardware bring-up)

- [ ] **Step 1: Build image already done in Task 16**

Confirm `/mnt/ssd/public/boot-files/images/orange-pi-5-pro/Armbian_*.img.xz` exists.

- [ ] **Step 2: Flip opi5pro-01 to `nfs` mode temporarily (current SD image still has old U-Boot)**

Edit `.inventory/inventory.yaml` opi5pro-01 entry: change `armbian_boot_mode: local_kernel` → `armbian_boot_mode: nfs`. Run:

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit opi5pro-01.igou.systems
```

Expected: board reboots into NFS root using the current (pre-update) U-Boot.

- [ ] **Step 3: Live-dd the new image to SD from the NFS-booted board**

The SD card still has the old image and old U-Boot binary (no baked localcmd). Flash the new image so the next U-Boot run has the baked localcmd dispatch table.

```bash
ssh opi5pro-01.igou.systems \
  'curl -sSL https://public.igou.systems/boot-files/images/orange-pi-5-pro/Armbian_latest.img.xz \
     | xz -dc | sudo dd of=/dev/mmcblk0 bs=4M status=progress conv=fsync'
```

Adjust the URL to the actual filename produced by Task 16 (check `/mnt/ssd/public/boot-files/images/orange-pi-5-pro/` for the published path or `latest` symlink). If `dd` fails, fall back to a manual SD reflash.

- [ ] **Step 4: PoE-cycle to load the new U-Boot**

```bash
ansible-playbook playbooks/poe_control.yml --limit opi5pro-01.igou.systems \
  -e armbian_poe_action=cycle
```

The board reboots; pxelinux.cfg still says `default nfs`, so it boots NFS-rooted again — but this time using the new U-Boot binary (with `__999_local_kernel_bake` having run at build time, so `localcmd` is baked into the compile-time default env). Wait for SSH to confirm reachability.

- [ ] **Step 5: Run reprovision_to_local against opi5pro-01**

```bash
ansible-playbook playbooks/reprovision_to_local.yml --limit opi5pro-01.igou.systems
```

Expected: NVMe wiped + repartitioned per `armbian_local_disks`; rootfs rsynced; identity reset. Per #77's disk-provision DSL behavior.

- [ ] **Step 6: Flip opi5pro-01 back to `local_kernel` and converge**

Revert `boot_mode` to `local_kernel` in inventory. Run:

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit opi5pro-01.igou.systems
```

Expected: pxelinux flips to `default local_kernel`; board PoE-cycles; U-Boot's PXE bootmeth reads pxelinux.cfg, hits `local_kernel` label → `localboot 0` → runs `$localcmd` from compile-time default → loads NVMe-resident kernel/initrd/dtb; comes up Linux-ready on NVMe root.

- [ ] **Step 7: Verify per `testing-armbian-board-hardware` skill**

UART, `findmnt /` (expect `/dev/nvme0n1p4`), `/proc/cmdline` (expect rendered bootargs, not pxelinux append), `uname -r`. Comment evidence on the opi5pro board-tracker.

No commit.

---

### Task 20: Hardware bring-up — orange-pi-5-01

**Files:** (none — hardware bring-up)

Identical to Task 19, with `orange-pi-5-01.igou.systems`. Same sequence: build done in Task 16 → flip to nfs → reprovision → flip back to local_kernel → converge → verify.

- [ ] **Step 1: Repeat Task 19 steps 2–7 for orange-pi-5-01**

Post evidence on the orange-pi-5 board-tracker.

---

### Task 21: Hardware bring-up — rock-5a-01 (NOWHERE proof point)

**Files:** (none — hardware bring-up)

rock-5a-01 is the second NOWHERE/hook proof point on a different mainline-uboot board (v2026.04 + Radxa-fork replacement, distinct from opi5max's patched v2025.04).

- [ ] **Step 1: Repeat Task 19 steps 2–7 for rock-5a-01**

Same sequence. Acceptance from the spec's Section 5 Layer 3:
- Cold-boot via `localboot 0` → ext4load from NVMe → login
- `apt install linux-image-*` + cycle picks up the new kernel

Post evidence on the rock-5a board-tracker. This is the formal acceptance for the "generalize across mainline-uboot boards" claim.

---

### Task 22: Hardware bring-up — rock-5b-01 (SPI persist proof point)

**Files:** (none — hardware bring-up. SPI-specific test additions.)

rock-5b-01 exercises the full SPI persistence pipeline: per-host `localcmd` written via fw_setenv, plus the `armbian_uboot_env_extra` override pathway.

- [ ] **Step 1: Repeat Task 19 steps 2–7 for rock-5b-01**

Note: when `boot_mode: local_kernel` AND `persist_via: spi`, step 4 of the convergence flow (step 3.5 = persist play) writes `localcmd` to SPI before the PoE cycle. UART capture should show U-Boot reading `localcmd` from SPI (not from compile-time default).

- [ ] **Step 2: Exercise `armbian_uboot_env_extra` override**

Add a host-var override to `.inventory/inventory.yaml` for rock-5b-01:

```yaml
          armbian_uboot_env_extra:
            bootdelay: "0"
```

Re-run convergence:

```bash
ansible-playbook playbooks/converge_boot_mode.yml --limit rock-5b-01.igou.systems
```

Expected: persist play drift-detects `bootdelay`, calls `fw_setenv bootdelay 0`, PoE-cycles via converge's step 4. After the cycle, on the running board:

```bash
ssh rock-5b-01.igou.systems 'sudo fw_printenv -n bootdelay'
```

Expected: `0`.

- [ ] **Step 3: Verify the override persists across a second cycle**

PoE-cycle again (out-of-band or `ansible-playbook playbooks/poe_control.yml --limit rock-5b-01.igou.systems -e armbian_poe_action=cycle`), wait for SSH, re-read `bootdelay`. Expected: still `0`.

- [ ] **Step 4: Document acceptance on the rock-5b board-tracker**

Comment on the rock-5b tracker issue: SPI persistence proven end-to-end (localcmd in SPI + `_extra` override + override persistence across cycles).

No commit.

---

### Task 23: Close #78 and #79

**Files:** (none — GitHub issue comments)

- [ ] **Step 1: Post closing comment on #78**

```bash
gh issue comment 78 --body "$(cat <<'EOF'
Closing in favor of the local_kernel generalization that landed via #82 and was generalized in [spec 2026-05-18-local-kernel-generalization-design.md](https://github.com/david-igou/ansible-collection-armbian/blob/main/docs/superpowers/specs/2026-05-18-local-kernel-generalization-design.md).

`local_kernel` mode lands kernel ownership on the board. Kernel updates are now `apt install linux-image-<branch>-<family>=<version>` on the running board, followed by a PoE cycle. No pxelinux multi-label, no per-version TFTP layout, no chroot-on-the-netboot-server apt. Rollback is `apt install linux-image-<branch>-<family>=<older-version>` plus cycle.

The "declarative rollback from inventory" property of the original framing is preserved — `armbian_local_kernel` is the declarative knob, and the kernel running on a host is observable via existing `board_boot_verify` facts.
EOF
)"
```

- [ ] **Step 2: Close #78**

```bash
gh issue close 78
```

- [ ] **Step 3: Post closing comment on #79**

```bash
gh issue comment 79 --body "$(cat <<'EOF'
Closing the issue as framed. The Pattern B/D dependency on #78's state-preservation was the whole reason it was blocked. With `local_kernel` (#82 + the [generalization spec 2026-05-18](https://github.com/david-igou/ansible-collection-armbian/blob/main/docs/superpowers/specs/2026-05-18-local-kernel-generalization-design.md)), k3s nodes use Pattern C (full local disk, native overlayfs, kernel updates via apt).

The k3s example itself is unblocked and becomes a separate, much smaller spec — Pattern C + upstream `k3s-io/k3s-ansible` wiring + a `docs/k3s-integration.md` covering the snapshotter / no_root_squash / kernel-module gotchas. Will track that as a new issue.
EOF
)"
```

- [ ] **Step 4: Close #79**

```bash
gh issue close 79
```

No commit.

---

## Plan summary

- **Phase 1** (Tasks 1–14): mechanism. Adds metadata, refactors the build hook, extracts dict composition, generalizes persist_uboot_env.yml, wires into converge, ships two new molecule scenarios (rendering + precedence). All CI-verifiable; no hardware. Ends with `phase1-mechanism-complete` git tag.
- **Phase 2** (Tasks 15–23): rollout. Updates real inventory for 4 hosts; rebuilds images; brings up each of the 5 boards on local_kernel; closes #78 and #79.

Phase 2 tasks are sized for user-paced hardware iteration. Each per-board task references the `testing-armbian-board-hardware` skill for evidence capture; per-iteration UART/findmnt/uname -r evidence lives on board-tracker issues, not in this plan.
