# Per-host build + rootfs provisioning — design spec

**Date:** 2026-05-27
**Status:** approved (pending user review of this written form)
**Scope:** `david_igou.armbian` collection — refactor from per-model to per-host as the unit of work for image building and rootfs provisioning.

---

## 1. Motivation

Today the collection's per-image artifacts (build output, NFS rootfs template, TFTP kernel/initrd/dtb) are keyed by `armbian_board_model`. `build_and_publish_from_inventory.yml` explicitly asserts that hosts of the same model cannot diverge on `armbian_board_branch` or `armbian_board_userpatches`, with a fail_msg that reads "Per-host builds are not supported in v3".

The user needs the opposite: the ability to build and roll out completely different images and configurations for hosts of the same hardware model, with the full build profile expressed in inventory (family → model → host inheritance). Use cases include host-specific secret injection (Tailscale auth keys, vault-decrypted credentials baked at build time), divergent customize-image scripts, and per-host branch/release pinning.

## 2. Goals

- Per-host as the unit of build, publish, and rootfs provisioning. No silent sharing between hosts; no cross-host divergence asserts blocking the workflow.
- Operator expresses the entire build profile in inventory via a three-layer family → model → host merge mirroring the same pattern for hardware configuration.
- Operator can opt out of custom builds per host by pointing `armbian_rootfs_src` directly at an upstream Armbian URL — the same role handles both stock and custom workflows.
- Adding a new board requires zero edits to the collection — only inventory.
- No `hash_behaviour = merge` (deprecated, global, leaky); merges are explicit and named.

## 3. Non-goals

- Build-time deduplication across hosts with identical profiles. The user explicitly chose "always per-host, no sharing" — N hosts with identical profiles produce N independent builds. (Operationally tunable later; not in scope here.)
- Migration / deprecation period. The collection is 0.0.x and the project explicitly accepts breaking changes between releases; this lands as a clean break in one PR.
- New build-time mutation framework. armbian/build's existing `customize-image.sh` and userpatch overlays remain the only mechanism for rootfs mutation; the refactor changes *who controls them* (operator inventory), not *what they can do*.

## 4. Cardinality flip — path layout

Pure per-host everywhere except hardware facts. `vars/boards.yml` is deleted; per-model hardware facts move into operator inventory under `inventory/group_vars/<model_group>.yml` with `inventory/group_vars/<family>.yml` family-level defaults.

| Today | After |
|---|---|
| `armbian_build_output_dir/<board>/...img.xz` | `armbian_build_output_dir/<host>/...img.xz` |
| `armbian_nfs_assets_export/images/<board>/...img.xz` | `armbian_nfs_assets_export/images/<host>/...img.xz` |
| `armbian_nfs_rootfs_path/_templates/<model>/` | gone |
| `armbian_nfs_rootfs_path/<host>/` | unchanged path; populated directly by `rootfs_provision` |
| `flash:/sbc/armbian/<model>/{vmlinuz,initrd.img,board.dtb}` | `flash:/sbc/armbian/<host>/{vmlinuz,initrd.img,board.dtb}` |
| `armbian_image_urls[<model>]` global host_var dict | gone — replaced by per-host `armbian_rootfs_src` (optional; defaults to derived URL) |
| `armbian_board_configs[<model>]` in `vars/boards.yml` | gone — replaced by `armbian_board_config` resolved per host via three-layer merge |

`armbian_image_urls` disappears because URL is derivable: every host's image lives at `armbian_nfs_assets_export/images/<host>/<manifest.image_filename>`, and the publish playbook is the source of truth for "where this host's image is". One less knob, one less drift surface.

## 5. Three-layer merge — board_config + build profile

### 5.1 `armbian_board_config` (hardware facts)

| Layer | Variable | Where | Purpose |
|---|---|---|---|
| family | `armbian_board_config_family` | `inventory/group_vars/<family>.yml` (e.g. `rk3588.yml`, `rk3588s.yml`) | SoC-family hardware defaults: console, earlycon, local_kernel.{storage,storage_scan}, uboot_env.storage (typical case) |
| model | `armbian_board_config_model` | `inventory/group_vars/<model_group>.yml` | Per-model deltas: `armbian_board_name` (the armbian/build BOARD= string), `dtb`, model-specific overrides like rock-5b's SPI uboot_env block |
| host | `armbian_board_config_host` | `inventory/host_vars/<host>.yml` (rare) | Per-host deltas — only when a single host of a model needs a non-standard partition layout etc. |
| resolved | `armbian_board_config` | Set by `tasks/_resolve_board_config.yml` | What every consumer reads |

Merge: `combine(recursive=true)` left-to-right (family → model → host). Required fields after merge: `armbian_board_name`, `dtb`, `console`. Resolver asserts presence.

### 5.2 `armbian_build` (build profile)

| Layer | Variable | Where | Purpose |
|---|---|---|---|
| defaults | `armbian_build_defaults` | Collection: `vars/build_defaults.yml` | Sane scalars (`release: bookworm`, `ref: v26.2.0-trunk.844`, `min_free_gb: 50`, `timeout: 7200`) and baseline `compile_args` |
| family | `armbian_build_family` | Operator: `group_vars/<family>.yml` | SoC-family userpatches (rk3588 PXE-first hook, PCI defconfig backfill, local_kernel bake hook, bcmdhd disable, uboot_env_check) |
| model | `armbian_build_model` | Operator: `group_vars/<model_group>.yml` | Per-model branch pin (e.g. rock-5b `branch: edge`) + per-model userpatches (e.g. rock-5b v2026.04 BOOTBRANCH override) |
| host | `armbian_build_host` | Operator: `host_vars/<host>.yml` | Per-host customize-image.sh, vault-bearing userpatches |
| resolved | `armbian_build` | Set by `tasks/_resolve_build_profile.yml` | What `image_build` consumes |

Merge contract per key:

| Key | Type | Semantics |
|---|---|---|
| `branch`, `release`, `ref`, `min_free_gb`, `timeout` | scalar | last-defined layer wins |
| `userpatches` | list of `{dest, content}` | list-concatenated across layers (defaults → family → model → host); duplicate `dest` is a **hard fail** naming both contributing layers, regardless of whether the contents match (forces operator to refactor explicitly) |
| `compile_args` | dict | dict-merged; last layer wins per key |

Hard fail on duplicate `dest` is deliberate: silent override of a family-level `customize-image.sh` by a host-level one would be ugly to debug. The operator either renames one or refactors the lower layer.

### 5.3 Symmetry

```
                     family               model               host           resolved
armbian_board_config _family ─► .yml      _model ─► .yml      _host ─► .yml  armbian_board_config
armbian_build        _family ─► .yml      _model ─► .yml      _host ─► .yml  armbian_build
```

(Plus `armbian_build_defaults` collection-shipped, no `defaults` layer for board_config since hardware facts have no collection-side defaults.)

Two resolvers, same shape, same merge semantics. The operator learns it once.

## 6. Local_kernel dispatch table — collapses

The `_local_kernel_dispatch_table` and `_uboot_env_storage_table` pre_tasks in today's `build_and_publish_from_inventory.yml` exist because one playbook run produced multiple BOARD= targets and the family hook needed a `${BOARD}`-keyed runtime lookup.

With per-host builds, each `image_build` invocation is for exactly one host, and the host's resolved `armbian_board_config` is fully in scope when the userpatch content is rendered. The bash associative array collapses to direct Jinja substitution at userpatch-templating time:

```bash
# Before (group_vars/armbian.yml)
declare -A LOCAL_KERNEL_CHAIN=(
    [orangepi5pro]='setenv bootargs ... ext4load nvme 0:1 ...'
    [rock-5b]='setenv bootargs ... ext4load nvme 0:1 ...'
    # one row per model in inventory
)
local chain="${LOCAL_KERNEL_CHAIN[${BOARD}]:-}"

# After (group_vars/rk3588.yml — armbian_build_family userpatches[].content)
{% if armbian_board_config.local_kernel is defined %}
local chain='setenv bootargs root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console={{ armbian_board_config.console }}; {{ armbian_board_config.local_kernel.storage_scan }}; ext4load {{ armbian_board_config.local_kernel.storage }} ...; ext4load {{ armbian_board_config.local_kernel.storage }} ${fdt_addr_r} /boot/dtb/{{ armbian_board_config.dtb }}; ...'
{% else %}
return 0   # board doesn't opt into local_kernel
{% endif %}
```

Same flow applies to `__999_uboot_env_check`: `local expected='{{ armbian_board_config.uboot_env.storage | default("") }}'`.

The userpatch content is double-rendered: once by Ansible at the time `image_build`'s `apply_userpatches.yml` writes it to the builder's userpatches dir (Jinja-rendered with the host's resolved facts), then once more by bash at build time for runtime substitutions like `${BOARD}` and `${BOOTCONFIG}`.

**Implementation verification step:** `apply_userpatches.yml` today uses `ansible.builtin.copy` with `content: "{{ item.content }}"`. This relies on Ansible's default recursive templating to resolve `{{ armbian_board_config.* }}` references inside the string value of `item.content`. The implementation must verify this resolves on the target Ansible version; if not, the resolver pre-renders userpatch content into a `__rendered_userpatches` list before the role consumes it. Either way the semantics are the same; the impl picks the mechanism that works.

## 7. Role contracts

### 7.1 `image_build` — re-keyed by host

Changes vs today (additions in **bold**):

| Var | After |
|---|---|
| `armbian_build_board` | required; caller resolves from `armbian_board_config.armbian_board_name` |
| **`armbian_build_host`** | **new, required — `inventory_hostname`. Drives per-host output paths.** |
| `armbian_build_branch`, `armbian_build_release`, `armbian_build_userpatches`, `armbian_build_compile_args`, `armbian_build_ref`, `armbian_build_min_free_gb`, `armbian_build_timeout`, `armbian_build_force` | unchanged scalars/lists; caller passes the resolved values from `armbian_build` |
| `armbian_build_cache_dir` | unchanged default `/var/lib/armbian_build` (must be pre-created + chowned for ansible_user). Per-host suffix `<host>/build/` appended internally. |
| `armbian_build_output_dir` | unchanged default `/var/lib/armbian_build/output`. Per-host suffix `<host>/` appended internally. |

Manifest gains a `host:` field, and the rebuild-decision tuple becomes six fields (patch_hash, armbian_build_ref, board, host, branch, release). `check_manifest.yml` adds `host` to the comparison.

Per-host build-tree isolation: each host gets its own armbian/build checkout under `/var/lib/armbian_build/<host>/build/`. Cost: ~200MB checkout × N hosts. Wins: parallel-safe by construction, secrets in host-layer userpatches never see another host's tree, cache invalidation is per-host.

The userpatch content argument_specs description updates to acknowledge that **patches may contain Jinja referencing `armbian_board_config.*`**; the existing `ansible.builtin.copy` with `content:` already does this rendering.

### 7.2 New role: `rootfs_provision` (collapses `image_extract` + `rootfs_clone`)

Rationale: the only reason `image_extract` and `rootfs_clone` were split was rootfs-template deduplication across hosts of the same model. With pure per-host, the 1:1 template:host relationship makes reflink-cloning save nothing. Merge.

Argument shape:

| Var | Required | Default | Purpose |
|---|---|---|---|
| `armbian_rootfs_src` | yes | — | URL or absolute path. Resolved by caller per precedence (host_vars > published manifest > fail). |
| `armbian_rootfs_host` | yes | — | inventory_hostname. Drives identity + output path. |
| `armbian_rootfs_dtb` | yes | — | DTB path under `/boot/dtb/` to stage as TFTP `board.dtb`. From `armbian_board_config.dtb`. |
| `armbian_rootfs_target_dir` | no | `{{ armbian_nfs_rootfs_path }}/{{ armbian_rootfs_host }}` | NFS rootfs destination on netboot_server. |
| `armbian_rootfs_tftp_dir` | no | `{{ armbian_image_cache }}/sbc-tftp/{{ armbian_rootfs_host }}` | Per-host TFTP staging dir. |
| `armbian_rootfs_image_cache` | no | `{{ armbian_image_cache }}/downloads` | URL-keyed shared download cache (`sha256-of-url/<basename>`). Hosts pointing at the same URL share the download; extraction is still per-host. |
| `armbian_rootfs_force_refresh` | no | false | Force re-extract regardless of sentinel. |

Task layout:

```
roles/rootfs_provision/tasks/
├── main.yml
├── _validate_inputs.yml
├── _resolve_src.yml            # url-or-path; sha256 cache key
├── _download_or_copy.yml       # → ${image_cache}/<sha-of-url>/<basename>
├── _extract.yml                # losetup + mount + rsync into target_dir
├── _stage_tftp.yml             # cp vmlinuz/initrd/<dtb> → tftp_dir
├── _strip_fstab.yml            # remove /dev/ entries (was in image_extract)
├── _identity_reset.yml         # hostname, machine-id, SSH host keys (was in rootfs_clone)
└── _write_sentinel.yml         # .armbian_rootfs_provision_complete
```

Sentinel content (JSON): `{ "src": "<resolved URL or path>", "src_sha256": "<image SHA>", "host": "<inventory_hostname>", "provisioned_at": "<ISO8601>" }`. Skip logic compares all three; `force_refresh` invalidates.

### 7.3 `disk_image` — direct source input

Today consumes `armbian_image_urls[<model>]` via callers. After: new required input `armbian_disk_image_src` (URL or local path); same resolver precedence as `rootfs_provision`. `armbian_image_urls` is gone everywhere.

### 7.4 `pxelinux_render` — resolved board_config + per-host TFTP paths

Template references `armbian/{{ inventory_hostname }}/{vmlinuz,initrd.img,board.dtb}` instead of `armbian/{{ pxelinux_render_model_name }}/...`. Reads `armbian_board_config.console`, `armbian_board_config.earlycon` directly. `converge_boot_mode.yml`'s `vars:` block for the role drops `pxelinux_render_model_name`, `board_console`, `pxelinux_render_earlycon` etc.

### 7.5 `persist_uboot_env.yml` — direct fact read

`armbian_board_configs[armbian_board_model].uboot_env.storage` → `armbian_board_config.uboot_env.storage`. Pre-task includes `_resolve_board_config.yml` so the fact is available.

### 7.6 Unchanged

`bootstrap_armbian`, `board_boot_wait`, `board_boot_verify`, `disk_provision`, the entire `routeros/` reference tree, the entire RouterOS playbook plumbing. The blast radius of the refactor stays contained to: image-producing path (`image_build`), image-consuming path (`rootfs_provision`, `disk_image`), boot-config path (`pxelinux_render`, `persist_uboot_env`), and the build hooks that migrate from `group_vars/armbian.yml` to `group_vars/rk3588.yml` as part of the family-layer move.

## 8. Playbook flow

### 8.1 `build_and_publish_from_inventory.yml` (post-refactor)

Three plays still — but the build play loops over inventory hosts instead of unique models.

```yaml
- name: Resolve effective configs per board host
  hosts: boards
  gather_facts: false
  tasks:
    - include_vars: { file: "{{ playbook_dir }}/../vars/build_defaults.yml" }
    - include_tasks: tasks/_resolve_board_config.yml
    - include_tasks: tasks/_resolve_build_profile.yml
    - set_fact:
        __wants_custom_build: >-
          {{ (armbian_build_family is defined)
             or (armbian_build_model is defined)
             or (armbian_build_host is defined) }}

- name: Build per host that opted into custom builds; stage on controller
  hosts: armbian_builders
  gather_facts: false
  tasks:
    - include_role:
        name: image_build
      vars:
        armbian_build_host:         "{{ item }}"
        armbian_build_board:        "{{ hostvars[item].armbian_board_config.armbian_board_name }}"
        armbian_build_branch:       "{{ hostvars[item].armbian_build.branch }}"
        armbian_build_release:      "{{ hostvars[item].armbian_build.release }}"
        armbian_build_ref:          "{{ hostvars[item].armbian_build.ref }}"
        armbian_build_userpatches:  "{{ hostvars[item].armbian_build.userpatches }}"
        armbian_build_compile_args: "{{ hostvars[item].armbian_build.compile_args }}"
      loop: >-
        {{ groups['boards'] | map('extract', hostvars)
           | selectattr('__wants_custom_build', 'equalto', true)
           | map(attribute='inventory_hostname') | list }}

    # rsync per-host directory from builder → controller staging
    # (per today's pattern; per-host path swap)

- name: Publish staged per-host directories to netboot server
  hosts: netboot_server
  gather_facts: false
  tasks:
    # rsync per-host directory controller staging → images/<host>/ on netboot_server
```

Notable changes vs today:
- Cross-host divergence asserts deleted — divergence is now the point.
- `_local_kernel_dispatch_table` / `_uboot_env_storage_table` pre_tasks deleted — collapsed into family-layer userpatch content via Jinja.
- `_resolve_board_config.yml` runs on `hosts: boards`; the resolved fact lives on each board host; the builder play reads via `hostvars[<host>]`.

### 8.2 `stage_netboot_assets.yml` (post-refactor)

```yaml
- name: Resolve board configs and rootfs sources per board host
  hosts: boards
  gather_facts: false
  tasks:
    - include_tasks: tasks/_resolve_board_config.yml
    - include_tasks: tasks/_resolve_rootfs_src.yml

- name: Provision per-host NFS rootfs + TFTP artifacts
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - include_role:
        name: rootfs_provision
      vars:
        armbian_rootfs_src:           "{{ hostvars[item].armbian_rootfs_src }}"
        armbian_rootfs_host:          "{{ item }}"
        armbian_rootfs_dtb:           "{{ hostvars[item].armbian_board_config.dtb }}"
        armbian_rootfs_force_refresh: "{{ armbian_force_refresh | default(false) }}"
      loop: "{{ groups['boards'] }}"
```

One play. One role invocation per host.

### 8.3 `tasks/_resolve_rootfs_src.yml`

Per-host fact resolver. Precedence:

1. host_vars `armbian_rootfs_src` set → use as-is.
2. Else: stat `armbian_nfs_assets_export/images/<host>/manifest.json` on netboot_server (delegated). If present, derive `armbian_rootfs_src` as the local-file path `<images-dir>/<host>/<manifest.image_filename>` (netboot_server resolves it locally — faster than HTTP back to self).
3. Else: fail with actionable message ("set armbian_rootfs_src in host_vars OR run build_and_publish_from_inventory.yml first").

### 8.4 `stage_router.yml` (post-refactor)

All loops over `groups['boards']` (per-host instead of `_unique_models`).

- Fetch task: `${armbian_image_cache}/sbc-tftp/<host>/{vmlinuz,initrd.img,board.dtb}` from netboot_server → `${armbian_tftp_cache_dir}/<host>/` on controller.
- Push task: upload each to `sbc/armbian/<host>/<filename>` on rb5009; register `/ip tftp` rule per file.
- Plumbing check: per-host rows.

New router TFTP layout:

```
flash:/sbc/
├── pxelinux.cfg/
│   └── 01-<MAC>              # per-board, unchanged
└── armbian/
    └── <inventory_hostname>/
        ├── vmlinuz
        ├── initrd.img
        └── board.dtb
```

## 9. Worked example — rock-5b-01

### Inventory

```yaml
# inventory/group_vars/rk3588.yml — family
armbian_board_config_family:
  console: ttyS2,1500000n8
  earlycon: uart8250,mmio32,0xfeb50000
  local_kernel:
    storage: "nvme 0:1"
    storage_scan: "nvme scan"
  uboot_env:
    storage: nowhere

armbian_build_family:
  userpatches:
    - dest: config/sources/families/rockchip-rk3588.conf
      content: |
        function pre_config_uboot_target__999_pxe_first() { ... }
        function pre_config_uboot_target__999_local_kernel_bake() {
            [[ "${BRANCH}" != "edge" ]] && return 0
            {% if armbian_board_config.local_kernel is defined %}
            local chain='setenv bootargs ... ext4load {{ armbian_board_config.local_kernel.storage }} ...'
            {% else %}
            return 0
            {% endif %}
            # ... bake into header ...
        }
        function pre_config_uboot_target__999_uboot_env_check() {
            local expected='{{ armbian_board_config.uboot_env.storage | default("") }}'
            # ... grep defconfig, compare ...
        }
        function extension_finish_config__999_no_bcmdhd_for_netboot() { ... }

# inventory/group_vars/rock_5b.yml — model
armbian_board_config_model:
  armbian_board_name: rock-5b
  dtb: rockchip/rk3588-rock-5b.dtb
  uboot_env:
    storage: spi_flash
    fw_env_config:
      device: /dev/mtd0
      offset: "0xc00000"
      size: "0x20000"
      sect_size: "0x1000"
    defaults: { pxefile_addr_r: "0x00500000", kernel_addr_r: "0x02080000", ... }

armbian_build_model:
  branch: edge
  userpatches:
    - dest: config/boards/rock-5b.conf
      content: |
        function post_family_config_branch_edge__999_rock5b_uboot_v2026_04() {
            [[ "${BOARD}" != "rock-5b" ]] && return 0
            [[ "${BRANCH}" != "edge" ]] && return 0
            declare -g BOOTBRANCH="tag:v2026.04"
            declare -g BOOTPATCHDIR="v2026.04"
        }

# inventory/host_vars/rock-5b-01.yml — host
armbian_board_mac: "aa:bb:cc:dd:ee:01"
armbian_boot_mode: local_kernel
armbian_local_kernel: { persist_via: hook }
armbian_local_disks: [ ... disk_provision DSL ... ]
armbian_poe_switch: switch
armbian_poe_port: ether4

# (optional) Host overrides hardware facts:
armbian_board_config_host:
  local_kernel:
    storage: "nvme 0:4"

armbian_build_host:
  userpatches:
    - dest: customize-image.sh
      content: |
        #!/bin/bash
        apt-get install -y tailscale
        tailscale up --authkey={{ vault_ts_key_rock_5b_01 }} --hostname=rock-5b-01
```

### Resolver output for rock-5b-01

```yaml
armbian_board_config:
  console: ttyS2,1500000n8
  earlycon: uart8250,mmio32,0xfeb50000
  armbian_board_name: rock-5b
  dtb: rockchip/rk3588-rock-5b.dtb
  local_kernel:
    storage: "nvme 0:4"             # host overrode family default
    storage_scan: "nvme scan"
  uboot_env:                         # model overrode family
    storage: spi_flash
    fw_env_config: { ... }
    defaults: { ... }

armbian_build:
  branch: edge                       # from model
  release: bookworm                  # from defaults
  ref: v26.2.0-trunk.844             # from defaults
  userpatches:
    - dest: config/sources/families/rockchip-rk3588.conf   # family (rendered with host facts)
      content: "..."
    - dest: config/boards/rock-5b.conf                     # model
      content: "..."
    - dest: customize-image.sh                              # host (vault inlined)
      content: "..."
  compile_args: { KERNEL_CONFIGURE: no, BUILD_DESKTOP: no, BUILD_MINIMAL: yes, ... }
  min_free_gb: 50
  timeout: 7200
```

### Adding a brand-new board (Banana Pi M7, rk3588)

Two edits to operator inventory; zero collection edits:

```yaml
# inventory/hosts.yml — add the host + add banana_pi_m7 as child of rk3588
boards:
  children:
    rk3588:
      children:
        rock_5b:
        banana_pi_m7:

banana_pi_m7:
  hosts:
    bpi-m7-01:
      ansible_host: 192.168.1.120
      armbian_board_mac: "..."
      armbian_board_model: banana-pi-m7
      armbian_boot_mode: nfs

# inventory/group_vars/banana_pi_m7.yml — declare model deltas
armbian_board_config_model:
  armbian_board_name: bananapim7
  dtb: rockchip/rk3588-bananapi-m7.dtb
  # console / earlycon / local_kernel / uboot_env inherited from rk3588 family
```

## 10. Migration sequencing

Clean break in one PR (project is 0.0.x, intentional breakage band).

1. **Land new primitives.** Add `roles/rootfs_provision/`, `vars/build_defaults.yml`, the three resolver task files. Old roles still exist, no callers changed. CI/molecule passes unchanged.
2. **Rewrite doc-inventory.** Add `inventory/group_vars/rk3588.yml` and `rk3588s.yml`. Migrate `inventory/group_vars/<model_group>.yml` files to `armbian_board_config_model` + `armbian_build_model` shape. Delete `vars/boards.yml`.
3. **Port playbooks.** `build_and_publish_from_inventory.yml`, `stage_netboot_assets.yml`, `stage_router.yml`, `converge_boot_mode.yml`, `persist_uboot_env.yml`, `provision_local_disk.yml`, `test_fleet_e2e.yml`, `test_hardware_e2e.yml`, `test_reprovision_e2e.yml` — all updated to consume resolved facts.
4. **Port roles.** `image_build` adds `armbian_build_host` + per-host suffix logic. `pxelinux_render` template + role vars rewritten. `disk_image` adds `armbian_disk_image_src` input.
5. **Delete superseded roles.** `roles/image_extract/`, `roles/rootfs_clone/`. Purge `armbian_image_urls` references.
6. **Docs.** CLAUDE.md updated. `adding-armbian-board` skill rewritten. `docs/boot-mode-override.md` adjusted for `armbian_board_config` references. README updated.
7. **Bump galaxy.yml.** 3.0.0 → 4.0.0 (signals the break per 0.0.x band conventions).

## 11. Testing strategy

- **Resolver unit tests.** Localhost-inventory molecule scenarios for `_resolve_board_config.yml` and `_resolve_build_profile.yml`. Pure transforms; easy to assert facts.
- **`rootfs_provision` molecule scenario.** Extends today's `image_extract` and `rootfs_clone` molecule coverage into a single combined scenario.
- **`playbooks/tests/test_build_and_publish_vars.yml`** ports to the new resolver outputs.
- **`test_fleet_e2e.yml`** is the integration safety net. Phase structure preserved; per-host paths shift. Re-run against the actual fleet is the real acceptance gate.

## 12. Open questions / explicit non-decisions

- **Default `armbian_build_cache_dir`** stays at `/var/lib/armbian_build` (pre-create + chown for ansible_user). An `inventory_dir`-relative default was considered but rejected because it breaks when builder ≠ controller (the path is controller-side; the builder must have it writable).
- **Build deduplication.** Explicitly out of scope — user chose pure per-host. A future spec could add profile-hash-based dedup if N hosts on identical profiles becomes a real cost.
- **Galaxy version bump.** 4.0.0 is suggested but the user has final say on numbering.
