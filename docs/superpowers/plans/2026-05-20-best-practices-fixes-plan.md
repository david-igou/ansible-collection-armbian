# Best-practices fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the maintainability + security fixes identified in
[`docs/ansible-best-practices-review.html`](../../ansible-best-practices-review.html)
in three coordinated releases (3.1.1, 3.2.0, 4.0.0).

**Architecture:** Seven workstreams grouped by release. WS-1 ships as a
patch (no API change). WS-2/3/4/5 ship as a minor (docs + idempotency
behaviour change but no input rename). WS-6 ships as a major (single
breaking rename of `pxelinux_render` variables). WS-7 (molecule) is
plumbing and can ship in any release.

**Tech stack:** Ansible 2.15+, `ansible-lint`, `yamllint`, `molecule`
(for WS-7), `ansible-playbook --syntax-check`, `playbooks/test_fleet_e2e.yml`
for the integration smoke at release boundaries.

**Spec:** [`docs/superpowers/specs/2026-05-20-best-practices-fixes-design.md`](../specs/2026-05-20-best-practices-fixes-design.md)

---

## Conventions for every task in this plan

- **Working directory:** repository root, `/workspace/ansible-collection-armbian_netboot/`.
- **Inventory check:** before any `ansible-playbook` or `ansible-lint` run,
  confirm `echo $ANSIBLE_INVENTORY` ends in `.inventory/` (per CLAUDE.md).
- **Commit cadence:** one commit per Task. Trailer:
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- **Verification:** every Task ends with a literal command + expected
  output, and a green run of `ansible-lint roles/<changed-role>/` for any
  task that touched a role.
- **Don't run `test_fleet_e2e.yml` per task.** It costs ~25 minutes against
  real hardware; only run it at release checkpoints (after WS-1, WS-5,
  WS-6).

---

# Release 3.1.1 — specs

## Task 1: Add meta/argument_specs.yml to bootstrap_armbian

**Files:**
- Create: `roles/bootstrap_armbian/meta/argument_specs.yml`

- [ ] **Step 1: Confirm the gap**

Run: `ls roles/bootstrap_armbian/meta/argument_specs.yml`
Expected: `No such file or directory`.

- [ ] **Step 2: Write the spec**

Create `roles/bootstrap_armbian/meta/argument_specs.yml`:

```yaml
---
argument_specs:
  main:
    short_description: "Provision an SSH-key user with passwordless sudo on a flashed Armbian board."
    description:
      - "Connects as root (with the Armbian default password) and creates an
        unprivileged user, authorises a fixed set of SSH keys for it, grants
        passwordless sudo, and disables password authentication in sshd."
      - "Idempotent: re-running against an already-bootstrapped board
        reconciles authorized_keys and is otherwise a no-op."
    options:
      armbian_bootstrap_user:
        type: str
        required: true
        description: "Username to create on the board."
      armbian_bootstrap_ssh_keys:
        type: list
        elements: str
        required: true
        description: >
          Public SSH keys to authorise for the new user. Must be non-empty —
          an empty list combined with the role's PasswordAuthentication=no
          step would render the board permanently unreachable.
```

- [ ] **Step 3: Add a runtime assertion mirroring the non-empty rule**

Open `roles/bootstrap_armbian/tasks/main.yml`. At the top of the file (immediately after the `---` and any existing top-level `assert`), add:

```yaml
- name: Assert SSH key list is non-empty
  ansible.builtin.assert:
    that:
      - armbian_bootstrap_ssh_keys | length > 0
    fail_msg: >
      armbian_bootstrap_ssh_keys is empty. Continuing would create
      a user with no authorised keys and disable password auth, leaving
      the board unreachable.
```

(If a similar assert already exists, do not duplicate it.)

- [ ] **Step 4: Lint + syntax**

Run: `ansible-lint roles/bootstrap_armbian/`
Expected: PASS.

Run: `ansible-playbook --syntax-check -i inventory playbooks/bootstrap_armbian.yml`
Expected: parse-OK.

- [ ] **Step 5: Commit**

```bash
git add roles/bootstrap_armbian/meta/argument_specs.yml roles/bootstrap_armbian/tasks/main.yml
git commit -m "bootstrap_armbian: add argument_specs + assert non-empty ssh_keys"
```

## Task 2: Reconcile board_boot_wait defaults vs argument_specs

**Files:**
- Modify: `roles/board_boot_wait/defaults/main.yml`
- Read: `roles/board_boot_wait/tasks/main.yml`
- Read: `roles/board_boot_wait/meta/argument_specs.yml`

- [ ] **Step 1: Confirm the three suspects are unreferenced**

Run:
```bash
for v in armbian_boot_retry_attempts armbian_ssh_wait_timeout armbian_ssh_wait_retry_attempts; do
  echo "=== $v ==="
  grep -rn "$v" roles/board_boot_wait/ || echo "  unused inside role"
done
```
Expected: each variable appears only in `defaults/main.yml`, never in `tasks/main.yml`.

- [ ] **Step 2: Delete the unused defaults**

In `roles/board_boot_wait/defaults/main.yml`, delete the three variable lines (and any comment block exclusively describing them).

- [ ] **Step 3: Verify retry logic still lives in the playbook layer**

Run: `grep -rn 'armbian_boot_retry_attempts' playbooks/`
Expected: at least one match under `playbooks/tasks/` (where the retry actually happens). This confirms the defaults belong there, not in the role.

- [ ] **Step 4: Lint**

Run: `ansible-lint roles/board_boot_wait/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add roles/board_boot_wait/defaults/main.yml
git commit -m "board_boot_wait: drop unused retry knobs from role defaults"
```

## Task 3: Cut release 3.1.1

**Files:**
- Modify: `galaxy.yml`
- Modify: `CHANGELOG.md` (if present) or create release notes inline in the commit.

- [ ] **Step 1: Verify acceptance criteria for this release**

Run:
```bash
ls roles/bootstrap_armbian/meta/argument_specs.yml
ls roles/*/meta/argument_specs.yml | wc -l
```
Expected: `argument_specs.yml` listed; count == 9.

- [ ] **Step 2: Bump version**

In `galaxy.yml`: change `version: 3.1.0` to `version: 3.1.1`.

- [ ] **Step 3: Run the fleet e2e smoke**

Run (with the real inventory exported): `ansible-playbook -i $ANSIBLE_INVENTORY playbooks/test_fleet_e2e.yml`
Expected: 5/5 PASS Summary table (this is the release gate).

- [ ] **Step 4: Commit + tag**

```bash
git add galaxy.yml
git commit -m "release: 3.1.1 (bootstrap_armbian argument_specs)"
git tag v3.1.1
```

Do NOT push the tag automatically. Confirm with the user first.

---

# Release 3.2.0 — docs + idempotency + style

## Task 4: Standardise meta/main.yml across all nine roles

**Files:**
- Modify: `roles/*/meta/main.yml` (all 9)

- [ ] **Step 1: Confirm the inconsistency**

Run:
```bash
grep -H 'author:\|license:' roles/*/meta/main.yml
```
Expected: 7 roles use `david-igou`, 2 use `David Igou`; 7 use MIT, 2 use GPL-3.0-or-later.

- [ ] **Step 2: For each of the nine roles, ensure the galaxy_info block matches**

For each `roles/<r>/meta/main.yml`, ensure:

```yaml
galaxy_info:
  role_name: <r>
  author: David Igou
  author_email: igou.david@gmail.com
  description: "<existing description, leave alone>"
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: <existing — leave alone>
      versions: <existing — leave alone>
  galaxy_tags:
    - armbian
    - netboot
    - <one role-specific tag — see below>
```

Per-role tag suggestions:

| Role | Third tag |
|---|---|
| `board_boot_verify` | `verification` |
| `board_boot_wait` | `lifecycle` |
| `bootstrap_armbian` | `provisioning` |
| `disk_image` | `imaging` |
| `disk_provision` | `provisioning` |
| `image_build` | `build` |
| `image_extract` | `imaging` |
| `pxelinux_render` | `pxe` |
| `rootfs_clone` | `provisioning` |

- [ ] **Step 3: Verify**

Run:
```bash
grep -L 'license: MIT' roles/*/meta/main.yml
grep -L 'author: David Igou' roles/*/meta/main.yml
grep -L 'galaxy_tags:' roles/*/meta/main.yml
```
Expected: each command returns empty (no file is missing the standard line).

- [ ] **Step 4: Top-level LICENSE check**

Run: `head -3 LICENSE`
Expected: an MIT preamble. If the file is GPL or absent, **stop and ask the user before proceeding** — the licence-of-record needs explicit confirmation.

- [ ] **Step 5: Commit**

```bash
git add roles/*/meta/main.yml
git commit -m "roles: standardise author/license/galaxy_tags across all meta/main.yml"
```

## Task 5: Update galaxy.yml authors + ansible.cfg booleans

**Files:**
- Modify: `galaxy.yml`
- Modify: `ansible.cfg`

- [ ] **Step 1: galaxy.yml authors**

Replace the `authors:` block with:

```yaml
authors:
  - David Igou <igou.david@gmail.com>
```

- [ ] **Step 2: ansible.cfg booleans**

Change `host_key_checking = False` → `host_key_checking = false`.

- [ ] **Step 3: Verify**

Run: `ansible-galaxy collection build --force --output-path /tmp/`
Expected: build succeeds; no validation warnings about `authors`.

Run: `ansible-config dump | grep HOST_KEY_CHECKING`
Expected: `HOST_KEY_CHECKING(...) = False` (Ansible normalises the parsed value).

- [ ] **Step 4: Commit**

```bash
git add galaxy.yml ansible.cfg
git commit -m "metadata: human-name in galaxy.yml authors, lowercase boolean in ansible.cfg"
```

## Task 6: Annotate vars/boards.yml placement decision

**Files:**
- Modify: `vars/boards.yml`

- [ ] **Step 1: Add header comment**

At the top of `vars/boards.yml` (immediately after `---`), insert:

```yaml
# Authoritative per-board catalogue.
#
# This file intentionally lives under vars/ (not defaults/) because the
# entries are *facts about hardware* that the collection owns, not
# user-overridable defaults. Per-host overrides should patch specific
# fields via group_vars / host_vars, not replace whole entries.
```

- [ ] **Step 2: Verify the file still parses**

Run: `ansible-playbook --syntax-check -i inventory playbooks/converge_boot_mode.yml -e target_hosts=localhost`
Expected: parse-OK.

- [ ] **Step 3: Commit**

```bash
git add vars/boards.yml
git commit -m "vars/boards: document why this lives under vars/ not defaults/"
```

## Task 7: Write README for disk_provision

**Files:**
- Create: `roles/disk_provision/README.md`

- [ ] **Step 1: Read the existing exemplar**

Run: `cat roles/disk_image/README.md`

- [ ] **Step 2: Write the README**

Create `roles/disk_provision/README.md` with these five sections (use the
existing `image_build`/`disk_image` READMEs for tone and length):

1. **Purpose** — one paragraph explaining the declarative `disk_binding` + repart + populate pipeline.
2. **Inputs** — table mirroring `meta/argument_specs.yml`. List every option (`disk_binding`, `disk_provision_source`, `reset_identity`, `fast_wipe`, `render_only`).
3. **Outputs / side effects** — partition table written, filesystems formatted, `/etc/fstab` rendered, optional identity reset.
4. **Idempotency & check mode** — preserve scan logic explained; partitions with matching labels are kept; `fast_wipe` bypasses the preserve scan; check mode renders the repart definitions but does not apply.
5. **Example** — a worked 3-partition `disk_binding` (esp + root + data), shown as a playbook task.

- [ ] **Step 3: Verify**

Run: `wc -l roles/disk_provision/README.md`
Expected: between 80 and 200 lines (the role is complex; full coverage is warranted).

- [ ] **Step 4: Commit**

```bash
git add roles/disk_provision/README.md
git commit -m "disk_provision: add README"
```

## Task 8: Write README for image_extract

**Files:**
- Create: `roles/image_extract/README.md`

- [ ] **Step 1: Write the five sections**

Same five-section structure as Task 7. Cover specifically:

- The URL-or-local-path source flexibility.
- The loop-device + mount lifecycle and the `block/rescue/always` cleanup guarantee.
- The on-server output layout (`<template_dir>/`, `<tftp_dir>/{vmlinuz,initrd.img,board.dtb}`).
- The idempotency probe (after Task 12 lands, this will become a sentinel file).

- [ ] **Step 2: Commit**

```bash
git add roles/image_extract/README.md
git commit -m "image_extract: add README"
```

## Task 9: Write READMEs for rootfs_clone, pxelinux_render, board_boot_wait, board_boot_verify

**Files:**
- Create: `roles/rootfs_clone/README.md`
- Create: `roles/pxelinux_render/README.md`
- Create: `roles/board_boot_wait/README.md`
- Create: `roles/board_boot_verify/README.md`

- [ ] **Step 1: Write each in turn, following the five-section layout**

Length guidance:
- `rootfs_clone`: 60–120 lines (identity-reset contract is non-trivial).
- `pxelinux_render`: 60–120 lines (boot-mode table + `extra_modes` example).
- `board_boot_wait`: 20–40 lines (thin role).
- `board_boot_verify`: 30–60 lines (boot-mode assertion matrix).

- [ ] **Step 2: Verify all four roles now have READMEs**

Run: `ls roles/*/README.md | wc -l`
Expected: `9`.

- [ ] **Step 3: Commit (one per README for reviewability)**

```bash
git add roles/rootfs_clone/README.md
git commit -m "rootfs_clone: add README"

git add roles/pxelinux_render/README.md
git commit -m "pxelinux_render: add README"

git add roles/board_boot_wait/README.md
git commit -m "board_boot_wait: add README"

git add roles/board_boot_verify/README.md
git commit -m "board_boot_verify: add README"
```

## Task 10: Fix changed_when on disk_image streaming branches

**Files:**
- Modify: `roles/disk_image/tasks/_write.yml`

- [ ] **Step 1: Identify the four branches**

Run: `grep -nE 'shell:|changed_when:' roles/disk_image/tasks/_write.yml`
Expected: four shell tasks, each with `changed_when: true`.

- [ ] **Step 2: For each branch, replace `changed_when: true` with content-derived logic**

For each of the four `ansible.builtin.shell:` blocks:

```yaml
# Add the register key:
  register: __disk_image_write
# Replace the changed_when line with:
  changed_when:
    - '"records out" in (__disk_image_write.stderr | default(""))'
    - 'not __disk_image_write.stderr is search("0\\+0 records out")'
```

- [ ] **Step 3: Lint**

Run: `ansible-lint roles/disk_image/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add roles/disk_image/tasks/_write.yml
git commit -m "disk_image: derive changed_when from dd records-out for each write branch"
```

## Task 11: Fix changed_when on disk_provision systemd-repart + rsync

**Files:**
- Modify: `roles/disk_provision/tasks/_apply_repart.yml`
- Modify: `roles/disk_provision/tasks/_populate.yml`

- [ ] **Step 1: systemd-repart**

In `_apply_repart.yml`, find the `systemd-repart` command. Add `--json=short` to the invocation if not already present, then:

```yaml
  register: __disk_provision_repart
  changed_when: (__disk_provision_repart.stdout | default('[]') | from_json | length) > 0
```

- [ ] **Step 2: rsync (still using `command`, will be replaced in Task 14)**

In `_populate.yml`, add `--itemize-changes` to the rsync flags. Then:

```yaml
  register: __disk_provision_populate
  changed_when: __disk_provision_populate.stdout_lines | reject('match', '^$') | list | length > 0
```

- [ ] **Step 3: Lint + syntax**

Run: `ansible-lint roles/disk_provision/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add roles/disk_provision/tasks/_apply_repart.yml roles/disk_provision/tasks/_populate.yml
git commit -m "disk_provision: derive changed_when from systemd-repart JSON and rsync itemize"
```

## Task 12: image_extract sentinel-file idempotency

**Files:**
- Modify: `roles/image_extract/tasks/main.yml`

- [ ] **Step 1: Find the current probe**

Run: `grep -n 'stat:\|_already_extracted' roles/image_extract/tasks/main.yml`

- [ ] **Step 2: Replace the probe with a sentinel check**

Locate the existing `ansible.builtin.stat:` probe and the `set_fact: _already_extracted: …` immediately after it. Replace the probe with:

```yaml
- name: Probe extraction sentinel
  ansible.builtin.stat:
    path: "{{ template_dir }}/.armbian_extract_complete"
  register: __image_extract_sentinel

- name: Compute already-extracted fast-path
  ansible.builtin.set_fact:
    _already_extracted: "{{ __image_extract_sentinel.stat.exists }}"
```

- [ ] **Step 3: Write the sentinel at the end of the success path**

Find the last task inside the success block (immediately before the `rescue:` if one exists, or before `always:`). After it, add:

```yaml
- name: Mark extraction complete
  ansible.builtin.copy:
    dest: "{{ template_dir }}/.armbian_extract_complete"
    content: "{{ ansible_date_time.iso8601 }}\n"
    mode: "0644"
  when: not _already_extracted
```

- [ ] **Step 4: Lint**

Run: `ansible-lint roles/image_extract/`
Expected: PASS.

- [ ] **Step 5: Smoke**

Run (against the real netboot server, twice in a row):
```bash
ansible-playbook -i $ANSIBLE_INVENTORY playbooks/stage_netboot_assets.yml --limit netboot_server
ansible-playbook -i $ANSIBLE_INVENTORY playbooks/stage_netboot_assets.yml --limit netboot_server
```
Expected: second run reports zero `changed:` for the extraction tasks.

- [ ] **Step 6: Commit**

```bash
git add roles/image_extract/tasks/main.yml
git commit -m "image_extract: switch idempotency probe to .armbian_extract_complete sentinel"
```

## Task 13: image_extract cleanup warning instead of silent swallow

**Files:**
- Modify: `roles/image_extract/tasks/_cleanup.yml`

- [ ] **Step 1: Find the umount + losetup tasks**

Run: `grep -nE '^- name:|failed_when' roles/image_extract/tasks/_cleanup.yml`

- [ ] **Step 2: For each `failed_when: false` task, register the result + add a debug warning**

```yaml
- name: Unmount the loop partition (best effort)
  ansible.builtin.command: umount {{ image_mount_dir }}
  register: __image_extract_umount
  failed_when: false
  changed_when: __image_extract_umount.rc == 0

- name: Warn if unmount failed
  ansible.builtin.debug:
    msg: "umount failed (rc={{ __image_extract_umount.rc }}): {{ __image_extract_umount.stderr }}"
  when: __image_extract_umount.rc != 0
```

Apply the same pattern to the `losetup -d` task.

- [ ] **Step 3: Lint**

Run: `ansible-lint roles/image_extract/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add roles/image_extract/tasks/_cleanup.yml
git commit -m "image_extract: warn on cleanup failures instead of silent swallow"
```

## Task 14: Replace disk_provision rsync command with synchronize

**Files:**
- Modify: `roles/disk_provision/tasks/_populate.yml`

- [ ] **Step 1: Replace the command-based rsync with synchronize**

Replace the entire rsync task block with:

```yaml
- name: Populate partition from source rootfs
  ansible.posix.synchronize:
    src: "{{ disk_provision_source }}/"
    dest: "{{ __disk_provision_mount_root }}{{ part.mountpoint }}"
    archive: true
    delete: true
    rsync_opts:
      - "--exclude=/proc/*"
      - "--exclude=/sys/*"
      - "--exclude=/dev/*"
      - "--exclude=/tmp/*"
      - "--itemize-changes"
  register: __disk_provision_populate
  changed_when: __disk_provision_populate.stdout_lines
                | default([])
                | reject('match', '^$')
                | list | length > 0
  loop: "{{ disk_binding.layout | selectattr('mountpoint', 'defined') | list }}"
  loop_control:
    label: "{{ part.mountpoint }}"
    loop_var: part
```

- [ ] **Step 2: Lint**

Run: `ansible-lint roles/disk_provision/`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add roles/disk_provision/tasks/_populate.yml
git commit -m "disk_provision: switch populate from rsync command to synchronize module"
```

## Task 15: Delete dead publish_scp.yml from image_build

**Files:**
- Delete: `roles/image_build/tasks/publish_scp.yml`
- Modify: `roles/image_build/tasks/main.yml`
- Modify: `roles/image_build/defaults/main.yml`
- Modify: `roles/image_build/meta/argument_specs.yml`
- Modify: `roles/image_build/README.md`

- [ ] **Step 1: Confirm `armbian_publish_target` is set nowhere**

Run:
```bash
grep -rn 'armbian_publish_target\|publish_scp' playbooks/ inventory/ vars/
```
Expected: zero matches in `playbooks/`, `inventory/`, and `vars/`. The only matches across the repo should be inside `roles/image_build/` (the dead-code self-references).

If the grep finds a setter, STOP — the file is not orphaned and this Task needs rescoping. Otherwise, proceed.

- [ ] **Step 2: Remove the include + guard**

In `roles/image_build/tasks/main.yml`, delete the three lines:

```yaml
- name: Publish .img.xz to remote (opt-in via armbian_publish_target)
  ansible.builtin.include_tasks: publish_scp.yml
  when: armbian_publish_target | default('') | length > 0
```

- [ ] **Step 3: Delete the sub-task file**

```bash
git rm roles/image_build/tasks/publish_scp.yml
```

- [ ] **Step 4: Delete the default and the argspec entry**

In `roles/image_build/defaults/main.yml`, delete the line:

```yaml
armbian_publish_target: ""
```

In `roles/image_build/meta/argument_specs.yml`, delete the `armbian_publish_target:` option block.

- [ ] **Step 5: Update the README**

In `roles/image_build/README.md`, delete any paragraph or table row that references `armbian_publish_target` or "optional SCP publish". Point readers at `playbooks/build_image.yml` (which already does the publish via `ansible.posix.synchronize`).

- [ ] **Step 6: Verify no dangling references**

Run:
```bash
grep -rn 'publish_scp\|armbian_publish_target' roles/ playbooks/ inventory/ vars/
```
Expected: zero matches.

- [ ] **Step 7: Lint + syntax**

Run: `ansible-lint roles/image_build/`
Expected: PASS.

Run: `ansible-playbook --syntax-check -i inventory playbooks/build_image.yml`
Expected: parse-OK.

- [ ] **Step 8: Commit**

```bash
git add -A roles/image_build/
git commit -m "image_build: delete dead publish_scp.yml (publish lives in build_image.yml)"
```

## Task 16: Replace rootfs_clone shell cp with command argv

**Files:**
- Modify: `roles/rootfs_clone/tasks/main.yml`

- [ ] **Step 1: Find the shell task**

Run: `grep -n 'shell:\|cp -a' roles/rootfs_clone/tasks/main.yml`

- [ ] **Step 2: Replace with command + argv**

Replace the shell block with:

```yaml
- name: Reflink-clone template into target_dir
  ansible.builtin.command:
    argv:
      - cp
      - -a
      - --reflink=auto
      - "{{ template_dir }}/."
      - "{{ target_dir }}/"
  when: not _target_stat.stat.exists
  changed_when: true
```

- [ ] **Step 3: Lint**

Run: `ansible-lint roles/rootfs_clone/`
Expected: PASS (and the previous `risky-shell-pipe` finding, if any, is gone).

- [ ] **Step 4: Commit**

```bash
git add roles/rootfs_clone/tasks/main.yml
git commit -m "rootfs_clone: use command:argv for the reflink clone"
```

## Task 17: Replace rootfs_clone shell rm glob with find+file

**Files:**
- Modify: `roles/rootfs_clone/tasks/_identity_reset.yml`

- [ ] **Step 1: Find the rm task**

Run: `grep -n 'shell:\|ssh_host_\*' roles/rootfs_clone/tasks/_identity_reset.yml`

- [ ] **Step 2: Replace with find + file loop**

Replace the shell rm block with:

```yaml
- name: Find stale SSH host keys in clone
  ansible.builtin.find:
    paths: "{{ target_dir }}/etc/ssh"
    patterns: "ssh_host_*"
  register: __rootfs_clone_stale_keys

- name: Remove stale SSH host keys
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ __rootfs_clone_stale_keys.files }}"
  loop_control:
    label: "{{ item.path | basename }}"
```

- [ ] **Step 3: Lint**

Run: `ansible-lint roles/rootfs_clone/`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add roles/rootfs_clone/tasks/_identity_reset.yml
git commit -m "rootfs_clone: replace shell-rm-glob with find+file loop for stale ssh keys"
```

## Task 18: Switch bootstrap_armbian handler to systemd_service

**Files:**
- Modify: `roles/bootstrap_armbian/handlers/main.yml`

- [ ] **Step 1: Change module**

Replace `ansible.builtin.service:` with `ansible.builtin.systemd_service:` in the `Restart sshd` handler. Keep the other keys (`name: ssh`, `state: restarted`) unchanged.

- [ ] **Step 2: Lint**

Run: `ansible-lint roles/bootstrap_armbian/`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add roles/bootstrap_armbian/handlers/main.yml
git commit -m "bootstrap_armbian: use systemd_service for sshd restart handler"
```

## Task 19: Add ansible_managed header to pxelinux_cfg template

**Files:**
- Modify: `roles/pxelinux_render/templates/pxelinux_cfg.j2`

- [ ] **Step 1: Prepend the header**

Add this as the first line of the template (above the existing custom comments):

```jinja2
# {{ ansible_managed }}
```

- [ ] **Step 2: Verify a render**

Run (against the real inventory, dry-render only):
```bash
ansible-playbook -i $ANSIBLE_INVENTORY playbooks/converge_boot_mode.yml --check --diff --limit <one-board>
```
Expected: the diff for the rendered pxelinux.cfg shows the `# Ansible managed: …` line at top.

- [ ] **Step 3: Commit**

```bash
git add roles/pxelinux_render/templates/pxelinux_cfg.j2
git commit -m "pxelinux_render: add ansible_managed marker to template header"
```

## Task 20: FQCN audit in disk_image/_validate.yml

**Files:**
- Modify: `roles/disk_image/tasks/_validate.yml` (if any short-form module names found)

- [ ] **Step 1: Scan for non-FQCN built-ins**

Run:
```bash
grep -nE '^\s+(copy|file|template|command|shell|set_fact|assert|debug|stat|slurp|fail|find):' roles/disk_image/tasks/_validate.yml
```
Expected: zero matches (if non-zero, fix in Step 2).

- [ ] **Step 2: Convert each match to `ansible.builtin.<name>:`**

If Step 1 returned matches, prefix each with `ansible.builtin.`.

- [ ] **Step 3: Lint**

Run: `ansible-lint roles/disk_image/`
Expected: PASS, no `fqcn[action-core]` findings.

- [ ] **Step 4: Commit (only if file changed)**

```bash
git add roles/disk_image/tasks/_validate.yml
git commit -m "disk_image: standardise FQCN in _validate.yml"
```

## Task 21: Cut release 3.2.0

**Files:**
- Modify: `galaxy.yml`

- [ ] **Step 1: Verify acceptance criteria for this release**

Run:
```bash
ls roles/*/README.md | wc -l                                            # expect 9
grep -L 'license: MIT' roles/*/meta/main.yml                            # expect empty
grep -L 'galaxy_tags:' roles/*/meta/main.yml                            # expect empty
grep -rn 'changed_when: true' roles/*/tasks/                            # only legitimate cases
```

- [ ] **Step 2: Bump version**

In `galaxy.yml`: change `version: 3.1.1` to `version: 3.2.0`.

- [ ] **Step 3: Run the fleet e2e smoke**

Run: `ansible-playbook -i $ANSIBLE_INVENTORY playbooks/test_fleet_e2e.yml`
Expected: 5/5 PASS Summary table.

- [ ] **Step 4: Commit + tag**

```bash
git add galaxy.yml
git commit -m "release: 3.2.0 (docs + idempotency + style)"
git tag v3.2.0
```

Do NOT push the tag automatically. Confirm with the user first.

---

# Release 4.0.0 — variable prefix rename

## Task 22: Rename pxelinux_render external variables (breaking)

**Files:**
- Modify: `roles/pxelinux_render/defaults/main.yml`
- Modify: `roles/pxelinux_render/meta/argument_specs.yml`
- Modify: `roles/pxelinux_render/templates/pxelinux_cfg.j2`
- Modify: `roles/pxelinux_render/tasks/main.yml`
- Modify: `roles/pxelinux_render/README.md`
- Modify: every caller listed below.

- [ ] **Step 1: Inventory all callers**

Run:
```bash
grep -rEn '\b(sd_root|local_root|pxe_verbose|tftp_kernel|tftp_initrd|tftp_dtb|earlycon|boot_mode|extra_modes|hostname|model_name|board_mac|nfs_server_ip|nfs_root_path|output_dir)\b' \
  roles/pxelinux_render/ playbooks/ inventory/
```
This is the rename surface. Capture the output to a file (`/tmp/pxelinux_render-rename-callers.txt`) so you can audit it after the change.

Caveat: some of these names (`boot_mode`, `hostname`, etc.) are also Ansible facts. The grep will over-report. The actual scope of variables to rename are *inputs declared in `roles/pxelinux_render/meta/argument_specs.yml` and `roles/pxelinux_render/defaults/main.yml`* — use that file as the canonical list.

- [ ] **Step 2: Apply the rename in defaults/main.yml**

For each variable in the spec's WS-6.1 table (old → new), rename in `roles/pxelinux_render/defaults/main.yml`.

- [ ] **Step 3: Apply the rename in meta/argument_specs.yml**

Same rename, applied to every `options:` key under `main:`.

- [ ] **Step 4: Apply the rename in the template**

In `roles/pxelinux_render/templates/pxelinux_cfg.j2`, every Jinja reference to one of the renamed vars becomes the prefixed form (`{{ pxelinux_render_<name> }}`).

- [ ] **Step 5: Apply the rename in tasks/main.yml**

Same renames for any `when:`, `set_fact:`, or assertion that references the old names.

- [ ] **Step 6: Apply the rename in every caller**

For each caller surfaced in Step 1 that actually passes one of these as a role variable (i.e. inside an `include_role: vars:` or `import_role: vars:` block, or via a top-level `vars:` for a play), apply the rename.

- [ ] **Step 7: Update the role README**

In `roles/pxelinux_render/README.md`, update the Inputs table to use the new names.

- [ ] **Step 8: Syntax-check every touched playbook**

For every playbook in Step 1's grep output, run:

```bash
ansible-playbook --syntax-check -i inventory <playbook>
```

Expected: parse-OK for all.

- [ ] **Step 9: Lint**

Run: `ansible-lint roles/pxelinux_render/ playbooks/`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add roles/pxelinux_render/ playbooks/
git commit -m "pxelinux_render: rename all role variables to pxelinux_render_* prefix"
```

## Task 23: Rename internal facts to __<role>_* prefix

**Files:**
- Modify: each role's tasks (per the WS-6.2 table in the spec).

- [ ] **Step 1: For each role, identify the existing internal facts**

```bash
for r in image_build image_extract disk_image disk_provision pxelinux_render rootfs_clone; do
  echo "=== $r ==="
  grep -nE 'set_fact:|register:' roles/$r/tasks/*.yml roles/$r/tasks/**/*.yml 2>/dev/null
done
```

- [ ] **Step 2: For each role, apply the WS-6.2 renames**

Use sed for batches, e.g.:

```bash
# image_build
find roles/image_build/tasks -type f -name '*.yml' -print0 | xargs -0 \
  sed -i \
    -e 's/\b_patch_hash\b/__image_build_patch_hash/g' \
    -e 's/\b_manifest_inputs\b/__image_build_manifest_inputs/g' \
    -e 's/\b_skip_build\b/__image_build_skip_build/g'
```

Repeat per role per the WS-6.2 table. Be careful with `_dp_*` → `__disk_provision_*`: do **not** match `_dp_` if it appears in a non-fact context. Inspect each match before committing.

- [ ] **Step 3: Lint everything**

Run: `ansible-lint roles/`
Expected: PASS.

- [ ] **Step 4: Run a dry e2e**

Run: `ansible-playbook --syntax-check -i inventory playbooks/test_fleet_e2e.yml`
Expected: parse-OK (this won't catch every fact misuse, but catches typos).

- [ ] **Step 5: Commit (one role per commit for reviewability)**

```bash
git add roles/image_build/
git commit -m "image_build: rename internal facts to __image_build_* prefix"

# ... repeat per role
```

## Task 24: Cut release 4.0.0

**Files:**
- Modify: `galaxy.yml`
- Create: `docs/migration-3.x-to-4.0.md`

- [ ] **Step 1: Write the migration guide**

Create `docs/migration-3.x-to-4.0.md` with:

- One paragraph framing the rename and why it happened (link to this plan).
- A table mapping every old → new variable name (copy from spec WS-6.1).
- A `git grep` recipe for finding callers.
- A note that internal-fact renames don't affect callers.

- [ ] **Step 2: Bump version**

In `galaxy.yml`: change `version: 3.2.0` to `version: 4.0.0`.

- [ ] **Step 3: Run the fleet e2e smoke**

Run: `ansible-playbook -i $ANSIBLE_INVENTORY playbooks/test_fleet_e2e.yml`
Expected: 5/5 PASS Summary table.

- [ ] **Step 4: Commit + tag**

```bash
git add galaxy.yml docs/migration-3.x-to-4.0.md
git commit -m "release: 4.0.0 (pxelinux_render variable rename)"
git tag v4.0.0
```

Do NOT push the tag automatically. Confirm with the user.

---

# Release-independent

## Task 25: Add molecule scenario for pxelinux_render

**Files:**
- Create: `roles/pxelinux_render/molecule/default/molecule.yml`
- Create: `roles/pxelinux_render/molecule/default/converge.yml`
- Create: `roles/pxelinux_render/molecule/default/fixtures/expected/01-aa-bb-cc-dd-ee-01.cfg`
- Create: `roles/pxelinux_render/molecule/default/verify.yml`

- [ ] **Step 1: Scenario plumbing**

Write `molecule.yml`:

```yaml
---
dependency:
  name: galaxy
driver:
  name: default
platforms:
  - name: instance
    image: python:3.12-slim
    pre_build_image: true
provisioner:
  name: ansible
verifier:
  name: ansible
```

- [ ] **Step 2: Converge — render two fixture boards**

Write `converge.yml`:

```yaml
---
- name: Render pxelinux.cfg for fixture boards
  hosts: instance
  gather_facts: false
  tasks:
    - name: Render board 1
      ansible.builtin.include_role:
        name: pxelinux_render
      vars:
        pxelinux_render_hostname: "fixture-board-01"
        pxelinux_render_model_name: "fixture-model"
        pxelinux_render_board_mac: "aa:bb:cc:dd:ee:01"
        pxelinux_render_boot_mode: "nfs"
        pxelinux_render_nfs_server_ip: "10.0.0.1"
        pxelinux_render_nfs_root_path: "/mnt/ssd/netboot/rootfs/fixture-board-01"
        pxelinux_render_output_dir: "/tmp/pxelinux-cfg"
```

- [ ] **Step 3: Fixture expected file**

Generate the expected file by running the converge once and capturing the output, then commit it as the golden fixture.

- [ ] **Step 4: Verify — diff against golden**

Write `verify.yml`:

```yaml
---
- name: Diff rendered config against golden fixture
  hosts: instance
  gather_facts: false
  tasks:
    - name: Slurp rendered file
      ansible.builtin.slurp:
        src: "/tmp/pxelinux-cfg/01-aa-bb-cc-dd-ee-01"
      register: rendered
    - name: Slurp golden fixture
      ansible.builtin.slurp:
        src: "fixtures/expected/01-aa-bb-cc-dd-ee-01.cfg"
      register: golden
    - name: Assert match
      ansible.builtin.assert:
        that:
          - rendered.content == golden.content
```

- [ ] **Step 5: Run the scenario**

Run: `cd roles/pxelinux_render && molecule test`
Expected: green run.

- [ ] **Step 6: Commit**

```bash
git add roles/pxelinux_render/molecule/
git commit -m "pxelinux_render: add molecule golden-file scenario"
```

## Task 26: Add molecule scenario for disk_provision

**Files:**
- Create: `roles/disk_provision/molecule/default/molecule.yml`
- Create: `roles/disk_provision/molecule/default/converge.yml`
- Create: `roles/disk_provision/molecule/default/verify.yml`

- [ ] **Step 1: Scenario plumbing**

Write `molecule.yml`:

```yaml
---
dependency:
  name: galaxy
driver:
  name: default
platforms:
  - name: instance
    image: quay.io/ansible/molecule-systemd:latest
    privileged: true
    pre_build_image: true
provisioner:
  name: ansible
verifier:
  name: ansible
```

- [ ] **Step 2: Converge — sparse loop file + role run**

Write `converge.yml` to create a 256 MiB sparse file, attach a loop device, and run `disk_provision` against it with a 2-partition `disk_binding` (esp + root).

- [ ] **Step 3: Verify — assert partition table + fstab**

Write `verify.yml` to:
- Run `sgdisk -p` on the loop device and assert two partitions exist with the expected labels.
- Slurp the rendered `/etc/fstab` and assert it contains LABEL=ESP and LABEL=ROOT entries.

- [ ] **Step 4: Run the scenario**

Run: `cd roles/disk_provision && molecule test`
Expected: green run.

- [ ] **Step 5: Commit**

```bash
git add roles/disk_provision/molecule/
git commit -m "disk_provision: add molecule loop-file scenario"
```

---

## Self-review checklist

After execution, re-run these to confirm the spec's acceptance criteria are met:

```bash
# 1. No plaintext credentials in tracked files
grep -rn '1234' inventory/ roles/ | grep -v '^Binary'

# 2. All roles have argument_specs
ls roles/*/meta/argument_specs.yml | wc -l   # expect 9

# 3. All roles have README
ls roles/*/README.md | wc -l                  # expect 9

# 4. All role licenses align
grep -L 'license: MIT' roles/*/meta/main.yml  # expect empty

# 5. No FQCN regressions
ansible-lint roles/                            # expect PASS

# 6. (4.0.0 only) Old pxelinux_render names gone
grep -rEn '\b(sd_root|local_root|pxe_verbose|tftp_kernel|tftp_initrd|tftp_dtb)\b' roles/pxelinux_render/ playbooks/
# expect: zero matches outside docs/migration-3.x-to-4.0.md

# 7. Fleet e2e green
ansible-playbook -i $ANSIBLE_INVENTORY playbooks/test_fleet_e2e.yml
# expect: 5/5 PASS Summary table
```

---

## Non-goals (recap from spec)

- Replacing `image_extract`'s loop-device approach.
- Adding cross-role integration tests beyond `test_fleet_e2e.yml`.
- Migrating away from RouterOS as the reference transport.
- Adding custom Ansible modules.
