# Per-Board Userpatches and Build Branch via Inventory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the playbook-embedded `build_userpatches` and `build_branches` per-board dicts in `playbooks/build_image.yml` into per-model inventory `group_vars/<model_group>.yml` files. A user can register a new board's patches and U-Boot branch in their inventory without editing the playbook.

**Architecture:** Each `armbian_netboot_board_model` already maps 1:1 to an inventory subgroup of `boards` (e.g. `orange-pi-5-max` ↔ `orange_pi_5_max`). The playbook resolves one representative host per model and reads `armbian_netboot_board_userpatches` (list, default `[]`) and `armbian_netboot_board_branch` (string, default `current`) from that host's resolved vars. Cross-board family-level overlays remain in the playbook as `build_userpatches_common` because they are workflow intent, not per-board hardware data.

**Tech Stack:** Ansible 2.15+, Jinja2, YAML. No new collections or modules.

---

## File Structure

**New files:**
- `inventory/group_vars/orange_pi_5_pro.yml` — `armbian_netboot_board_branch: edge`
- `inventory/group_vars/orange_pi_5.yml` — `armbian_netboot_board_branch: edge`
- `inventory/group_vars/orange_pi_5_max.yml` — `armbian_netboot_board_branch: edge` + RTL8125 MAC patch
- `inventory/group_vars/rock_5a.yml` — `armbian_netboot_board_branch: edge`
- `inventory/group_vars/rock_5b.yml` — `armbian_netboot_board_branch: edge`
- `playbooks/tests/test_build_image_vars.yml` — localhost-only assertion harness over example inventory

**Modified files:**
- `playbooks/build_image.yml` — drop the two embedded dicts; add a `_board_model_first_host` resolver pre_task; switch the include_role's `vars:` block to hostvars lookup
- `CLAUDE.md` — update "Adding a new board" minimum-touched-files section + collection-structure docstring
- `.claude/skills/adding-armbian-board/SKILL.md` — update Phase 4 (branch decision) and per-board userpatches guidance

**Untouched (intentional):**
- `vars/boards.yml` — board hardware metadata stays put. Userpatches and branch are caller intent, not hardware facts. (See `feedback_role_intent_separation` memory.)
- `roles/image_build/` — role contract is unchanged; it still receives `armbian_build_userpatches` and `armbian_build_branch` as inputs.
- `extensions/molecule/image_build/` — molecule scenario passes `scenario_userpatches` directly and does not exercise the playbook's per-board dispatch. Skipped.
- `.inventory/` — gitignored, user-owned. Task 9 provides paste-ready content for the user to apply manually.

---

## Task 1: Add `_board_model_first_host` resolver to build_image.yml

**Files:**
- Modify: `playbooks/build_image.yml:442-509` (pre_tasks block — insert a new task before "Resolve build targets from armbian_netboot_board_configs")

**Context:** The playbook already computes `_board_models` (unique board models in `groups['boards']`). To read per-model group_vars-defined variables, we need one representative host per model. Hosts of the same model share group_vars by inheritance, so picking the first host is sufficient.

- [ ] **Step 1: Add the resolver pre_task**

In `playbooks/build_image.yml`, insert this task immediately after the existing "Resolve unique armbian_netboot_board_model values from groups['boards']" task (currently at lines 447-453):

```yaml
    - name: Resolve a representative host per board model
      # Per-model build vars (armbian_netboot_board_userpatches,
      # armbian_netboot_board_branch) come from
      # inventory/group_vars/<model_group>.yml. Hosts of the same model
      # all inherit those group_vars, so picking any one host is
      # sufficient — we use the first host listed in groups['boards']
      # for each model. Used by the include_role vars: block below.
      ansible.builtin.set_fact:
        _board_model_first_host: >-
          {{
            _board_model_first_host | default({})
            | combine({
                item: (
                  groups['boards']
                  | map('extract', hostvars)
                  | selectattr('armbian_netboot_board_model', 'equalto', item)
                  | map(attribute='inventory_hostname')
                  | first
                )
              })
          }}
      loop: "{{ _board_models }}"
```

- [ ] **Step 2: Verify syntax with ansible-playbook --syntax-check**

Run from collection root:
```bash
ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check
```

Expected: `playbook: playbooks/build_image.yml` (no error). If a Jinja parse error appears, fix and re-run.

- [ ] **Step 3: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "refactor(build_image): add _board_model_first_host resolver"
```

---

## Task 2: Add cross-host consistency assertions to build_image.yml

**Files:**
- Modify: `playbooks/build_image.yml` (pre_tasks block — append after the `_board_model_first_host` resolver from Task 1)

**Context:** `build_image.yml` builds one `.img.xz` per model. If two hosts of the same model declare divergent `armbian_netboot_board_branch` or `armbian_netboot_board_userpatches` (e.g. via a host_vars override), the playbook would silently use only the first host's values and the second host would end up running an image it didn't ask for. Per-host build divergence would require keying builds by `(model + sha256(userpatches+branch))` and switching `armbian_netboot_image_urls[<model>]` to a host-keyed map — out of scope for v3. Fail loudly when divergence is detected so the operator either consolidates into per-model group_vars or opens a follow-on spec.

- [ ] **Step 1: Append the branch-consistency assert**

In `playbooks/build_image.yml`, immediately after the "Resolve a representative host per board model" task from Task 1, append:

```yaml
    - name: Assert all hosts of each model agree on armbian_netboot_board_branch
      # build_image.yml builds one .img.xz per model — divergent
      # branch declarations across hosts of the same model would
      # silently use only the first host's value. Per-host build
      # divergence would require keying builds by (model + patch-hash)
      # and a host-keyed armbian_netboot_image_urls map; out of scope
      # for v3. Fail loudly so the operator consolidates into
      # inventory/group_vars/<model_group>.yml, or opens a follow-on
      # spec for genuinely per-host builds.
      ansible.builtin.assert:
        that:
          - >-
            (groups['boards']
             | map('extract', hostvars)
             | selectattr('armbian_netboot_board_model', 'equalto', item)
             | map(attribute='armbian_netboot_board_branch', default='current')
             | unique | list | length) == 1
        fail_msg: >-
          Model '{{ item }}' has hosts with divergent
          armbian_netboot_board_branch values. Move the override into
          inventory/group_vars/<model_group>.yml (per-model) or remove
          the host_vars override. Per-host builds are not supported in
          v3.
      loop: "{{ _board_models }}"
```

- [ ] **Step 2: Append the userpatches-consistency assert**

Immediately after the previous task, append:

```yaml
    - name: Assert all hosts of each model agree on armbian_netboot_board_userpatches
      # Same per-model build rule as the branch assert above. The
      # to_json(sort_keys=true) canonicalisation makes the comparison
      # deterministic across dict-key ordering differences in YAML
      # source.
      ansible.builtin.assert:
        that:
          - >-
            (groups['boards']
             | map('extract', hostvars)
             | selectattr('armbian_netboot_board_model', 'equalto', item)
             | map(attribute='armbian_netboot_board_userpatches', default=[])
             | map('to_json', sort_keys=true)
             | unique | list | length) == 1
        fail_msg: >-
          Model '{{ item }}' has hosts with divergent
          armbian_netboot_board_userpatches. Same reason as branch:
          builds are per-model.
      loop: "{{ _board_models }}"
```

- [ ] **Step 3: Run syntax-check**

```bash
ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check
```

Expected: `playbook: playbooks/build_image.yml`.

- [ ] **Step 4: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "feat(build_image): assert per-model branch/userpatches consistency"
```

---

## Task 3: Write a localhost-only test harness over example inventory

**Files:**
- Create: `playbooks/tests/test_build_image_vars.yml`

**Context:** A pure-Jinja resolution test that doesn't touch any real host. Runs on localhost, reads `groups['boards']` from the example inventory (`inventory/hosts.yml`), asserts the per-model resolved values for `armbian_netboot_board_userpatches` and `armbian_netboot_board_branch` match expectations. This is the "failing test" — it should FAIL after this task (because Task 4 hasn't created the group_vars files yet).

- [ ] **Step 1: Create the test directory**

```bash
mkdir -p playbooks/tests
```

- [ ] **Step 2: Write the test playbook**

Create `playbooks/tests/test_build_image_vars.yml`:

```yaml
---
# Localhost-only test harness that exercises the same per-model
# variable resolution build_image.yml uses, then asserts the resolved
# values match what the example inventory should carry.
#
# This is a static check — no SSH, no Docker, no armbian/build clone.
# It runs entirely against the documentation-only example inventory.
#
# Run with:
#   unset ANSIBLE_INVENTORY
#   ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
#
# Failures here indicate either (a) drift between the playbook's
# expected variable contract and the example inventory's group_vars,
# or (b) the resolver logic in build_image.yml needs the same update.

- name: Resolve per-model build vars and assert expected values
  hosts: localhost
  connection: local
  gather_facts: false

  pre_tasks:
    - name: Resolve unique armbian_netboot_board_model values from groups['boards']
      ansible.builtin.set_fact:
        _board_models: >-
          {{ groups['boards']
             | map('extract', hostvars, 'armbian_netboot_board_model')
             | unique
             | list }}

    - name: Resolve a representative host per board model
      ansible.builtin.set_fact:
        _board_model_first_host: >-
          {{
            _board_model_first_host | default({})
            | combine({
                item: (
                  groups['boards']
                  | map('extract', hostvars)
                  | selectattr('armbian_netboot_board_model', 'equalto', item)
                  | map(attribute='inventory_hostname')
                  | first
                )
              })
          }}
      loop: "{{ _board_models }}"

  tasks:
    - name: Assert every model declares armbian_netboot_board_branch
      ansible.builtin.assert:
        that:
          - "hostvars[_board_model_first_host[item]].armbian_netboot_board_branch is defined"
        fail_msg: >-
          Model '{{ item }}' (host '{{ _board_model_first_host[item] }}')
          is missing armbian_netboot_board_branch in its inventory
          group_vars. Define it in
          inventory/group_vars/<model_group>.yml.
      loop: "{{ _board_models }}"

    - name: Assert every model's armbian_netboot_board_branch is a known value
      ansible.builtin.assert:
        that:
          - "hostvars[_board_model_first_host[item]].armbian_netboot_board_branch in ['current', 'edge', 'vendor', 'legacy']"
        fail_msg: >-
          Model '{{ item }}' has armbian_netboot_board_branch =
          '{{ hostvars[_board_model_first_host[item]].armbian_netboot_board_branch }}',
          which is not a known armbian/build BRANCH value.
      loop: "{{ _board_models }}"

    - name: Assert armbian_netboot_board_userpatches (when defined) is a well-formed list
      ansible.builtin.assert:
        that:
          - "hostvars[_board_model_first_host[item]].armbian_netboot_board_userpatches is iterable"
          - >-
            hostvars[_board_model_first_host[item]].armbian_netboot_board_userpatches
            | selectattr('dest', 'undefined') | list | length == 0
          - >-
            hostvars[_board_model_first_host[item]].armbian_netboot_board_userpatches
            | selectattr('content', 'undefined') | list | length == 0
        fail_msg: >-
          Model '{{ item }}' has armbian_netboot_board_userpatches
          defined but at least one entry is missing 'dest' or 'content'.
      when:
        - "hostvars[_board_model_first_host[item]].armbian_netboot_board_userpatches is defined"
      loop: "{{ _board_models }}"

    - name: Assert all hosts of each model agree on armbian_netboot_board_branch
      # Mirrors the runtime assert in playbooks/build_image.yml so the
      # example inventory contract documents the per-model rule even
      # when each model currently has only one host.
      ansible.builtin.assert:
        that:
          - >-
            (groups['boards']
             | map('extract', hostvars)
             | selectattr('armbian_netboot_board_model', 'equalto', item)
             | map(attribute='armbian_netboot_board_branch', default='current')
             | unique | list | length) == 1
        fail_msg: >-
          Model '{{ item }}' has hosts with divergent
          armbian_netboot_board_branch values in the example inventory.
      loop: "{{ _board_models }}"

    - name: Assert all hosts of each model agree on armbian_netboot_board_userpatches
      ansible.builtin.assert:
        that:
          - >-
            (groups['boards']
             | map('extract', hostvars)
             | selectattr('armbian_netboot_board_model', 'equalto', item)
             | map(attribute='armbian_netboot_board_userpatches', default=[])
             | map('to_json', sort_keys=true)
             | unique | list | length) == 1
        fail_msg: >-
          Model '{{ item }}' has hosts with divergent
          armbian_netboot_board_userpatches in the example inventory.
      loop: "{{ _board_models }}"

    - name: Assert orange-pi-5-max ships the RTL8125 MAC userpatch
      ansible.builtin.assert:
        that:
          - "(hostvars[_board_model_first_host['orange-pi-5-max']].armbian_netboot_board_userpatches | default([])) | length == 1"
          - "'prefer-chip-mac' in (hostvars[_board_model_first_host['orange-pi-5-max']].armbian_netboot_board_userpatches | default([]))[0].dest"
        fail_msg: >-
          orange-pi-5-max group_vars is missing the
          0099-prefer-chip-mac-over-cpuid.patch userpatch (needed for
          RTL8125 chip MAC consistency). Add it to
          inventory/group_vars/orange_pi_5_max.yml under
          armbian_netboot_board_userpatches.
      when: "'orange-pi-5-max' in _board_models"

    - name: Assert every model defaults to edge branch in v3 fleet
      ansible.builtin.assert:
        that:
          - "hostvars[_board_model_first_host[item]].armbian_netboot_board_branch == 'edge'"
        fail_msg: >-
          Model '{{ item }}' has armbian_netboot_board_branch =
          '{{ hostvars[_board_model_first_host[item]].armbian_netboot_board_branch }}';
          example-inventory contract expects 'edge' for all currently
          tracked rk3588(s) boards (see plan
          docs/superpowers/plans/2026-05-25-per-board-userpatches-inventory.md).
      loop: "{{ _board_models }}"
```

- [ ] **Step 3: Run the test and confirm it FAILS**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: FAIL on the first assert ("missing armbian_netboot_board_branch"). The example inventory has not yet been updated; this confirms the test is doing real work.

- [ ] **Step 4: Commit**

```bash
git add playbooks/tests/test_build_image_vars.yml
git commit -m "test(build_image): add per-board build var inventory contract test"
```

---

## Task 4: Create per-model inventory group_vars files

**Files:**
- Create: `inventory/group_vars/orange_pi_5_pro.yml`
- Create: `inventory/group_vars/orange_pi_5.yml`
- Create: `inventory/group_vars/orange_pi_5_max.yml`
- Create: `inventory/group_vars/rock_5a.yml`
- Create: `inventory/group_vars/rock_5b.yml`

**Context:** Each file applies to its eponymous group declared under `boards.children` in `inventory/hosts.yml`. The branch values come from the playbook's current `build_branches:` dict (all five boards on `edge`). The userpatches for orange-pi-5-max comes from the playbook's current `build_userpatches.orangepi5-max` entry verbatim.

- [ ] **Step 1: Write `inventory/group_vars/orange_pi_5_pro.yml`**

```yaml
---
# Per-model vars for the orange_pi_5_pro group. Loaded by
# playbooks/build_image.yml when building the orange-pi-5-pro
# armbian image. See
# docs/superpowers/plans/2026-05-25-per-board-userpatches-inventory.md
# for the resolver mechanism.

# ── armbian/build BRANCH ─────────────────────────────────────────────
# orange-pi-5-pro uses the YT6801 PCIe NIC, which is supported only by
# armbian/build's `orangepi5pro` board config on the edge branch
# (mainline u-boot v2026.04). The current branch's family-default
# Radxa fork lacks the YT6801 driver entirely.
armbian_netboot_board_branch: edge

# ── per-board userpatches ────────────────────────────────────────────
# None — the rk3588 family-level overlay
# (build_userpatches_common.__999_pxe_first in build_image.yml) covers
# PXE-first ordering and CONFIG_PCI_INIT_R backfill. Add per-board
# entries here only after confirming the family hook does not cover
# your case.
# armbian_netboot_board_userpatches: []
```

- [ ] **Step 2: Write `inventory/group_vars/orange_pi_5.yml`**

```yaml
---
# Per-model vars for the orange_pi_5 group. See
# inventory/group_vars/orange_pi_5_pro.yml header for the rationale on
# branch selection and per-board userpatches.

# armbian/build's orangepi5.conf
# `post_family_config__orangepi5_use_mainline_uboot` hook forces
# mainline v2026.04 on every branch, so this entry is documentation —
# the build target lands on mainline u-boot regardless. Keep `edge`
# explicit for symmetry with the other rk3588(s) boards in this fleet.
armbian_netboot_board_branch: edge
```

- [ ] **Step 3: Write `inventory/group_vars/orange_pi_5_max.yml`**

```yaml
---
# Per-model vars for the orange_pi_5_max group.

# ── armbian/build BRANCH ─────────────────────────────────────────────
# orangepi5-max ships an RTL8125BG PCIe 2.5GbE NIC. The family-default
# Radxa next-dev-v2024.10 fork lacks the r8169-family driver, so PXE
# silently fails. armbian/build's
# `post_family_config_branch_edge__orangepi5max_use_mainline_uboot`
# (in upstream config/boards/orangepi5-max.csc) swaps in mainline
# u-boot v2025.04 + armbian/build's patch/u-boot/v2025.04/
# board_orangepi5-max/ overlay, which adds CONFIG_RTL8169=y +
# CONFIG_PCIE_DW_ROCKCHIP=y. That hook gates on BRANCH=edge.
armbian_netboot_board_branch: edge

# ── per-board userpatches ────────────────────────────────────────────
# Skip rockchip_setup_macaddr()'s env-set on this board so the RTL8125's
# hardware-stored MAC (read by the r8169 driver from the chip's MAC0
# register at probe time) wins end-to-end. Without this patch:
#   1. rockchip_setup_macaddr() runs in misc_init_r and writes
#      SHA-of-cpuid MAC to env ethaddr.
#   2. eth_post_probe in net/eth-uclass.c reads the chip MAC, sees env
#      ethaddr is non-zero, overrides chip MAC with env MAC, warns
#      "MAC addresses don't match".
#   3. U-Boot DHCP/PXE uses env MAC; kernel reads chip MAC directly
#      → two DHCP leases per cold boot, pxelinux.cfg/01-<mac> lookup
#      against a MAC the operator never sees in Linux.
#
# The patch gates on root /compatible "xunlong,orangepi-5-max" via
# of_machine_is_compatible(), so it has zero effect on any other rk3588
# board sharing arch/arm/mach-rockchip/board.c.
#
# CONFIG_ENV_IS_NOWHERE=y on this board's defconfig, so env is
# volatile; the chip-MAC will be re-derived by eth_post_probe on every
# cold boot. No persistence path needed (unlike rock-5b).
armbian_netboot_board_userpatches:
  - dest: "u-boot/v2025.04/board_orangepi5-max/0099-prefer-chip-mac-over-cpuid.patch"
    content: |
      --- a/arch/arm/mach-rockchip/board.c
      +++ b/arch/arm/mach-rockchip/board.c
      @@ -329,6 +329,21 @@ int rockchip_setup_macaddr(void)
       	int size = sizeof(hash);
       	u8 mac_addr[6];

      +	/*
      +	 * Skip env-set on boards whose NIC has a hardware-stored MAC
      +	 * (e.g. RTL8125 reads MAC from its own MAC0 register at probe
      +	 * time). If we write a SHA-of-cpuid MAC to env here,
      +	 * eth_post_probe in net/eth-uclass.c will override the chip
      +	 * MAC with our env value, causing U-Boot DHCP/PXE to use a
      +	 * different MAC than the Linux kernel uses (kernel reads
      +	 * chip MAC directly). Symptom: two DHCP leases per cold
      +	 * boot, pxelinux.cfg/01-<mac> miss against the MAC visible
      +	 * from Linux. See david_igou.armbian_netboot's
      +	 * inventory/group_vars/orange_pi_5_max.yml for rationale.
      +	 */
      +	if (of_machine_is_compatible("xunlong,orangepi-5-max"))
      +		return 0;
      +
       	/* Only generate a MAC address, if none is set in the environment */
       	if (env_get("ethaddr"))
       		return 0;
```

- [ ] **Step 4: Write `inventory/group_vars/rock_5a.yml`**

```yaml
---
# Per-model vars for the rock_5a group.

# ── armbian/build BRANCH ─────────────────────────────────────────────
# armbian/build has no mainline override for rock-5a (upstream's
# config/boards/rock-5a.conf only carries a vendor-branch hook), so we
# ship one in build_userpatches_common:
# `__999_rock5a_use_mainline_uboot` (in playbooks/build_image.yml).
# That hook gates on BRANCH=edge — this entry is what activates it.
# Without it, rock-5a would build against the Radxa fork's
# BOOT_TARGET_DEVICES X-macro form, which the `__999_pxe_first` sed
# cannot patch (PXE stays at the end of the boot order, SD wins).
armbian_netboot_board_branch: edge
```

- [ ] **Step 5: Write `inventory/group_vars/rock_5b.yml`**

```yaml
---
# Per-model vars for the rock_5b group.

# ── armbian/build BRANCH ─────────────────────────────────────────────
# armbian/build's
# `post_family_config_branch_edge__rock-5b_use_mainline_uboot` (in
# config/boards/rock-5b.conf) swaps the Radxa next-dev-v2024.10 fork
# (which lacks the RTL8125 PCIe NIC driver Rock 5B ships with) for
# mainline u-boot. The family-default `current` branch builds against
# the Radxa fork and cannot PXE on Rock 5B.
#
# Our `__999_rock5b_uboot_v2026_04` hook in build_userpatches_common
# bumps that upstream-hook's v2026.01 default to v2026.04. Both hooks
# gate on BRANCH=edge.
armbian_netboot_board_branch: edge
```

- [ ] **Step 6: Run the test again and confirm it PASSES**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS (all assertions hold). If any assertion fails, fix the relevant `inventory/group_vars/<model>.yml` file and re-run.

- [ ] **Step 7: Commit**

```bash
git add inventory/group_vars/orange_pi_5_pro.yml \
        inventory/group_vars/orange_pi_5.yml \
        inventory/group_vars/orange_pi_5_max.yml \
        inventory/group_vars/rock_5a.yml \
        inventory/group_vars/rock_5b.yml
git commit -m "inventory(example): declare per-board build branch/userpatches"
```

---

## Task 5: Refactor build_image.yml to read from inventory

**Files:**
- Modify: `playbooks/build_image.yml:346-441` (delete `build_userpatches:` and `build_branches:` blocks from `vars:`)
- Modify: `playbooks/build_image.yml:515-523` (rewrite the include_role `vars:` block)

**Context:** With per-model files in place, the playbook no longer needs its embedded per-board dicts. The remaining `build_userpatches_common` stays — it carries the cross-board rk3588 family hooks that are workflow intent.

- [ ] **Step 1: Delete the `build_userpatches:` block from the play `vars:`**

In `playbooks/build_image.yml`, locate the `# Per-board userpatches — escape hatch...` block (starts at line 346) and delete from `# Per-board userpatches — escape hatch...` (line 346) through the end of the `orangepi5-max:` entry (line 401, just before `# Per-board armbian/build BRANCH override.`). The deleted span is the entire `build_userpatches:` definition including the long board.c patch text.

After deletion, the play's `vars:` block ends with `build_userpatches_common:` (which closes around line 344 with `declare -g INSTALL_HEADERS="no"\n          }\n`).

- [ ] **Step 2: Delete the `build_branches:` block from the play `vars:`**

Continuing in `playbooks/build_image.yml`, delete from `# Per-board armbian/build BRANCH override.` (line 403) through `orangepi5pro: edge` (line 440).

After both deletions, the play `vars:` contains only `build_userpatches_common:` plus the closing newline before `pre_tasks:`.

- [ ] **Step 3: Rewrite the include_role `vars:` block**

Locate the build-loop task (currently at lines 515-523):

```yaml
    - name: Build image per inventory board
      ansible.builtin.include_role:
        name: image_build
      vars:
        armbian_build_board: "{{ item }}"
        armbian_build_userpatches: "{{ build_userpatches_common + (build_userpatches[item] | default([])) }}"
        armbian_build_branch: "{{ build_branches[item] | default('current') }}"
      loop: "{{ _build_targets }}"
```

Replace the `vars:` block with hostvars-based lookup. The `_build_targets` loop iterates `armbian_board_name` values, but `_board_model_first_host` is keyed by `armbian_netboot_board_model`. Convert from one to the other inline:

```yaml
    - name: Build image per inventory board
      ansible.builtin.include_role:
        name: image_build
      vars:
        # Map the armbian_board_name (build target) back to its model
        # to look up the representative host carrying per-model
        # group_vars.
        _board_model: >-
          {{
            _board_models
            | selectattr('extract', 'defined')
            | map('extract', armbian_netboot_board_configs, 'armbian_board_name')
            | list | zip(_board_models) | items2dict | get(item)
          }}
        _first_host: "{{ _board_model_first_host[_board_model] }}"
        armbian_build_board: "{{ item }}"
        armbian_build_userpatches: >-
          {{
            build_userpatches_common
            + (hostvars[_first_host].armbian_netboot_board_userpatches | default([]))
          }}
        armbian_build_branch: "{{ hostvars[_first_host].armbian_netboot_board_branch | default('current') }}"
      loop: "{{ _build_targets }}"
```

**NOTE:** The `_board_model` Jinja above is dense — `items2dict` requires a list of length-2 sequences. Confirm by reading `_build_targets` (list of armbian_board_name) and pairing each with the original model. Simpler alternative: build the reverse map in a pre_task and reference it here. Use the simpler form:

Add this pre_task immediately after the "Resolve a representative host per board model" task from Task 1:

```yaml
    - name: Resolve armbian_board_name → board_model reverse map
      ansible.builtin.set_fact:
        _build_target_to_model: >-
          {{
            _build_target_to_model | default({})
            | combine({
                armbian_netboot_board_configs[item].armbian_board_name: item
              })
          }}
      loop: "{{ _board_models }}"
```

Then the include_role's vars block simplifies to:

```yaml
    - name: Build image per inventory board
      ansible.builtin.include_role:
        name: image_build
      vars:
        _first_host: "{{ _board_model_first_host[_build_target_to_model[item]] }}"
        armbian_build_board: "{{ item }}"
        armbian_build_userpatches: >-
          {{
            build_userpatches_common
            + (hostvars[_first_host].armbian_netboot_board_userpatches | default([]))
          }}
        armbian_build_branch: "{{ hostvars[_first_host].armbian_netboot_board_branch | default('current') }}"
      loop: "{{ _build_targets }}"
```

Use the second form. Both `_board_model_first_host` and `_build_target_to_model` are pre_task facts.

- [ ] **Step 4: Update the playbook docstring**

Locate the docstring at the top of `playbooks/build_image.yml` (lines 22-26):

```yaml
# The PXE-first userpatches table is playbook data, not role data —
# the armbian_build role itself is intent-agnostic. Add a new board by
# extending build_userpatches with another entry and adding the host(s)
# under groups['boards'] in inventory with an armbian_netboot_board_model that exists in
# vars/boards.yml.
```

Replace with:

```yaml
# The PXE-first userpatches family overlay is playbook data
# (build_userpatches_common) — the armbian_build role itself is
# intent-agnostic. Per-board userpatches and U-Boot branch live in
# inventory group_vars at inventory/group_vars/<model_group>.yml as
# armbian_netboot_board_userpatches and armbian_netboot_board_branch.
# Add a new board by:
#   1. Adding host(s) under groups['boards'] in inventory with an
#      armbian_netboot_board_model that exists in vars/boards.yml.
#   2. (Optional) Creating inventory/group_vars/<model_group>.yml with
#      armbian_netboot_board_branch (default 'current') and any
#      per-board armbian_netboot_board_userpatches.
```

- [ ] **Step 5: Run syntax-check**

```bash
ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check
```

Expected: `playbook: playbooks/build_image.yml`.

- [ ] **Step 6: Run the test playbook to confirm no regression**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS (same as Task 4 Step 6).

- [ ] **Step 7: Run ansible-lint on the modified playbook**

```bash
ansible-lint playbooks/build_image.yml
```

Expected: no new findings vs. baseline. (If `ansible-lint` complains about pre-existing issues, ignore those — only new findings introduced by this refactor matter.)

- [ ] **Step 8: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "refactor(build_image): read per-board branch/userpatches from inventory"
```

---

## Task 6: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:387` (mentions `build_branches`)
- Modify: `CLAUDE.md:408-413` (Minimum touched files — points 4 and 5)
- Modify: `CLAUDE.md` collection-structure section if needed

- [ ] **Step 1: Update the "Adding a new board" minimum touched files list**

Locate this block in `CLAUDE.md` (around line 397):

```markdown
Minimum touched files for a new board:

1. `inventory/hosts.yml` (doc-only example) + your real inventory:
   add the host(s) under a new per-model subgroup of `boards` with
   `armbian_netboot_board_mac`, `armbian_netboot_board_model`,
   `armbian_netboot_boot_mode`, `armbian_netboot_poe_switch`,
   `armbian_netboot_poe_port`.
2. `vars/boards.yml`: entry keyed by `armbian_netboot_board_model` under
   `armbian_netboot_board_configs` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`, `earlycon`.
3. `inventory/group_vars/all.yml`: add an
   `armbian_netboot_image_urls[<model>]` entry pointing at the
   locally-published custom build (consumed on the netboot_server),
   AND an `armbian_netboot_image_urls_http[<model>]` entry with the
   http(s):// URL the boards stream from for the Phase 3 dd-to-SD step.
4. `playbooks/build_image.yml` `build_branches:` if the board's
   family-default U-Boot tree can't netboot (e.g. rk3588 PCIe-NIC
   boards need `edge` for mainline U-Boot).
5. (Rare) `playbooks/build_image.yml` `build_userpatches:` if the
   board needs source patches beyond what `build_userpatches_common`
   already covers — most new boards won't.
```

Replace items 4 and 5 with:

```markdown
4. `inventory/group_vars/<model_group>.yml` (doc-only example +
   real inventory): set `armbian_netboot_board_branch` if the board's
   family-default U-Boot tree can't netboot (e.g. rk3588 PCIe-NIC
   boards need `edge` for mainline U-Boot). Default `current` if
   omitted.
5. (Rare) `inventory/group_vars/<model_group>.yml`
   `armbian_netboot_board_userpatches`: list of `{dest, content}`
   patches the image_build role drops into `userpatches/` for this
   board's build. Add only after confirming `build_userpatches_common`
   in `playbooks/build_image.yml` (the cross-board rk3588 family
   overlay) doesn't already cover the case.
```

- [ ] **Step 2: Update the surrounding sentence at line 387**

Find:
```
via `build_branches`), post-build defconfig audits
```

Replace with:
```
via `armbian_netboot_board_branch` in inventory group_vars), post-build defconfig audits
```

- [ ] **Step 3: Run yamllint to confirm no doc-block format drift**

(CLAUDE.md is not YAML-linted, but verify it renders cleanly. Open it and skim the changed section.)

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): per-board branch/userpatches live in inventory group_vars"
```

---

## Task 7: Update the adding-armbian-board skill

**Files:**
- Modify: `.claude/skills/adding-armbian-board/SKILL.md` (Phase 4 references)

**Context:** The skill currently directs new-board onboarders to edit `playbooks/build_image.yml`. After this refactor, the same change happens via inventory group_vars.

- [ ] **Step 1: Update Phase 4 — U-Boot branch decision**

In `.claude/skills/adding-armbian-board/SKILL.md`, find:

```markdown
## Phase 4 — U-Boot branch decision

Default: `current` (no `build_branches` entry). Switch to `edge` only when the family-default U-Boot tree can't support the board's NIC — set `build_branches: { <board>: edge }` in `playbooks/build_image.yml`. The Radxa `next-dev-*` fork (rk3588 family default) lacks the RTL8125 driver, so any rk3588 board with that NIC needs `edge`.

Per-board `build_userpatches` entries are rare — `build_userpatches_common`'s `__999_pxe_first` family hook covers all rk3588 boards (PXE-first BOOT_TARGETS + appends `CONFIG_PCI_INIT_R=y` when missing). Add a per-board entry only after verifying the existing hooks don't cover the case.
```

Replace with:

```markdown
## Phase 4 — U-Boot branch decision

Default: `current` (no `armbian_netboot_board_branch` entry needed). Switch to `edge` only when the family-default U-Boot tree can't support the board's NIC — set `armbian_netboot_board_branch: edge` in `inventory/group_vars/<model_group>.yml` (and the same path in your real inventory). The Radxa `next-dev-*` fork (rk3588 family default) lacks the RTL8125 driver, so any rk3588 board with that NIC needs `edge`.

Per-board `armbian_netboot_board_userpatches` entries are rare — `build_userpatches_common` in `playbooks/build_image.yml`'s `__999_pxe_first` family hook covers all rk3588 boards (PXE-first BOOT_TARGETS + appends `CONFIG_PCI_INIT_R=y` when missing). Add a per-board list under `armbian_netboot_board_userpatches` in `inventory/group_vars/<model_group>.yml` only after verifying the existing hooks don't cover the case.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/adding-armbian-board/SKILL.md
git commit -m "docs(skill): adding-armbian-board points at inventory for branch/userpatches"
```

---

## Task 8: Lint + molecule regression gate

**Files:**
- (no file changes — verification only)

**Context:** The refactor touches `playbooks/build_image.yml` and adds files under `inventory/group_vars/` and `playbooks/tests/`. None of these directly modify role internals, but lint must stay clean and the `image_build` molecule scenario must continue to exercise the role's full preflight + manage_checkout + apply_userpatches + compute_inputs + check_manifest path without regression. `local_kernel_render` is included because it lives in the same dispatch-table area `build_image.yml` references in `_local_kernel_dispatch_table`; running it confirms vars/boards.yml structure is unchanged.

Wall-time budget: `image_build` ~5–7 minutes (Docker install + shallow armbian/build clone), `local_kernel_render` ~2 minutes. Run them sequentially.

- [ ] **Step 1: Run yamllint over modified directories**

```bash
make yamllint
```

Expected: exit 0. If any of the new YAML files (`inventory/group_vars/<model>.yml`, `playbooks/tests/test_build_image_vars.yml`) fail, fix the offending file before proceeding. Common issues: trailing whitespace, lines >120 chars, missing document start `---`, indent inconsistencies.

- [ ] **Step 2: Run ansible-lint over playbooks + roles**

```bash
make ansible-lint
```

Expected: no new findings vs. the baseline at branch start. (Pre-existing findings are tolerated — only new ones introduced by this refactor block progress.) If the new test playbook trips a rule like `name[casing]` or `fqcn[action-core]`, fix the offending line; the existing playbook style is the reference.

- [ ] **Step 3: Run the image_build molecule scenario**

```bash
make molecule SCENARIO=image_build
```

Expected: full molecule sequence (dependency → syntax → create → prepare → converge → verify → destroy) reports `PLAY RECAP` with `failed=0` on every play. Verify in particular that the converge phase's `Apply image_build role` task completes without errors — confirms the role's input contract (`armbian_build_userpatches`, `armbian_build_branch`) is intact.

If the scenario fails on a setup/infrastructure issue unrelated to this refactor (Docker install flake, network egress hiccup), retry once. Persistent failure means the refactor broke something — diagnose before continuing.

- [ ] **Step 4: Run the local_kernel_render molecule scenario**

```bash
make molecule SCENARIO=local_kernel_render
```

Expected: PLAY RECAP `failed=0`. This scenario verifies the `render_localcmd_chain.j2` macro that build_image.yml's `_local_kernel_dispatch_table` pre_task inlines. If this passes, the dispatch table format is unchanged.

- [ ] **Step 5: Run the test harness against the example inventory one more time**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS. Final smoke check that the test harness still gates the example inventory after all docs/lint changes.

- [ ] **Step 6: Commit the verification record (no code changes — empty commit optional)**

No code changes from this task; skip the commit. The previous task's commit is the last code change. Move directly to Task 9.

---

## Task 9: Migration note for real (.inventory/) — operator action item

**Files:**
- (no file changes — produce migration instructions for the operator)

**Context:** The `.inventory/` directory is gitignored and owned by the operator. Code changes have already removed the per-board dicts from `build_image.yml`; without matching `.inventory/group_vars/<model_group>.yml` entries, the next `ansible-playbook playbooks/build_image.yml` would build every board with default `current` branch and zero per-board userpatches, regressing the orange-pi-5-max RTL8125 MAC fix and forcing every rk3588 board onto the family-default fork. The operator must apply the same per-model files to their real inventory before next build.

- [ ] **Step 1: Produce paste-ready content for the operator**

Print the following to the conversation (these are the same files as Task 4, but the operator copies them into their `.inventory/group_vars/`):

```bash
# In the operator's shell, with .inventory/ as the real inventory dir:
mkdir -p .inventory/group_vars
cp inventory/group_vars/orange_pi_5_pro.yml .inventory/group_vars/
cp inventory/group_vars/orange_pi_5.yml .inventory/group_vars/
cp inventory/group_vars/orange_pi_5_max.yml .inventory/group_vars/
cp inventory/group_vars/rock_5a.yml .inventory/group_vars/
cp inventory/group_vars/rock_5b.yml .inventory/group_vars/
```

- [ ] **Step 2: Run the test playbook against the real inventory as a sanity check**

```bash
# Operator only; requires .inventory/ populated per Step 1.
ANSIBLE_INVENTORY=.inventory ansible-playbook \
  -i .inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS. If FAIL, the operator's real inventory has different group names or board models than the example; reconcile case-by-case.

- [ ] **Step 3: (No commit — `.inventory/` is gitignored.)**

---

## Self-Review

**1. Spec coverage:**
- Move per-board `build_userpatches` to inventory → Task 5 (delete) + Task 4 (add to inventory). ✓
- Move per-board `build_branches` to inventory → Task 5 (delete) + Task 4 (add to inventory). ✓
- Update example inventory to demonstrate → Task 4. ✓
- Per-host divergence handling (build is per-model; divergent host_vars fail loudly) → Task 2 (playbook runtime assert) + Task 3 (test harness). ✓
- Keep cross-board `build_userpatches_common` in playbook → confirmed in Task 5 Step 1 (only deletes the per-board dict, not the common one). ✓
- Docs updated → Tasks 6 and 7. ✓
- Lint + molecule regression gate → Task 8. ✓
- Operator's real inventory updated → Task 9. ✓

**2. Placeholder scan:**
- No "TBD" / "implement later" instances.
- Every step shows the actual code/commands to apply.
- The `_board_model` lookup discussed-and-discarded in Task 5 Step 3 is replaced with the simpler `_build_target_to_model` pre_task approach; both pieces of code are shown completely.

**3. Type consistency:**
- `armbian_netboot_board_userpatches` is always a `list[dict]` with `dest` and `content` keys (matches the role's existing input contract).
- `armbian_netboot_board_branch` is always a `string` (one of `current`/`edge`/`vendor`/`legacy`).
- `_board_model_first_host` is `dict[model_str → host_str]` everywhere it's referenced.
- `_build_target_to_model` is `dict[armbian_board_name_str → model_str]`.
- `_first_host` is a `string` (hostname).

**4. Edge cases verified:**
- A new board with NO `armbian_netboot_board_userpatches` defined → `default([])` kicks in, only `build_userpatches_common` is applied.
- A new board with NO `armbian_netboot_board_branch` defined → `default('current')` kicks in.
- Multiple hosts of the same model with identical group_vars → all share the same value; Task 2 asserts pass trivially.
- Multiple hosts of the same model with divergent values (e.g. a host_vars override on one host) → Task 2 asserts fail with a clear error pointing the operator at either group_vars consolidation or a follow-on per-host build spec. Builds are stopped before any image work begins.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-25-per-board-userpatches-inventory.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
