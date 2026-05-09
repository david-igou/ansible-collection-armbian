# 2026-05-05 — `armbian_build` role v1: design

**Issue:** [#16](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/16)
**Direction spec:** [`2026-05-05-collection-direction-design.md`](./2026-05-05-collection-direction-design.md)

## Goal

Land the `armbian_build` role + `playbooks/build_image.yml` in v1, producing a
custom Armbian `.img.xz` image for `orangepi5pro` with PXE-first
`BOOT_TARGETS` patched at U-Boot compile time. The image is consumed by the
existing `netboot_assets` and `reprovision` workflows through the
`armbian_image_urls` indirection — no downstream role changes.

## Architecture & boundaries

**The role does one thing.** `armbian_build` produces a `.img.xz` +
`manifest.json` in a configurable output directory on the builder host,
given a board, branch, release, and a list of userpatches to apply. It does
not publish, does not configure DHCP, does not touch the netboot server, and
is fully agnostic to *why* a caller wants a particular set of patches —
PXE-first is one caller's intent, expressed as data in
`playbooks/build_image.yml`, not a role-internal concern.

**The playbook composes the workflow.** `playbooks/build_image.yml` is two
plays:

1. `hosts: armbian_builders` — invokes `armbian_build` per opted-in board.
2. `hosts: netboot_server` — `synchronize` (mode: pull, delegated to the
   builder) each produced artifact directory into
   `nfs_assets_export/images/<board>/`.

**Three preconditions** the role assumes (and pre-flight asserts):

- Docker ≥17.06 with privileged container support is installed and
  runnable by the connecting user.
- `armbian_build_cache_dir` and `armbian_build_output_dir` exist with
  ≥`armbian_build_min_free_gb` free space.
- Egress to `github.com`, `apt.armbian.com`, `ghcr.io` (and the kernel
  mirrors `armbian/build` reaches transitively) is unrestricted.

**Inventory boundary.** Opt-in is per-host via
`host_board_overrides.armbian_build_enabled: true`.
`playbooks/build_image.yml` filters hosts in the `boards` group by that
flag and deduplicates to one build per `armbian_board_name`.

**What stays unchanged.** `netboot_assets`, `reprovision`, `bootloader`, and
the inventory structure are not modified by this work. Consumption is via
the existing `armbian_image_urls[<board_model>]` indirection — operators
flip the URL to point at the locally published image after a build.

## Role layout

```
roles/armbian_build/
├── README.md
├── defaults/main.yml
├── meta/main.yml
└── tasks/
    ├── main.yml                 # orchestrator: imports the others in order
    ├── preflight.yml            # docker, privileged container, disk space, egress
    ├── manage_checkout.yml      # clone-or-fetch armbian/build at armbian_build_ref
    ├── apply_userpatches.yml    # write each {dest, content} into <userpatches_dir>/<dest>
    ├── compute_inputs.yml       # patch_hash + manifest fact
    ├── check_manifest.yml       # set _skip_build if existing manifest matches
    ├── invoke_build.yml         # ./compile.sh docker BOARD=… (skipped when _skip_build)
    └── write_manifest.yml       # write manifest.json next to the produced .img.xz
```

The role intentionally has **no `templates/` and no `vars/`** — it carries
no caller-specific data. All inputs come from the calling playbook.

`tasks/main.yml` is a glue file that imports the others in order and gates
`invoke_build` on `_skip_build`. Each individual task file stays small and
single-purpose, matching the existing role style in this collection.

`manage_checkout.yml` uses `ansible.builtin.git` with
`version: "{{ armbian_build_ref }}"`. On re-run it fetches and checks out,
leaving the build cache (`cache/`, `output/`) intact so kernel build
artifacts survive between runs (incremental builds finish in minutes
instead of hours).

`apply_userpatches.yml` is ~5 lines: a loop over
`armbian_build_userpatches` that creates parent dirs and writes each
`content` to `<userpatches_dir>/<dest>` using `ansible.builtin.copy`. It
asserts `dest` does not contain `..` to prevent path escape.

`compute_inputs.yml` is the only file that does the hashing. It produces
`_patch_hash = sha256(canonical-JSON-encoded armbian_build_userpatches)`
and assembles the manifest fact (decision fields plus `image_filename`
predicted from board/branch/release and `built_at` set later).

`check_manifest.yml` reads `<output_dir>/<board>/manifest.json` if it
exists; sets `_skip_build = true` only when **all five decision fields**
match the current invocation's inputs: `patch_hash`, `armbian_build_ref`,
`board`, `branch`, `release`. File missing, parse error, or any field
mismatch → `_skip_build = false` (rebuild).

`invoke_build.yml` is `ansible.builtin.command` invoking
`./compile.sh docker` with `async`/`poll: 30` so a long build doesn't tie
up the SSH session; default `armbian_build_timeout: 7200` covers a
cold-cache full build.

`write_manifest.yml` writes the manifest atomically (temp file → rename)
so a concurrent reader either sees the old manifest or a complete new one.

## Inputs

### `defaults/main.yml`

```yaml
# armbian/build pinning. Upstream uses a vX.Y.Z-trunk.NNN release scheme;
# pin to a specific trunk release for reproducibility.
armbian_build_ref: "v26.2.0-trunk.844"

# Filesystem layout on the builder
armbian_build_cache_dir: "/var/lib/armbian_build"            # armbian/build checkout + cache + userpatches
armbian_build_output_dir: "/var/lib/armbian_build/output"    # final .img.xz + manifest.json land here

# Per-build inputs (caller sets board; branch/release defaulted)
armbian_build_board: ""                # required; e.g. "orangepi5pro"
armbian_build_branch: "current"
armbian_build_release: "bookworm"

# Userpatches to apply before the build. List of { dest, content } entries.
# `dest` is a path relative to USERPATCHES_DIR (no leading slash, no ..).
# Empty by default — caller is responsible for any patches they want applied.
armbian_build_userpatches: []

# Preflight thresholds
armbian_build_min_free_gb: 50
armbian_build_required_egress_hosts:
  - github.com
  - apt.armbian.com
  - ghcr.io

# compile.sh argument knobs (overridable, but sane defaults for a netboot image).
# These are NOT folded into patch_hash — they are operator-tunable knobs;
# manifest fields like `branch` and `release` cover the rebuild-decision dimensions.
armbian_build_compile_args:
  KERNEL_CONFIGURE: "no"
  BUILD_DESKTOP: "no"
  BUILD_MINIMAL: "yes"
  COMPRESS_OUTPUTIMAGE: "sha,xz"
  EXPERT: "yes"

# Build timeout (seconds). 2h covers cold-cache full builds.
armbian_build_timeout: 7200

# Set true on the CLI to bypass the manifest-match skip and force a rebuild.
armbian_build_force: false
```

### Caller-side inputs (in `playbooks/build_image.yml`)

The PXE-first patch table is **playbook data**, not role data:

```yaml
build_userpatches:
  orangepi5pro:
    - dest: "config/boards/orangepi5pro.conf"
      content: |
        function pre_config_uboot_target__orangepi5pro_pxe_first() {
            declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
            sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                include/configs/rockchip-common.h
        }
```

For v2 (additional Rockchip boards), the same data shape extends —
each new board appends a key to `build_userpatches`. For Allwinner (sunxi),
the only difference is the `include/configs/<soc>-common.h` path — still
pure data.

### Inventory opt-in

```yaml
# inventory/host_vars/orangepi5pro-01.yml
host_board_overrides:
  armbian_build_enabled: true
```

```yaml
# inventory/group_vars/all.yml
armbian_image_urls:
  orange-pi-5-pro: "{{ image_server_url }}/orangepi5pro/Armbian_<version>_orangepi5pro_bookworm_current_<kernel>.img.xz"
```

The operator updates the `armbian_image_urls` string after each build
that bumps the version. The build play surfaces the produced filename
in its output and in `manifest.json` so this is a one-line copy-paste.

## Idempotency & rebuild logic

**Per role invocation:**

1. `compute_inputs.yml` produces:
   - `_patch_hash = sha256(canonical-JSON-encoded armbian_build_userpatches)`
   - The manifest fact (decision subset: `patch_hash`, `armbian_build_ref`,
     `board`, `branch`, `release`)

2. `check_manifest.yml` looks for `<output_dir>/<board>/manifest.json`:
   - File missing, unreadable, or fails to parse → rebuild
   - File present with all five decision fields matching the current
     invocation (`patch_hash`, `armbian_build_ref`, `board`, `branch`,
     `release`) → `_skip_build = true`
   - Any field mismatch → rebuild
   - `armbian_build_force: true` always rebuilds regardless of match

3. `invoke_build.yml` runs only when `_skip_build` is false.

4. `write_manifest.yml` runs only when a build happened. Writes the full
   manifest (decision fields + `image_filename` + ISO-8601 `built_at`)
   atomically.

**Manifest schema (full set written by `write_manifest.yml`):**

```json
{
  "patch_hash": "sha256:abcd…",
  "armbian_build_ref": "v26.2.0-trunk.844",
  "board": "orangepi5pro",
  "branch": "current",
  "release": "bookworm",
  "image_filename": "Armbian_<version>_orangepi5pro_bookworm_current_<kernel>.img.xz",
  "built_at": "2026-05-05T12:34:56Z"
}
```

`built_at` is informational only — never read for rebuild decisions.

**What's not in the hash, on purpose:**
`armbian_build_compile_args` are operator-tunable knobs (e.g. flipping
`EXPERT` for diagnostics). Folding them into the hash would make CLI
overrides flip rebuild decisions in confusing ways. If a flag genuinely
affects the produced image's content, capture it as a manifest field and
rely on `armbian_build_force` for override cases.

`branch` and `release` *do* affect the build artifact and *are* manifest
fields, so changing them via `-e` triggers a manifest mismatch → rebuild.
Equivalent semantics, cleaner field separation.

## Build invocation & artifact handling

```yaml
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
```

`USERPATCHES_DIR` points outside the upstream `armbian/build` checkout so
`git fetch`/`checkout` on the upstream tree never touches our overlays.
The role creates `<armbian_build_cache_dir>/userpatches/` and
`apply_userpatches.yml` writes into it.

`armbian/build` produces output to
`<checkout>/output/images/Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz`.
The kernel version isn't known in advance, so the role uses
`ansible.builtin.find` with `age: -10m` to locate the artifact produced
by the current run, asserts exactly one match, then moves it to
`<output_dir>/<board>/<image_filename>`.

**Final artifact directory structure:**

```
{{ armbian_build_output_dir }}/<board>/
├── Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz
├── Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz.sha   # from COMPRESS_OUTPUTIMAGE=sha,xz
└── manifest.json
```

The `.sha` from `armbian/build` is upstream's per-build integrity check
(useful end-to-end after `synchronize`); not consumed by our manifest.

## `playbooks/build_image.yml` (full sketch)

```yaml
---
- name: Build custom Armbian images on builders
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
  tasks:
    - name: Build image per opted-in board
      ansible.builtin.include_role:
        name: armbian_build
      vars:
        armbian_build_board: "{{ item }}"
        armbian_build_userpatches: "{{ build_userpatches[item] }}"
      loop: "{{ _build_targets }}"

- name: Publish images to netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - name: Ensure per-board image directory exists
      ansible.builtin.file:
        path: "{{ nfs_assets_export }}/images/{{ item }}"
        state: directory
        mode: "0755"
      loop: "{{ hostvars[groups['armbian_builders'][0]]._build_targets }}"

    - name: Pull image + manifest from builder
      ansible.posix.synchronize:
        src: "{{ hostvars[groups['armbian_builders'][0]].armbian_build_output_dir }}/{{ item }}/"
        dest: "{{ nfs_assets_export }}/images/{{ item }}/"
        mode: pull
        delete: false
      delegate_to: "{{ groups['armbian_builders'][0] }}"
      loop: "{{ hostvars[groups['armbian_builders'][0]]._build_targets }}"
```

`mode: pull` with `delegate_to: <builder>` runs rsync on the builder with
the netboot server as destination — bytes flow directly between the two,
not via the control node.

`delete: false` is deliberate: the builder accumulates output across runs
and we don't garbage-collect the destination. Cleanup is a future
operator concern.

`groups['armbian_builders'][0]` assumes a single builder. Multi-builder
support is out of scope for v1.

## Inventory plumbing

**New group `armbian_builders`** in the documentation `inventory/hosts.yml`:

```yaml
all:
  children:
    armbian_builders:
      hosts:
        builder-01:
          ansible_host: 192.0.2.50
          ansible_user: builder
          ansible_become: true
```

**Per-host opt-in** via `host_board_overrides.armbian_build_enabled`,
piggybacking the existing `host_board_overrides` mechanism documented in
`CLAUDE.md`. The build play's `_build_targets` deduplicates by
`armbian_board_name`, so N opi5pro-* hosts opted in produce one build.

**`armbian_image_urls` override** in `inventory/group_vars/all.yml` to
point at the local image. Concrete URL with the actual produced version +
kernel revision; pattern/glob resolution would force HTTP directory
listing or inventory mutation, both worse than a one-line edit after each
version-bump build.

**Documentation updates that ship with the role:**

- `inventory/hosts.yml` (sample) gains an `armbian_builders` example group.
- `inventory/group_vars/all.yml` (sample) gains a commented
  `armbian_image_urls` example for the local override pattern.
- `roles/armbian_build/README.md` documents the role's contract: inputs
  (board, branch, release, userpatches, output dir), outputs
  (`.img.xz` + `manifest.json`), preflight assumptions, idempotency model.
- WIP banners removed from `README.md`, `CLAUDE.md`,
  `docs/architecture.md`, and the affected role READMEs once v1 acceptance
  criteria are met.

## Error handling

| Phase | Failure mode | Behaviour |
|---|---|---|
| Preflight | Docker missing or not privileged | Hard fail naming the missing prerequisite |
| Preflight | Free space < `armbian_build_min_free_gb` | Hard fail with actual value vs threshold |
| Preflight | Required egress host unreachable | Hard fail naming the host |
| Checkout | `armbian_build_ref` doesn't exist | `ansible.builtin.git` error propagates |
| Userpatches | `dest` contains `..` (path escape) | Hard fail before any file is written |
| Manifest check | `manifest.json` malformed JSON | Treat as missing → rebuild (logged) |
| Build | `compile.sh` exits non-zero | Hard fail; last 100 lines captured for the operator |
| Build | Async timeout exceeded | Hard fail; partial output left in `armbian/build/output/images/` |
| Locate artifact | `find` returns 0 or >1 matches | Hard fail with candidate count |
| Manifest write | Disk/permission error | Hard fail; no manifest is written → next run rebuilds (correct conservative behaviour) |
| Publish | `synchronize` fails | Build artifact intact on builder; re-run skips rebuild and re-runs publish |

## Testing strategy (v1)

No Molecule scaffold — kept light to match the rest of the collection.

- **End-to-end manual run** against a real `armbian_builders` host and a
  real `netboot_server`, on `orangepi5pro`. Acceptance is issue #16's
  criteria below.
- **Idempotency check.** Two consecutive `playbooks/build_image.yml` runs
  with no input changes — second completes in seconds (preflight + manifest
  match + rsync no-op).
- **Rebuild trigger check.** Edit `build_userpatches[orangepi5pro][0].content`
  byte; re-run; confirm role rebuilds (manifest mismatch detected) and
  publish ships the new artifact.
- **Lint.** `ansible-lint --profile=production roles/armbian_build/ playbooks/build_image.yml`
  clean.
- **Static check.** `yamllint` clean on the new files.

## Out of scope for v1

All deferred to follow-up issues already filed per the direction spec:

- Multiple builders, build-pool sharding, distributed coordination
- U-Boot deb-only output path (consumption mode for boards on stock images)
- Allwinner sunxi support (different `include/configs/<soc>-common.h`)
- Headless image (bake user/keys, disable `armbian-firstlogin`)
- Garbage collection of old `<output_dir>/<board>/<file>.img.xz` revisions
- Auto-updating `armbian_image_urls` after a successful build (currently
  a manual copy-paste from the manifest)

## v1 acceptance criteria (from issue #16)

- [ ] `roles/armbian_build/` exists with the layout from the role-layout
  section above.
- [ ] `playbooks/build_image.yml` produces
  `Armbian_*_orangepi5pro_*_current_*.img.xz` + `manifest.json` in the
  builder's output dir, then publishes to
  `nfs_assets_export/images/orangepi5pro/`.
- [ ] Loop-mounting the produced `.img.xz` and grepping `BOOT_TARGETS` in
  the embedded U-Boot config shows
  `"pxe dhcp mmc1 mmc0 nvme scsi usb spi"`.
- [ ] `host_board_overrides.armbian_build_enabled: true` on opi5pro-01 +
  the `armbian_image_urls[orange-pi-5-pro]` override makes the existing
  `stage_netboot_assets.yml` + `reprovision.yml` flow consume the custom
  image.
- [ ] After reprovision, `enable_netboot.yml` + reboot lands the board in
  NFS root (closes the empirical question raised in #2).
- [ ] WIP banners removed from `README.md`, `CLAUDE.md`,
  `docs/architecture.md`, and the affected role READMEs.

## Open question for review

- **Default `armbian_build_ref`.** Spec uses `v26.2.0-trunk.844` (latest
  trunk release at time of writing). Confirm or substitute.
