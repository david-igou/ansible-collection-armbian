# v1 Scope Narrowing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trim the collection to a single deliverable for v1 — `orangepi5pro` netboot capability via custom Armbian image + RouterOS DHCP toggle. Reprovisioning, on-host bootloader flashing, and all other boards are deleted from the repo.

**Architecture:** Move shared board metadata out of the to-be-deleted `bootloader` role into a collection-level `vars/boards.yml`, slim `routeros_dhcp` to only the `nfsroot` mode, drop `host_board_overrides`, then delete `roles/bootloader/`, `roles/reprovision/`, and the playbooks that drive them. Rewrite documentation around the v1 surface.

**Tech Stack:** Ansible collection, RouterOS via `community.routeros`, NFS/TFTP content management on a netboot server, custom Armbian image build via `armbian/build`.

**Spec:** [`docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](../specs/2026-05-07-v1-scope-narrowing-design.md)

---

## File Structure

**Create:**
- `vars/boards.yml` — collection-level shared board metadata table; one entry (`orange-pi-5-pro`).

**Modify:**
- `roles/nfs_content/tasks/preflight.yml` — drop apt-package existence check; keep image URL HEAD check.
- `roles/nfs_content/tasks/main.yml` — `include_vars` path moves to new `vars/boards.yml`.
- `roles/nfs_content/defaults/main.yml` — drop `nfs_reprovision_path`.
- `roles/nfs_content/tasks/per_board.yml` — drop reprovision wording in the assets-copy task name.
- `roles/routeros_dhcp/defaults/main.yml` — drop `routeros_opt_set_reprovision_prefix`, drop `netboot_modes.reprovision`.
- `roles/routeros_dhcp/tasks/setup_options.yml` — drop the reprovision option-67 entry and the `armbian-reprovision` option set.
- `roles/routeros_dhcp/tasks/enable_netboot.yml` — drop `netboot_mode` validation, unconditionally set `dhcp-option=armbian-nfsroot`.
- `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml` — drop `netboot_mode` validation; `include_vars` path moves to new `vars/boards.yml`.
- `roles/routeros_dhcp/tasks/disable_netboot.yml` — trim the "called from reprovision.yml" comment.
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — drop the `reprovision` branch (`netboot_mode`-conditional sections).
- `roles/routeros_dhcp/README.md` — drop reprovision option-set documentation.
- `roles/nfs_content/README.md` — drop reprovision references.
- `roles/bootstrap_armbian/README.md` — drop references to deleted playbooks.
- `playbooks/build_image.yml` — `include_vars` path moves; drop the `host_board_overrides.armbian_build_enabled` filter (build all unique board_models in inventory).
- `playbooks/enable_netboot.yml` — drop the `netboot_mode=reprovision` example from the comment block.
- `playbooks/disable_netboot.yml` — drop the "cancel a queued reprovision" wording in the comment.
- `playbooks/setup_routeros_dhcp.yml` — drop the `armbian-reprovision*` lines from the comment block.
- `playbooks/populate_nfs_content.yml` — drop "for the reprovision role to fetch" wording.
- `playbooks/test_hardware_e2e.yml` — drop the `host_board_overrides.armbian_build_enabled` warning task; drop `netboot_mode: nfsroot` (now redundant) from the enable-netboot include.
- `inventory/hosts.yml` — prune to `orange-pi-5-pro` only; drop `host_board_overrides` example block.
- `inventory/group_vars/all.yml` — drop `armbian_apt_suite`, `armbian_branch`; prune `armbian_image_urls` to `orange-pi-5-pro`.
- `CLAUDE.md` — rewrite around v1 framing.
- `docs/architecture.md` — rewrite to v1 model.
- `docs/routeros-setup.md` — light trim if anything references reprovision.

**Delete:**
- `roles/bootloader/` (entire directory).
- `roles/reprovision/` (entire directory).
- `playbooks/flash_bootloader.yml`.
- `playbooks/reprovision.yml`.
- `docs/board-bootloader.md`.

**Verification approach:** This is an Ansible repo with no formal test suite. Verification at each task is `make lint` (yamllint + ansible-lint), `ansible-playbook --syntax-check` for any modified playbook, and — at the end — a real `setup_routeros_dhcp.yml` run against RouterOS to confirm the slimmed object set still produces an idempotent 3-object state (option 66 + nfsroot bootfile + nfsroot bundle).

---

### Task 1: Add `vars/boards.yml` at collection root

**Why first:** Every subsequent task that migrates an `include_vars` path needs the new file to exist. Creating it first means the migrations are cherry-pickable.

**Files:**
- Create: `vars/boards.yml`

- [ ] **Step 1: Create `vars/boards.yml`**

```yaml
---
# Per-board metadata for boards in v1 scope. Keyed by board_model
# (matches inventory host_vars and pxelinux paths).
#
# v1 fields:
#   armbian_dl_dir       dl.armbian.com subdirectory (documentation
#                        pointer; not used by code post-slim)
#   armbian_board_name   armbian/build BOARD= target. Used by
#                        playbooks/build_image.yml to map board_model
#                        to the build target string.
#   armbian_support      Armbian support tier (standard / community /
#                        wip / unsupported). Documentation only.
#   dtb                  Device tree path under /boot/dtb/. Used by
#                        roles/nfs_content/tasks/per_board.yml.
#   console              Kernel console parameter. Used by
#                        roles/routeros_dhcp/templates/pxelinux_cfg.j2.

board_configs:
  orange-pi-5-pro:
    armbian_dl_dir: orangepi5pro
    armbian_board_name: orangepi5pro
    armbian_support: community
    dtb: rockchip/rk3588s-orangepi-5-pro.dtb
    console: ttyS2,1500000n8
```

- [ ] **Step 2: Verify yamllint passes**

```bash
yamllint -c .yamllint.yml vars/boards.yml
```

Expected: no output (success).

- [ ] **Step 3: Commit**

```bash
git add vars/boards.yml
git commit -m "Add collection-level vars/boards.yml for v1 board metadata"
```

---

### Task 2: Slim `nfs_content` preflight and defaults

**Why now:** Drops the apt-package check that depends on `uboot_apt_package` (a field that won't exist in the new `vars/boards.yml`). Also drops the `nfs_reprovision_path` default. Doing this before migrating the include_vars path means the consumer is field-aligned with the new vars file ahead of the path switch.

**Files:**
- Modify: `roles/nfs_content/tasks/preflight.yml`
- Modify: `roles/nfs_content/defaults/main.yml`
- Modify: `roles/nfs_content/tasks/per_board.yml` (comment trim only)

- [ ] **Step 1: Replace `roles/nfs_content/tasks/preflight.yml`**

```yaml
---
# Pre-flight validation for populate_nfs_content.yml.
#
# Catches one class of misconfiguration that would otherwise surface
# late: armbian_image_urls[<model>] is unreachable (404, dead mirror,
# typo). Without this check, failure shows up after we've created loop
# devices and started extracting.

- name: Validate each board's image URL is reachable
  ansible.builtin.uri:
    url: "{{ armbian_image_urls[item] }}"
    method: HEAD
    status_code: [200, 302]
    follow_redirects: all
    timeout: 30
  register: _image_url_check
  failed_when: _image_url_check.status not in [200, 302]
  loop: "{{ _board_models }}"
  loop_control:
    label: "{{ item }} → {{ armbian_image_urls[item] | default('(unset)') }}"
  when: armbian_image_urls[item] is defined

- name: Fail if any board lacks an image URL
  ansible.builtin.fail:
    msg: |
      armbian_image_urls['{{ item }}'] is not set in
      inventory/group_vars/all.yml. Add the full .img.xz URL.
  when: armbian_image_urls[item] is not defined
  loop: "{{ _board_models }}"

- name: Preflight passed
  ansible.builtin.debug:
    msg: >-
      Preflight OK: validated image URLs for
      {{ _board_models | length }} board model(s).
```

- [ ] **Step 2: Drop `nfs_reprovision_path` and the apt URL var from `roles/nfs_content/defaults/main.yml`**

Remove these lines from the file:

```yaml
nfs_reprovision_path: /exports/reprovision
```

And remove the `armbian_apt_packages_url` block at the bottom of the file (the `armbian_apt_packages_url: >-` definition and the surrounding comment block about Armbian apt mirror — preflight no longer fetches `Packages.gz`).

Also delete the comment lines mentioning the reprovision role's HTTP download from the `nfs_assets_export` doc block (`# reprovision role downloads from ...`).

- [ ] **Step 3: Trim reprovision wording in `roles/nfs_content/tasks/per_board.yml`**

Find the task whose name is "Copy Armbian image to assets for reprovision HTTP download" (around line 112) and rename it to:

```yaml
- name: Copy Armbian image to assets for HTTP download
```

(Task body unchanged — it is still the right behavior; only the name references reprovision.)

- [ ] **Step 4: Verify yamllint and ansible-lint**

```bash
make lint
```

Expected: passes (or fails only on pre-existing warnings unrelated to these files).

- [ ] **Step 5: Commit**

```bash
git add roles/nfs_content/tasks/preflight.yml \
        roles/nfs_content/defaults/main.yml \
        roles/nfs_content/tasks/per_board.yml
git commit -m "Slim nfs_content preflight to URL HEAD only and drop reprovision defaults"
```

---

### Task 3: Migrate `include_vars` paths to `vars/boards.yml`

**Why now:** Moves all consumers of board metadata to the new file in one commit, so the next tasks can delete `roles/bootloader/` without a flush of broken includes.

**Files:**
- Modify: `roles/nfs_content/tasks/main.yml`
- Modify: `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml`
- Modify: `playbooks/build_image.yml`

- [ ] **Step 1: Update `roles/nfs_content/tasks/main.yml`**

Find the block at lines 13-15 and replace:

```yaml
- name: Load board configs
  ansible.builtin.include_vars:
    file: "{{ role_path }}/../bootloader/vars/boards.yml"
```

with:

```yaml
- name: Load board configs
  ansible.builtin.include_vars:
    file: "{{ role_path }}/../../vars/boards.yml"
```

(The role lives at `roles/nfs_content/`, so `../../vars/boards.yml` resolves to the collection root.)

- [ ] **Step 2: Update `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml`**

Find the block around lines 21-28 and replace:

```yaml
# Load the per-board configs the pxelinux template needs (board console,
# DTB filename). These live in the bootloader role's vars/ tree; we
# include them here rather than depending on the bootloader role being
# referenced from this play.
- name: Load board configs
  ansible.builtin.include_vars:
    file: "{{ role_path }}/../bootloader/vars/boards.yml"
  tags: pxelinux
```

with:

```yaml
# Load the per-board configs the pxelinux template needs (board console,
# DTB filename). These live in the collection-level vars/boards.yml so
# this role does not depend on any other role being present.
- name: Load board configs
  ansible.builtin.include_vars:
    file: "{{ role_path }}/../../vars/boards.yml"
  tags: pxelinux
```

- [ ] **Step 3: Update `playbooks/build_image.yml`**

In the `pre_tasks` block (lines 51-67), replace the existing `include_vars` and `set_fact` tasks with:

```yaml
  pre_tasks:
    - name: Load board configs for board name lookup
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

    - name: Resolve build targets from inventory hosts
      ansible.builtin.set_fact:
        _build_targets: >-
          {{ groups['boards']
             | map('extract', hostvars, 'board_model')
             | unique
             | map('extract', board_configs, 'armbian_board_name')
             | list }}

    - name: Report build targets
      ansible.builtin.debug:
        msg: "Will build images for: {{ _build_targets }}"
```

(Drops `_bootloader_vars` indirection — `include_vars` without `name:` injects `board_configs` as a top-level fact. Drops the `host_board_overrides.armbian_build_enabled` filter since v1 has no opt-out path.)

- [ ] **Step 4: Verify lint and syntax-check**

```bash
make lint
ansible-playbook --syntax-check playbooks/populate_nfs_content.yml playbooks/enable_netboot.yml playbooks/build_image.yml
```

Expected: lint passes, syntax-check passes.

- [ ] **Step 5: Commit**

```bash
git add roles/nfs_content/tasks/main.yml \
        roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml \
        playbooks/build_image.yml
git commit -m "Migrate board metadata include_vars to collection-level vars/boards.yml

Drops cross-role file path. build_image.yml also drops the
host_board_overrides.armbian_build_enabled filter — v1 has no opt-out
path, every board_model in inventory gets built."
```

---

### Task 4: Slim `routeros_dhcp` defaults and `setup_options.yml`

**Why now:** Removes the reprovision option set from RouterOS object creation. Done before deleting `playbooks/reprovision.yml` so the role internally goes to the v1 shape first; the playbook delete in Task 9 is then a clean drop with no internal references left to chase.

**Files:**
- Modify: `roles/routeros_dhcp/defaults/main.yml`
- Modify: `roles/routeros_dhcp/tasks/setup_options.yml`

- [ ] **Step 1: Replace `roles/routeros_dhcp/defaults/main.yml`**

```yaml
---
# Name of the DHCP server on RouterOS to manage
routeros_dhcp_server_name: "dhcp1"

# DHCP option names created once during setup (setup_options.yml playbook)
routeros_opt_tftp_name: "armbian-tftp-server"
routeros_opt_set_nfsroot_prefix: "armbian-nfsroot"

# Boot mode pxelinux config path served from TFTP
netboot_modes:
  nfsroot: "pxelinux.cfg/nfsroot-default"
```

- [ ] **Step 2: Replace `roles/routeros_dhcp/tasks/setup_options.yml`**

```yaml
---
# Creates the reusable DHCP option objects on RouterOS.
# Run once (or after a RouterOS reset) before using enable/disable netboot.
#
# RouterOS DHCP option structure for PXE:
#   option 66 (TFTP server)  → routeros_opt_tftp_name
#   option 67 (boot file)    → armbian-nfsroot-bootfile (nfsroot mode)
#   option set               → armbian-nfsroot (bundles 66 + nfsroot 67)

- name: Create DHCP option — TFTP server (option 66)
  community.routeros.command:
    commands:
      - >
        /ip dhcp-server option
        add name="{{ routeros_opt_tftp_name }}"
        code=66
        value="'{{ tftp_server_ip | default(netboot_server_ip) }}'"
  register: _opt_tftp
  changed_when: >
    (_opt_tftp.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  failed_when: >
    'failure' in (_opt_tftp.stdout | default([]) | join(' '))
    and (_opt_tftp.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  tags: routeros, routeros_setup

- name: Create DHCP option — nfsroot boot file (option 67)
  community.routeros.command:
    commands:
      - >
        /ip dhcp-server option
        add name="{{ routeros_opt_set_nfsroot_prefix }}-bootfile"
        code=67
        value="'{{ netboot_modes.nfsroot }}'"
  register: _opt_bootfile
  changed_when: >
    (_opt_bootfile.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  failed_when: >
    'failure' in (_opt_bootfile.stdout | default([]) | join(' '))
    and (_opt_bootfile.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  tags: routeros, routeros_setup

- name: Create DHCP option set — bundle TFTP + nfsroot boot file
  community.routeros.command:
    commands:
      - >
        /ip dhcp-server option sets
        add name="{{ routeros_opt_set_nfsroot_prefix }}"
        options="{{ routeros_opt_tftp_name }},{{ routeros_opt_set_nfsroot_prefix }}-bootfile"
  register: _opt_sets
  changed_when: >
    (_opt_sets.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  failed_when: >
    'failure' in (_opt_sets.stdout | default([]) | join(' '))
    and (_opt_sets.stdout | default([]) | join(' ') | regex_search('already exists|must be unique')) is none
  tags: routeros, routeros_setup
```

(Result: 3 RouterOS objects per run instead of 5. The `register` names are kept for parity with the originals so any external review tooling still maps cleanly.)

- [ ] **Step 3: Verify yamllint and ansible-lint**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git add roles/routeros_dhcp/defaults/main.yml roles/routeros_dhcp/tasks/setup_options.yml
git commit -m "Slim routeros_dhcp setup_options to nfsroot mode only

Drops the armbian-reprovision option set and bootfile, and the
netboot_modes.reprovision default. Setup now creates 3 RouterOS
objects: option 66, the nfsroot bootfile, and the armbian-nfsroot
bundle."
```

---

### Task 5: Slim `routeros_dhcp` enable_netboot + write_pxelinux_cfg + template

**Why now:** Drops the `nfsroot` / `reprovision` conditional that's no longer relevant. Same justification as Task 4 — internal slim before deleting the reprovision playbook.

**Files:**
- Modify: `roles/routeros_dhcp/tasks/enable_netboot.yml`
- Modify: `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml`
- Modify: `roles/routeros_dhcp/templates/pxelinux_cfg.j2`
- Modify: `roles/routeros_dhcp/tasks/disable_netboot.yml`

- [ ] **Step 1: Replace `roles/routeros_dhcp/tasks/enable_netboot.yml`**

```yaml
---
# Sets the PXE DHCP option set on a board's static lease, switching it
# into PXE boot on the next DHCP renewal. Designed to be run from a play
# with `hosts: routeros_routers`.
#
# This task file deliberately does not touch the netboot server's TFTP
# config — that is `write_pxelinux_cfg.yml`'s responsibility, and it
# runs in a separate play against `hosts: netboot_server` so the control
# node never NFS-mounts the export.
#
# Required variables: board_mac

- name: Assign netboot DHCP option set for {{ board_mac }}
  community.routeros.command:
    commands:
      - >
        /ip dhcp-server lease
        set [find mac-address="{{ board_mac }}"]
        dhcp-option="{{ routeros_opt_set_nfsroot_prefix }}"
  tags: routeros, enable_netboot
```

- [ ] **Step 2: Replace `roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml`**

```yaml
---
# Writes the per-board pxelinux.cfg file directly on the netboot server's
# filesystem. Designed to be run from a play with `hosts: netboot_server`,
# `become: true` — it operates on `tftp_nfs_export` as a local path, the
# same way nfs_content does. No NFS mount on the control node.
#
# Required variables:
#   board_mac          MAC address of the board (drives 01-<mac> filename)
#   board_model        board model key (drives kernel/initrd/DTB paths)
#   target_board_host  inventory hostname (drives nfsroot path + label)

# Load the per-board configs the pxelinux template needs (board console,
# DTB filename) from the collection-level vars/boards.yml.
- name: Load board configs
  ansible.builtin.include_vars:
    file: "{{ role_path }}/../../vars/boards.yml"
  tags: pxelinux

- name: Ensure pxelinux.cfg directory exists on netboot server
  ansible.builtin.file:
    path: "{{ tftp_nfs_export }}/pxelinux.cfg"
    state: directory
    mode: "0755"
  tags: pxelinux

- name: Generate pxelinux.cfg for {{ target_board_host }}
  ansible.builtin.template:
    src: "{{ role_path }}/templates/pxelinux_cfg.j2"
    dest: >-
      {{ tftp_nfs_export }}/pxelinux.cfg/01-{{
        board_mac | lower | replace(':', '-')
      }}
    mode: "0644"
  tags: pxelinux
```

- [ ] **Step 3: Slim `roles/routeros_dhcp/templates/pxelinux_cfg.j2`**

Read the file first to see its current shape:

```bash
cat roles/routeros_dhcp/templates/pxelinux_cfg.j2
```

Then drop any `{% if netboot_mode == 'reprovision' %}` / `{% else %}` / `{% endif %}` branches, keeping only the `nfsroot`-mode body. The two `console={{ board_configs[board_model].console }}` references (lines 16 and 28) currently sit in different branches — collapse to a single APPEND/KERNEL/INITRD block that always points at the per-host nfsroot path. The template name (`DEFAULT`) can stay as `nfsroot-default` to match `netboot_modes.nfsroot`.

If the template is hard to follow, the post-slim file should look like:

```jinja
{# pxelinux.cfg per-board file. Boots the per-host NFS rootfs. #}
default nfsroot
prompt 0

label nfsroot
    kernel armbian/{{ board_model }}/vmlinuz
    initrd armbian/{{ board_model }}/initrd.img
    append console={{ board_configs[board_model].console }} \
           console=tty1 \
           root=/dev/nfs \
           nfsroot={{ nfs_server_ip | default(netboot_server_ip) }}:{{ nfs_rootfs_path }}/{{ target_board_host }},vers=4.2 \
           ip=dhcp \
           rootwait
```

(Adjust to the file's actual structure — preserve any other lines that are not reprovision-conditional.)

- [ ] **Step 4: Trim `roles/routeros_dhcp/tasks/disable_netboot.yml` comment**

Edit lines 5-6 from:

```yaml
# Called automatically by reprovision.yml after flashing (via SSH to RouterOS).
# Can also be run manually via the disable_netboot.yml playbook to cancel a
# queued netboot.
```

to:

```yaml
# Called via the disable_netboot.yml playbook to revert a board to disk boot.
```

Also drop the now-stale "non-SPI boards" paragraph (lines 7-11) — that paragraph references the deleted bootloader role's worldview. Keep the "Required variables: board_mac" line.

- [ ] **Step 5: Verify lint and syntax-check**

```bash
make lint
ansible-playbook --syntax-check playbooks/setup_routeros_dhcp.yml playbooks/enable_netboot.yml playbooks/disable_netboot.yml
```

- [ ] **Step 6: Commit**

```bash
git add roles/routeros_dhcp/tasks/enable_netboot.yml \
        roles/routeros_dhcp/tasks/write_pxelinux_cfg.yml \
        roles/routeros_dhcp/templates/pxelinux_cfg.j2 \
        roles/routeros_dhcp/tasks/disable_netboot.yml
git commit -m "Slim routeros_dhcp tasks and template to nfsroot-only

Drops the netboot_mode='nfsroot'|'reprovision' validation and the
reprovision branch in pxelinux_cfg.j2. enable_netboot task now
unconditionally sets dhcp-option=armbian-nfsroot."
```

---

### Task 6: Trim playbook comment blocks

**Why now:** Cleans up the user-facing usage docs in playbook headers ahead of deleting the reprovision/flash_bootloader playbooks. Pure prose; no behavior changes.

**Files:**
- Modify: `playbooks/enable_netboot.yml`
- Modify: `playbooks/disable_netboot.yml`
- Modify: `playbooks/setup_routeros_dhcp.yml`
- Modify: `playbooks/populate_nfs_content.yml`

- [ ] **Step 1: Update `playbooks/enable_netboot.yml` header**

Replace the header comment block (lines 1-26, before the first `- name:`) with:

```yaml
---
# Enables network boot for one or more boards.
# Writes per-host pxelinux.cfg directly on the netboot server over SSH,
# assigns the armbian-nfsroot DHCP option set on RouterOS, and optionally
# reboots boards to apply the change.
#
# Usage:
#   # Enable NFS root mode for a specific board
#   ansible-playbook playbooks/enable_netboot.yml --limit orange-pi-5-pro-01
#
#   # Enable for all boards
#   ansible-playbook playbooks/enable_netboot.yml
#
#   # Enable without rebooting (e.g. board is currently off)
#   ansible-playbook playbooks/enable_netboot.yml \
#     --limit orange-pi-5-pro-01 \
#     -e netboot_reboot=false
```

- [ ] **Step 2: Update `playbooks/disable_netboot.yml` header**

Replace lines 1-7 with:

```yaml
---
# Reverts boards to disk boot by clearing the armbian-nfsroot DHCP option
# set from each board's static lease.
#
# Usage:
#   ansible-playbook playbooks/disable_netboot.yml --limit orange-pi-5-pro-01
```

- [ ] **Step 3: Update `playbooks/setup_routeros_dhcp.yml` header**

Replace the comment block (lines 1-21) with:

```yaml
---
# Creates the shared RouterOS DHCP option objects that per-board
# enable_netboot / disable_netboot runs reuse:
#
#   - dhcp-option `armbian-tftp-server`           (option 66)
#   - dhcp-option `armbian-nfsroot-bootfile`      (option 67)
#   - option set  `armbian-nfsroot`               (bundles 66 + 67)
#
# Per-board state is exclusively the `dhcp-option` field on each static
# lease — set by enable_netboot.yml / cleared by disable_netboot.yml.
# This playbook only manages the shared object set; it is idempotent and
# typically only needs to run once per RouterOS device.
#
# Re-run after RouterOS firmware upgrades that may have reset
# `/ip dhcp-server option` state, or any time you change
# `routeros_dhcp_*` variable defaults.
#
# Usage:
#   ansible-playbook playbooks/setup_routeros_dhcp.yml
```

- [ ] **Step 4: Update `playbooks/populate_nfs_content.yml` comment**

In the comment block (lines 13-15), replace:

```yaml
#   - Publishes a copy of the `.img.xz` to the HTTP assets directory
#     for the reprovision role to fetch
```

with:

```yaml
#   - Publishes a copy of the `.img.xz` to the HTTP assets directory
```

Also update line 8 (the preflight description) — replace:

```yaml
# Pre-flights every board's `uboot_apt_package` against the Armbian apt
# repo and HEAD-checks every `armbian_image_urls` entry before any
# destructive work; failures here surface at apt/URL config time, not
# halfway through an extraction.
```

with:

```yaml
# Pre-flights every `armbian_image_urls` entry with an HTTP HEAD before
# any destructive work; URL failures surface at config time, not
# halfway through an extraction.
```

- [ ] **Step 5: Verify yamllint**

```bash
yamllint -c .yamllint.yml playbooks/
```

- [ ] **Step 6: Commit**

```bash
git add playbooks/enable_netboot.yml \
        playbooks/disable_netboot.yml \
        playbooks/setup_routeros_dhcp.yml \
        playbooks/populate_nfs_content.yml
git commit -m "Trim reprovision references from playbook usage docs"
```

---

### Task 7: Update `test_hardware_e2e.yml`

**Why now:** Drops references to v1-deleted concepts: the `host_board_overrides.armbian_build_enabled` warning task and the now-redundant `netboot_mode: nfsroot` var pass.

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml`

- [ ] **Step 1: Drop the `host_board_overrides` warning task**

Delete the task block at lines 94-101 in `playbooks/test_hardware_e2e.yml`:

```yaml
    - name: Pre-flight — warn if board not opted into custom build
      ansible.builtin.debug:
        msg: >-
          WARNING: host_board_overrides.armbian_build_enabled is not true on
          {{ inventory_hostname }}. v1 starts from a manually flashed SD card,
          so this is allowed — but if you meant to use a custom build, the
          inventory state is inconsistent.
      when: not (host_board_overrides.armbian_build_enabled | default(false))
```

- [ ] **Step 2: Drop the `netboot_mode: nfsroot` var pass**

In the Phase 2 `include_role` block (around line 209), remove the `netboot_mode: nfsroot` line so the block reads:

```yaml
        - name: Phase 2 — set DHCP option to armbian-nfsroot
          block:
            - name: Phase 2 — include routeros_dhcp enable_netboot
              ansible.builtin.include_role:
                name: routeros_dhcp
                tasks_from: enable_netboot.yml
              vars:
                board_mac: "{{ board_mac }}"
          delegate_to: "{{ _routeros_target }}"
```

- [ ] **Step 3: Verify lint and syntax-check**

```bash
make lint
ansible-playbook --syntax-check playbooks/test_hardware_e2e.yml
```

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "Drop host_board_overrides and netboot_mode refs from test_hardware_e2e"
```

---

### Task 8: Trim role READMEs

**Why now:** Same as Task 6 — clean prose ahead of deletions. The READMEs still accurately describe role behavior post-slim, just need surgical removal of reprovision/bootloader references.

**Files:**
- Modify: `roles/routeros_dhcp/README.md`
- Modify: `roles/nfs_content/README.md`
- Modify: `roles/bootstrap_armbian/README.md`

- [ ] **Step 1: Read and trim `roles/routeros_dhcp/README.md`**

```bash
cat roles/routeros_dhcp/README.md
```

Remove every reference to `armbian-reprovision`, the reprovision option set, `routeros_opt_set_reprovision_prefix`, and any "Enable PXE reprovision mode for a board" example block. The README's structural sections (Overview, Tasks, Variables, Usage) all stay — just collapse the per-mode listings to nfsroot-only.

- [ ] **Step 2: Read and trim `roles/nfs_content/README.md`**

```bash
cat roles/nfs_content/README.md
```

Remove every reference to `nfs_reprovision_path` (variable), the reprovision role, and "so the `reprovision` role can fetch it from inside the NFS-booted ..." wording.

- [ ] **Step 3: Read and trim `roles/bootstrap_armbian/README.md`**

```bash
cat roles/bootstrap_armbian/README.md
```

Remove references to:
- "would otherwise hang the apt install step in the bootloader role"
- `flash_bootloader.yml`
- `reprovision.yml`
- The framing around "playbooks connect as the provisioned user"

Keep the role's actual behavior description (provisions SSH-key user with passwordless sudo on a freshly flashed Armbian).

- [ ] **Step 4: Verify yamllint (if it scans markdown — it shouldn't, but check)**

```bash
make lint
```

- [ ] **Step 5: Commit**

```bash
git add roles/routeros_dhcp/README.md \
        roles/nfs_content/README.md \
        roles/bootstrap_armbian/README.md
git commit -m "Trim reprovision and bootloader references from role READMEs"
```

---

### Task 9: Delete `flash_bootloader.yml` and `reprovision.yml` playbooks

**Why now:** All non-deleted code has been migrated off these playbooks' surface (option sets, task files, vars). Safe drop.

**Files:**
- Delete: `playbooks/flash_bootloader.yml`
- Delete: `playbooks/reprovision.yml`

- [ ] **Step 1: Delete the playbooks**

```bash
git rm playbooks/flash_bootloader.yml playbooks/reprovision.yml
```

- [ ] **Step 2: Verify nothing references them**

```bash
grep -rn "flash_bootloader\.yml\|reprovision\.yml" \
  --include="*.yml" --include="*.yaml" --include="*.md" \
  /workspace/ansible-collection-armbian_netboot/ \
  | grep -v "docs/superpowers/"
```

Expected: only matches inside `docs/superpowers/specs/` (historical specs may name them) and possibly `CLAUDE.md` (will be rewritten in Task 14). No matches in `roles/`, `playbooks/`, `inventory/`, top-level `docs/`.

- [ ] **Step 3: Verify ansible-lint**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git commit -m "Delete reprovision.yml and flash_bootloader.yml playbooks

Reprovisioning and on-host bootloader flashing are out of v1 scope
per docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md.
Re-introduction post-v1 should re-derive against the slimmer model."
```

---

### Task 10: Delete `roles/bootloader/`, `roles/reprovision/`, and `docs/board-bootloader.md`

**Why now:** Nothing references the role internals anymore. The board metadata moved to `vars/boards.yml` in Task 1; the playbooks that imported these roles are gone (Task 9).

**Files:**
- Delete: `roles/bootloader/` (entire directory)
- Delete: `roles/reprovision/` (entire directory)
- Delete: `docs/board-bootloader.md`

- [ ] **Step 1: Delete the roles and the bootloader doc**

```bash
git rm -r roles/bootloader/ roles/reprovision/ docs/board-bootloader.md
```

- [ ] **Step 2: Verify no surviving references**

```bash
grep -rn "roles/bootloader\|roles/reprovision\|docs/board-bootloader" \
  --include="*.yml" --include="*.yaml" --include="*.md" \
  /workspace/ansible-collection-armbian_netboot/ \
  | grep -v "docs/superpowers/"
```

Expected: zero matches outside `docs/superpowers/`. Some matches inside `CLAUDE.md` are expected — that's rewritten in Task 14.

- [ ] **Step 3: Verify ansible-lint**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git commit -m "Delete bootloader and reprovision roles, docs/board-bootloader.md

Custom Armbian images built by armbian_build replace on-host U-Boot
flashing as v1's PXE-first delivery mechanism. The bootloader role's
SoC-family flash strategies (SPI, eMMC boot partition, eMMC user-area
seek, in-place SD) and the reprovision role's NFS-rooted disk-flash
flow are deferred to a later phase.

Spec: docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md"
```

---

### Task 11: Trim `inventory/hosts.yml` to v1 scope

**Why now:** Sample inventory needs to reflect v1 reality once the bootloader concepts are gone.

**Files:**
- Modify: `inventory/hosts.yml`

- [ ] **Step 1: Replace `inventory/hosts.yml`**

```yaml
---
# DOCUMENTATION-ONLY INVENTORY — not used at runtime.
# The real inventory lives in .inventory/ (gitignored) and is picked up
# by Ansible's default inventory search. This file exists solely to
# illustrate the expected group structure, host variables, and naming
# conventions for users setting up their own inventory.
#
# v1 supports the Orange Pi 5 Pro only (board_model: orange-pi-5-pro).
# The board boots from a manually flashed SD card containing a custom
# Armbian image built via playbooks/build_image.yml. Its U-Boot tries
# PXE first; when DHCP advertises an armbian-nfsroot option set the
# board NFS-roots, otherwise it falls through to the SD rootfs.
#
# Multiple hosts of the same board_model are supported: each gets its
# own NFS rootfs export, hostname, machine-id, and SSH host keys (see
# nfs_content/tasks/per_host.yml). The model-level template in
# nfs_rootfs_path/_templates/<board_model>/ is shared via
# `cp --reflink=auto`, so storage cost stays at one rootfs per model
# on filesystems that support reflinks (XFS, btrfs, ZFS).

all:
  children:
    netboot_server:
      hosts:
        netboot-server:
          ansible_host: 192.168.1.10
          ansible_user: ansible
          ansible_become: true

    # Hosts that run armbian/build to produce custom .img.xz images,
    # consumed by populate_nfs_content via armbian_image_urls overridden
    # to the netboot server's HTTP assets path.
    armbian_builders:
      hosts:
        builder-01:
          ansible_host: 192.0.2.50
          ansible_user: builder
          ansible_become: true

    # `routeros` is the parent of every RouterOS device this collection
    # touches. Per-host SSH settings (ansible_user, ansible_port) live
    # directly on the host entries below; group_vars/routeros.yml pins
    # only the network_cli connection plumbing.
    routeros:
      children:
        routeros_routers:
        routeros_switches:

    # Routers run a DHCP server. setup_routeros_dhcp.yml,
    # enable_netboot.yml, and disable_netboot.yml all target this group
    # — the DHCP-mutating commands would fail on switches.
    routeros_routers:
      hosts:
        router:
          ansible_host: 192.168.1.1
          ansible_user: ansible-netboot
          ansible_port: 22

    # Switches that should also be provisioned with the same
    # ansible-netboot SSH user, but are not the DHCP server this
    # collection drives. Only targeted by bootstrap_routeros_user.yml
    # (via the routeros_netboot parent group).
    routeros_switches:
      hosts:
        switch:
          ansible_host: 192.168.1.2
          ansible_user: ansible-netboot
          ansible_port: 22

    # Subset of `routeros` that bootstrap_routeros_user.yml provisions
    # the ansible-netboot user on. By default that's the same as
    # `routeros` (every device).
    routeros_netboot:
      children:
        routeros_routers:
        routeros_switches:

    boards:
      children:
        # Orange Pi 5 Pro: no SPI, no eMMC → custom Armbian image is
        # written to the SD card by the operator before this inventory
        # is exercised. The card stays inserted permanently. PoE
        # provides power; PoE cycling is the only available power
        # control surface for these boards.
        orange_pi_5_pro:
          hosts:
            orange-pi-5-pro-01:
              ansible_host: 192.168.1.111
              board_mac: "aa:bb:cc:dd:ee:11"
              board_model: orange-pi-5-pro
              poe_switch: switch
              poe_port: ether4
```

- [ ] **Step 2: Verify yamllint**

```bash
yamllint -c .yamllint.yml inventory/hosts.yml
```

- [ ] **Step 3: Commit**

```bash
git add inventory/hosts.yml
git commit -m "Prune sample inventory to v1 scope (orange-pi-5-pro only)"
```

---

### Task 12: Trim `inventory/group_vars/all.yml`

**Why now:** Drops vars whose only consumers (preflight apt-package check, bootloader role) are gone, and prunes `armbian_image_urls` to v1 scope.

**Files:**
- Modify: `inventory/group_vars/all.yml`

- [ ] **Step 1: Replace `inventory/group_vars/all.yml`**

```yaml
---
# ── Addresses ────────────────────────────────────────────────────────────────
# IP of the netboot server, used as the default for both TFTP and NFS roles
# when they share an address. These are collection-level variables (they end
# up inside RouterOS DHCP options, pxelinux.cfg, and HTTP image URLs — not
# as SSH targets), so they are not duplicates of `ansible_host`.
#
# When TFTP/HTTP and NFS run on different hosts (e.g. netboot.xyz container
# on a macvlan network at one IP, NFS exported from the host at another),
# override `tftp_server_ip` and `nfs_server_ip` independently:
#
#   tftp_server_ip: "10.10.45.242"   # netbootxyz container
#   nfs_server_ip:  "10.10.9.213"    # NFS server
#
# In a single-host setup, leave both unset and just set netboot_server_ip.
netboot_server_ip: "192.168.1.10"
# tftp_server_ip: "{{ netboot_server_ip }}"
# nfs_server_ip:  "{{ netboot_server_ip }}"

# Name of the RouterOS DHCP server that owns the static leases this
# collection mutates. Visible on RouterOS as `/ip dhcp-server print`.
routeros_dhcp_server_name: "dhcp1"

# ── NFS export paths on the netboot server ───────────────────────────────────
# These must already exist and be exported before running
# populate_nfs_content.yml.
# nfs_rootfs_path is the parent export. Inside it:
#   _templates/<board_model>/   per-model rootfs templates (extracted images)
#   <inventory_hostname>/       per-host rootfs (cp --reflink from template)
nfs_rootfs_path: /exports/rootfs
tftp_nfs_export: /opt/netbootxyz/config
nfs_assets_export: /opt/netbootxyz/assets

# ── Armbian image URLs ────────────────────────────────────────────────────────
# Set to the full .img.xz URL for each board model. v1 expects this to
# point at the locally-published custom build (not the upstream
# dl.armbian.com URL) — playbooks/build_image.yml publishes the custom
# .img.xz to nfs_assets_export/images/<board>/, served over HTTP at
# image_server_url/<board>/.
armbian_image_urls:
  orange-pi-5-pro: "{{ image_server_url }}/orangepi5pro/Armbian_<version>_orangepi5pro_bookworm_current_<kernel>.img.xz"

# ── Board SSH defaults ────────────────────────────────────────────────────────
ansible_user: "armbian"
ansible_become: true
ansible_ssh_common_args: "-o StrictHostKeyChecking=no"

# ── Armbian default credentials (NFS root environment) ───────────────────────
# Used by test_hardware_e2e.yml to SSH into boards booted from the NFS
# rootfs (root/1234 on a fresh Armbian image until first interactive
# login). Encrypt with ansible-vault before committing real values.
armbian_default_password: "1234"
```

(Drops `armbian_apt_suite`, `armbian_branch`, the multi-board `armbian_image_urls` entries, and the `host_board_overrides`-driven custom-build-override commentary.)

- [ ] **Step 2: Verify yamllint**

```bash
yamllint -c .yamllint.yml inventory/group_vars/all.yml
```

- [ ] **Step 3: Commit**

```bash
git add inventory/group_vars/all.yml
git commit -m "Trim group_vars/all.yml to v1 scope

Drops armbian_apt_suite (preflight apt check is gone) and armbian_branch
(was unused). Prunes armbian_image_urls to orange-pi-5-pro only and
points it at the locally-published custom build."
```

---

### Task 13: Rewrite `CLAUDE.md`

**Why now:** All structural changes are complete; the doc rewrite reflects the final state.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read the current `CLAUDE.md` to preserve sections that don't need rewriting**

```bash
cat CLAUDE.md
```

- [ ] **Step 2: Rewrite `CLAUDE.md`**

The full rewrite is below. Sections to delete entirely:

- **Status block** about "netboot trigger is WIP pending the `armbian_build` role" — replace with a v1 status block.
- **"Three bootloader flash paths"** section — gone.
- **"Idempotent flashing and integrity verification"** — gone.
- **"Pre-flight validation"** apt-package half — replace with URL-only.
- **"Reprovision workflow"** — gone.
- **"Where things run"** table — drop reprovision.yml, flash_bootloader.yml, build_image.yml stays.
- **"SBC ecosystem reality"** — keep but trim aggressively (eMMC strategies, U-Boot env storage, bootloader write strategy bullets all go).
- **"Field resolution: how `_board` is built"** — gone (no `_board` in v1).
- **"Adding a new board"** — replaced with a much simpler v1 version.
- **"Key files"** — update paths.

Sections to keep largely intact:
- The opening "What this repo is" framing (just edit the WIP framing).
- "Mental model: roles + workflow playbooks" — drop `bootloader` and `reprovision` rows from the table.
- "Collection structure" — update the tree to remove deleted paths and add `vars/boards.yml`.
- "Running playbooks" — drop flash_bootloader, reprovision; update numbering.
- "Inventory: documentation vs. real" — keep verbatim.
- "Required configuration before first run" — trim `armbian_apt_suite`, drop bootloader-related variables.
- "How NFS content is managed" — keep, light trim of reprovision references.
- "RouterOS DHCP objects" — update from 2 modes to 1 mode (one option set).
- "PoE power control" — keep verbatim.

Concrete content for the rewritten sections:

**New status block (replaces the existing Status section):**

```markdown
## ✅ Status: v1 = orangepi5pro netboot capability only

This collection is currently scoped to a single deliverable: a custom
Armbian SD image for `orangepi5pro` whose U-Boot tries PXE first, so
toggling a RouterOS DHCP option set switches the board between an NFS
rootfs and the local SD rootfs. v1 explicitly does not include
reprovisioning, on-host bootloader flashing, or any board other than
`orangepi5pro`. Reprovisioning and on-host bootloader flashing have
been deleted from the repo, not deferred-in-place; they will be
re-introduced post-v1 against the slimmer model.

The "what runs over NFS / why" question is deferred — v1 just
demonstrates that a board can be flipped between SD and NFS via DHCP.
See `playbooks/test_hardware_e2e.yml` for the assertion harness.

Spec: [`docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md`](docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md)
```

**New "Mental model" table (replace the existing one):**

```markdown
| Role | Enforces / produces |
|---|---|
| `armbian_build` | `.img.xz` Armbian image with PXE-first U-Boot baked in, published to netboot server |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a freshly flashed board |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state |
| `nfs_content` | rootfs / TFTP / pxelinux content under server exports |
| `routeros_dhcp` | Shared DHCP option set (`armbian-nfsroot`) + per-lease assignment on RouterOS |
| `routeros_poe` | PoE port state (on/off) on RouterOS switch ports |
```

**New "Collection structure" tree (replace the existing tree):**

```markdown
david_igou/armbian_netboot/   (this repo root)
├── galaxy.yml                # Collection metadata
├── ansible.cfg               # Ansible config for direct-from-root runs
├── requirements.yml          # External collection dependencies
├── meta/runtime.yml          # Minimum Ansible version (>=2.15)
├── vars/
│   └── boards.yml            # Per-board metadata (v1: orange-pi-5-pro only)
├── roles/
│   ├── armbian_build/             # Build custom .img.xz on armbian_builders host
│   ├── bootstrap_armbian/         # Provision passwordless-sudo SSH-key user
│   ├── bootstrap_routeros_user/   # Provision RouterOS user/group/SSH keys
│   ├── nfs_content/               # Populate NFS exports (preflight + per-model + per-host)
│   ├── routeros_dhcp/             # RouterOS DHCP option management (nfsroot mode)
│   └── routeros_poe/              # PoE power control via RouterOS switch
├── playbooks/
│   ├── bootstrap_armbian.yml        # (0) Provision SSH-key user on flashed boards
│   ├── bootstrap_routeros_user.yml  # (1) Provision RouterOS user/group/SSH keys
│   ├── populate_nfs_content.yml     # (2) Populate NFS rootfs + TFTP content
│   ├── setup_routeros_dhcp.yml      # (3) Create RouterOS DHCP option objects
│   ├── build_image.yml              # Build custom Armbian .img.xz for orangepi5pro
│   ├── enable_netboot.yml           # Toggle board into NFS-root mode
│   ├── disable_netboot.yml          # Revert to disk boot
│   ├── poe_control.yml              # PoE power on/off/cycle via switch
│   ├── test_hardware_e2e.yml        # SD → NFS → SD assertion harness
│   └── tasks/
│       └── diagnostic_bundle.yml
├── .inventory/               # Real inventory (gitignored)
├── inventory/                # Documentation-only sample inventory
│   ├── hosts.yml             # orange-pi-5-pro example only
│   └── group_vars/
│       ├── all.yml           # Global vars (image URLs, NFS paths, etc.)
│       └── routeros.yml      # network_cli connection plumbing
└── docs/
    ├── architecture.md
    ├── routeros-setup.md
    └── superpowers/specs/    # Design specs (this repo's history of decisions)
```

**New "Running playbooks" section (replace existing):**

```markdown
## Running playbooks

Run from the collection root:

```bash
# Install required external collections first
ansible-galaxy collection install -r requirements.yml

# (0) Build the custom Armbian image for orange-pi-5-pro on a builder
# host. Publishes the resulting .img.xz to the netboot server's HTTP
# assets directory. Re-run after changes to the patch table or pinned
# armbian/build ref.
ansible-playbook playbooks/build_image.yml

# (1) Bootstrap a freshly flashed Armbian board: create the inventory's
# `ansible_user` with passwordless sudo + SSH-key auth.
ansible-playbook playbooks/bootstrap_armbian.yml --limit orange-pi-5-pro-01

# (2) Bootstrap the RouterOS SSH user (one-time, against an existing admin user).
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=<existing-admin>

# (3) Populate NFS exports with rootfs/kernel/DTB.
ansible-playbook playbooks/populate_nfs_content.yml

# (4) Create the shared RouterOS DHCP option objects.
ansible-playbook playbooks/setup_routeros_dhcp.yml

# Toggle a board into NFS-root mode (board reboots immediately).
ansible-playbook playbooks/enable_netboot.yml --limit orange-pi-5-pro-01

# Revert a board to disk boot.
ansible-playbook playbooks/disable_netboot.yml --limit orange-pi-5-pro-01

# Power cycle a board via its upstream RouterOS switch.
ansible-playbook playbooks/poe_control.yml --limit orange-pi-5-pro-01 -e poe_action=cycle

# Hardware E2E test: toggle a board through SD → nfsroot → SD and assert
# each transition. Single board via --limit. Optional serial capture
# with `-e capture_serial=true` (see playbook header).
ansible-playbook playbooks/test_hardware_e2e.yml --limit orange-pi-5-pro-01
```
```

**New "Where things run" table:**

```markdown
| Playbook | Runs on |
|---|---|
| `bootstrap_armbian.yml` | **boards** (connects as root with `armbian_default_password`; idempotent) |
| `bootstrap_routeros_user.yml` | RouterOS (router + switches via `routeros_netboot`) |
| `populate_nfs_content.yml` | **netboot server** (image extraction, NFS/TFTP content) |
| `setup_routeros_dhcp.yml` | RouterOS (shared DHCP option objects) |
| `build_image.yml` | **`armbian_builders`** (Docker-capable build host); publishes to **netboot server** over SSH |
| `enable_netboot.yml` / `disable_netboot.yml` | **netboot server** (pxelinux.cfg over SSH) + RouterOS (DHCP) |
| `poe_control.yml` | **boards** (delegated to `routeros_switches` via `poe_switch` hostvar) |
| `test_hardware_e2e.yml` | **boards** + RouterOS (DHCP, delegated) + RouterOS switch (PoE, delegated) |
```

**New "RouterOS DHCP objects" section:**

```markdown
## RouterOS DHCP objects

Three objects are created once by `setup_routeros_dhcp.yml` and reused for all boards:
- `dhcp-option armbian-tftp-server` (option 66 → TFTP server IP)
- `dhcp-option armbian-nfsroot-bootfile` (option 67 → pxelinux.cfg/nfsroot-default)
- `dhcp-option set armbian-nfsroot` (bundles the two above)

Per-board `enable_netboot` sets `dhcp-option=armbian-nfsroot` on the static lease;
`disable_netboot` clears it. This is the only per-board RouterOS state.
```

**New "Adding a new board" section (replaces the multi-step variant):**

```markdown
## Adding a new board (post-v1)

Boards beyond `orange-pi-5-pro` are out of v1 scope. When the next
board comes online:

1. Add a `pre_config_uboot_target__<board>_pxe_first` entry to the
   `build_userpatches` block in `playbooks/build_image.yml`.
2. Add an entry to `vars/boards.yml` with `armbian_dl_dir`,
   `armbian_board_name`, `armbian_support`, `dtb`, `console`.
3. Add the host(s) under a new per-model subgroup of `boards` in
   `inventory/hosts.yml` with `board_mac` and `board_model`.
4. Add an `armbian_image_urls[<board_model>]` entry pointing at the
   locally-published custom build.
5. Run `playbooks/build_image.yml` to produce the image, then
   `populate_nfs_content.yml` and the rest of the v1 sequence.
```

**Trim "SBC ecosystem reality" — keep the framing about why naming/DTB/console varies, but drop these bullets:**

- Optional features (presence, not just configuration) — bullet went bootloader-deep
- Boot sources & order — bootloader concern
- U-Boot environment storage — bootloader concern
- Bootloader write strategy — bootloader concern

Keep:
- Naming variation
- Console UART variation
- DTB layout variation
- Software support tier variation
- Armbian U-Boot deb naming (kept as a heads-up for future board onboarding)

**"Key files" section update:**

```markdown
## Key files

- `vars/boards.yml` — authoritative per-board metadata (v1: orangepi5pro)
- `roles/nfs_content/tasks/preflight.yml` — image URL HEAD validation
- `roles/nfs_content/tasks/per_host.yml` — per-host rootfs clone + identity reset
- `inventory/group_vars/all.yml` — IPs, NFS paths, image URLs (edit before first run)
- `roles/routeros_dhcp/templates/pxelinux_cfg.j2` — per-host TFTP boot config
- `roles/routeros_poe/tasks/main.yml` — PoE power control (delegates to switch)
- `playbooks/build_image.yml` — custom Armbian image build pipeline
- `galaxy.yml` — collection namespace, version, external dependencies
```

- [ ] **Step 3: Verify yamllint (CLAUDE.md is markdown — check that nothing else broke)**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "Rewrite CLAUDE.md around v1 scope

Removes the bootloader-flash, reprovision workflow, and
multi-board onboarding sections. Replaces the WIP banner with a
v1-scope status block. Updates the playbook ordering to the v1
sequence (build → bootstrap → populate → setup_dhcp →
enable/disable_netboot → test).

Spec: docs/superpowers/specs/2026-05-07-v1-scope-narrowing-design.md"
```

---

### Task 14: Rewrite `docs/architecture.md`

**Why now:** Companion to the CLAUDE.md rewrite — the standalone architecture doc needs the same shape change.

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 1: Read current `docs/architecture.md`**

```bash
cat docs/architecture.md
```

- [ ] **Step 2: Rewrite `docs/architecture.md`**

The rewrite mirrors the CLAUDE.md changes for the architecture-doc audience (someone reading the repo cold without the agent-facing guidance). The structure should cover, in this order:

1. **What this repo is** — `david_igou.armbian_netboot` Ansible collection for managing custom Armbian SD images that PXE-first boot on `orange-pi-5-pro`. RouterOS DHCP toggle is the only mode switch.

2. **The v1 invariant**: U-Boot tries PXE first by compile-time `BOOT_TARGETS` (set by the `armbian_build` role's userpatch). When DHCP advertises an `armbian-nfsroot` option set the board NFS-roots; without it the board falls through to the local SD rootfs. There is no on-host bootloader flashing in v1 — the U-Boot binary is part of the SD image, written once by the operator.

3. **Roles** — table mirroring the one in CLAUDE.md (without reprovision/bootloader rows).

4. **Workflow** — the v1 numbered ordering.

5. **NFS content layout** — `nfs_rootfs_path/_templates/<model>/` per-model template, `nfs_rootfs_path/<inventory_hostname>/` per-host rootfs (cp --reflink), `tftp_nfs_export/armbian/<model>/{vmlinuz,initrd.img,*.dtb}` per-model TFTP content, `tftp_nfs_export/pxelinux.cfg/01-<mac>` per-board boot config.

6. **RouterOS object set** — option 66 + nfsroot bootfile + nfsroot bundle (3 objects).

7. **Out of v1 scope (deferred)** — reprovisioning, on-host bootloader flashing, boards other than `orange-pi-5-pro`.

Length target: ~150 lines. Drop every reference to `bootloader_target`, `reprovision`, `flash_bootloader`, SoC families, eMMC strategies, SD seek offsets, `host_board_overrides`.

- [ ] **Step 3: Verify yamllint**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md
git commit -m "Rewrite docs/architecture.md to v1 model"
```

---

### Task 15: Trim `docs/routeros-setup.md`

**Why now:** Final doc cleanup — light trim if the doc references the reprovision option set or two-mode dhcp-option pattern.

**Files:**
- Modify: `docs/routeros-setup.md`

- [ ] **Step 1: Read current `docs/routeros-setup.md`**

```bash
cat docs/routeros-setup.md
```

- [ ] **Step 2: Trim references to `armbian-reprovision`**

Find any references to `armbian-reprovision`, `routeros_opt_set_reprovision_prefix`, `netboot_mode=reprovision`, or `pxelinux.cfg/reprovision-default` and remove the surrounding sentences/list items. The doc's RouterOS configuration walkthrough (DHCP server, option creation, lease attachment) stays — only the "two modes" framing collapses to "one mode".

- [ ] **Step 3: Verify yamllint**

```bash
make lint
```

- [ ] **Step 4: Commit**

```bash
git add docs/routeros-setup.md
git commit -m "Trim reprovision references from docs/routeros-setup.md"
```

---

### Task 16: Final integration verification

**Why last:** Confirms the slimmed v1 still produces a clean lint pass, syntax-checks every playbook, and (if the operator has hardware available) re-runs `setup_routeros_dhcp.yml` to confirm idempotency on real RouterOS — the slimmed setup_options.yml should produce exactly 3 objects on first run and 0 changes on subsequent runs.

**Files:** none.

- [ ] **Step 1: Run full lint**

```bash
make lint
```

Expected: passes cleanly. If pre-existing warnings appear that were already present at the start of this plan, they are out of scope; flag them but do not block.

- [ ] **Step 2: Syntax-check every surviving playbook**

```bash
for pb in playbooks/*.yml; do
  echo "=== $pb ==="
  ansible-playbook --syntax-check "$pb" || echo "SYNTAX FAIL: $pb"
done
```

Expected: no `SYNTAX FAIL` lines.

- [ ] **Step 3: Verify file-system invariants**

```bash
test ! -d roles/bootloader/        || echo "FAIL: roles/bootloader/ still exists"
test ! -d roles/reprovision/       || echo "FAIL: roles/reprovision/ still exists"
test ! -f playbooks/flash_bootloader.yml || echo "FAIL: flash_bootloader.yml still exists"
test ! -f playbooks/reprovision.yml      || echo "FAIL: reprovision.yml still exists"
test ! -f docs/board-bootloader.md       || echo "FAIL: docs/board-bootloader.md still exists"
test -f vars/boards.yml || echo "FAIL: vars/boards.yml missing"
grep -q "orange-pi-5-pro" vars/boards.yml || echo "FAIL: orange-pi-5-pro entry missing"
! grep -rn "reprovision\|bootloader" roles/ playbooks/ inventory/ vars/ --include='*.yml' --include='*.yaml' \
  | grep -vE "(disable_netboot\.yml|test_hardware_e2e\.yml)" \
  || echo "FAIL: stray reprovision/bootloader references in slimmed surface (review grep output)"
```

Expected: no `FAIL:` lines. (The grep allow-list permits `disable_netboot.yml`'s comment about "revert" and `test_hardware_e2e.yml`'s comments about the v1 flow — adjust the allow-list if other legitimate references remain.)

- [ ] **Step 4: (Optional, hardware-dependent) Verify idempotency on real RouterOS**

```bash
ansible-playbook playbooks/setup_routeros_dhcp.yml
ansible-playbook playbooks/setup_routeros_dhcp.yml   # second run — must report ok=N changed=0
```

Expected: second run reports `ok=4 changed=0 failed=0`. On the RouterOS side, `/ip dhcp-server option print` shows exactly 2 entries (`armbian-tftp-server`, `armbian-nfsroot-bootfile`) and `/ip dhcp-server option sets print` shows exactly 1 entry (`armbian-nfsroot`).

- [ ] **Step 5: Note that no commit is needed for verification**

If all checks pass, the plan is complete. The final state of `git log --oneline` should show one commit per task in order.

---

## Self-Review

**Spec coverage:**
- v1 scope statement → captured in Task 13 (CLAUDE.md status block) and Task 14 (architecture.md).
- Roles & playbooks kept vs deleted → Tasks 9 (playbooks) + 10 (roles).
- Slimming inside `routeros_dhcp` → Tasks 4 + 5.
- Board metadata location (`vars/boards.yml`) → Task 1; consumers migrated in Task 3.
- Per-role cleanup (`nfs_content` preflight + URL HEAD) → Task 2.
- `inventory/group_vars/all.yml` cleanup → Task 12.
- `inventory/hosts.yml` non-v1 board pruning → Task 11.
- Documentation rewrite (CLAUDE.md, architecture.md, board-bootloader.md delete, routeros-setup.md trim) → Tasks 13 + 14 + 10 + 15.
- Acceptance criteria → covered by Task 16.

**Placeholder scan:** No `TBD`, `TODO`, `add appropriate error handling` patterns. All steps that change code show the code. Some doc-rewrite tasks (13, 14) describe section-level intent rather than full reproduced text — that is a deliberate choice for prose rewrites that depend on the existing file's structure; the bullet-level intent is concrete.

**Type / name consistency:**
- `routeros_opt_set_nfsroot_prefix` is the kept var across Tasks 4, 5, and 6.
- `armbian-nfsroot` is the option set name in Tasks 4, 5, 6, 11, 13, 14.
- `vars/boards.yml` path consistent across Tasks 1, 3, 5, 13.
- `board_configs[<model>]` lookup pattern preserved in vars/boards.yml; consumers (per_board.yml, pxelinux_cfg.j2, build_image.yml) reference the same dict key shape.

The plan is ready.
