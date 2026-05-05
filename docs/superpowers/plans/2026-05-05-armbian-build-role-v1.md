# armbian_build role v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `armbian_build` role + `playbooks/build_image.yml` so a custom Armbian image with PXE-first `BOOT_TARGETS` can be produced for `orangepi5pro` and consumed by the existing `nfs_content` / `reprovision` workflows via the `armbian_image_urls` indirection.

**Architecture:** A single-purpose role generates `.img.xz` + `manifest.json` in an output directory on a builder host given a board, branch, release, and a list of userpatches. The role is intent-agnostic — PXE-first specifics live as data in `playbooks/build_image.yml`, not inside the role. A second play in the same playbook publishes the artifact directly from the builder to the netboot server's HTTP export via `synchronize` (mode pull, delegated to the builder).

**Tech Stack:** Ansible (collection-style role; FQCN modules), `armbian/build` (Docker mode), `ansible.posix.synchronize` for transfer.

**Spec:** [`docs/superpowers/specs/2026-05-05-armbian-build-role-v1-design.md`](../specs/2026-05-05-armbian-build-role-v1-design.md)

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `roles/armbian_build/README.md` | Role contract: inputs, outputs, preflight assumptions, idempotency model |
| `roles/armbian_build/defaults/main.yml` | Default values for every role variable |
| `roles/armbian_build/meta/main.yml` | Galaxy metadata, min Ansible version |
| `roles/armbian_build/tasks/main.yml` | Glue file — imports the per-phase task files in order |
| `roles/armbian_build/tasks/preflight.yml` | Validate docker, privileged container support, free space, egress |
| `roles/armbian_build/tasks/manage_checkout.yml` | Ensure cache + output dirs; clone/fetch `armbian/build` at the pinned ref |
| `roles/armbian_build/tasks/apply_userpatches.yml` | Write `{dest, content}` entries into `<userpatches_dir>/<dest>` after path-escape assertion |
| `roles/armbian_build/tasks/compute_inputs.yml` | Compute `_patch_hash` and assemble `_manifest_inputs` fact |
| `roles/armbian_build/tasks/check_manifest.yml` | Read any existing `manifest.json` and set `_skip_build` |
| `roles/armbian_build/tasks/invoke_build.yml` | Run `compile.sh docker`, locate produced artifact, move to per-board output dir |
| `roles/armbian_build/tasks/write_manifest.yml` | Write final `manifest.json` atomically next to the produced image |
| `playbooks/build_image.yml` | Two-play composition: build per opted-in board, then publish artifacts to netboot server |

**Modified:**

| Path | Change |
|---|---|
| `inventory/hosts.yml` | Add `armbian_builders` example group with one builder host |
| `inventory/group_vars/all.yml` | Add commented `armbian_image_urls` example for the local-override pattern |

**Out of scope for this plan (deferred to follow-up issues):** WIP banner removal in `README.md` / `CLAUDE.md` / `docs/architecture.md`. That step depends on a successful end-to-end run on real hardware; it's the operator's confirmation step, not part of role implementation.

---

## Validation approach

This collection has no Molecule scaffold. Per-task validation is:

- **`yamllint <file>`** after each file is written.
- **`ansible-lint --profile=production roles/armbian_build/`** after the role is complete.
- **`ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check`** after the playbook is complete (uses the documentation inventory; sample data is enough for syntax-check).

The end-to-end functional run against real hardware is **not** automated — it's the operator's acceptance step at the end of this plan.

Run `echo $ANSIBLE_INVENTORY` at the start of the implementation session — it should point at `.inventory/`. Do not modify `.inventory/` for this work; all inventory edits land in the documentation `inventory/`.

---

## Task 1: Role skeleton (defaults, meta, README)

**Files:**
- Create: `roles/armbian_build/README.md`
- Create: `roles/armbian_build/defaults/main.yml`
- Create: `roles/armbian_build/meta/main.yml`

- [ ] **Step 1: Write `roles/armbian_build/defaults/main.yml`**

```yaml
---
# armbian/build pinning. Upstream uses a vX.Y.Z-trunk.NNN release scheme;
# pin to a specific trunk release for reproducibility. Bumping the ref is
# a deliberate role-level change.
armbian_build_ref: "v26.2.0-trunk.844"

# Filesystem layout on the builder host
armbian_build_cache_dir: "/var/lib/armbian_build"            # armbian/build checkout + cache + userpatches
armbian_build_output_dir: "/var/lib/armbian_build/output"    # final .img.xz + manifest.json land here

# Per-build inputs. Caller sets board; branch/release defaulted to a
# CLI-friendly modern Armbian Rockchip image.
armbian_build_board: ""
armbian_build_branch: "current"
armbian_build_release: "bookworm"

# Userpatches to apply before the build. Each entry is { dest, content }
# where `dest` is a path relative to USERPATCHES_DIR (no leading slash,
# no `..`). Empty by default — the caller decides what patches (if any)
# to apply. The role is fully agnostic to what the patches do.
armbian_build_userpatches: []

# Preflight thresholds and egress check list
armbian_build_min_free_gb: 50
armbian_build_required_egress_hosts:
  - github.com
  - apt.armbian.com
  - ghcr.io

# compile.sh argument knobs. Overridable per-run, NOT folded into
# patch_hash — manifest fields like `branch` and `release` cover the
# rebuild-decision dimensions; these are operator-tunable diagnostics.
armbian_build_compile_args:
  KERNEL_CONFIGURE: "no"
  BUILD_DESKTOP: "no"
  BUILD_MINIMAL: "yes"
  COMPRESS_OUTPUTIMAGE: "sha,xz"
  EXPERT: "yes"

# Build timeout in seconds. 2h covers cold-cache full builds.
armbian_build_timeout: 7200

# Set true via -e to bypass manifest-match skip and force a rebuild.
armbian_build_force: false
```

- [ ] **Step 2: Write `roles/armbian_build/meta/main.yml`**

```yaml
---
galaxy_info:
  role_name: armbian_build
  author: David Igou
  description: Build a custom Armbian image with caller-supplied userpatches via armbian/build (Docker mode)
  license: GPL-3.0-or-later
  min_ansible_version: "2.15"
  platforms:
    - name: Debian
      versions:
        - bookworm
    - name: Ubuntu
      versions:
        - jammy
        - noble

  galaxy_tags:
    - armbian
    - build
    - image

dependencies: []
```

- [ ] **Step 3: Write `roles/armbian_build/README.md`**

```markdown
# armbian_build

Build a custom Armbian image with caller-supplied userpatches, using
[`armbian/build`](https://github.com/armbian/build) in Docker mode. The
role is single-purpose and intent-agnostic: it does not know (nor care)
what your userpatches do — callers (typically a workflow playbook) supply
the patch list and consume the resulting `.img.xz` + `manifest.json` from
`armbian_build_output_dir/<board>/`.

## Inputs

| Var | Default | Purpose |
|---|---|---|
| `armbian_build_board` | _required_ | Armbian board name, e.g. `orangepi5pro` |
| `armbian_build_branch` | `current` | Armbian kernel/U-Boot branch |
| `armbian_build_release` | `bookworm` | Userspace release |
| `armbian_build_ref` | `v26.2.0-trunk.844` | Pinned `armbian/build` git ref |
| `armbian_build_userpatches` | `[]` | List of `{ dest, content }` entries |
| `armbian_build_cache_dir` | `/var/lib/armbian_build` | Checkout + cache + userpatches root |
| `armbian_build_output_dir` | `/var/lib/armbian_build/output` | Where `<board>/<file>.img.xz` + `manifest.json` land |
| `armbian_build_min_free_gb` | `50` | Preflight threshold |
| `armbian_build_required_egress_hosts` | github.com, apt.armbian.com, ghcr.io | Preflight HEAD-checks |
| `armbian_build_compile_args` | _see defaults_ | Per-run knobs forwarded to `compile.sh` |
| `armbian_build_timeout` | `7200` | Build timeout in seconds |
| `armbian_build_force` | `false` | Force rebuild even if manifest matches |

## Outputs

`<armbian_build_output_dir>/<board>/`:
- `Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz`
- `Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz.sha` (when `COMPRESS_OUTPUTIMAGE` includes `sha`)
- `manifest.json`

## Manifest schema

```json
{
  "patch_hash": "sha256:…",
  "armbian_build_ref": "v26.2.0-trunk.844",
  "board": "orangepi5pro",
  "branch": "current",
  "release": "bookworm",
  "image_filename": "Armbian_…img.xz",
  "built_at": "2026-05-05T12:34:56Z"
}
```

## Idempotency

The role skips the build (and the manifest write) when an existing
`manifest.json` matches all five decision fields: `patch_hash`,
`armbian_build_ref`, `board`, `branch`, `release`. `patch_hash` is
`sha256` of the canonical-JSON-encoded `armbian_build_userpatches`. Pass
`-e armbian_build_force=true` to override.

## Preflight assumptions

The role does not install Docker or modify the host beyond its own
`armbian_build_cache_dir` and `armbian_build_output_dir`. Preflight
hard-fails if any prerequisite is missing.

- Docker ≥17.06 is installed and runnable by the connecting user.
- Privileged containers work (`docker run --privileged hello-world`).
- Free space at `armbian_build_cache_dir` ≥ `armbian_build_min_free_gb` GB.
- `armbian_build_required_egress_hosts` are HTTPS-reachable.

## Example

```yaml
- ansible.builtin.include_role:
    name: armbian_build
  vars:
    armbian_build_board: orangepi5pro
    armbian_build_userpatches:
      - dest: "config/boards/orangepi5pro.conf"
        content: |
          function pre_config_uboot_target__orangepi5pro_pxe_first() {
              declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
              sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                  include/configs/rockchip-common.h
          }
```
```

- [ ] **Step 4: Lint the new files**

Run: `yamllint roles/armbian_build/defaults/main.yml roles/armbian_build/meta/main.yml`
Expected: no output (clean)

- [ ] **Step 5: Commit**

```bash
git add roles/armbian_build/README.md roles/armbian_build/defaults/main.yml roles/armbian_build/meta/main.yml
git commit -m "Add armbian_build role skeleton (defaults, meta, README)"
```

---

## Task 2: Preflight task file

**Files:**
- Create: `roles/armbian_build/tasks/preflight.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/preflight.yml`**

```yaml
---
# Preflight: validate Docker, privileged container support, disk space,
# and egress reachability before any expensive operation. All failures
# are hard fails with operator-actionable messages.

- name: Gather mount facts (free-space check)
  ansible.builtin.setup:
    filter: ansible_mounts
    gather_subset:
      - "!all"
      - "!min"
      - mounts

- name: Check docker is installed
  ansible.builtin.command: docker --version
  changed_when: false
  register: _docker_version
  failed_when: _docker_version.rc != 0

- name: Verify privileged container support
  ansible.builtin.command: docker run --rm --privileged hello-world
  changed_when: false
  register: _docker_privileged
  failed_when: _docker_privileged.rc != 0

- name: Resolve free space at armbian_build_cache_dir
  ansible.builtin.set_fact:
    _cache_mount: >-
      {{ ansible_mounts
         | sort(attribute='mount', reverse=true)
         | selectattr('mount', 'in', armbian_build_cache_dir + '/')
         | list | first }}

- name: Assert sufficient free space at the cache dir
  ansible.builtin.assert:
    that:
      - _cache_mount is defined
      - (_cache_mount.size_available | int) >= (armbian_build_min_free_gb | int * 1024 * 1024 * 1024)
    fail_msg: >-
      Insufficient free space at {{ armbian_build_cache_dir }}
      ({{ (_cache_mount.size_available | int / 1024 / 1024 / 1024) | round(1) }} GB available,
       {{ armbian_build_min_free_gb }} GB required)

- name: HEAD-check required egress hosts
  ansible.builtin.uri:
    url: "https://{{ item }}"
    method: HEAD
    status_code: [200, 301, 302, 405]
    timeout: 10
  loop: "{{ armbian_build_required_egress_hosts }}"
  loop_control:
    label: "{{ item }}"
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/preflight.yml`
Expected: no output (clean)

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/preflight.yml
git commit -m "Add armbian_build preflight: docker, disk, egress checks"
```

---

## Task 3: Checkout management

**Files:**
- Create: `roles/armbian_build/tasks/manage_checkout.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/manage_checkout.yml`**

```yaml
---
# Ensure the cache, userpatches, and output directories exist; clone or
# update armbian/build to the pinned ref. The build cache (cache/,
# output/ inside the checkout) survives across runs so kernel build
# artifacts can be reused for incremental builds.

- name: Ensure cache, userpatches, and output directories exist
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - "{{ armbian_build_cache_dir }}"
    - "{{ armbian_build_cache_dir }}/userpatches"
    - "{{ armbian_build_output_dir }}"

- name: Clone or update armbian/build at the pinned ref
  ansible.builtin.git:
    repo: https://github.com/armbian/build.git
    dest: "{{ armbian_build_cache_dir }}/build"
    version: "{{ armbian_build_ref }}"
    force: false                   # preserve untracked files (cache/, output/)
    update: true
    depth: 1                       # shallow; we only need the pinned ref's tree
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/manage_checkout.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/manage_checkout.yml
git commit -m "Add armbian_build checkout management"
```

---

## Task 4: Apply userpatches

**Files:**
- Create: `roles/armbian_build/tasks/apply_userpatches.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/apply_userpatches.yml`**

```yaml
---
# Drop each { dest, content } entry into <armbian_build_cache_dir>/userpatches/<dest>.
# Asserts that no `dest` contains `..` or starts with `/` to prevent path
# escape (we do not want a hostile or buggy caller to write outside the
# userpatches tree).

- name: Assert userpatches dest paths are safe
  ansible.builtin.assert:
    that:
      - "'..' not in item.dest"
      - not item.dest.startswith('/')
    fail_msg: "Unsafe userpatches dest (must be relative and not contain '..'): {{ item.dest }}"
  loop: "{{ armbian_build_userpatches }}"
  loop_control:
    label: "{{ item.dest }}"

- name: Ensure parent directories for userpatches files exist
  ansible.builtin.file:
    path: "{{ (armbian_build_cache_dir + '/userpatches/' + item.dest) | dirname }}"
    state: directory
    mode: "0755"
  loop: "{{ armbian_build_userpatches }}"
  loop_control:
    label: "{{ item.dest }}"

- name: Write userpatches files
  ansible.builtin.copy:
    dest: "{{ armbian_build_cache_dir }}/userpatches/{{ item.dest }}"
    content: "{{ item.content }}"
    mode: "0644"
  loop: "{{ armbian_build_userpatches }}"
  loop_control:
    label: "{{ item.dest }}"
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/apply_userpatches.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/apply_userpatches.yml
git commit -m "Add armbian_build userpatches application with path-escape guard"
```

---

## Task 5: Compute inputs (patch_hash, manifest fact)

**Files:**
- Create: `roles/armbian_build/tasks/compute_inputs.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/compute_inputs.yml`**

```yaml
---
# Compute the inputs that drive the rebuild decision and seed the
# eventual manifest. patch_hash is sha256 of the canonical-JSON-encoded
# armbian_build_userpatches list — pure function of what the caller
# passed in.
#
# The five decision fields (patch_hash, armbian_build_ref, board,
# branch, release) are exactly what check_manifest.yml will compare.

- name: Compute patch_hash from userpatches
  ansible.builtin.set_fact:
    _patch_hash: "sha256:{{ armbian_build_userpatches | to_json(sort_keys=true) | hash('sha256') }}"

- name: Assemble manifest decision-fields fact
  ansible.builtin.set_fact:
    _manifest_inputs:
      patch_hash: "{{ _patch_hash }}"
      armbian_build_ref: "{{ armbian_build_ref }}"
      board: "{{ armbian_build_board }}"
      branch: "{{ armbian_build_branch }}"
      release: "{{ armbian_build_release }}"
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/compute_inputs.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/compute_inputs.yml
git commit -m "Add armbian_build patch_hash and manifest-inputs computation"
```

---

## Task 6: Check manifest (skip-build decision)

**Files:**
- Create: `roles/armbian_build/tasks/check_manifest.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/check_manifest.yml`**

```yaml
---
# Read any existing per-board manifest and decide whether a rebuild is
# needed. _skip_build is true only when ALL five decision fields match.
# Anything else (file missing, parse error, partial match,
# armbian_build_force) → rebuild.

- name: Compute per-board manifest path
  ansible.builtin.set_fact:
    _manifest_path: "{{ armbian_build_output_dir }}/{{ armbian_build_board }}/manifest.json"

- name: Stat existing manifest
  ansible.builtin.stat:
    path: "{{ _manifest_path }}"
  register: _manifest_stat

- name: Default to no existing manifest
  ansible.builtin.set_fact:
    _existing_manifest: {}

- name: Read and parse existing manifest if present
  block:
    - name: Slurp existing manifest
      ansible.builtin.slurp:
        src: "{{ _manifest_path }}"
      register: _manifest_raw
      when: _manifest_stat.stat.exists

    - name: Parse manifest JSON
      ansible.builtin.set_fact:
        _existing_manifest: "{{ _manifest_raw.content | b64decode | from_json }}"
      when: _manifest_stat.stat.exists
  rescue:
    - name: Note manifest unparseable — will rebuild
      ansible.builtin.debug:
        msg: "Existing manifest at {{ _manifest_path }} is unparseable; treating as missing"
    - name: Reset to empty manifest
      ansible.builtin.set_fact:
        _existing_manifest: {}

- name: Decide whether to skip the build
  ansible.builtin.set_fact:
    _skip_build: >-
      {{ (not (armbian_build_force | bool))
         and (_existing_manifest.patch_hash | default('') == _manifest_inputs.patch_hash)
         and (_existing_manifest.armbian_build_ref | default('') == _manifest_inputs.armbian_build_ref)
         and (_existing_manifest.board | default('') == _manifest_inputs.board)
         and (_existing_manifest.branch | default('') == _manifest_inputs.branch)
         and (_existing_manifest.release | default('') == _manifest_inputs.release) }}

- name: Report skip-build decision
  ansible.builtin.debug:
    msg: >-
      armbian_build for {{ armbian_build_board }}:
      {{ 'skipping (manifest matches)' if _skip_build else 'will build (manifest mismatch or forced)' }}
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/check_manifest.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/check_manifest.yml
git commit -m "Add armbian_build manifest-based skip-build decision"
```

---

## Task 7: Invoke build

**Files:**
- Create: `roles/armbian_build/tasks/invoke_build.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/invoke_build.yml`**

```yaml
---
# Run armbian/build's compile.sh in Docker mode, locate the produced
# .img.xz (kernel version is unknown ahead of time, so glob+age-filter),
# and move both the image and its .sha sidecar into the per-board output
# directory. Async/poll keeps long builds from tying up the SSH session.

- name: Build Armbian image with userpatches applied
  ansible.builtin.command:
    cmd: >-
      ./compile.sh docker
      BOARD={{ armbian_build_board }}
      BRANCH={{ armbian_build_branch }}
      RELEASE={{ armbian_build_release }}
      USERPATCHES_DIR={{ armbian_build_cache_dir }}/userpatches
      {% for k, v in armbian_build_compile_args.items() %}{{ k }}={{ v }} {% endfor %}
    chdir: "{{ armbian_build_cache_dir }}/build"
  async: "{{ armbian_build_timeout }}"
  poll: 30
  changed_when: true

- name: Locate the produced .img.xz from this run
  ansible.builtin.find:
    paths: "{{ armbian_build_cache_dir }}/build/output/images"
    patterns: "Armbian_*_{{ armbian_build_board }}_{{ armbian_build_release }}_{{ armbian_build_branch }}_*.img.xz"
    age: -10m
  register: _produced_images

- name: Assert exactly one image was produced
  ansible.builtin.assert:
    that: _produced_images.files | length == 1
    fail_msg: >-
      Expected exactly one .img.xz produced for
      {{ armbian_build_board }}/{{ armbian_build_release }}/{{ armbian_build_branch }},
      found {{ _produced_images.files | length }}

- name: Set produced image filename
  ansible.builtin.set_fact:
    _image_filename: "{{ _produced_images.files[0].path | basename }}"

- name: Ensure per-board output directory exists
  ansible.builtin.file:
    path: "{{ armbian_build_output_dir }}/{{ armbian_build_board }}"
    state: directory
    mode: "0755"

- name: Move produced image into the per-board output directory
  ansible.builtin.command:
    cmd: >-
      mv {{ _produced_images.files[0].path }}
         {{ armbian_build_output_dir }}/{{ armbian_build_board }}/{{ _image_filename }}
  changed_when: true

- name: Stat the .sha sidecar (may not exist depending on COMPRESS_OUTPUTIMAGE)
  ansible.builtin.stat:
    path: "{{ _produced_images.files[0].path }}.sha"
  register: _sha_stat

- name: Move the .sha sidecar if present
  ansible.builtin.command:
    cmd: >-
      mv {{ _produced_images.files[0].path }}.sha
         {{ armbian_build_output_dir }}/{{ armbian_build_board }}/{{ _image_filename }}.sha
  changed_when: true
  when: _sha_stat.stat.exists
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/invoke_build.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/invoke_build.yml
git commit -m "Add armbian_build compile.sh invocation and artifact relocation"
```

---

## Task 8: Write manifest

**Files:**
- Create: `roles/armbian_build/tasks/write_manifest.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/write_manifest.yml`**

```yaml
---
# Write manifest.json next to the produced image. Atomically (temp file →
# rename) so concurrent readers either see the old manifest or a complete
# new one. Includes the five decision fields (used by check_manifest on
# subsequent runs) plus image_filename and built_at for debuggability.

- name: Capture build timestamp (UTC, ISO 8601)
  ansible.builtin.set_fact:
    _built_at: "{{ '%Y-%m-%dT%H:%M:%SZ' | strftime(ansible_date_time.epoch | default(lookup('pipe', 'date -u +%s'))) }}"

- name: Assemble final manifest
  ansible.builtin.set_fact:
    _manifest:
      patch_hash: "{{ _manifest_inputs.patch_hash }}"
      armbian_build_ref: "{{ _manifest_inputs.armbian_build_ref }}"
      board: "{{ _manifest_inputs.board }}"
      branch: "{{ _manifest_inputs.branch }}"
      release: "{{ _manifest_inputs.release }}"
      image_filename: "{{ _image_filename }}"
      built_at: "{{ _built_at }}"

- name: Write manifest.json atomically
  ansible.builtin.copy:
    dest: "{{ armbian_build_output_dir }}/{{ armbian_build_board }}/manifest.json"
    content: "{{ _manifest | to_nice_json(sort_keys=true) }}\n"
    mode: "0644"
```

- [ ] **Step 2: Lint**

Run: `yamllint roles/armbian_build/tasks/write_manifest.yml`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/write_manifest.yml
git commit -m "Add armbian_build manifest write"
```

---

## Task 9: Wire `tasks/main.yml`

**Files:**
- Create: `roles/armbian_build/tasks/main.yml`

- [ ] **Step 1: Write `roles/armbian_build/tasks/main.yml`**

```yaml
---
# Build a custom Armbian image with the supplied userpatches.
#
# Single-purpose, intent-agnostic role. The caller (typically a workflow
# playbook) supplies the board, branch, release, and userpatches list;
# this role enforces the desired output state under
# armbian_build_output_dir/<board>/.

- name: Validate required inputs
  ansible.builtin.assert:
    that:
      - armbian_build_board | length > 0
    fail_msg: "armbian_build_board is required"

- name: Preflight (docker, disk, egress)
  ansible.builtin.include_tasks: preflight.yml

- name: Manage armbian/build checkout
  ansible.builtin.include_tasks: manage_checkout.yml

- name: Apply userpatches
  ansible.builtin.include_tasks: apply_userpatches.yml

- name: Compute build inputs (patch_hash, manifest fact)
  ansible.builtin.include_tasks: compute_inputs.yml

- name: Check existing manifest for skip-build decision
  ansible.builtin.include_tasks: check_manifest.yml

- name: Invoke armbian/build (skipped when manifest matches)
  ansible.builtin.include_tasks: invoke_build.yml
  when: not (_skip_build | bool)

- name: Write manifest
  ansible.builtin.include_tasks: write_manifest.yml
  when: not (_skip_build | bool)
```

- [ ] **Step 2: Lint the role as a whole**

Run: `yamllint roles/armbian_build/`
Expected: no output

Run: `ansible-lint --profile=production roles/armbian_build/`
Expected: no output (clean)

If `ansible-lint` flags issues (most likely fully-qualified-collection-name reminders, idempotency hints on the `command:` modules in `invoke_build.yml`), address each — `command:` calls already have `changed_when: true` set deliberately because the build is genuinely a state change.

- [ ] **Step 3: Commit**

```bash
git add roles/armbian_build/tasks/main.yml
git commit -m "Wire armbian_build tasks/main.yml orchestrator"
```

---

## Task 10: `playbooks/build_image.yml`

**Files:**
- Create: `playbooks/build_image.yml`

- [ ] **Step 1: Write `playbooks/build_image.yml`**

```yaml
---
# Builds custom Armbian images for boards opted in via
# host_board_overrides.armbian_build_enabled, then publishes the
# resulting artifact directories to the netboot server's HTTP export.
#
# Two plays:
#   1. hosts: armbian_builders — invoke the armbian_build role per
#      unique opted-in board.
#   2. hosts: netboot_server — synchronize each <board>/ directory
#      from the builder into nfs_assets_export/images/<board>/.
#
# The PXE-first userpatches table is playbook data, not role data —
# the armbian_build role itself is intent-agnostic. Add a new board by
# extending build_userpatches with another entry and setting
# host_board_overrides.armbian_build_enabled: true on its hosts.
#
# Usage:
#   ansible-playbook playbooks/build_image.yml

- name: Build custom Armbian images on the builder host
  hosts: armbian_builders
  gather_facts: false
  vars:
    build_userpatches:
      orangepi5pro:
        - dest: "config/boards/orangepi5pro.conf"
          content: |
            function pre_config_uboot_target__orangepi5pro_pxe_first() {
                declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                    include/configs/rockchip-common.h
            }
  pre_tasks:
    - name: Resolve build targets from opted-in hosts
      ansible.builtin.set_fact:
        _build_targets: >-
          {{ groups['boards']
             | map('extract', hostvars)
             | selectattr('host_board_overrides.armbian_build_enabled', 'defined')
             | selectattr('host_board_overrides.armbian_build_enabled')
             | map(attribute='_board.armbian_board_name')
             | unique | list }}

    - name: Report build targets
      ansible.builtin.debug:
        msg: "Will build images for: {{ _build_targets }}"

  tasks:
    - name: Build image per opted-in board
      ansible.builtin.include_role:
        name: armbian_build
      vars:
        armbian_build_board: "{{ item }}"
        armbian_build_userpatches: "{{ build_userpatches[item] }}"
      loop: "{{ _build_targets }}"

- name: Publish images to the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  vars:
    _builder: "{{ groups['armbian_builders'][0] }}"
  tasks:
    - name: Ensure per-board image directory exists
      ansible.builtin.file:
        path: "{{ nfs_assets_export }}/images/{{ item }}"
        state: directory
        mode: "0755"
      loop: "{{ hostvars[_builder]._build_targets }}"

    - name: Pull image + manifest from builder to netboot server
      ansible.posix.synchronize:
        src: "{{ hostvars[_builder].armbian_build_output_dir }}/{{ item }}/"
        dest: "{{ nfs_assets_export }}/images/{{ item }}/"
        mode: pull
        delete: false
      delegate_to: "{{ _builder }}"
      loop: "{{ hostvars[_builder]._build_targets }}"
```

- [ ] **Step 2: Lint and syntax-check**

Run: `yamllint playbooks/build_image.yml`
Expected: no output

Run: `ansible-lint --profile=production playbooks/build_image.yml`
Expected: clean (or only nameable warnings — fix them)

Run: `ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check`
Expected: `playbook: playbooks/build_image.yml` with no errors

- [ ] **Step 3: Commit**

```bash
git add playbooks/build_image.yml
git commit -m "Add playbooks/build_image.yml: build then publish custom images"
```

---

## Task 11: Inventory documentation samples

**Files:**
- Modify: `inventory/hosts.yml`
- Modify: `inventory/group_vars/all.yml`

- [ ] **Step 1: Read the current `inventory/hosts.yml` to find the right spot**

Read: `inventory/hosts.yml`

Locate the `all.children:` block. The `armbian_builders` group is added as a sibling of the existing `boards`, `routeros`, and `netboot_server` entries.

- [ ] **Step 2: Add `armbian_builders` example group to `inventory/hosts.yml`**

Append (or insert in the appropriate spot under `all.children:`):

```yaml
    # Optional: hosts that run armbian/build to produce custom images
    # (consumed via the local-override pattern in armbian_image_urls).
    # Required when any host has host_board_overrides.armbian_build_enabled: true.
    armbian_builders:
      hosts:
        builder-01:
          ansible_host: 192.0.2.50
          ansible_user: builder
          ansible_become: true
```

- [ ] **Step 3: Add commented `armbian_image_urls` example to `inventory/group_vars/all.yml`**

After the existing `armbian_image_urls:` block, append a comment + commented-out example showing the local-override pattern. Use the existing comment style:

```yaml
# ── Custom build override (for boards built via playbooks/build_image.yml) ──
# After a successful build, override the upstream URL to point at the locally
# published copy on the netboot server. The exact filename includes the
# version + kernel revision; copy it from the produced manifest.json.
#
#   armbian_image_urls:
#     orange-pi-5-pro: "{{ image_server_url }}/images/orangepi5pro/Armbian_<version>_orangepi5pro_bookworm_current_<kernel>.img.xz"
```

- [ ] **Step 4: Lint**

Run: `yamllint inventory/hosts.yml inventory/group_vars/all.yml`
Expected: no output

- [ ] **Step 5: Commit**

```bash
git add inventory/hosts.yml inventory/group_vars/all.yml
git commit -m "Document armbian_builders group and armbian_image_urls override"
```

---

## Task 12: Final lint pass on the whole new surface

- [ ] **Step 1: Lint the complete role**

Run: `ansible-lint --profile=production roles/armbian_build/ playbooks/build_image.yml`
Expected: no findings

If anything flags, fix inline. Common issues:
- `risky-shell-pipe` on `command:` invocations using `mv` — already deliberate (build artifacts genuinely move)
- `name[missing]` if any task is unnamed — name it
- `fqcn[action-core]` if a non-FQCN module slipped in — fix to `ansible.builtin.<module>`

- [ ] **Step 2: Syntax-check the playbook against the documentation inventory**

Run: `ansible-playbook -i inventory/ playbooks/build_image.yml --syntax-check`
Expected: `playbook: playbooks/build_image.yml` with no errors

- [ ] **Step 3: Verify no untracked changes remain**

Run: `git status`
Expected: clean working tree (all changes committed in earlier tasks)

If lint required edits, commit with:

```bash
git commit -am "Lint fixes for armbian_build role and build_image playbook"
```

---

## Task 13: Operator end-to-end acceptance run (manual)

This task does not produce code commits — it's the operator's confirmation that the v1 acceptance criteria are met against real hardware. Run after Tasks 1–12 are complete and merged to a feature branch.

- [ ] **Step 1: Verify environment**

Run: `echo $ANSIBLE_INVENTORY`
Expected: a path ending in `.inventory/`

Run: `ansible -m ping armbian_builders`
Expected: `SUCCESS` for the configured builder host

Run: `ansible -m ping netboot_server`
Expected: `SUCCESS`

- [ ] **Step 2: Configure inventory opt-in for the test board**

In the real (gitignored) `.inventory/`, on the host_vars file for an `orangepi5pro` board (e.g. `orangepi5pro-01`), set:

```yaml
host_board_overrides:
  armbian_build_enabled: true
```

- [ ] **Step 3: Run the build playbook**

Run: `ansible-playbook playbooks/build_image.yml`
Expected: builder runs the role; produces `<armbian_build_output_dir>/orangepi5pro/Armbian_*.img.xz` + `manifest.json`; second play synchronizes both into `nfs_assets_export/images/orangepi5pro/` on the netboot server.

Verify on the builder:

```bash
ls -la /var/lib/armbian_build/output/orangepi5pro/
cat /var/lib/armbian_build/output/orangepi5pro/manifest.json
```

Verify on the netboot server:

```bash
ls -la /opt/netbootxyz/assets/images/orangepi5pro/
```

- [ ] **Step 4: Verify the BOOT_TARGETS patch took effect**

Loop-mount the produced image and grep:

```bash
xz -d -k /opt/netbootxyz/assets/images/orangepi5pro/Armbian_*_orangepi5pro_*.img.xz
sudo losetup -P /dev/loop0 /opt/netbootxyz/assets/images/orangepi5pro/Armbian_*_orangepi5pro_*.img
sudo mount /dev/loop0p1 /mnt
strings /mnt/usr/lib/u-boot*/u-boot.itb 2>/dev/null | grep -E 'pxe dhcp.*spi' || \
  sudo dd if=/dev/loop0 bs=1M count=32 2>/dev/null | strings | grep -E 'pxe dhcp.*spi'
```

Expected: a string containing `pxe dhcp mmc1 mmc0 nvme scsi usb spi` is present.

Cleanup: `sudo umount /mnt && sudo losetup -d /dev/loop0`

- [ ] **Step 5: Verify idempotency**

Run: `ansible-playbook playbooks/build_image.yml`
Expected: completes in ~tens of seconds (preflight + manifest match → skip-build + rsync no-op).

- [ ] **Step 6: Verify rebuild is triggered by an input change**

Edit `playbooks/build_image.yml` and add a no-op shell comment to `build_userpatches[orangepi5pro][0].content` (e.g. `# version bump test`).
Run: `ansible-playbook playbooks/build_image.yml`
Expected: the role rebuilds (manifest mismatch detected); publish ships the new artifact.

Revert the edit before committing.

- [ ] **Step 7: Wire the local image URL and run the downstream flow**

Update `inventory/group_vars/all.yml` (or the equivalent in `.inventory/`) `armbian_image_urls[orange-pi-5-pro]` to the local URL produced (filename from `manifest.json`).

Run: `ansible-playbook playbooks/populate_nfs_content.yml --limit netboot_server`
Run: `ansible-playbook playbooks/reprovision.yml --limit orangepi5pro-01`

Expected: reprovision completes; the board comes up from disk with the custom image.

- [ ] **Step 8: Verify the netboot trigger now works**

Run: `ansible-playbook playbooks/enable_netboot.yml --limit orangepi5pro-01 -e netboot_mode=nfsroot`
Expected: board reboots into NFS root (closes the empirical loop from issue #2).

- [ ] **Step 9: Remove WIP banners**

If all of steps 1–8 succeeded, remove the WIP markers from:
- `README.md`
- `CLAUDE.md` (the "⚠️ Status: netboot trigger is WIP" section)
- `docs/architecture.md`
- `roles/armbian_build/README.md` (if any "WIP" notes were inserted during development)
- `playbooks/build_image.yml` header comment (if any)

Commit:

```bash
git commit -am "Remove WIP banners after armbian_build v1 acceptance"
```

---

## v1 acceptance criteria recap (from the spec)

- [ ] `roles/armbian_build/` exists with the layout from the spec.
- [ ] `playbooks/build_image.yml` produces `Armbian_*_orangepi5pro_*_current_*.img.xz` + `manifest.json` in the builder's output dir, then publishes to `nfs_assets_export/images/orangepi5pro/`.
- [ ] Loop-mounting the produced `.img.xz` and grepping `BOOT_TARGETS` shows `"pxe dhcp mmc1 mmc0 nvme scsi usb spi"`.
- [ ] `host_board_overrides.armbian_build_enabled: true` on opi5pro-01 + the `armbian_image_urls[orange-pi-5-pro]` override makes `populate_nfs_content.yml` + `reprovision.yml` consume the custom image.
- [ ] After reprovision, `enable_netboot.yml` + reboot lands the board in NFS root.
- [ ] WIP banners removed from `README.md`, `CLAUDE.md`, `docs/architecture.md`, and the affected role READMEs.
