# Per-Board U-Boot Hooks Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the two board-selective U-Boot override hooks (`__999_rock5a_use_mainline_uboot`, `__999_rock5b_uboot_v2026_04`) out of `build_userpatches_common` in `playbooks/build_image.yml` and into per-board `armbian_board_userpatches` entries in `inventory/group_vars/rock_5a.yml` / `rock_5b.yml`. Deliver them via the per-board overlay `userpatches/config/boards/<board>.conf` (sourced by armbian/build only when building that board) instead of via the rk3588 family conf overlay.

**Architecture:** armbian/build sources four user-overlay paths additively (i.e. ON TOP of the upstream file, not replacing it): `userpatches/lib.config`, `userpatches/config/sources/families/<family>.conf`, `userpatches/config/boards/<board>.conf`, and `userpatches/customize-image.sh`. Today the rk3588 family overlay carries five `__999_*` hooks; three (`__999_pxe_first`, `__999_local_kernel_bake`, `__999_no_bcmdhd_for_netboot`) are truly family-shared and stay where they are. The other two are per-board hooks that currently filter internally on `BOARD=`; moving them to per-board overlays makes the per-board scope a structural property (only sourced for that board) instead of a runtime filter, removes them from the playbook surface, and lets the operator change them by editing one inventory file. The role contract (`armbian_build_userpatches` as a flat `list[{dest, content}]`) is unchanged.

**Tech Stack:** Ansible 2.15+, Jinja2, YAML, bash (function bodies for armbian/build hooks). No new collections or modules.

**Prerequisite:** Plan `docs/superpowers/plans/2026-05-25-per-board-userpatches-inventory.md` must be fully implemented and merged first. This plan depends on:
- `inventory/group_vars/rock_5a.yml` and `rock_5b.yml` existing with `armbian_board_branch: edge`.
- `playbooks/build_image.yml`'s include_role vars resolving `armbian_board_userpatches` from per-model hostvars.
- `playbooks/tests/test_build_image_vars.yml` existing as the per-model contract test.

If the prerequisite plan is not yet merged, stop and execute that first.

---

## File Structure

**Modified files:**
- `inventory/group_vars/rock_5a.yml` — add `armbian_board_userpatches` entry with `dest: config/boards/rock-5a.conf` carrying the relocated hook.
- `inventory/group_vars/rock_5b.yml` — same shape, with `dest: config/boards/rock-5b.conf`.
- `playbooks/build_image.yml` — delete the two function blocks (and their preceding comment blocks) from `build_userpatches_common`. Keep the three family-shared hooks.
- `playbooks/tests/test_build_image_vars.yml` — extend with per-board hook assertions (rock-5a and rock-5b must each carry a per-board conf overlay entry).
- `CLAUDE.md` — update the "Adding a new board" minimum-touched-files notes if they reference `build_userpatches_common` as the home for per-board hooks.
- `.claude/skills/adding-armbian-board/SKILL.md` — refresh Phase 4 guidance to point operators at per-board confs for board-specific U-Boot hooks.

**Untouched (intentional):**
- `roles/image_build/` — role contract unchanged; it still receives a flat `armbian_build_userpatches` list of `{dest, content}` and writes each to `<cache>/build/userpatches/<dest>`.
- `vars/boards.yml` — board hardware metadata stays put.
- `inventory/group_vars/orange_pi_5{,_pro,_max}.yml` — no rk3588 board besides rock-5a/rock-5b has its U-Boot pin overridden per-board today; leave alone.
- `docs/uboot-armbian-build-explainer.html` — references the family overlay path generically; the three remaining hooks still live there, so no factual breakage.

---

## Task 1: Extend test harness with failing assertions for per-board hooks

**Files:**
- Modify: `playbooks/tests/test_build_image_vars.yml` (append new asserts after the existing `orange-pi-5-max` ships-the-RTL8125-patch assert)

**Context:** The prior plan's test harness asserts orange-pi-5-max ships its `0099-prefer-chip-mac-over-cpuid.patch` userpatch. We extend it with the same shape for rock-5a and rock-5b: each must carry exactly one userpatch entry whose `dest` is the per-board conf overlay path. The asserts also explicitly forbid `dest: config/sources/families/rockchip-rk3588.conf` for those two boards — that's the regression guard against accidentally re-adding the hook to the family overlay.

- [ ] **Step 1: Append per-board conf asserts**

In `playbooks/tests/test_build_image_vars.yml`, immediately after the "Assert orange-pi-5-max ships the RTL8125 MAC userpatch" task, append:

```yaml
    - name: Assert rock-5a ships its mainline-u-boot hook via per-board conf overlay
      ansible.builtin.assert:
        that:
          - "(hostvars[_board_model_first_host['rock-5a']].armbian_board_userpatches | default([])) | length >= 1"
          - >-
            (hostvars[_board_model_first_host['rock-5a']].armbian_board_userpatches | default([]))
            | selectattr('dest', 'equalto', 'config/boards/rock-5a.conf')
            | list | length == 1
          - >-
            (hostvars[_board_model_first_host['rock-5a']].armbian_board_userpatches | default([]))
            | selectattr('dest', 'equalto', 'config/sources/families/rockchip-rk3588.conf')
            | list | length == 0
          - >-
            'post_family_config_branch_edge__999_rock5a_use_mainline_uboot' in
            ((hostvars[_board_model_first_host['rock-5a']].armbian_board_userpatches | default([]))
             | selectattr('dest', 'equalto', 'config/boards/rock-5a.conf')
             | map(attribute='content') | first | default(''))
        fail_msg: >-
          rock-5a group_vars must ship the
          post_family_config_branch_edge__999_rock5a_use_mainline_uboot
          hook via dest: config/boards/rock-5a.conf (a per-board overlay
          armbian/build sources only when building rock-5a). It must NOT
          ship via the rk3588 family overlay — that defeats the
          per-board scoping.
      when: "'rock-5a' in _board_models"

    - name: Assert rock-5b ships its v2026.04 u-boot bump via per-board conf overlay
      ansible.builtin.assert:
        that:
          - "(hostvars[_board_model_first_host['rock-5b']].armbian_board_userpatches | default([])) | length >= 1"
          - >-
            (hostvars[_board_model_first_host['rock-5b']].armbian_board_userpatches | default([]))
            | selectattr('dest', 'equalto', 'config/boards/rock-5b.conf')
            | list | length == 1
          - >-
            (hostvars[_board_model_first_host['rock-5b']].armbian_board_userpatches | default([]))
            | selectattr('dest', 'equalto', 'config/sources/families/rockchip-rk3588.conf')
            | list | length == 0
          - >-
            'post_family_config_branch_edge__999_rock5b_uboot_v2026_04' in
            ((hostvars[_board_model_first_host['rock-5b']].armbian_board_userpatches | default([]))
             | selectattr('dest', 'equalto', 'config/boards/rock-5b.conf')
             | map(attribute='content') | first | default(''))
        fail_msg: >-
          rock-5b group_vars must ship the
          post_family_config_branch_edge__999_rock5b_uboot_v2026_04
          hook via dest: config/boards/rock-5b.conf. See the rock-5a
          assert above for the rationale.
      when: "'rock-5b' in _board_models"
```

- [ ] **Step 2: Run the test and confirm it FAILS**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: FAIL on the new rock-5a assert ("rock-5a group_vars must ship the … hook via dest: config/boards/rock-5a.conf"). The prerequisite plan put only `armbian_board_branch: edge` in `rock_5a.yml` — no userpatches list — so the `selectattr('dest', 'equalto', 'config/boards/rock-5a.conf') | list | length == 1` clause fails. This confirms the test is doing real work.

- [ ] **Step 3: Commit**

```bash
git add playbooks/tests/test_build_image_vars.yml
git commit -m "test(build_image): assert rock-5{a,b} ship u-boot hooks via per-board conf overlay"
```

---

## Task 2: Relocate `__999_rock5b_uboot_v2026_04` into `inventory/group_vars/rock_5b.yml`

**Files:**
- Modify: `inventory/group_vars/rock_5b.yml` (append `armbian_board_userpatches` after the existing `armbian_board_branch` line)

**Context:** The function body is unchanged from `playbooks/build_image.yml:242-248`. The internal `[[ "${BOARD}" != "rock-5b" ]] && return 0` filter is kept as defensive belt-and-suspenders even though `userpatches/config/boards/rock-5b.conf` is only sourced for that board. The comment block (currently in `playbooks/build_image.yml:225-241`) moves with it, with light edits to explain the new delivery path.

- [ ] **Step 1: Rewrite `inventory/group_vars/rock_5b.yml`**

Replace the file's content (it currently has only `armbian_board_branch: edge` plus its comment block) with:

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
# Our `__999_rock5b_uboot_v2026_04` hook below (delivered via the
# per-board conf overlay) bumps that upstream-hook's v2026.01 default
# to v2026.04. Both hooks gate on BRANCH=edge.
armbian_board_branch: edge

# ── per-board userpatches ────────────────────────────────────────────
# Delivered as a userpatches OVERLAY of config/boards/rock-5b.conf —
# armbian/build sources userpatches/config/boards/<board>.conf AFTER
# the upstream board conf, so this ADDS our hook function rather than
# replacing the upstream file (which carries the v2026.01 mainline
# pin we are bumping). The overlay is only sourced when BOARD=rock-5b
# is being built, so this hook does not run for any other rk3588 board.
#
# armbian/build's extension manager registers any function matching
# `post_family_config_branch_<branch>__*` and calls them after the
# family config is resolved, in numeric-prefix sort order. Upstream's
# `post_family_config_branch_edge__rock-5b_use_mainline_uboot` is
# auto-prefixed `500_`; ours has an explicit `__999_` numeric ID so it
# sorts after upstream and wins on the BOOTBRANCH / BOOTPATCHDIR
# re-declaration. armbian/build ships a `patch/u-boot/v2026.04/`
# directory, so BOOTPATCHDIR points at a real patch set (not at
# v2026.01 patches applied to a v2026.04 tree, which would risk
# rejects).
#
# Per the explainer (docs/uboot-armbian-build-explainer.html §8.2),
# v2026.04 does NOT clear any of rock-5b's three PXE failure layers
# on its own — Approach B (playbooks/persist_uboot_env.yml) still has
# to run to populate SPI env. The bump is just to track upstream.
armbian_board_userpatches:
  - dest: "config/boards/rock-5b.conf"
    content: |
      function post_family_config_branch_edge__999_rock5b_uboot_v2026_04() {
          [[ "${BOARD}" != "rock-5b" ]] && return 0
          [[ "${BRANCH}" != "edge" ]] && return 0
          display_alert "${BOARD}" "overriding u-boot pin to v2026.04 (was v2026.01)" "info"
          declare -g BOOTBRANCH="tag:v2026.04"
          declare -g BOOTPATCHDIR="v2026.04"
      }
```

- [ ] **Step 2: Run the test playbook**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: FAIL — but now the failure is on the rock-5a assert (the rock-5b assert passes). This confirms Task 2 worked without making the test trivially-green.

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/rock_5b.yml
git commit -m "inventory(rock_5b): relocate __999_rock5b_uboot_v2026_04 to per-board conf overlay"
```

---

## Task 3: Relocate `__999_rock5a_use_mainline_uboot` into `inventory/group_vars/rock_5a.yml`

**Files:**
- Modify: `inventory/group_vars/rock_5a.yml` (replace the file's content)

**Context:** Same shape as Task 2. The function body is unchanged from `playbooks/build_image.yml:304-324`; comment block (lines 250-303) moves with it, with light edits.

- [ ] **Step 1: Rewrite `inventory/group_vars/rock_5a.yml`**

Replace the file's content with:

```yaml
---
# Per-model vars for the rock_5a group.

# ── armbian/build BRANCH ─────────────────────────────────────────────
# armbian/build has no mainline override for rock-5a (upstream's
# config/boards/rock-5a.conf only carries a vendor-branch hook). We
# ship the override below as a per-board userpatches overlay; that
# hook gates on BRANCH=edge — this entry is what activates it.
# Without it, rock-5a would build against the Radxa fork's
# BOOT_TARGET_DEVICES X-macro form, which the `__999_pxe_first` sed
# (in playbooks/build_image.yml's build_userpatches_common) cannot
# patch — PXE stays at the end of the boot order and SD wins.
armbian_board_branch: edge

# ── per-board userpatches ────────────────────────────────────────────
# Delivered as a userpatches OVERLAY of config/boards/rock-5a.conf
# (sourced by armbian/build AFTER the upstream board conf, and only
# when BOARD=rock-5a). See inventory/group_vars/rock_5b.yml for the
# overlay-mechanism explanation.
#
# Switch rock-5a from the rk3588 family-default Radxa fork
# (next-dev-v2024.10) to mainline u-boot v2026.04 on the edge branch.
# armbian/build's config/boards/rock-5a.conf has no
# `post_family_config_branch_edge__*` hook of its own (unlike
# rock-5b), so without this override rock-5a would build against the
# Radxa fork, which:
#   1. uses the X-macro `BOOT_TARGET_DEVICES(func)` form in
#      include/configs/rockchip-common.h — the family-shared
#      `__999_pxe_first` sed against `#define BOOT_TARGETS` is
#      silently a no-op, so PXE stays at the end of the Radxa fork's
#      default order (USB → SD → NVMe → SCSI → eMMC → MTD → RKNAND
#      → PXE → DHCP) and SD wins.
#   2. has no `post_family_config_branch_edge` override at all in
#      upstream armbian/build for rock-5a (only the vendor branch
#      gets `post_family_config_branch_vendor__dual_uboot_for_rock5a`).
# Mainline v2026.04 already ships a rock5a-rk3588s_defconfig (note:
# NO dash between "rock" and "5a" — matches rock-5b's mainline naming
# pattern, distinct from the Radxa fork's rock-5a-rk3588s_defconfig).
# Upstream's rock5a defconfig includes CONFIG_PHY_REALTEK=y and a DT
# PHY node carrying the Realtek OUI compatible
# (`ethernet-phy-id001c.c916`, which is RTL8211F per the Radxa
# product page); whether that matches the specific Rock 5A revision
# in operator's hands is NOT something this file should assume. See
# "SBC ecosystem reality" in CLAUDE.md for why and how to validate
# against the live `dmesg`/`ethtool` output.
#
# The body mirrors armbian/build's
# `post_family_config_branch_edge__rock-5b_use_mainline_uboot`
# exactly (BOOT_SCENARIO + prepare_boot_configuration to reuse the
# ATF path from rockchip64_common, binman-produced
# u-boot-rockchip{,-spi}.bin via UBOOT_TARGET_MAP, custom
# write_uboot_platform{,_mtd}). Auto-prefixed `500_` by
# initialize_extension_manager would NOT happen here because this
# hook has an explicit `__999_` numeric ID; sort order only matters
# relative to any future upstream hook on the same name.
# Diverges from rock-5b's mainline override in one place:
# UBOOT_TARGET_MAP lists only u-boot-rockchip.bin (no -spi.bin
# variant). rock-5b's mainline binman config emits both SD-bootable
# and SPI-bootable images, but mainline v2026.04's rock5a binman
# config (`arch/arm/dts/rk3588s-rock-5a-u-boot.dtsi` is a near-empty
# stub) only emits the SD-bootable form. Listing u-boot-rockchip-spi.bin
# in UBOOT_TARGET_MAP makes
# `deploy_built_uboot_bins_for_one_target_to_packaging_area`
# exit_with_error after the SD bin has already been copied. We
# netboot from SD; the SPI variant is unused, so dropping it is the
# correct minimal fix (vs. the heavier alternative of patching the
# upstream u-boot DTSI to add a binman SPI image node).
# Correspondingly we don't redefine write_uboot_platform_mtd — the
# unset clears rockchip64_common's default; no MTD writer is needed
# since BOOT_SUPPORT_SPI's SPI-loader build path is not exercised
# when no SPI artifact exists.
armbian_board_userpatches:
  - dest: "config/boards/rock-5a.conf"
    content: |
      function post_family_config_branch_edge__999_rock5a_use_mainline_uboot() {
          [[ "${BOARD}" != "rock-5a" ]] && return 0
          [[ "${BRANCH}" != "edge" ]] && return 0
          display_alert "${BOARD}" "switching to mainline u-boot v2026.04 (was Radxa next-dev-v2024.10)" "info"

          BOOT_SCENARIO="tpl-blob-atf-mainline"
          prepare_boot_configuration

          declare -g BOOTCONFIG="rock5a-rk3588s_defconfig"
          declare -g BOOTDELAY=1
          declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
          declare -g BOOTBRANCH="tag:v2026.04"
          declare -g BOOTPATCHDIR="v2026.04"
          declare -g BOOTDIR="u-boot-${BOARD}"
          declare -g UBOOT_TARGET_MAP="BL31=bl31.elf ROCKCHIP_TPL=${RKBIN_DIR}/${DDR_BLOB};;u-boot-rockchip.bin"
          unset uboot_custom_postprocess write_uboot_platform write_uboot_platform_mtd

          function write_uboot_platform() {
              dd "if=$1/u-boot-rockchip.bin" "of=$2" bs=32k seek=1 conv=notrunc status=none
          }
      }
```

- [ ] **Step 2: Run the test playbook and confirm it PASSES**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS (all assertions hold). If any fail, the most likely cause is a typo in the `dest` path or a missing newline in the `content` block making the function-name substring search miss; re-read the failing assert and fix.

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/rock_5a.yml
git commit -m "inventory(rock_5a): relocate __999_rock5a_use_mainline_uboot to per-board conf overlay"
```

---

## Task 4: Strip the two relocated hooks from `build_userpatches_common`

**Files:**
- Modify: `playbooks/build_image.yml:225-324` (delete the rock-5b block at 225-248 and the rock-5a block at 250-324, preserving one blank line between the env-storage hook at line 223 `}` and the bcmdhd hook at line 326)

**Context:** With Tasks 2 and 3 in place, the family conf overlay no longer needs to carry those two hooks. The role's `apply_userpatches.yml` uses `ansible.builtin.copy` which is overwrite-style — the next build rewrites `userpatches/config/sources/families/rockchip-rk3588.conf` in full with the new `build_userpatches_common` contents, so no stale-file pollution remains from prior runs. Keep `__999_pxe_first`, `__999_local_kernel_bake`, and `__999_no_bcmdhd_for_netboot` exactly where they are — they're truly family-shared.

- [ ] **Step 1: Delete the rock-5b hook block**

In `playbooks/build_image.yml`, delete lines 225 through 248 inclusive. The deleted span starts with the comment `# Bumps rock-5b's mainline u-boot pin from armbian/build's` and ends with the closing `}` of `post_family_config_branch_edge__999_rock5b_uboot_v2026_04`. Verify by `grep -c 'rock5b_uboot_v2026_04' playbooks/build_image.yml`; expected: `0`.

- [ ] **Step 2: Delete the rock-5a hook block**

In `playbooks/build_image.yml`, delete what was lines 250 through 324 (now shifted up by 24 lines after Step 1, but locate by content). The deleted span starts with the comment `# Switch rock-5a from the rk3588 family-default Radxa fork` and ends with the closing `}` of `post_family_config_branch_edge__999_rock5a_use_mainline_uboot`. Verify by `grep -c 'rock5a_use_mainline_uboot' playbooks/build_image.yml`; expected: `0`.

- [ ] **Step 3: Verify exactly one blank line separates the env-storage hook from the bcmdhd hook**

The closing `}` of the env-storage discovery function (was at line 223) should now be followed by one blank line, then `# Suppress the bcmdhd Broadcom WiFi DKMS driver.` Open the file at the relevant span and confirm spacing. If two consecutive blank lines exist (because both deletions left a trailing blank), remove one.

- [ ] **Step 4: Run ansible-playbook --syntax-check**

```bash
ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check
```

Expected: `playbook: playbooks/build_image.yml` with no error.

- [ ] **Step 5: Run yamllint**

```bash
make yamllint
```

Expected: exit 0. The most likely failure mode is a trailing-whitespace or doubled-blank-line introduced by the deletion; fix and re-run.

- [ ] **Step 6: Run the test playbook one more time**

```bash
unset ANSIBLE_INVENTORY
ansible-playbook -i inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS. Sanity check that the strip didn't disturb the per-model variable resolution.

- [ ] **Step 7: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "refactor(build_image): drop rock-5a/rock-5b hooks from family overlay (relocated to inventory)"
```

---

## Task 5: Run the image_build molecule scenario as a role-contract regression

**Files:**
- (no file changes — verification only)

**Context:** The `image_build` molecule scenario builds an orangepi5pro image, exercising the full role path: preflight → manage_checkout → apply_userpatches → compute_inputs → check_manifest → invoke_build. The scenario does NOT exercise rock-5a or rock-5b builds (it uses orangepi5pro). What it verifies for this refactor: the role still accepts the new `armbian_build_userpatches` list shape (each entry still `{dest, content}`); the play-level resolution that includes `build_userpatches_common + per_board_userpatches` is unchanged for orangepi5pro (which has no per-board userpatches today); no per-model resolver change affects the orangepi5pro path.

Real rock-5a/rock-5b verification can only happen on hardware via `playbooks/build_image.yml` followed by `playbooks/test_fleet_e2e.yml` — out of scope for this plan and handled by operator action in Task 7.

Wall-time budget: ~5–7 minutes.

- [ ] **Step 1: Run the molecule scenario**

```bash
make molecule SCENARIO=image_build
```

Expected: full sequence (dependency → syntax → create → prepare → converge → verify → destroy) reports `PLAY RECAP` with `failed=0` on every play. In particular, the converge phase's `Apply image_build role` task must succeed — confirms the role still accepts the post-refactor input shape.

If the scenario fails on a setup/infrastructure issue unrelated to this refactor (Docker install flake, network egress hiccup), retry once. Persistent failure means this refactor broke something — diagnose before continuing.

- [ ] **Step 2: Run ansible-lint baseline check**

```bash
make ansible-lint
```

Expected: no new findings vs. the baseline at branch start. Pre-existing findings are tolerated.

- [ ] **Step 3: (No commit — verification only.)**

---

## Task 6: Update docs and the adding-armbian-board skill

**Files:**
- Modify: `CLAUDE.md` (anywhere `build_userpatches_common` is described as the home for per-board hooks)
- Modify: `.claude/skills/adding-armbian-board/SKILL.md` (Phase 4 / hook-placement guidance)

**Context:** Today CLAUDE.md and the skill direct new-board onboarders to add per-board U-Boot hooks under `build_userpatches_common` in the playbook. After this refactor, the canonical location for per-board hooks is a `dest: config/boards/<board>.conf` entry under `armbian_board_userpatches` in the matching `inventory/group_vars/<model_group>.yml`. Update both docs to reflect that, and explain WHEN to use the family overlay vs. the per-board overlay so the next onboarder doesn't have to re-derive the distinction.

- [ ] **Step 1: Audit CLAUDE.md for stale references**

Search `CLAUDE.md` for `build_userpatches_common`:
```bash
grep -n 'build_userpatches_common\|build_userpatches' CLAUDE.md
```

For each hit, decide:
- If it describes the **family-shared** PXE-first hook, leave it (the hook still lives there).
- If it describes adding **per-board** hooks, update to point at `armbian_board_userpatches` per-board conf overlays.

The most likely affected spot is the "Adding a new board" minimum-touched-files list (was already touched by the prior plan to remove `build_branches:` and `build_userpatches:`; double-check the resulting text now reflects per-board confs as one option for board-specific hooks).

- [ ] **Step 2: Add a short guidance block to CLAUDE.md**

Append to the existing collection-structure or "Adding a new board" section (whichever already covers userpatches), one paragraph explaining the family-vs-per-board overlay choice. Use this wording:

```markdown
### Where to put a new armbian/build hook

Two overlay paths are available; choose by SCOPE:

- **Family-shared** — the hook applies identically to every board in a SoC family (e.g. rk3588). Add it to `build_userpatches_common` in `playbooks/build_image.yml` under `dest: config/sources/families/<family>.conf`. Today's examples: `__999_pxe_first`, `__999_local_kernel_bake`, `__999_no_bcmdhd_for_netboot`.
- **Per-board** — the hook applies to ONE board (different `BOOTBRANCH`, different `UBOOT_TARGET_MAP`, different patchdir, etc.). Add it to `inventory/group_vars/<model_group>.yml` under `armbian_board_userpatches` with `dest: config/boards/<board>.conf`. armbian/build only sources that overlay when building the matching board, so the per-board scope is structural — no `if BOARD == ...` filter needed. Today's examples: `__999_rock5a_use_mainline_uboot`, `__999_rock5b_uboot_v2026_04`.

If you find yourself adding `[[ "${BOARD}" != "..." ]] && return 0` inside `build_userpatches_common`, that's the cue to write a per-board overlay instead.
```

(Place this block adjacent to the existing "Adding a new board" content — exact location is up to you; keep it discoverable from the table of contents if one exists.)

- [ ] **Step 3: Update the adding-armbian-board skill**

In `.claude/skills/adding-armbian-board/SKILL.md`, find the Phase 4 section. After the prior plan's edits, it currently mentions `armbian_board_userpatches` for `userpatches/` source-patch entries. Append a sentence (or short paragraph) clarifying the per-board conf overlay shape, with this wording:

```markdown
For board-specific armbian/build hook FUNCTIONS (as opposed to source patches against the kernel or U-Boot tree), use `dest: config/boards/<board>.conf`. armbian/build sources that overlay file additively on top of upstream's `config/boards/<board>.conf` only when building that board, so the hook fires per-board structurally — you do not need an internal `[[ "${BOARD}" != "..." ]] && return 0` filter (keep one as defensive belt-and-suspenders if you wish). Source-tree patches still use the `userpatches/u-boot/<version>/<board>/<NNNN-name>.patch` shape — see the orange-pi-5-max RTL8125 patch in `inventory/group_vars/orange_pi_5_max.yml` for an example.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md .claude/skills/adding-armbian-board/SKILL.md
git commit -m "docs: per-board armbian/build hooks live in per-board conf overlays"
```

---

## Task 7: Operator migration note for `.inventory/`

**Files:**
- (no file changes — produce migration instructions for the operator)

**Context:** Same situation as the prior plan's Task 9: `.inventory/` is gitignored and operator-owned. The example inventory in `inventory/group_vars/rock_5{a,b}.yml` has been updated by Tasks 2 and 3; the operator must apply equivalent changes to their real inventory before the next image build, otherwise the rock-5a and rock-5b builds will lose the v2026.04 mainline U-Boot override (the playbook no longer carries it, and the operator's real `.inventory/group_vars/rock_5{a,b}.yml` does not yet have the relocated hook).

- [ ] **Step 1: Produce paste-ready instructions for the operator**

Print this to the conversation:

```bash
# In the operator's shell, with .inventory/ as the real inventory dir:
cp inventory/group_vars/rock_5a.yml .inventory/group_vars/
cp inventory/group_vars/rock_5b.yml .inventory/group_vars/
```

If the operator has any local customisations in `.inventory/group_vars/rock_5{a,b}.yml` beyond what the example carries, they must merge (not overwrite) — the new content adds an `armbian_board_userpatches` list; existing keys like `armbian_board_branch` are unchanged in name/value.

- [ ] **Step 2: Operator sanity-checks against real inventory**

```bash
# Operator only; requires .inventory/ populated per Step 1.
ANSIBLE_INVENTORY=.inventory ansible-playbook \
  -i .inventory/ playbooks/tests/test_build_image_vars.yml
```

Expected: PASS. If FAIL, the operator's real inventory has different group names or board models than the example; reconcile case-by-case.

- [ ] **Step 3: Operator real-hardware verification (out-of-band)**

The molecule scenario in Task 5 does NOT exercise rock-5a or rock-5b. Real verification requires:
```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/build_image.yml --limit rock-5a-01,rock-5b-01
# then stage and converge as usual
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/stage_netboot_assets.yml
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/stage_router.yml
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/test_fleet_e2e.yml --limit rock-5a-01
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/test_fleet_e2e.yml --limit rock-5b-01
```

The fleet e2e test exercises the SD → NFS → SD round trip. A successful run on both boards confirms the relocated hooks still produce a PXE-capable mainline-u-boot image.

- [ ] **Step 4: (No commit — `.inventory/` is gitignored.)**

---

## Self-Review

**1. Spec coverage:**
- Move `__999_rock5a_use_mainline_uboot` from playbook to inventory → Task 3 (relocate) + Task 4 (strip from playbook). ✓
- Move `__999_rock5b_uboot_v2026_04` from playbook to inventory → Task 2 (relocate) + Task 4 (strip from playbook). ✓
- Change `dest` from family overlay path to per-board conf overlay path → Tasks 2 and 3 both use `dest: config/boards/<board>.conf`. ✓
- Keep the three truly-shared hooks in `build_userpatches_common` → Task 4 Step 1/2 explicitly delete only the two named blocks. ✓
- TDD red → green: Task 1 lands failing asserts before any relocation. ✓
- Test asserts the hook is NOT in the family overlay (regression guard) → Task 1 Step 1 asserts `selectattr('dest', 'equalto', 'config/sources/families/rockchip-rk3588.conf') | list | length == 0` for each of rock-5a and rock-5b. ✓
- Docs updated → Task 6. ✓
- Operator migration path for `.inventory/` → Task 7. ✓
- Role contract preservation → Task 5 (molecule regression) verifies no role-contract drift. ✓

**2. Placeholder scan:**
- No "TBD" / "implement later" instances.
- Every step shows the actual code/commands to apply.
- Function bodies in Tasks 2 and 3 are reproduced verbatim from the source playbook lines, not summarised or referenced by line range alone.

**3. Type consistency:**
- `armbian_board_userpatches` is always `list[{dest: str, content: str}]` — matches the role's existing input contract and the prior plan's contract.
- `dest` is always a string path relative to `userpatches/` (no leading `/`, no `..` — the role's `apply_userpatches.yml` asserts both).
- `content` is always a multi-line YAML literal block scalar (`|`) preserving leading-tab indentation inside the bash function body.
- Function names (`post_family_config_branch_edge__999_rock5{a,b}_*`) are identical in inventory and in the Task 1 test-harness substring search.

**4. Edge cases verified:**
- Stale family-overlay file on the builder host from a prior run carrying the old hooks → the role uses `ansible.builtin.copy` which is overwrite-style; Task 4's next build rewrites `userpatches/config/sources/families/rockchip-rk3588.conf` in full with only the three remaining hooks, removing the relocated ones automatically. No manual cleanup needed.
- Build of orange-pi-5{,_pro,_max} after this refactor → their per-board overlays don't exist (those boards don't have `armbian_board_userpatches` carrying a `config/boards/*.conf` entry); the three family-shared hooks still fire via the family overlay. Behaviour unchanged.
- Build of rock-5a or rock-5b with `armbian_board_branch: current` (someone manually overrides) → the relocated hooks have `[[ "${BRANCH}" != "edge" ]] && return 0` as belt-and-suspenders; they no-op. armbian/build's hook-name `_branch_edge_` segment also gates discovery at the extension-manager level. Belt-and-suspenders is intentional.
- A future board added with its own per-board hook → the operator follows the new CLAUDE.md guidance from Task 6: per-board conf overlay in inventory. No playbook touch needed.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-26-per-board-uboot-hooks-relocation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
