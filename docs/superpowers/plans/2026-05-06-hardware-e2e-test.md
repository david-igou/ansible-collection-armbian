# Hardware E2E PXE-first toggle test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Ansible playbook that toggles a single board through disk → nfsroot → disk, asserts `findmnt /` reaches the expected source at each phase, and emits a diagnostic bundle at every checkpoint to make it useful as a netboot-debugging tool.

**Architecture:** One play with `hosts: boards`, all phases inside a single `block:` so failure cleanup runs via `always:`. PoE-cycle (via `routeros_poe` role) drives every transition; SSH `wait_for_connection` + `ansible.builtin.setup`'s `ansible_mounts` fact powers the assertion (matches the precedent in `playbooks/reprovision.yml`). Connection identity for the NFS-root phase is overridden via block-scoped `vars:` (root + `armbian_default_password`), restored automatically when the block exits. `routeros_dhcp` role tasks are `include_role`'d with `delegate_to` to the first host in `routeros_routers`, since the entry-points target a RouterOS host directly.

**Tech Stack:** Ansible 2.15+, `community.routeros.command`, `ansible.posix` (already declared in `requirements.yml`), existing `routeros_dhcp` and `routeros_poe` roles.

---

## File structure

| File | Responsibility |
|---|---|
| `playbooks/test_hardware_e2e.yml` (new) | The playbook itself: pre-flight, three phases, always-block cleanup. |
| `playbooks/tasks/diagnostic_bundle.yml` (new) | Reusable task file, `import_tasks`'d at every verify checkpoint. Gathers and prints diagnostics in one debug message. |
| `CLAUDE.md` (modify) | Add the playbook to the running-playbooks section + Where things run table. |
| `README.md` (modify) | One-paragraph mention in the "Workflows" section. |

No new role for v1. If the verify logic grows past ~150 lines, refactor into `roles/hardware_e2e_test/` — that's a follow-up plan, not this one.

---

## Task 1: Create the diagnostic bundle task file

The bundle is reusable and called three times, so it ships as its own task file before any caller exists.

**Files:**
- Create: `playbooks/tasks/diagnostic_bundle.yml`

- [ ] **Step 1: Write the diagnostic bundle task file**

```yaml
---
# Gathers a fixed set of operator-readable diagnostics from the target
# board and prints them as one debug message at the call site. Each
# gather command uses failed_when: false / changed_when: false so a
# missing tool (e.g., journalctl on a future minimal NFS rootfs) does
# not abort the test. Imported at every verify checkpoint in
# test_hardware_e2e.yml.
#
# Required: ansible.builtin.setup must have been called in the parent
# play before this task file runs (we read ansible_mounts).

- name: Diagnostic bundle — findmnt root source
  ansible.builtin.command: findmnt -no SOURCE /
  changed_when: false
  failed_when: false
  register: _diag_findmnt

- name: Diagnostic bundle — kernel cmdline
  ansible.builtin.slurp:
    src: /proc/cmdline
  register: _diag_cmdline
  failed_when: false

- name: Diagnostic bundle — IPv4 routes
  ansible.builtin.command: ip -4 route
  changed_when: false
  failed_when: false
  register: _diag_route

- name: Diagnostic bundle — DNS resolver config
  ansible.builtin.slurp:
    src: /etc/resolv.conf
  register: _diag_resolv
  failed_when: false

- name: Diagnostic bundle — block devices
  ansible.builtin.command: lsblk -no NAME,SIZE,TYPE,MOUNTPOINT
  changed_when: false
  failed_when: false
  register: _diag_lsblk

- name: Diagnostic bundle — installed U-Boot debs
  ansible.builtin.command: dpkg-query -W -f='${Package} ${Version}\n' linux-u-boot-*
  changed_when: false
  failed_when: false
  register: _diag_uboot

- name: Diagnostic bundle — last 100 journal lines this boot
  ansible.builtin.command: journalctl -b 0 --no-pager -n 100
  changed_when: false
  failed_when: false
  register: _diag_journal

- name: Diagnostic bundle — print
  ansible.builtin.debug:
    msg:
      - "==== diagnostic bundle: {{ _diag_phase | default('unknown') }} ===="
      - "findmnt /:        {{ _diag_findmnt.stdout | default('(unavailable)') }}"
      - "rootfs (facts):   {{ ansible_mounts | selectattr('mount', 'equalto', '/')
                                            | map(attribute='device') | first | default('?') }}
                            ({{ ansible_mounts | selectattr('mount', 'equalto', '/')
                                              | map(attribute='fstype') | first | default('?') }})"
      - "/proc/cmdline:    {{ _diag_cmdline.content | default('') | b64decode | trim }}"
      - "ip -4 route:      {{ _diag_route.stdout_lines | default([]) }}"
      - "resolv.conf:      {{ _diag_resolv.content | default('') | b64decode | trim }}"
      - "lsblk:            {{ _diag_lsblk.stdout_lines | default([]) }}"
      - "linux-u-boot-*:   {{ _diag_uboot.stdout_lines | default(['(none installed)']) }}"
      - "journal (b 0):    {{ _diag_journal.stdout_lines | default([]) }}"
```

- [ ] **Step 2: Lint the new file**

Run: `yamllint -c .yamllint.yml playbooks/tasks/diagnostic_bundle.yml && ansible-lint playbooks/tasks/diagnostic_bundle.yml`
Expected: no failures, lint clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/tasks/diagnostic_bundle.yml
git commit -m "$(cat <<'EOF'
Add reusable diagnostic_bundle task file for hardware tests

Gathers findmnt, /proc/cmdline, ip route, resolv.conf, lsblk,
linux-u-boot-* deb versions, and the last 100 journal lines from the
target host, then emits the whole set as a single debug message
labelled by _diag_phase. Each gather is non-fatal so missing tools
don't abort the run. Imported at every verify checkpoint in the
hardware E2E playbook (next task).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Playbook skeleton with pre-flight asserts

Create the playbook with header comment, the play header, and pre-flight assertions only. No phases yet.

**Files:**
- Create: `playbooks/test_hardware_e2e.yml`

- [ ] **Step 1: Write the skeleton + pre-flight**

```yaml
---
# Hardware end-to-end test for the PXE-first boot toggle.
#
# Drives the target board through three phases:
#   1. disk boot baseline (PoE cycle, assert local rootfs)
#   2. nfsroot (set DHCP option, PoE cycle, assert NFS rootfs)
#   3. back to disk (clear DHCP option, PoE cycle, assert local rootfs)
#
# Pre-condition (v1): the target board has a custom-built Armbian
# image manually flashed to its SD card (or other primary storage)
# and is wired to its poe_switch port. v1 does not call reprovision.yml;
# the operator owns getting the custom image onto disk for now.
#
# Diagnostic bundle (playbooks/tasks/diagnostic_bundle.yml) runs at
# every verify checkpoint to surface findmnt, kernel cmdline, routes,
# resolv.conf, lsblk, U-Boot deb version, and the last 100 journal
# lines so a failure tells the operator what went wrong without
# re-SSHing.
#
# Failure cleanup: by default, the always-block clears the DHCP option
# and PoE-cycles the board back to disk boot regardless of pass/fail.
# Pass `-e leave_state=true` to preserve the failure state for forensic
# debugging.
#
# Usage:
#   ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01
#   ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01 -e leave_state=true

- name: Hardware E2E PXE-first toggle test
  hosts: boards
  gather_facts: false
  vars:
    leave_state: false
    _routeros_target: "{{ groups['routeros_routers'] | first }}"
    _wait_timeout: 300

  tasks:
    - name: Pre-flight — assert exactly one board targeted
      ansible.builtin.assert:
        that: ansible_play_hosts | length == 1
        fail_msg: >-
          test_hardware_e2e.yml is single-board. Pass --limit <hostname>.
          Got {{ ansible_play_hosts | length }} hosts: {{ ansible_play_hosts }}
      run_once: true

    - name: Pre-flight — assert per-board PoE state
      ansible.builtin.assert:
        that:
          - poe_switch is defined
          - poe_switch | length > 0
          - poe_port is defined
          - poe_port | length > 0
        fail_msg: >-
          {{ inventory_hostname }} needs poe_switch and poe_port hostvars set.
          Add them to inventory/host_vars/{{ inventory_hostname }}.yml.

    - name: Pre-flight — assert armbian_default_password is set
      ansible.builtin.assert:
        that:
          - armbian_default_password is defined
          - armbian_default_password | length > 0
        fail_msg: >-
          armbian_default_password must be set in group_vars (vault recommended).
          Phase 2 SSH to the NFS-mounted board uses these credentials.
      run_once: true

    - name: Pre-flight — warn if board not opted into custom build
      ansible.builtin.debug:
        msg: >-
          WARNING: host_board_overrides.armbian_build_enabled is not true on
          {{ inventory_hostname }}. v1 starts from a manually flashed SD card,
          so this is allowed — but if you meant to use a custom build, the
          inventory state is inconsistent.
      when: not (host_board_overrides.armbian_build_enabled | default(false))

    - name: Pre-flight — probe RouterOS for armbian-nfsroot option set
      community.routeros.command:
        commands:
          - "/ip dhcp-server option sets print where name=armbian-nfsroot"
      delegate_to: "{{ _routeros_target }}"
      run_once: true
      register: _opt_probe
      changed_when: false
      failed_when: "'armbian-nfsroot' not in (_opt_probe.stdout_lines | join(' '))"
```

- [ ] **Step 2: Lint and syntax-check**

Run:
```bash
yamllint -c .yamllint.yml playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
ansible-playbook playbooks/test_hardware_e2e.yml --syntax-check --limit __none__
```
Expected: lint clean, `--syntax-check` returns "playbook: …" with no errors. (`--limit __none__` is a non-existent host so no real targets resolve.)

- [ ] **Step 3: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "$(cat <<'EOF'
Scaffold playbooks/test_hardware_e2e.yml with pre-flight asserts

Single-board, single-play hardware test scaffold. Pre-flight asserts
that exactly one board is targeted (--limit), poe_switch/poe_port
hostvars are set, armbian_default_password is defined, and that
RouterOS has the armbian-nfsroot option set defined. Warns (does not
fail) if the board isn't opted into the custom-build flow, since v1
explicitly supports manually flashed SD cards. Phase tasks land in
follow-up commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Phase 1 — disk-boot baseline

Add the first phase: PoE cycle, wait for SSH on the inventory identity, gather facts, run diagnostic bundle, assert disk-rooted.

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml` (append tasks after pre-flight)

- [ ] **Step 1: Append phase-1 tasks**

Add these tasks at the end of the existing `tasks:` list (immediately after the RouterOS option-set probe task):

```yaml
    - name: Phase 1 — PoE cycle to disk-boot baseline
      ansible.builtin.include_role:
        name: routeros_poe
      vars:
        poe_action: cycle

    - name: Phase 1 — wait for SSH (disk-boot identity)
      ansible.builtin.wait_for_connection:
        delay: 30
        timeout: "{{ _wait_timeout }}"

    - name: Phase 1 — gather facts
      ansible.builtin.setup:

    - name: Phase 1 — diagnostic bundle
      ansible.builtin.import_tasks: tasks/diagnostic_bundle.yml
      vars:
        _diag_phase: "phase 1 — disk-boot baseline"

    - name: Phase 1 — assert rootfs is on a local block device
      ansible.builtin.assert:
        that:
          - (ansible_mounts | selectattr('mount', 'equalto', '/')
              | map(attribute='fstype') | first) not in ['nfs', 'nfs4']
          - (ansible_mounts | selectattr('mount', 'equalto', '/')
              | map(attribute='device') | first) is match('^/dev/')
        fail_msg: >-
          Phase 1: expected rootfs on /dev/<block>; got
          {{ ansible_mounts | selectattr('mount', 'equalto', '/')
                            | map(attribute='device') | first }}
          ({{ ansible_mounts | selectattr('mount', 'equalto', '/')
                             | map(attribute='fstype') | first }}).
          Diagnostic bundle is in the prior debug task.
```

- [ ] **Step 2: Lint and syntax-check**

Run:
```bash
yamllint -c .yamllint.yml playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
ansible-playbook playbooks/test_hardware_e2e.yml --syntax-check --limit __none__
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "$(cat <<'EOF'
Add phase 1 (disk-boot baseline) to test_hardware_e2e.yml

PoE-cycles the board, waits for SSH on the inventory ansible_user,
gathers facts, runs the diagnostic bundle labeled "phase 1 —
disk-boot baseline", and asserts the root mount is on a /dev/* block
device with a non-NFS fstype. Establishes the no-DHCP-option default
state before the toggle phases run.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Phase 2 — nfsroot (with block-scoped identity override)

Add the nfsroot phase. Identity override (root + armbian_default_password) lives on a `block:` so it auto-restores when the block exits.

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml` (append after phase-1 tasks)

- [ ] **Step 1: Append phase-2 tasks**

Add these tasks at the end of the existing `tasks:` list (after the phase-1 assertion):

```yaml
    - name: Phase 2 — set DHCP option to armbian-nfsroot
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: enable_netboot.yml
      vars:
        board_mac: "{{ board_mac }}"
        netboot_mode: nfsroot
      delegate_to: "{{ _routeros_target }}"

    - name: Phase 2 — PoE cycle into nfsroot
      ansible.builtin.include_role:
        name: routeros_poe
      vars:
        poe_action: cycle

    - name: Phase 2 — verify NFS-mounted boot
      block:
        - name: Phase 2 — reset connection so new identity takes effect
          ansible.builtin.meta: reset_connection

        - name: Phase 2 — wait for SSH (NFS-root identity)
          ansible.builtin.wait_for_connection:
            delay: 30
            timeout: "{{ _wait_timeout }}"

        - name: Phase 2 — gather facts
          ansible.builtin.setup:

        - name: Phase 2 — diagnostic bundle
          ansible.builtin.import_tasks: tasks/diagnostic_bundle.yml
          vars:
            _diag_phase: "phase 2 — nfsroot"

        - name: Phase 2 — assert rootfs is NFS
          ansible.builtin.assert:
            that:
              - (ansible_mounts | selectattr('mount', 'equalto', '/')
                  | map(attribute='fstype') | first) in ['nfs', 'nfs4']
            fail_msg: >-
              Phase 2: expected NFS-mounted rootfs; got fstype
              {{ ansible_mounts | selectattr('mount', 'equalto', '/')
                                | map(attribute='fstype') | first }}.
              Board did not PXE-boot into NFS root despite DHCP option
              armbian-nfsroot being set. Diagnostic bundle is in the
              prior debug task — check /proc/cmdline for nfsroot=, and
              confirm the linux-u-boot-* deb on disk has PXE-first
              BOOT_TARGETS baked in.
      vars:
        ansible_user: root
        ansible_password: "{{ armbian_default_password }}"
        ansible_ssh_common_args: "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        ansible_become: false
```

- [ ] **Step 2: Lint and syntax-check**

Run:
```bash
yamllint -c .yamllint.yml playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
ansible-playbook playbooks/test_hardware_e2e.yml --syntax-check --limit __none__
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "$(cat <<'EOF'
Add phase 2 (nfsroot) to test_hardware_e2e.yml

Sets DHCP option armbian-nfsroot via routeros_dhcp role's
enable_netboot task entry-point (delegated to the first
routeros_routers host since the role's tasks target RouterOS
directly), PoE-cycles the board, then runs verify steps inside a
block scoped with NFS-root SSH identity (root /
armbian_default_password). Block-scoped vars auto-restore the
inventory ansible_user when the block exits, no manual restore
needed. The assert is the load-bearing one: stock Armbian Rockchip
current never reaches NFS root regardless of DHCP, so reaching it
proves the patched BOOT_TARGETS is in effect.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Phase 3 — back to disk

Add the third phase: clear DHCP, PoE cycle, wait for SSH on the inventory identity (auto-restored when the phase-2 block exits), assert disk again.

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml` (append after phase-2 block)

- [ ] **Step 1: Append phase-3 tasks**

Add these tasks at the end of the existing `tasks:` list (after the phase-2 block):

```yaml
    - name: Phase 3 — clear DHCP option
      ansible.builtin.include_role:
        name: routeros_dhcp
        tasks_from: disable_netboot.yml
      vars:
        board_mac: "{{ board_mac }}"
      delegate_to: "{{ _routeros_target }}"

    - name: Phase 3 — PoE cycle back to disk
      ansible.builtin.include_role:
        name: routeros_poe
      vars:
        poe_action: cycle

    - name: Phase 3 — reset connection so inventory identity takes effect
      ansible.builtin.meta: reset_connection

    - name: Phase 3 — wait for SSH (disk-boot identity)
      ansible.builtin.wait_for_connection:
        delay: 30
        timeout: "{{ _wait_timeout }}"

    - name: Phase 3 — gather facts
      ansible.builtin.setup:

    - name: Phase 3 — diagnostic bundle
      ansible.builtin.import_tasks: tasks/diagnostic_bundle.yml
      vars:
        _diag_phase: "phase 3 — back to disk"

    - name: Phase 3 — assert rootfs returned to local block device
      ansible.builtin.assert:
        that:
          - (ansible_mounts | selectattr('mount', 'equalto', '/')
              | map(attribute='fstype') | first) not in ['nfs', 'nfs4']
          - (ansible_mounts | selectattr('mount', 'equalto', '/')
              | map(attribute='device') | first) is match('^/dev/')
        fail_msg: >-
          Phase 3: expected rootfs on /dev/<block> after clearing the
          DHCP option; got
          {{ ansible_mounts | selectattr('mount', 'equalto', '/')
                            | map(attribute='device') | first }}
          ({{ ansible_mounts | selectattr('mount', 'equalto', '/')
                             | map(attribute='fstype') | first }}).
          Toggle is not bidirectional — DHCP option may not have been
          cleared on the lease, or the board is not honouring DHCP
          renewal. Diagnostic bundle is in the prior debug task.
```

- [ ] **Step 2: Lint and syntax-check**

Run:
```bash
yamllint -c .yamllint.yml playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
ansible-playbook playbooks/test_hardware_e2e.yml --syntax-check --limit __none__
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "$(cat <<'EOF'
Add phase 3 (back to disk) to test_hardware_e2e.yml

Clears the DHCP option via the routeros_dhcp role's disable_netboot
task entry-point (delegated to RouterOS), PoE-cycles, resets the
connection so the inventory ansible_user takes effect, waits for
SSH, and asserts the rootfs returned to /dev/. This confirms the
toggle is bidirectional — clearing the DHCP option lets U-Boot fall
through PXE/DHCP attempts to the local disk.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wrap phases in block/always for cleanup with leave_state

Convert the linear sequence into a `block:` followed by `always:` that runs cleanup conditionally on `leave_state`.

**Files:**
- Modify: `playbooks/test_hardware_e2e.yml`

- [ ] **Step 1: Refactor — wrap phases 1-3 in a block, add always-block**

Restructure the playbook so the three phase task groups become children of a single block, with an `always:` clause appended. The pre-flight tasks stay outside the block (no cleanup needed if pre-flight fails).

The shape becomes:

```yaml
  tasks:
    # ... pre-flight tasks unchanged ...

    - name: Test phases (cleanup runs in always)
      block:
        # ... all phase 1 tasks moved here ...
        # ... all phase 2 tasks moved here ...
        # ... all phase 3 tasks moved here ...
      always:
        - name: Cleanup — print exit-state notice if leave_state
          ansible.builtin.debug:
            msg: >-
              leave_state=true: not cleaning up. Board may be in NFS
              root; clear DHCP manually with:
              ansible-playbook playbooks/disable_netboot.yml
              --limit {{ inventory_hostname }}
          when: leave_state | bool

        - name: Cleanup — clear DHCP option on RouterOS
          ansible.builtin.include_role:
            name: routeros_dhcp
            tasks_from: disable_netboot.yml
          vars:
            board_mac: "{{ board_mac }}"
          delegate_to: "{{ _routeros_target }}"
          when: not (leave_state | bool)

        - name: Cleanup — PoE cycle back to disk boot
          ansible.builtin.include_role:
            name: routeros_poe
          vars:
            poe_action: cycle
          when: not (leave_state | bool)

        - name: Cleanup — reset connection to inventory identity
          ansible.builtin.meta: reset_connection
          when: not (leave_state | bool)

        - name: Cleanup — wait for SSH after cleanup cycle
          ansible.builtin.wait_for_connection:
            delay: 30
            timeout: "{{ _wait_timeout }}"
          when: not (leave_state | bool)

        - name: Cleanup — verify board returned to disk boot
          ansible.builtin.setup:
          when: not (leave_state | bool)

        - name: Cleanup — assert disk-rooted (post-cleanup)
          ansible.builtin.assert:
            that:
              - (ansible_mounts | selectattr('mount', 'equalto', '/')
                  | map(attribute='fstype') | first) not in ['nfs', 'nfs4']
            fail_msg: >-
              Cleanup left the board in NFS root mode despite clearing the
              DHCP option. Investigate RouterOS lease state for
              {{ board_mac }} and the linux-u-boot-* deb on disk.
          when: not (leave_state | bool)
```

The phase-3 tasks already do their own cleanup-equivalent on the happy path, but the always-block re-does the DHCP clear so a phase-2 failure (where the board is still in NFS root) gets cleaned up. Doing the work twice on a happy run is cheap; the safety on the failure path is the point.

- [ ] **Step 2: Lint and syntax-check**

Run:
```bash
yamllint -c .yamllint.yml playbooks/test_hardware_e2e.yml
ansible-lint playbooks/test_hardware_e2e.yml
ansible-playbook playbooks/test_hardware_e2e.yml --syntax-check --limit __none__
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add playbooks/test_hardware_e2e.yml
git commit -m "$(cat <<'EOF'
Wrap test_hardware_e2e.yml phases in block/always for cleanup

Phases 1-3 move into a block; the always handler clears the DHCP
option, PoE-cycles back to disk, and re-asserts disk-rooted state
unless -e leave_state=true is passed. Failure cleanup is what makes
this safe to abort or fail mid-toggle: a phase-2 failure that left
the board in NFS root gets cleaned up so the operator can retry
without first running disable_netboot.yml manually. leave_state=true
preserves the failure state for forensic debugging and prints a
hint pointing at disable_netboot.yml.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Document the playbook in CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md` (add to the "Running playbooks" examples + the "Where things run" table)
- Modify: `README.md` (one-paragraph mention)

- [ ] **Step 1: Add `CLAUDE.md` entry under "Running playbooks"**

Append this block after the existing `# Ad-hoc: PoE power cycle a board…` example and before any closing fence:

```markdown
# Ad-hoc hardware E2E test: toggle a board through disk → nfsroot → disk
# and assert each transition (post manually-flashed SD card).
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01

# Same, preserving the failure state for forensic debugging if a phase fails:
ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01 -e leave_state=true
```

- [ ] **Step 2: Add `CLAUDE.md` row to "Where things run" table**

Insert a new row after the `poe_control.yml` row:

```markdown
| `test_hardware_e2e.yml` | **boards** (single-board via --limit) + RouterOS (DHCP toggle, delegated) + RouterOS switch (PoE cycle, delegated to `poe_switch`) |
```

- [ ] **Step 3: Add `README.md` paragraph**

Locate the "Workflows" section in `README.md` and insert this paragraph at the end of the workflows list:

```markdown
- **`playbooks/test_hardware_e2e.yml`** — repeatable hardware regression test
  for the PXE-first boot-mode invariant. Drives a board with a manually flashed
  custom Armbian image through disk → nfsroot → disk via RouterOS DHCP toggle and
  PoE cycles, asserting `findmnt /` reports the expected source at each
  transition. Diagnostic bundle (cmdline, route, lsblk, U-Boot deb version,
  journal) emitted at every checkpoint. Pass `-e leave_state=true` to preserve
  the failure state for forensic debugging.
```

- [ ] **Step 4: Lint markdown (best-effort, no project rule on markdown)**

Run:
```bash
yamllint -c .yamllint.yml CLAUDE.md README.md 2>/dev/null || true
ansible-lint playbooks/ roles/
```
The yamllint call is best-effort; the project doesn't lint Markdown. The ansible-lint call confirms nothing in the repo regressed.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
Document playbooks/test_hardware_e2e.yml

Adds the hardware E2E toggle test to CLAUDE.md's "Running playbooks"
examples + "Where things run" table, and to README.md's Workflows
section. Documents both the default invocation and the
leave_state=true variant for forensic debugging on a failed run.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Acceptance — operator hardware run (manual, post-implementation)

Not a coding task; do this once after Tasks 1-7 land to validate against real hardware.

- [ ] Ensure a target opi5pro board has a custom-built Armbian image manually flashed to its SD card and is connected to its `poe_switch` port.
- [ ] Run: `ansible-playbook playbooks/test_hardware_e2e.yml --limit opi5pro-01`
- [ ] Expected: all three phases pass; cleanup leaves the board in disk-boot mode.
- [ ] If any phase fails, re-run with `-e leave_state=true` to preserve the failure state, then capture serial output out of band and inspect.
- [ ] If pass: file the issue-#2 / issue-#3 closure, remove the WIP banners from `README.md`, `CLAUDE.md`, and `docs/architecture.md`.
