# Deterministic Fleet E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase 0/A/B/C/C2/D structure of `playbooks/test_fleet_e2e.yml` with a six-phase deterministic flow (0 PoE down → 1 NFS reset → 2 NFS boot + bootstrap + SPI persist → 3 dd SD → 4 SD boot + bootstrap → 5 NVMe reprovision + local_kernel verify) so every state layer is force-recreated before the test exercises it.

**Architecture:** Single playbook with eight plays (pre-flight; Phase 0; Phase 1; Phase 2a; Phase 2b; Phase 3; Phase 4; Phase 5; Summary). Pre-flight resolves retry knobs and clears stale known_hosts. Phase 0 runs against boards (PoE-off only). Phase 1 runs on `netboot_server` (force_refresh `image_extract` + `rootfs_clone`). Phases 2-5 run against boards. Phase 2 splits into 2a (lifecycle + bootstrap_armbian + verify) and 2b (`import_playbook: persist_uboot_env.yml`), recorded as one row "2" in the timing table. `bootstrap_armbian` is the single source of truth for the igou user — no manual NFS-rootfs injection, no `auto_bootstrap_if_needed` probe.

**Tech Stack:** Ansible 2.15+, existing collection roles (`image_extract`, `rootfs_clone`, `disk_image`, `bootstrap_armbian`, `board_boot_verify`, `disk_provision`), existing tasks (`_lifecycle_set_and_verify.yml`, `cold_boot_with_retry.yml`), existing playbook (`persist_uboot_env.yml`).

**Spec:** [`docs/superpowers/specs/2026-05-19-deterministic-fleet-e2e-design.md`](../specs/2026-05-19-deterministic-fleet-e2e-design.md)

**Branch:** `deterministic-fleet-e2e` (cut from `disk-image-role`, which has the `disk_image` role this plan consumes in Phase 3)

---

## Task 1: Skeleton — docstring + pre-flight + empty Summary

Replace the entire `playbooks/test_fleet_e2e.yml` content with the new docstring, the trimmed pre-flight play (no igou-injection play), and a placeholder Summary play. After this task the playbook has only the pre-flight + Summary plays — no phases yet. Lint and syntax-check must pass.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml` (full rewrite)

- [ ] **Step 1: Replace `playbooks/test_fleet_e2e.yml` entirely**

```yaml
---
# Multi-board deterministic fleet end-to-end test.
#
# Runs a six-phase deterministic lifecycle on every host in the target
# group. Each phase produces a known-clean state for the next, so an
# unclean prior-run state cannot poison the next iteration.
#
#   Phase 0 — PoE-off all target boards (clean slate; no live rootfs at
#             risk during Phase 1's NFS reset).
#   Phase 1 — Force-refresh per-model NFS template + per-host NFS clone
#             on netboot_server (image_extract + rootfs_clone, both
#             force_refresh=true). Boards stay powered off.
#   Phase 2 — Converge to NFS, PoE-on + wait, run bootstrap_armbian
#             unconditionally (fresh NFS clone has only root+password),
#             persist SPI U-Boot env for spi_flash boards (no-op for
#             others), verify rootfs is on NFS.
#   Phase 3 — From NFS boot, dd canonical SD image to /dev/mmcblk0 via
#             the disk_image role.
#   Phase 4 — Converge to SD, PoE-cycle + wait, run bootstrap_armbian
#             unconditionally (fresh SD has only root+password), verify
#             rootfs is on a local block device.
#   Phase 5 — Converge back to NFS, reprovision NVMe via disk_provision
#             (rsync NFS rootfs to NVMe via systemd-repart), converge
#             to local_kernel, verify rootfs on NVMe + TFTP HITS flat.
#
# Parallelism: Phases 0/2/3/4 run all hosts in parallel (ansible's
# default forks behaviour). Phase 5 runs `throttle: 2` (NVMe rsync
# contention guard); dial via -e fleet_phase_5_throttle=N.
#
# Pre-requirements (one-time per fleet):
#   - SSH key in ~/.ssh authorised on `boards`, `netboot_server`,
#     `rb5009`, and each PoE switch.
#   - Inventory's `armbian_netboot_image_urls[<model>]` published
#     somewhere reachable from netboot_server (Phase 1) and from the
#     board (Phase 3 dd-from-URL).
#   - stage_router.yml has been run (per-model TFTP rows on rb5009).
#   - Inventory's `armbian_netboot_local_disks` set per board (Phase 5).
#   - Inventory's `armbian_netboot_poe_switch` + `armbian_netboot_poe_port`
#     set per board.
#
# Per-board artefacts: /tmp/iter-FLEET-<host>/{0-poe-down,1-nfs-reset,
# 2-nfs-bootstrap,3-dd-sd,4-sd-bootstrap,5-nvme-localkernel}/. Final
# play emits a summary table.
#
# Usage:
#   # Full fleet, default target group:
#   ansible-playbook playbooks/test_fleet_e2e.yml
#
#   # Subset of hosts (use -e target_hosts=, not --limit, because the
#   # plays delegate to rb5009/netboot_server/PoE switches):
#   ansible-playbook playbooks/test_fleet_e2e.yml -e target_hosts=opi5pro-01.igou.systems
#
#   # Skip phases you've already proven on a previous run:
#   ansible-playbook playbooks/test_fleet_e2e.yml -e skip_phase_3=true
#   # Available: skip_phase_0, skip_phase_1, skip_phase_2, skip_phase_3,
#   # skip_phase_4, skip_phase_5.
#
# SD-flake survival: Phases 2/4/5 use the in-tree cold_boot_with_retry
# primitive and default to armbian_netboot_boot_retry_attempts=1 at
# fleet-play scope. A single rock-5b voltage-select flake (tracker #38)
# gets one automatic retry before the host falls out of the run.
# Override with -e armbian_netboot_boot_retry_attempts=N or set in
# inventory for fleet-wide tuning.

- name: "Pre-flight: ensure all per-board artifact dirs exist on controller"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Create /tmp/iter-FLEET-<host>/{0-poe-down,1-nfs-reset,2-nfs-bootstrap,3-dd-sd,4-sd-bootstrap,5-nvme-localkernel}"
      ansible.builtin.file:
        path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/{{ item }}"
        state: directory
        mode: '0755'
      loop:
        - 0-poe-down
        - 1-nfs-reset
        - 2-nfs-bootstrap
        - 3-dd-sd
        - 4-sd-bootstrap
        - 5-nvme-localkernel
      delegate_to: localhost
      vars:
        ansible_connection: local

    - name: "Reset per-host phase-timing TSV"
      ansible.builtin.copy:
        content: "phase\tstart_epoch\tend_epoch\tduration_s\n"
        dest: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
        mode: '0644'
      delegate_to: localhost
      vars:
        ansible_connection: local

    - name: "Pre-flight — resolve fleet SD-flake retry default"
      ansible.builtin.set_fact:
        armbian_netboot_boot_retry_attempts: "{{ armbian_netboot_boot_retry_attempts | default(1) | int }}"

    - name: "Pre-flight — resolve fleet PoE cycle delay default"
      ansible.builtin.set_fact:
        armbian_netboot_poe_cycle_delay: "{{ armbian_netboot_poe_cycle_delay | default(30) | int }}"

    - name: "Pre-flight — clear stale known_hosts entries on controller"
      ansible.builtin.command:
        cmd: "ssh-keygen -R {{ item }}"
      delegate_to: localhost
      connection: local
      become: false
      loop: "{{ [inventory_hostname, ansible_host | default(inventory_hostname)] | unique }}"
      changed_when: false
      failed_when: false

    - name: "Pre-flight — bypass known_hosts for the fleet run (boot-mode transitions swap host keys)"
      ansible.builtin.set_fact:
        ansible_ssh_common_args: "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"

# Phase plays (0, 1, 2a, 2b, 3, 4, 5) are appended by subsequent tasks
# in this implementation plan.

- name: "Summary"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Summary — per-board per-phase wall-time table"
      run_once: true
      ansible.builtin.debug:
        msg: "Summary Jinja completed in Task 8."
```

- [ ] **Step 2: Run lint**

Run: `cd /workspace/ansible-collection-armbian_netboot && make lint`
Expected: PASS (0 failures from ansible-lint).

- [ ] **Step 3: Run syntax-check**

Run: `cd /workspace/ansible-collection-armbian_netboot && ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Verify the old phases are gone**

Run: `grep -E "Phase [A-D]|skip_dd_sd|skip_sd|skip_nfs|skip_reprovision|skip_local_kernel|skip_kernel_update" /workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`
Expected: no output (no stale phase letter references).

- [ ] **Step 5: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: skeleton — pre-flight + Summary placeholder (no phases yet)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Phase 0 — PoE down all target boards

Insert the Phase 0 play between the pre-flight play and the Summary play. PoE-off + drain (no PoE-on), no SSH wait. Each board's PoE control is delegated to its `armbian_netboot_poe_switch`.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert the Phase 0 play immediately before the `Summary` play**

Find the comment line:

```yaml
# Phase plays (0, 1, 2a, 2b, 3, 4, 5) are appended by subsequent tasks
# in this implementation plan.
```

Immediately after it (still before the Summary play), insert:

```yaml
- name: "Phase 0 — PoE down all target boards"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_phase_0: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/0-poe-down"
  tasks:
    - name: "Phase 0 — block"
      when: not (skip_phase_0 | bool)
      block:
        - name: "Phase 0 — start timer"
          ansible.builtin.set_fact:
            _t_phase_0_start: "{{ lookup('pipe', 'date +%s') | int }}"

        # Power off the board's PoE port + drain capacitors. We don't
        # re-energise here — Phase 2's PoE cycle owns the next power-on.
        - name: "Phase 0 — PoE off"
          community.routeros.command:
            commands:
              - '/interface ethernet poe set [find name="{{ armbian_netboot_poe_port }}"] poe-out=off'
          delegate_to: "{{ armbian_netboot_poe_switch }}"
          register: _poe_off
          retries: 3
          delay: 5
          until: _poe_off is succeeded

        - name: "Phase 0 — pause for capacitor drain"
          ansible.builtin.pause:
            seconds: "{{ armbian_netboot_poe_cycle_delay | int }}"

        - name: "Phase 0 — write evidence"
          ansible.builtin.copy:
            content: |
              === Phase 0 (PoE down) — {{ inventory_hostname }} ===
              switch:  {{ armbian_netboot_poe_switch }}
              port:    {{ armbian_netboot_poe_port }}
              drain_s: {{ armbian_netboot_poe_cycle_delay }}
            dest: "{{ fleet_artifact_dir }}/poe-down-evidence.txt"
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

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 0 — PoE-off all target boards (clean slate)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Phase 1 — NFS reset (force_refresh on netboot_server)

Insert the Phase 1 play between Phase 0 and Summary. Runs on `netboot_server` with `become: true`. Loops `image_extract` over unique models from `target_hosts`, then loops `rootfs_clone` over `target_hosts`. Both with `force_refresh: true`.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert Phase 1 immediately after Phase 0, before the Summary play**

```yaml
- name: "Phase 1 — Force-refresh NFS templates + per-host clones (netboot_server)"
  hosts: netboot_server
  become: true
  gather_facts: false
  vars:
    skip_phase_1: false
    _target_boards: "{{ query('inventory_hostnames', target_hosts | default('boards')) }}"
    _target_models: >-
      {{ _target_boards
         | map('extract', hostvars, 'armbian_netboot_board_model')
         | list | unique }}
  pre_tasks:
    - name: "Phase 1 — load board configs (consumed by image_extract dtb lookup)"
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"

  tasks:
    - name: "Phase 1 — block"
      when: not (skip_phase_1 | bool)
      block:
        - name: "Phase 1 — start timer (per-board, delegated)"
          ansible.builtin.set_fact:
            _t_phase_1_start: "{{ lookup('pipe', 'date +%s') | int }}"
          run_once: true

        - name: "Phase 1 — extract per-model templates (force_refresh)"
          ansible.builtin.include_role:
            name: image_extract
          vars:
            armbian_image_src: "{{ armbian_netboot_image_urls[item] }}"
            model_name: "{{ item }}"
            template_dir: "{{ armbian_netboot_nfs_rootfs_path }}/_templates/{{ item }}"
            tftp_dir: "{{ armbian_netboot_image_cache | default('/var/lib/armbian_netboot/cache') }}/sbc-tftp/{{ item }}"
            board_dtb: "{{ armbian_netboot_board_configs[item].dtb }}"
            force_refresh: true
          loop: "{{ _target_models }}"

        - name: "Phase 1 — clone per-host rootfs (force_refresh)"
          ansible.builtin.include_role:
            name: rootfs_clone
          vars:
            template_dir: "{{ armbian_netboot_nfs_rootfs_path }}/_templates/{{ hostvars[_board].armbian_netboot_board_model }}"
            target_dir: "{{ armbian_netboot_nfs_rootfs_path }}/{{ _board }}"
            hostname: "{{ _board }}"
            force_refresh: true
          loop: "{{ _target_boards }}"
          loop_control:
            loop_var: _board

        - name: "Phase 1 — per-board evidence + timing"
          ansible.builtin.shell: |
            set -euo pipefail
            HOST={{ board }}
            DIR=/tmp/iter-FLEET-${HOST}/1-nfs-reset
            mkdir -p "${DIR}"
            cat > "${DIR}/nfs-reset-evidence.txt" <<EOF
            === Phase 1 (NFS reset) — ${HOST} ===
            template: {{ armbian_netboot_nfs_rootfs_path }}/_templates/{{ hostvars[board].armbian_netboot_board_model }}
            target:   {{ armbian_netboot_nfs_rootfs_path }}/${HOST}
            force_refresh: true
            EOF
            T_END=$(date +%s)
            T_START={{ _t_phase_1_start }}
            DUR=$(( T_END - T_START ))
            echo -e "1\t${T_START}\t${T_END}\t${DUR}" >> /tmp/iter-FLEET-${HOST}/timing.tsv
          args:
            executable: /bin/bash
          loop: "{{ _target_boards }}"
          loop_control:
            loop_var: board
          delegate_to: localhost
          changed_when: false
```

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 1 — force-refresh NFS templates + per-host clones

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Phase 2 — NFS boot + bootstrap_armbian + SPI persist

Two plays: 2a runs `_lifecycle_set_and_verify` + `bootstrap_armbian` (inline-include with root+password override) + `board_boot_verify`. 2b imports `persist_uboot_env.yml` so it can use `import_playbook` (which only works at play level). The Summary play treats them as one phase row (`2`); timing covers both.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert Phase 2a after Phase 1**

```yaml
- name: "Phase 2a — NFS boot + bootstrap_armbian + verify"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_phase_2: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/2-nfs-bootstrap"
  pre_tasks:
    - name: "Phase 2a — load board configs"
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"
  tasks:
    - name: "Phase 2a — block"
      when: not (skip_phase_2 | bool)
      block:
        - name: "Phase 2 — start timer"
          ansible.builtin.set_fact:
            _t_phase_2_start: "{{ lookup('pipe', 'date +%s') | int }}"

        - name: "Phase 2a — set + verify nfs"
          ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
          vars:
            target_boot_mode: nfs
            on_failure_revert_to: nfs

        # Fresh NFS clone has only root+default-password. Run
        # bootstrap_armbian unconditionally to install igou. No
        # auto_bootstrap_if_needed probe — we know the answer.
        - name: "Phase 2a — bootstrap_armbian (unconditional; fresh NFS clone)"
          ansible.builtin.include_role:
            name: bootstrap_armbian
          vars:
            ansible_user: root
            ansible_password: "{{ armbian_netboot_default_password }}"
            ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            ansible_become: false

        - name: "Phase 2a — reset connection (so subsequent tasks use igou identity)"
          ansible.builtin.meta: reset_connection

        - name: "Phase 2a — verify rootfs is on NFS"
          ansible.builtin.include_role:
            name: board_boot_verify
          vars:
            boot_mode: nfs
```

- [ ] **Step 2: Insert Phase 2b after Phase 2a**

```yaml
- name: "Phase 2b — Persist SPI U-Boot env (no-op for non-SPI boards)"
  ansible.builtin.import_playbook: persist_uboot_env.yml
  vars:
    armbian_netboot_persist_uboot_env_cycle: false
  when: not (skip_phase_2 | default(false) | bool)
```

- [ ] **Step 3: Append Phase 2 evidence + timing as a third play (since Phase 2b is import_playbook, we close out timing in a small follow-up play)**

After Phase 2b, insert:

```yaml
- name: "Phase 2 — evidence + timing"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Phase 2 — write evidence (igou + SPI persist done)"
      when: not (skip_phase_2 | default(false) | bool)
      ansible.builtin.copy:
        content: |
          === Phase 2 (NFS boot + bootstrap + SPI persist) — {{ inventory_hostname }} ===
          rootfs:  NFS ({{ armbian_netboot_nfs_rootfs_path }}/{{ inventory_hostname }})
          igou:    bootstrapped via bootstrap_armbian
          SPI:     persist_uboot_env.yml ran (no-op when uboot_env.storage != spi_flash)
        dest: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/2-nfs-bootstrap/nfs-bootstrap-evidence.txt"
      delegate_to: localhost
      vars:
        ansible_connection: local

    - name: "Phase 2 — record timing (covers Phase 2a + Phase 2b)"
      when: not (skip_phase_2 | default(false) | bool)
      ansible.builtin.lineinfile:
        path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
        line: "2\t{{ _t_phase_2_start | default(0) }}\t{{ _t_end }}\t{{ (_t_end | int) - (_t_phase_2_start | default(0) | int) }}"
        create: true
        mode: '0644'
      vars:
        _t_end: "{{ lookup('pipe', 'date +%s') | int }}"
        ansible_connection: local
      delegate_to: localhost
```

Note: `_t_phase_2_start` was set in Phase 2a's host facts. Across play boundaries within a single playbook run, host facts persist — so this read works. Default to 0 if Phase 2a was skipped so the timing math doesn't blow up.

- [ ] **Step 4: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 5: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 2 — NFS boot + bootstrap_armbian + SPI persist

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Phase 3 — dd canonical SD image via `disk_image` role

Single play targeting boards (now on NFS as igou). Invokes the `disk_image` role with `image_source` from `armbian_netboot_image_urls[<model>]` and `target_device` from `armbian_netboot_sd_device`.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert Phase 3 after the Phase 2 evidence-and-timing play**

```yaml
- name: "Phase 3 — dd canonical SD image via disk_image role"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_phase_3: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/3-dd-sd"
  tasks:
    - name: "Phase 3 — block"
      when: not (skip_phase_3 | bool)
      block:
        - name: "Phase 3 — start timer"
          ansible.builtin.set_fact:
            _t_phase_3_start: "{{ lookup('pipe', 'date +%s') | int }}"

        - name: "Phase 3 — dd canonical image to SD"
          ansible.builtin.include_role:
            name: disk_image
          vars:
            image_source: "{{ armbian_netboot_image_urls[armbian_netboot_board_model] }}"
            target_device: "{{ armbian_netboot_sd_device | default('/dev/mmcblk0') }}"

        - name: "Phase 3 — write evidence"
          ansible.builtin.copy:
            content: |
              === Phase 3 (dd SD) — {{ inventory_hostname }} ===
              source:  {{ armbian_netboot_image_urls[armbian_netboot_board_model] }}
              target:  {{ armbian_netboot_sd_device | default('/dev/mmcblk0') }}
              From-state: NFS rootfs (board was bootstrapped + verified NFS in Phase 2)
            dest: "{{ fleet_artifact_dir }}/dd-sd-evidence.txt"
          delegate_to: localhost
          vars:
            ansible_connection: local

        - name: "Phase 3 — record timing"
          ansible.builtin.lineinfile:
            path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
            line: "3\t{{ _t_phase_3_start }}\t{{ _t_end }}\t{{ (_t_end | int) - (_t_phase_3_start | int) }}"
            create: true
            mode: '0644'
          vars:
            _t_end: "{{ lookup('pipe', 'date +%s') | int }}"
            ansible_connection: local
          delegate_to: localhost
```

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 3 — dd canonical SD image via disk_image role

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Phase 4 — SD boot + bootstrap_armbian

Mirrors Phase 2a but for SD boot mode. Same unconditional `bootstrap_armbian` pattern (freshly dd'd SD has only root+password).

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert Phase 4 after Phase 3**

```yaml
- name: "Phase 4 — SD boot + bootstrap_armbian + verify"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  vars:
    skip_phase_4: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/4-sd-bootstrap"
  pre_tasks:
    - name: "Phase 4 — load board configs"
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"
  tasks:
    - name: "Phase 4 — block"
      when: not (skip_phase_4 | bool)
      block:
        - name: "Phase 4 — start timer"
          ansible.builtin.set_fact:
            _t_phase_4_start: "{{ lookup('pipe', 'date +%s') | int }}"

        - name: "Phase 4 — set + verify sd"
          ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
          vars:
            target_boot_mode: sd
            on_failure_revert_to: nfs

        - name: "Phase 4 — bootstrap_armbian (unconditional; freshly dd'd SD)"
          ansible.builtin.include_role:
            name: bootstrap_armbian
          vars:
            ansible_user: root
            ansible_password: "{{ armbian_netboot_default_password }}"
            ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            ansible_become: false

        - name: "Phase 4 — reset connection"
          ansible.builtin.meta: reset_connection

        - name: "Phase 4 — verify rootfs is on a local block device"
          ansible.builtin.include_role:
            name: board_boot_verify
          vars:
            boot_mode: sd

        - name: "Phase 4 — write evidence"
          ansible.builtin.copy:
            content: |
              === Phase 4 (SD boot + bootstrap) — {{ inventory_hostname }} ===
              rootfs:  SD (local block device, post-bootstrap)
              source:  freshly dd'd canonical image (Phase 3)
              igou:    bootstrapped via bootstrap_armbian
            dest: "{{ fleet_artifact_dir }}/sd-bootstrap-evidence.txt"
          delegate_to: localhost
          vars:
            ansible_connection: local

        - name: "Phase 4 — record timing"
          ansible.builtin.lineinfile:
            path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
            line: "4\t{{ _t_phase_4_start }}\t{{ _t_end }}\t{{ (_t_end | int) - (_t_phase_4_start | int) }}"
            create: true
            mode: '0644'
          vars:
            _t_end: "{{ lookup('pipe', 'date +%s') | int }}"
            ansible_connection: local
          delegate_to: localhost
```

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 4 — SD boot + bootstrap_armbian (unconditional)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Phase 5 — NVMe reprovision + local_kernel verify

Largest play. Converges back to NFS (rsync source), runs `disk_provision` over `armbian_netboot_local_disks`, then converges to `local_kernel` mode and asserts TFTP HITS for vmlinuz remain flat across the cycle (proof U-Boot used baked localcmd, not PXE). `throttle: 2` for NVMe rsync contention.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Insert Phase 5 after Phase 4**

```yaml
- name: "Phase 5 — NVMe reprovision + local_kernel verify (throttled)"
  hosts: "{{ target_hosts | default('boards') }}"
  throttle: "{{ fleet_phase_5_throttle | default(2) | int }}"
  gather_facts: true
  gather_subset: [mounts]
  vars:
    skip_phase_5: false
    fleet_artifact_dir: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/5-nvme-localkernel"
  pre_tasks:
    - name: "Phase 5 — load board configs"
      ansible.builtin.include_vars:
        file: "{{ playbook_dir }}/../vars/boards.yml"
  tasks:
    - name: "Phase 5 — block"
      when: not (skip_phase_5 | bool)
      block:
        - name: "Phase 5 — start timer"
          ansible.builtin.set_fact:
            _t_phase_5_start: "{{ lookup('pipe', 'date +%s') | int }}"

        - name: "Phase 5 — set + verify nfs (rsync source for disk_provision)"
          ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
          vars:
            target_boot_mode: nfs
            on_failure_revert_to: nfs

        - name: "Phase 5 — re-gather mount facts after NFS converge"
          ansible.builtin.setup:
            gather_subset: [mounts]

        - name: "Phase 5 — guard: must be on NFS before wiping local disks"
          ansible.builtin.assert:
            that: >-
              ansible_mounts | selectattr('mount', 'equalto', '/')
                | map(attribute='fstype') | first in ['nfs', 'nfs4']
            fail_msg: "{{ inventory_hostname }} is not on NFS — refusing to wipe NVMe."

        - name: "Phase 5 — cross-binding validate (no duplicate mount paths, exactly one '/')"
          ansible.builtin.assert:
            that:
              - >-
                (armbian_netboot_local_disks | map(attribute='layout') | flatten
                 | selectattr('mount', 'defined') | map(attribute='mount') | list | length)
                ==
                (armbian_netboot_local_disks | map(attribute='layout') | flatten
                 | selectattr('mount', 'defined') | map(attribute='mount') | list | unique | length)
              - >-
                (armbian_netboot_local_disks | map(attribute='layout') | flatten
                 | selectattr('mount', 'defined') | selectattr('mount', 'equalto', '/')
                 | list | length) == 1

        - name: "Phase 5 — provision each declared local disk"
          ansible.builtin.include_role:
            name: disk_provision
          vars:
            disk_binding: "{{ item }}"
          loop: "{{ armbian_netboot_local_disks | default([]) }}"
          loop_control:
            label: "{{ item.device }}"

        - name: "Phase 5 — record TFTP HITS BEFORE local_kernel cycle"
          community.routeros.command:
            commands:
              - '/ip tftp print where real-filename~"{{ armbian_netboot_board_model }}/vmlinuz"'
          delegate_to: "{{ armbian_netboot_router }}"
          register: _hits_before

        - name: "Phase 5 — set + verify local_kernel"
          ansible.builtin.include_tasks: tasks/_lifecycle_set_and_verify.yml
          vars:
            target_boot_mode: local_kernel
            on_failure_revert_to: nfs

        - name: "Phase 5 — record TFTP HITS AFTER local_kernel cycle"
          community.routeros.command:
            commands:
              - '/ip tftp print where real-filename~"{{ armbian_netboot_board_model }}/vmlinuz"'
          delegate_to: "{{ armbian_netboot_router }}"
          register: _hits_after

        - name: "Phase 5 — extract HITS counts"
          ansible.builtin.set_fact:
            _hits_before_n: "{{ (_hits_before.stdout[0] | default('') | regex_findall('[0-9]+\\s*$', multiline=True) | first | default('0')) | int }}"
            _hits_after_n: "{{ (_hits_after.stdout[0] | default('') | regex_findall('[0-9]+\\s*$', multiline=True) | first | default('0')) | int }}"

        - name: "Phase 5 — assert TFTP-flat (local_kernel = U-Boot baked localcmd, no TFTP fetch)"
          ansible.builtin.assert:
            that: (_hits_after_n | int) == (_hits_before_n | int)
            fail_msg: >-
              local_kernel mode incremented vmlinuz TFTP HITS by
              {{ (_hits_after_n | int) - (_hits_before_n | int) }} — U-Boot
              is still PXE-fetching the kernel. Check that the baked
              localcmd is present in the U-Boot binary (image_build hook)
              or in SPI env (persist_uboot_env).
            success_msg: "vmlinuz HITS unchanged across cycle ({{ _hits_before_n }}) — local_kernel proven"

        - name: "Phase 5 — write evidence"
          ansible.builtin.copy:
            content: |
              === Phase 5 (NVMe reprovision + local_kernel) — {{ inventory_hostname }} ===
              NVMe layout: {{ armbian_netboot_local_disks | default([]) | length }} disk(s) declared
              TFTP vmlinuz HITS: before={{ _hits_before_n }} after={{ _hits_after_n }} delta=0
              U-Boot baked localcmd (or SPI env) loaded kernel from NVMe.
            dest: "{{ fleet_artifact_dir }}/nvme-localkernel-evidence.txt"
          delegate_to: localhost
          vars:
            ansible_connection: local

        - name: "Phase 5 — record timing"
          ansible.builtin.lineinfile:
            path: "/tmp/iter-FLEET-{{ inventory_hostname | regex_replace('\\..*', '') }}/timing.tsv"
            line: "5\t{{ _t_phase_5_start }}\t{{ _t_end }}\t{{ (_t_end | int) - (_t_phase_5_start | int) }}"
            create: true
            mode: '0644'
          vars:
            _t_end: "{{ lookup('pipe', 'date +%s') | int }}"
            ansible_connection: local
          delegate_to: localhost
```

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Phase 5 — NVMe reprovision + local_kernel TFTP-flat verify

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Summary play — render six-phase timing table

Replace the placeholder Summary `debug` task with the real Jinja-rendered per-board per-phase timing table.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`

- [ ] **Step 1: Replace the Summary play's placeholder task**

Find:

```yaml
- name: "Summary"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Summary — per-board per-phase wall-time table"
      run_once: true
      ansible.builtin.debug:
        msg: "Summary Jinja completed in Task 8."
```

Replace with:

```yaml
- name: "Summary"
  hosts: "{{ target_hosts | default('boards') }}"
  gather_facts: false
  tasks:
    - name: "Summary — per-board per-phase wall-time table"
      run_once: true
      ansible.builtin.debug:
        msg: |
          === Deterministic fleet test per-phase wall times (seconds) ===

          Board                            0      1      2      3      4      5     Total
          ──────────────────────────────  ────   ────   ────   ────   ────   ─────  ─────
          {% for h in ansible_play_hosts -%}
          {%- set rows = lookup('file', '/tmp/iter-FLEET-' + (h | regex_replace('\\..*', '')) + '/timing.tsv', errors='ignore') | default('', true) -%}
          {%- set ns = namespace(P0='-', P1='-', P2='-', P3='-', P4='-', P5='-', total=0) -%}
          {%- for line in rows.split('\n') -%}
            {%- set f = line.split('\t') -%}
            {%- if f | length >= 4 and f[0] in ['0','1','2','3','4','5'] -%}
              {%- if f[0] == '0' %}{% set ns.P0 = f[3] %}{% endif -%}
              {%- if f[0] == '1' %}{% set ns.P1 = f[3] %}{% endif -%}
              {%- if f[0] == '2' %}{% set ns.P2 = f[3] %}{% endif -%}
              {%- if f[0] == '3' %}{% set ns.P3 = f[3] %}{% endif -%}
              {%- if f[0] == '4' %}{% set ns.P4 = f[3] %}{% endif -%}
              {%- if f[0] == '5' %}{% set ns.P5 = f[3] %}{% endif -%}
              {%- set ns.total = ns.total + (f[3] | int) -%}
            {%- endif -%}
          {%- endfor %}
          {{ '%-30s' | format(h) }}  {{ '%-5s' | format(ns.P0) }}  {{ '%-5s' | format(ns.P1) }}  {{ '%-5s' | format(ns.P2) }}  {{ '%-5s' | format(ns.P3) }}  {{ '%-5s' | format(ns.P4) }}  {{ '%-5s' | format(ns.P5) }}  {{ ns.total }}
          {% endfor %}
          (Phase 5 throttled to {{ fleet_phase_5_throttle | default(2) }} hosts in parallel;
           the others run in parallel across all hosts.
           Per-host artefacts: /tmp/iter-FLEET-<host>/timing.tsv)
```

- [ ] **Step 2: Run lint**

Run: `make lint`
Expected: PASS.

- [ ] **Step 3: Run syntax-check**

Run: `ansible-playbook --syntax-check playbooks/test_fleet_e2e.yml`
Expected: PASS.

- [ ] **Step 4: Sanity-check play count**

Run: `grep -c '^- name:' /workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`
Expected: `10`.

Run: `grep '^- name:' /workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`
Expected output (order matters):
1. `Pre-flight: ensure all per-board artifact dirs exist on controller`
2. `Phase 0 — PoE down all target boards`
3. `Phase 1 — Force-refresh NFS templates + per-host clones (netboot_server)`
4. `Phase 2a — NFS boot + bootstrap_armbian + verify`
5. `Phase 2b — Persist SPI U-Boot env (no-op for non-SPI boards)` (this is the `import_playbook` line)
6. `Phase 2 — evidence + timing`
7. `Phase 3 — dd canonical SD image via disk_image role`
8. `Phase 4 — SD boot + bootstrap_armbian + verify`
9. `Phase 5 — NVMe reprovision + local_kernel verify (throttled)`
10. `Summary`

- [ ] **Step 5: Commit**

```bash
git add playbooks/test_fleet_e2e.yml
git commit -m "test_fleet_e2e: Summary play — six-phase wall-time table

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Docs updates

Update CLAUDE.md and `docs/end-to-end-fleet-test.html` to reflect the new deterministic structure. CLAUDE.md's "Running playbooks" section currently mentions `test_hardware_e2e.yml` and may reference `test_fleet_e2e` indirectly — skim for stale phase letters. The HTML doc has a "Shipped: dd a known image to SD" section that references Phase 0 of the old structure; update to point at Phase 3.

**Files:**
- Modify: `/workspace/ansible-collection-armbian_netboot/CLAUDE.md`
- Modify: `/workspace/ansible-collection-armbian_netboot/docs/end-to-end-fleet-test.html`

- [ ] **Step 1: Find existing CLAUDE.md mentions of test_fleet_e2e or old phases**

Run: `grep -n "Phase [A-D]\|skip_dd_sd\|test_fleet_e2e\|Phase 0/A/B" /workspace/ansible-collection-armbian_netboot/CLAUDE.md`

For each match, decide whether the line refers to the *new* deterministic flow (leave as-is) or to the *old* Phase 0/A/B/C/D framing (rewrite). If a line says `Phase A/B/C/D` or `skip_dd_sd`, update it.

The most likely match is the playbook ASCII tree under `## Collection structure` — if it lists `test_fleet_e2e.yml` with a comment describing the old phases, update the comment to:

```
│   ├── test_fleet_e2e.yml         # Deterministic 6-phase fleet test (0 PoE-down → 1 NFS reset → 2 NFS boot+bootstrap+SPI → 3 dd SD → 4 SD boot+bootstrap → 5 NVMe local_kernel)
```

- [ ] **Step 2: Update `docs/end-to-end-fleet-test.html` "Shipped: dd a known image to SD" section**

The section currently says the dd preflight is implemented as Phase 0 of test_fleet_e2e.yml. Replace the reference to `Phase 0` with `Phase 3` and adjust the surrounding prose to note the new deterministic flow:

Find the `<h3 id="improve-dd-preflight">` heading and its first `<p>`. Update the `<p>` to read approximately:

```html
<p>Shipped in <code>playbooks/test_fleet_e2e.yml</code> Phase 3 of
the deterministic six-phase flow, backed by the <code>disk_image</code>
role. Phase 3 runs after Phase 2 has booted every target board on a
freshly-refreshed NFS rootfs (Phase 1) and bootstrapped igou, then
streams the canonical image from
<code>armbian_netboot_image_urls[&lt;model&gt;]</code> to
<code>/dev/mmcblk0</code> via <code>curl | xz -dc | dd</code>. Skip
with <code>-e skip_phase_3=true</code>.</p>
```

If there's a second/third paragraph referring to the dd preflight as a stand-alone Phase 0, rewrite to past tense + cite the deterministic flow as the canonical location.

Search for any remaining `skip_dd_sd` mentions in the file (`grep -n "skip_dd_sd" /workspace/ansible-collection-armbian_netboot/docs/end-to-end-fleet-test.html`) and replace each with `skip_phase_3`.

- [ ] **Step 3: Run lint (HTML is unaffected; yamllint+ansible-lint validate YAML only)**

Run: `make lint`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/end-to-end-fleet-test.html
git commit -m "docs: update for deterministic fleet e2e (Phase 0 dd → Phase 3 of new flow)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Final verification

End-to-end sanity sweep. No code changes unless something surfaces.

**Files:** none modified unless lint/syntax-check surfaces an issue.

- [ ] **Step 1: Full lint pass**

Run: `cd /workspace/ansible-collection-armbian_netboot && make lint`
Expected: PASS.

- [ ] **Step 2: Syntax-check every playbook (sanity sweep — guarantees the new test_fleet_e2e.yml didn't break other playbooks via shared task imports)**

Run: `for p in playbooks/*.yml; do ansible-playbook --syntax-check "$p" >/dev/null 2>&1 || echo "FAIL: $p"; done; echo DONE`
Expected: `DONE` with no `FAIL:` lines.

- [ ] **Step 3: Confirm the playbook structure is what we expect**

Run: `grep '^- name:' /workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`
Expected: lists 10 `- name:` lines matching the structure described in Task 8 step 4.

- [ ] **Step 4: Confirm no stale references to old phase letters**

Run: `grep -nE "Phase [A-D]|Phase C2|skip_dd_sd|skip_sd|skip_nfs|skip_reprovision|skip_local_kernel|skip_kernel_update|kernel_update_pin|kernel_pkg|armbian_netboot_kernel_target|fleet_phase_c_throttle" /workspace/ansible-collection-armbian_netboot/playbooks/test_fleet_e2e.yml`
Expected: no output. (If there ARE matches, decide whether each is stale and fix.)

- [ ] **Step 5: Confirm the collection still builds**

Run: `cd /workspace/ansible-collection-armbian_netboot && make collection-build`
Expected: PASS, produces `david_igou-armbian_netboot-<version>.tar.gz`.

Run: `make clean`

- [ ] **Step 6: No commit unless step 1-5 surfaced something to fix.** Report done.

Tell the operator: deterministic fleet e2e implementation complete. Hardware validation is a follow-up:

```bash
ansible-playbook playbooks/test_fleet_e2e.yml -e target_hosts=<one-board>
```

Expected behavior on hardware: all six phases complete; final Summary shows per-phase timing; board ends up booted on NVMe in `local_kernel` mode with TFTP HITS unchanged across the Phase 5 cycle.
