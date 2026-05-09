# Bootflow PXE-First Invariant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the v1 "PXE-first U-Boot with fast fall-through to SD" invariant by adding a RouterOS-side preflight that asserts the SBC network's `next-server` field is set correctly, and extending `disable_netboot` to remove the per-board `pxelinux.cfg` so file-presence symmetrically tracks lease state.

**Architecture:** Single new preflight task file in the `routeros_dhcp` role; included at the top of every playbook that depends on netboot working (`setup_routeros_dhcp.yml`, `enable_netboot.yml`, `disable_netboot.yml`, `stage_netboot_assets.yml`). Adds a required role variable (`routeros_sbc_network_address`). Adds a sibling role task file `remove_pxelinux_cfg.yml` and a new netboot-server play in `playbooks/disable_netboot.yml`. Documentation updates fix the wrong "no next-server" wording in `docs/architecture.md` and document the new required inventory variable in `CLAUDE.md`.

**Tech Stack:** Ansible collection (`david_igou.armbian_netboot`); RouterOS via `community.routeros.command`; netboot server (TrueNAS) accessed over SSH for filesystem ops; mainline U-Boot v2025.10's `bootflow` framework on the SD-resident image.

**Spec:** [`docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md`](../specs/2026-05-07-bootflow-pxe-first-design.md)

**Repo state at plan time:** Branch `feat/bootflow-pxe-first` is checked out at commit `8b699df` (the spec). No code changes yet. RouterOS already has `next-server=10.10.45.242` set on vlan9 from the experiment.

---

## File Structure

**Create:**
- `roles/routeros_dhcp/tasks/preflight_next_server.yml` — read SBC network's `next-server`, assert it equals `tftp_server_ip`. Includes assertions on the new role variable.
- `roles/routeros_dhcp/tasks/remove_pxelinux_cfg.yml` — `ansible.builtin.file: state=absent` for the per-board `pxelinux.cfg/01-<MAC>` file. Sibling to the existing `write_pxelinux_cfg.yml`.

**Modify:**
- `roles/routeros_dhcp/defaults/main.yml` — add `routeros_sbc_network_address: ""`.
- `playbooks/setup_routeros_dhcp.yml` — add `pre_tasks:` block invoking the preflight via `include_role` + `tasks_from`.
- `playbooks/enable_netboot.yml` — add the preflight to the existing `Configure PXE boot on RouterOS` play.
- `playbooks/disable_netboot.yml` — add the preflight + add a new play before the existing one that removes the per-board `pxelinux.cfg` on the netboot server.
- `playbooks/stage_netboot_assets.yml` — add a separate pre-play targeting `routeros_routers` that runs the preflight before the netboot-server play.
- `docs/architecture.md` — replace the wrong "no `next-server`" wording (lines 36–38) and add a one-paragraph "RouterOS prerequisite" section explaining that the SBC network's `next-server` is owned by an external repo and is the load-bearing knob.
- `CLAUDE.md` — under the "Required configuration before first run" section, add `routeros_sbc_network_address` to the list of required inventory variables.

**Verification approach:** No formal test suite. Per task: `make lint` (yamllint + ansible-lint, both must pass), `ansible-playbook --syntax-check` for any modified playbook. End-to-end: a hardware run-through against opi5pro-01 — `setup_routeros_dhcp.yml`, then `stage_netboot_assets.yml`, then a power-cycle confirming the board boots from SD via the fast-404 fall-through, then `enable_netboot.yml --limit opi5pro-01.igou.systems` + power-cycle confirming NFS root, then `disable_netboot.yml` + power-cycle confirming SD. Time the cold-boot path; should be ≤30 s in disabled-netboot mode.

---

### Task 1: Add the new role variable + preflight task file

**Why first:** Subsequent tasks include the preflight in playbooks. Creating it first means each include lands a working reference, not a dangling one.

**Files:**
- Modify: `roles/routeros_dhcp/defaults/main.yml`
- Create: `roles/routeros_dhcp/tasks/preflight_next_server.yml`

- [ ] **Step 1: Add the new variable to role defaults**

Edit `roles/routeros_dhcp/defaults/main.yml`. After the existing `netboot_modes:` block, append:

```yaml

# CIDR of the RouterOS DHCP network the SBCs are attached to. Required.
# This network's `next-server` field is what populates BOOTP siaddr in
# DHCP replies, which U-Boot 2025.10's PXE bootmeth uses as the TFTP
# source (option 66 is silently ignored). The next-server value itself
# is owned by an external RouterOS-config repo; this role only asserts
# the value is correct via preflight_next_server.yml.
routeros_sbc_network_address: ""
```

- [ ] **Step 2: Create the preflight task file**

Create `roles/routeros_dhcp/tasks/preflight_next_server.yml` with this exact content:

```yaml
---
# Asserts that the SBC RouterOS network has next-server set to the
# TFTP server IP. Without this, U-Boot's PXE bootmeth has no way to
# reach the netboot.xyz container's TFTP daemon (option 66 is ignored
# by U-Boot 2025.10 for serverip selection). The fail message names
# the exact RouterOS command the user can run in their
# RouterOS-config repo to fix it.
#
# This file is included from playbooks that depend on netboot working:
#   - setup_routeros_dhcp.yml   (option-set creation)
#   - enable_netboot.yml        (per-board lease assignment)
#   - disable_netboot.yml       (per-board lease clear)
#   - stage_netboot_assets.yml  (TFTP/NFS content)
#
# Each play that includes it must target a host that can reach
# RouterOS via community.routeros.command (i.e. routeros_routers or
# its parent). For plays that primarily target other hosts (e.g. the
# netboot_server), include this preflight via a separate small play
# at the top.

- name: Preflight — assert routeros_sbc_network_address is set
  ansible.builtin.assert:
    that:
      - routeros_sbc_network_address | length > 0
    fail_msg: >-
      routeros_sbc_network_address is required. Set it in your
      inventory's group_vars (e.g. .inventory/group_vars/all.yml) to
      the CIDR of the RouterOS DHCP network the SBCs live on, e.g.
      "10.10.9.0/24".
  tags: preflight

- name: Preflight — read RouterOS SBC network's next-server
  community.routeros.command:
    commands:
      - "/ip dhcp-server network print as-value where address={{ routeros_sbc_network_address }}"
  register: _routeros_sbc_network
  changed_when: false
  tags: preflight

- name: Preflight — assert next-server matches tftp_server_ip
  ansible.builtin.assert:
    that:
      - _routeros_sbc_network.stdout | length > 0
      - (_routeros_sbc_network.stdout | join('')) is search('next-server=' ~ (tftp_server_ip | default(netboot_server_ip)))
    fail_msg: |
      RouterOS network {{ routeros_sbc_network_address }} does not have
      next-server={{ tftp_server_ip | default(netboot_server_ip) }}.
      U-Boot 2025.10's PXE bootmeth uses BOOTP siaddr (RouterOS
      next-server) as the TFTP server; without this set correctly,
      every netboot attempt TFTPs from the gateway and hangs in
      retries until the chip's watchdog resets it.

      This is owned by your separate RouterOS-config repo, not by
      this collection. Fix it there with:

        /ip dhcp-server network set [find address={{ routeros_sbc_network_address }}] \
          next-server={{ tftp_server_ip | default(netboot_server_ip) }}

      Then re-run the play.
  tags: preflight
```

- [ ] **Step 3: Lint**

```bash
yamllint -c .yamllint.yml roles/routeros_dhcp/
```

Expected: clean.

```bash
make lint
```

Expected: yamllint + ansible-lint clean. Profile 'production' passed.

- [ ] **Step 4: Commit**

```bash
git add roles/routeros_dhcp/defaults/main.yml \
        roles/routeros_dhcp/tasks/preflight_next_server.yml
git commit -m "Add preflight_next_server task asserting RouterOS SBC network has next-server set

U-Boot 2025.10's PXE bootmeth ignores DHCP option 66 for serverip
selection; it uses BOOTP siaddr (RouterOS network's next-server)
instead. Without next-server set, every netboot TFTPs from the
DHCP-server fallback (the gateway) and hangs.

The next-server value is owned externally (separate RouterOS-config
repo), so this collection asserts the precondition rather than
writing it. Fail message names the exact RouterOS command the user
can paste into their RouterOS-config repo.

New role variable: routeros_sbc_network_address. Required input;
preflight asserts non-empty before reading RouterOS state.

See docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md.
"
```

---

### Task 2: Wire preflight into setup_routeros_dhcp.yml

**Files:**
- Modify: `playbooks/setup_routeros_dhcp.yml`

- [ ] **Step 1: Add the pre_tasks block**

Edit `playbooks/setup_routeros_dhcp.yml`. The existing play's structure is `hosts: routeros_routers / vars / roles`. Add `pre_tasks:` between `vars:` and `roles:`. The full play becomes:

```yaml
- name: Configure RouterOS DHCP option objects
  hosts: routeros_routers
  gather_facts: false
  vars:
    routeros_setup_options: true
  pre_tasks:
    - name: Preflight — verify RouterOS SBC network's next-server
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: preflight_next_server.yml
  roles:
    - role: routeros_dhcp
      tags: routeros
```

- [ ] **Step 2: Syntax-check + lint**

```bash
ansible-playbook --syntax-check playbooks/setup_routeros_dhcp.yml
make lint
```

Expected: both clean.

- [ ] **Step 3: Verify the failure path (with intentionally wrong CIDR)**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/setup_routeros_dhcp.yml \
  -e routeros_sbc_network_address=0.0.0.0/0 --tags preflight
```

Expected: the second assert fires (`RouterOS network 0.0.0.0/0 does not have next-server=10.10.45.242`). The full remediation message is in the fail_msg; confirm it appears.

- [ ] **Step 4: Verify the success path**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/setup_routeros_dhcp.yml \
  -e routeros_sbc_network_address=10.10.9.0/24 --tags preflight
```

Expected: all three preflight tasks pass; the rest of the play is gated by `--tags preflight` to not run.

- [ ] **Step 5: Commit**

```bash
git add playbooks/setup_routeros_dhcp.yml
git commit -m "Wire preflight_next_server into setup_routeros_dhcp.yml

Runs before the role's setup_options.yml so a misconfigured
RouterOS network fails fast with the remediation command, before
any state is written.
"
```

---

### Task 3: Wire preflight into enable_netboot.yml

**Files:**
- Modify: `playbooks/enable_netboot.yml`

- [ ] **Step 1: Add preflight to the RouterOS play**

Edit `playbooks/enable_netboot.yml`. Find the play `name: Configure PXE boot on RouterOS` (around line 30). Insert the preflight as the first task in that play's `tasks:` list. The play becomes:

```yaml
- name: Configure PXE boot on RouterOS
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Preflight — verify RouterOS SBC network's next-server
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: preflight_next_server.yml
      run_once: true

    - name: Enable netboot on RouterOS for each target board
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: enable_netboot.yml
      vars:
        board_mac: "{{ hostvars[item]['board_mac'] }}"
      loop: "{{ query('inventory_hostnames', target_hosts | default('boards')) }}"
      loop_control:
        label: "{{ item }} ({{ hostvars[item]['board_model'] }})"
```

`run_once: true` — the preflight reads global RouterOS state, no need to repeat per host in the routers group (typically just one router anyway).

- [ ] **Step 2: Syntax-check + lint**

```bash
ansible-playbook --syntax-check playbooks/enable_netboot.yml
make lint
```

Expected: clean.

- [ ] **Step 3: Verify the success path runs preflight before the role**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/enable_netboot.yml \
  --check --limit opi5pro-01.igou.systems \
  -e routeros_sbc_network_address=10.10.9.0/24
```

Expected (`--check` mode): the netboot_server play runs (writes pxelinux.cfg in check mode = no actual change), the RouterOS play runs the preflight first (3 tasks: assert var, read network, assert next-server), then runs the existing enable_netboot include. No errors.

- [ ] **Step 4: Commit**

```bash
git add playbooks/enable_netboot.yml
git commit -m "Wire preflight_next_server into enable_netboot.yml

Runs once at the top of the RouterOS play, before any per-board
lease assignment. Cheap: 3 tasks, only RouterOS-side, idempotent.
"
```

---

### Task 4: Wire preflight into disable_netboot.yml

**Files:**
- Modify: `playbooks/disable_netboot.yml`

- [ ] **Step 1: Add preflight to the RouterOS play**

Edit `playbooks/disable_netboot.yml`. The current single play targets `routeros_routers`. Add the preflight as the first task. The play becomes:

```yaml
- name: Disable netboot for boards
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Preflight — verify RouterOS SBC network's next-server
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: preflight_next_server.yml
      run_once: true

    - name: Disable netboot on RouterOS for each target board
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: disable_netboot.yml
      vars:
        board_mac: "{{ hostvars[item]['board_mac'] }}"
        board_model: "{{ hostvars[item]['board_model'] }}"
      loop: "{{ query('inventory_hostnames', target_hosts | default('boards')) }}"
      loop_control:
        label: "{{ item }} ({{ hostvars[item]['board_model'] }})"
```

- [ ] **Step 2: Syntax-check + lint**

```bash
ansible-playbook --syntax-check playbooks/disable_netboot.yml
make lint
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/disable_netboot.yml
git commit -m "Wire preflight_next_server into disable_netboot.yml

Same shape as enable_netboot's wiring: run_once at the top of the
RouterOS play.
"
```

---

### Task 5: Wire preflight into stage_netboot_assets.yml

**Files:**
- Modify: `playbooks/stage_netboot_assets.yml`

- [ ] **Step 1: Add a separate pre-play targeting routeros_routers**

Edit `playbooks/stage_netboot_assets.yml`. The existing play targets `netboot_server` (truenas), so the preflight needs a separate play because RouterOS access is through a different host. Insert a new play *before* the existing one. The file becomes:

```yaml
---
# Populates the netboot server's NFS rootfs / TFTP exports for every board
# in inventory. Runs against the netboot server itself over SSH; the
# control node does not need an NFS client mount.
#
# Pre-flights every `armbian_image_urls` entry with an HTTP HEAD before
# any destructive work; URL failures surface at config time, not
# halfway through an extraction.
#
# Also pre-flights the RouterOS SBC network's next-server: the netboot
# content this play writes is only useful if U-Boot's PXE bootmeth can
# reach this server, which requires next-server set on the SBC network.
# See docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md.
#
# For each unique board model in inventory:
#   - Downloads the `.img.xz`, extracts the rootfs into
#     `nfs_rootfs_path/_templates/<model>/`
#   - Stages kernel / initrd / DTB into the TFTP tree
#   - Publishes a copy of the `.img.xz` to the HTTP assets directory
#
# For each inventory host:
#   - Reflink-clones the model template into
#     `nfs_rootfs_path/<inventory_hostname>/`
#   - Resets hostname / machine-id / SSH host keys for unique on-the-wire
#     identity
#
# Re-run this playbook whenever you add a board model, change an image
# URL, or add a new host to inventory. It is idempotent.
#
# Usage:
#   ansible-playbook playbooks/stage_netboot_assets.yml
#
# To re-run only the per-host clone step (e.g. after adding a host):
#   ansible-playbook playbooks/stage_netboot_assets.yml --tags netboot_assets

- name: Preflight RouterOS SBC network configuration
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Verify RouterOS SBC network's next-server
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: preflight_next_server.yml
      run_once: true

- name: Populate NFS rootfs and TFTP content on the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  roles:
    - role: netboot_assets
      tags: netboot_assets
```

- [ ] **Step 2: Syntax-check + lint**

```bash
ansible-playbook --syntax-check playbooks/stage_netboot_assets.yml
make lint
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/stage_netboot_assets.yml
git commit -m "Wire preflight_next_server into stage_netboot_assets.yml

Separate pre-play targeting routeros_routers because the main play
runs on netboot_server (truenas). Same fail-fast shape as the other
playbooks, just split across two plays since they target different
hosts.
"
```

---

### Task 6: Add remove_pxelinux_cfg role task + new netboot-server play in disable_netboot.yml

**Why this task:** With the new design, file presence on the netboot server is the load-bearing signal for mode (option-set assignment is now ornamental). For `disable_netboot.yml` to fully revert the lease state, it must remove the per-board `pxelinux.cfg/01-<MAC>` from the netboot server. Today the playbook only clears the option-set on the RouterOS lease.

**Files:**
- Create: `roles/routeros_dhcp/tasks/remove_pxelinux_cfg.yml`
- Modify: `playbooks/disable_netboot.yml`

- [ ] **Step 1: Create the role task file**

Create `roles/routeros_dhcp/tasks/remove_pxelinux_cfg.yml` with this exact content:

```yaml
---
# Removes the per-board pxelinux.cfg file from the netboot server.
# Sibling to write_pxelinux_cfg.yml: same path conventions, same
# variable contract. Idempotent — file: state=absent is a no-op
# when the file isn't there.
#
# Required variables:
#   board_mac          MAC address (drives 01-<mac> filename)
#   target_board_host  inventory hostname (label only; logging)
#
# Run from a play with hosts: netboot_server, become: true.
# Operates on tftp_nfs_export as a local path; no NFS client mount
# on the control node.

- name: Remove per-board pxelinux.cfg for {{ target_board_host }}
  ansible.builtin.file:
    path: >-
      {{ tftp_nfs_export }}/pxelinux.cfg/01-{{
        board_mac | lower | replace(':', '-')
      }}
    state: absent
  tags: pxelinux
```

- [ ] **Step 2: Add a new netboot-server play to disable_netboot.yml**

Edit `playbooks/disable_netboot.yml`. The current file (after Task 4) has a single RouterOS play with the preflight. Add a new play *before* it that removes the per-board pxelinux.cfg on the netboot server. The full file becomes:

```yaml
---
# Reverts boards to disk boot by:
#   - removing the per-board pxelinux.cfg/01-<MAC> from the netboot
#     server (so U-Boot's PXE bootmeth fast-404s on the fallback
#     chain and falls through to MMC)
#   - clearing the armbian-nfsroot DHCP option set from each board's
#     static lease (now ornamental — file presence is the
#     load-bearing signal post-2026-05-07-bootflow-pxe-first-design,
#     but kept for symmetry with enable_netboot.yml)
#
# Usage:
#   ansible-playbook playbooks/disable_netboot.yml --limit orange-pi-5-pro-01

- name: Remove per-board pxelinux.cfg on the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - name: Remove pxelinux.cfg per target board
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: remove_pxelinux_cfg.yml
      vars:
        board_mac: "{{ hostvars[item]['board_mac'] }}"
        target_board_host: "{{ item }}"
      loop: "{{ query('inventory_hostnames', target_hosts | default('boards')) }}"
      loop_control:
        label: "{{ item }} ({{ hostvars[item]['board_model'] }})"

- name: Disable netboot for boards
  hosts: routeros_routers
  gather_facts: false
  tasks:
    - name: Preflight — verify RouterOS SBC network's next-server
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: preflight_next_server.yml
      run_once: true

    - name: Disable netboot on RouterOS for each target board
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: disable_netboot.yml
      vars:
        board_mac: "{{ hostvars[item]['board_mac'] }}"
        board_model: "{{ hostvars[item]['board_model'] }}"
      loop: "{{ query('inventory_hostnames', target_hosts | default('boards')) }}"
      loop_control:
        label: "{{ item }} ({{ hostvars[item]['board_model'] }})"
```

- [ ] **Step 3: Syntax-check + lint**

```bash
ansible-playbook --syntax-check playbooks/disable_netboot.yml
make lint
```

Expected: clean.

- [ ] **Step 4: Verify file removal works (write a sentinel, run, confirm gone)**

```bash
ssh truenas_admin@truenas.igou.systems 'sudo touch \
  /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-c0-74-2b-fb-4d-fd; \
  ls -la /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-c0-74-2b-fb-4d-fd'
```

Expected: file exists.

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/disable_netboot.yml \
  --limit opi5pro-01.igou.systems \
  -e routeros_sbc_network_address=10.10.9.0/24
```

Expected: both plays succeed; recap shows `truenas.igou.systems: ok=N changed=1` (the file removal).

```bash
ssh truenas_admin@truenas.igou.systems 'ls /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-c0-74-2b-fb-4d-fd'
```

Expected: `No such file or directory`.

- [ ] **Step 5: Commit**

```bash
git add roles/routeros_dhcp/tasks/remove_pxelinux_cfg.yml \
        playbooks/disable_netboot.yml
git commit -m "Extend disable_netboot to remove per-board pxelinux.cfg

With the new design, file presence on the netboot server is the
load-bearing signal that determines whether U-Boot loads NFS-root
config or fast-404s through to MMC. The lease's option-set is now
ornamental (option 66 is silently ignored by U-Boot 2025.10) but
kept for symmetry with enable_netboot.

New role task: remove_pxelinux_cfg.yml — sibling to the existing
write_pxelinux_cfg.yml, same variable contract. Plays a new
netboot-server play in disable_netboot.yml before the existing
RouterOS play.

See docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md.
"
```

---

### Task 7: Update docs/architecture.md

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 1: Replace the wrong "no next-server" wording**

Edit `docs/architecture.md`. Find the bullet list around lines 33–38:

```markdown
- DHCP lease has the `armbian-nfsroot` option set assigned → U-Boot's PXE
  target succeeds, board NFS-roots from the netboot server.
- DHCP lease has no option assigned → PXE target falls through (no
  `next-server`), `bootflow scan` continues down the list, lands on
  mmc1's `boot.scr`, board boots local SD rootfs.
```

Replace with:

```markdown
- DHCP lease has the `armbian-nfsroot` option set assigned → per-board
  `pxelinux.cfg/01-<MAC>` exists on the netboot server's TFTP root →
  U-Boot's PXE bootmeth loads it, fetches kernel/initrd/DTB,
  NFS-roots from the netboot server.
- DHCP lease has no option set assigned → per-board `pxelinux.cfg/01-<MAC>`
  is absent → U-Boot's PXE bootmeth fast-404s through the fallback
  chain (`01-<MAC>` → `0A0A0919` → ... → `default`, ~5–10 s total)
  → `bootflow scan` aborts the network bootdev and proceeds to
  mmc1's `boot.scr`, board boots local SD rootfs.
```

- [ ] **Step 2: Add a "RouterOS prerequisite" section**

Still in `docs/architecture.md`, after the v1-invariant section but before "Roles", insert this new section:

```markdown
## External RouterOS prerequisite

The SBC RouterOS network's `next-server` field must be set to the
TFTP server's IP. U-Boot 2025.10's PXE bootmeth derives the TFTP
source (`serverip`) from BOOTP `siaddr` (RFC 951 next-server) — DHCP
option 66 is parsed but silently ignored for `serverip` selection.
Without `next-server`, U-Boot falls back to the DHCP server's own IP
(via option 54), which has no TFTP daemon, and every netboot attempt
hangs in retries until the chip's watchdog resets the board.

This collection does not write `next-server`; it is owned by the
operator's separate RouterOS-config repo. The
`routeros_dhcp/preflight_next_server` task asserts the value is set
correctly before any play that depends on netboot working
(`setup_routeros_dhcp.yml`, `enable_netboot.yml`,
`disable_netboot.yml`, `stage_netboot_assets.yml`). The fail message
names the exact RouterOS command to run if the assertion fires.

The required inventory variable is `routeros_sbc_network_address`
(CIDR; e.g. `"10.10.9.0/24"`). See
[`docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md`](superpowers/specs/2026-05-07-bootflow-pxe-first-design.md)
for the full design context.
```

- [ ] **Step 3: Lint markdown**

```bash
yamllint -c .yamllint.yml docs/architecture.md 2>&1 | head
```

(Yamllint doesn't lint Markdown but won't error on it; primarily checks no embedded YAML is broken.)

- [ ] **Step 4: Commit**

```bash
git add docs/architecture.md
git commit -m "Document the actual U-Boot bootflow PXE-first invariant in architecture.md

Previous text claimed 'PXE target falls through (no next-server)' as
the SD-boot trigger. That's wrong on two counts: (a) RouterOS always
fills siaddr (defaulting to the DHCP server itself if next-server is
unset), so 'no next-server' isn't a real lease state; (b) U-Boot
2025.10's PXE bootmeth ignores option 66 for serverip selection.

Replace with the actual mechanism: per-board pxelinux.cfg/01-<MAC>
file presence on the netboot server determines whether U-Boot
NFS-roots or fast-404s through to MMC. Add a new section
documenting the external RouterOS prerequisite (next-server on the
SBC network) and pointing at the implementation spec.
"
```

---

### Task 8: Update CLAUDE.md to document the new required variable

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add to the required-config list**

Edit `CLAUDE.md`. Find the section "Required configuration before first run" (search for that header). Inside the `inventory/group_vars/all.yml — collection-level variables:` bullet list, add a new entry alongside `armbian_default_password` and `armbian_image_urls`:

```markdown
- `routeros_sbc_network_address` (required) — CIDR of the RouterOS DHCP
  network the SBCs are attached to (e.g. `"10.10.9.0/24"`). Required
  by the `routeros_dhcp` role's preflight, which asserts the network's
  `next-server` field equals `tftp_server_ip`. U-Boot 2025.10's PXE
  bootmeth uses BOOTP `siaddr` (next-server) as the TFTP source —
  option 66 is silently ignored. The `next-server` value itself is
  owned by your RouterOS-config repo; this collection only asserts.
  See `docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md`.
```

- [ ] **Step 2: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document routeros_sbc_network_address in CLAUDE.md required-config list

Required input for the routeros_dhcp role's preflight_next_server
task. Without it, every play that depends on netboot working fails
fast at the assertion (intentional). Pointing at the spec for the
full rationale.
"
```

---

### Task 9: User actions (inventory pin) + final hardware E2E test

**Why this task:** Code changes are done. The remaining steps require operator action on the user's private inventory and a hardware run to validate end-to-end. No commit.

- [ ] **Step 1: User adds the variable to .inventory**

Tell the user to add this line to `.inventory/group_vars/all.yml` (after the existing `armbian_default_password` line, exact CIDR matching their vlan9):

```yaml
# CIDR of the RouterOS DHCP network the SBCs live on. Required by the
# routeros_dhcp role's preflight (asserts next-server is set on this
# network). The next-server value itself is in your RouterOS-config
# repo, not here.
routeros_sbc_network_address: "10.10.9.0/24"
```

Verify:

```bash
grep routeros_sbc_network_address .inventory/group_vars/all.yml
```

Expected: prints the new line.

- [ ] **Step 2: User confirms RouterOS-config repo has next-server set**

This was set during the brainstorming experiment; user should verify their RouterOS-config repo includes this. If not, add it to that repo:

```
/ip dhcp-server network set [find address=10.10.9.0/24] next-server=10.10.45.242
```

Verify the live RouterOS state via the existing collection's check path:

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/setup_routeros_dhcp.yml --tags preflight
```

Expected: all three preflight tasks pass.

- [ ] **Step 3: Re-populate NFS content for the new image**

The current image on truenas (`6.18.27`) was just published; the per-host TFTP/NFS content has not been re-extracted. Run:

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/stage_netboot_assets.yml
```

Expected: `localhost ok=N changed>=1`, `truenas.igou.systems ok=M changed>=1`, no failures.

- [ ] **Step 4: Cold-boot the board with netboot disabled, time it**

The lease should currently be `dhcp-option-set=""` (cleared after experiments). Verify:

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/disable_netboot.yml \
  --limit opi5pro-01.igou.systems
```

Then power-cycle:

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/poe_control.yml \
  --limit opi5pro-01.igou.systems -e poe_action=cycle
```

Watch serial via `sudo cat /dev/ttyUSB0` while polling `nc -z opi5pro-01.igou.systems 22`. Expected: PoE-on → "Starting kernel" within ~30 s; SSH up within ~60 s. Confirm boot is from SD (login banner says "orangepi5pro login:", `cat /etc/hostname` returns `orangepi5pro`).

- [ ] **Step 5: Toggle to NFS-root, time it, validate**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/enable_netboot.yml \
  --limit opi5pro-01.igou.systems
```

That play already reboots the board (line in playbook: `command: reboot async: 1 poll: 0`). Watch serial. Expected: U-Boot boots, PXE bootmeth loads `pxelinux.cfg/01-c0-74-2b-fb-4d-fd` from `10.10.45.242`, fetches `armbian/orange-pi-5-pro/{vmlinuz,initrd.img,board.dtb}` from same TFTP server, kernel boots NFS root.

If the kernel/initrd/dtb fetches fail, that's the *open question* called out in the spec: the per-host TFTP layout under `tftp_nfs_export` may need adjustment for the new image. Pause and investigate; the spec does not promise this just works without further iteration.

If the kernel boots but NFS mount fails, that's a separate issue (the per-host NFS rootfs may be missing or misnamed). Investigate via the kernel's mount error messages on serial.

- [ ] **Step 6: Toggle back to SD, confirm clean cycle**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/disable_netboot.yml \
  --limit opi5pro-01.igou.systems
```

Power-cycle and confirm SD boot:

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/poe_control.yml \
  --limit opi5pro-01.igou.systems -e poe_action=cycle
```

Expected: full SD ↔ NFS ↔ SD cycle works. The collection's existing `playbooks/test_hardware_e2e.yml` formalises this — running it should now succeed end-to-end.

- [ ] **Step 7: Run test_hardware_e2e.yml to confirm**

```bash
ANSIBLE_INVENTORY=.inventory ansible-playbook playbooks/test_hardware_e2e.yml \
  --limit opi5pro-01.igou.systems
```

Expected: full SD → NFS → SD test passes; the test asserts each transition.

---

## Self-Review

**Spec coverage:**
- Spec §"Add: roles/routeros_dhcp/tasks/preflight_next_server.yml" → Task 1.
- Spec §"Add: roles/routeros_dhcp/defaults/main.yml — new variable" → Task 1.
- Spec §"Modify: playbooks/setup_routeros_dhcp.yml" → Task 2.
- Spec §"Modify: playbooks/enable_netboot.yml" → Task 3.
- Spec §"Modify: playbooks/disable_netboot.yml — preflight wiring" → Task 4.
- Spec §"Modify: playbooks/stage_netboot_assets.yml" → Task 5.
- Spec §"Modify: roles/routeros_dhcp/tasks/disable_netboot.yml" (extend to delete file) → Task 6 (implemented as a sibling task file `remove_pxelinux_cfg.yml` per role-task convention rather than mutating the existing RouterOS-only file).
- Spec §"Modify: docs/architecture.md" → Task 7.
- Spec §"Not changed: roles/armbian_build/*, setup_options.yml, pxelinux_cfg.j2, netboot_assets/*" → none of these are touched, confirmed.
- Spec §"Required: routeros_sbc_network_address (CIDR)" + CLAUDE.md note → Task 8.
- Spec §"Open question: end-to-end NFS-root validation" → Task 9 explicitly handles this with a pause-and-investigate gate.

**Placeholder scan:** No "TBD"/"TODO"/"figure out later" in the plan. The Task 9 NFS-root step explicitly says to pause and investigate if it fails, with a pointer to the spec's open-question section — that is a real instruction, not a placeholder.

**Type consistency:** Task 1 defines `routeros_sbc_network_address` and `_routeros_sbc_network` (register var). Tasks 2–5 reference `routeros_sbc_network_address` consistently. Task 6's `remove_pxelinux_cfg.yml` uses the same `board_mac | lower | replace(':', '-')` filename derivation as the existing `write_pxelinux_cfg.yml`, verified. Task 9's example commands all use the variable name as defined.

**Risk note:** Task 9 step 5 (NFS-root validation) is the highest-risk step — the spec explicitly flags this as deferred-to-implementation-plan. If it fails, the spec is still correct; the failure is in pre-existing TFTP-layout content on the netboot server, not in this design's changes. The plan's instruction to pause and investigate is the right behaviour.
