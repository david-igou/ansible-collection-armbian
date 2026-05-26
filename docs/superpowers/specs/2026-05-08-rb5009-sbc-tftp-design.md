# rb5009-Hosted SBC TFTP — Design Spec

**Date:** 2026-05-08
**Status:** Drafted in response to infra change: TFTP for x86 PXE clients moved from netboot.xyz container (10.10.45.242, TrueNAS macvlan) to rb5009 (per-subnet IP). The new infra makes vlan9's `next-server=10.10.9.1`, which is incompatible with PR #31's preflight assertion (`next-server=tftp_server_ip=10.10.45.242`) and breaks the SBC v1 NFS-root path entirely.

## Problem

PR #31 (2026-05-07) restored the v1 PXE-first invariant by asserting that the SBC RouterOS network's `next-server` points at `tftp_server_ip=10.10.45.242` (the netboot.xyz container running on TrueNAS). The collection writes per-board `pxelinux.cfg/01-<MAC>` to that container's TFTP root over SSH; U-Boot's PXE bootmeth fetches the config + kernel/initrd/dtb from the container.

The new x86 PXE infrastructure (managed by `igou-ansible/playbooks/routeros/deploy_netboot_binaries.yml`) configures vlan9 with:

```
network 10.10.9.0/24:
  next-server   = 10.10.9.1            (rb5009)
  boot-file-name = netboot.xyz.kpxe    (BIOS default; UEFI overridden by option-93 matchers)

rb5009 /ip tftp serves:
  netboot.xyz.kpxe       (BIOS iPXE)
  netboot.xyz.efi        (UEFI x64 iPXE)
  netboot.xyz-arm64.efi  (UEFI arm64 iPXE)
  menu.ipxe              (TFTP-redirect: chain tftp://10.10.45.242/menu.ipxe)
```

The orange-pi cannot follow that iPXE chainload pipeline. U-Boot's PXE bootmeth does not execute `.kpxe` or `.efi` iPXE binaries — it does `pxelinux.cfg/*` discovery against BOOTP siaddr (the network's `next-server`). With `next-server=10.10.9.1`, U-Boot looks for `pxelinux.cfg/01-<MAC>` on rb5009. rb5009 only serves the iPXE binaries; no per-board pxelinux.cfg exists. The fetch 404s, U-Boot falls through to SD — *which is the disable behavior, not the enable behavior*. The NFS-root half of v1 is broken.

PR #31's preflight (`next-server == tftp_server_ip == 10.10.45.242`) fails structurally, and even if disabled, the underlying control-surface assumption is wrong: the collection writes pxelinux.cfg to a TFTP server the SBC no longer reaches.

## Constraint

`igou-ansible` owns vlan9's `next-server` and `boot-file-name` (network-level fields). This collection does not contend that ownership. Per-board state — pxelinux.cfg, kernel/initrd/dtb — is the collection's responsibility and must move to wherever the SBC's chosen TFTP server now lives. Given the new infra, that's rb5009.

rb5009 has 1 GB of flash with ~950 MB available. Per-board-model footprint is ~50–60 MB (vmlinuz ~12 MB, initrd.img ~30–50 MB, board.dtb ~50 KB), so option B (host all SBC TFTP content on rb5009) is feasible without external storage.

## Goal

Restore the SBC NFS-root path under the new infra by relocating the collection's TFTP content from the netboot.xyz container (TrueNAS) to rb5009. Preserve PR #31's "file presence is the load-bearing signal" semantics so the v1 invariant — DHCP-driven SD/NFS toggle, no on-board state — survives the relocation. Keep the implementation entirely within this collection (do not push SBC TFTP responsibilities into `igou-ansible`).

## Decisions

1. **The DHCP option-set on the static lease is dropped.** PR #31 retained `armbian-nfsroot` as a "ornamental but symmetric" toggle. With network-level `next-server` now owned externally and option 66/67 ignored by U-Boot's PXE bootmeth, the option-set has no boot effect. Removing it eliminates the vestigial RouterOS DHCP mutations from `enable_netboot.yml` / `disable_netboot.yml` and deletes `setup_routeros_dhcp.yml` outright. **File presence on rb5009 is the only control surface.**

2. **SBC TFTP content lives in `flash:/sbc/` as a sibling tree to `flash:/netboot/`.** Sibling layout (not nested under `flash:/netboot/`) keeps a clean ownership boundary against `igou-ansible`. Per-file `/ip tftp` rows mirror `igou-ansible`'s registration pattern — explicit, auditable, and known to work. No wildcards or `ip-addresses` scoping.

3. **Plumbing-check preflight replaces next-server preflight.** `igou-ansible` enforces `next-server` idempotently in its own deploy playbook; duplicating the check here adds noise without catching new failures. The new preflight asserts that rb5009 has the per-model `/ip tftp` rows registered before per-board operations run, with an actionable error message ("run `stage_netboot_assets.yml` first").

4. **The playbook + role rename to `stage_netboot_assets`.** The expanded scope (TrueNAS NFS rootfs + rb5009 TFTP files) makes `populate_nfs_content.yml` and `nfs_content` misleading. "Stage" describes idempotent two-host placement; "assets" aligns with `igou-ansible`'s vocabulary.

5. **No automated migration from PR #31 state.** The user is the only operator with PR #31's deployed artifacts. Migration is a documented manual cleanup (a few RouterOS commands plus an `rm -rf` on TrueNAS) — not worth a dedicated playbook.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Control node (Ansible)                       │
└────────────────────┬───────────────────────────┬─────────────────┘
                     │ SSH+become                │ network_cli
                     ▼                           ▼
   ┌────────────────────────────┐    ┌────────────────────────────┐
   │   netboot_server (TrueNAS) │    │       rb5009 (RouterOS)    │
   │                            │    │                            │
   │  /mnt/ssd/netboot/rootfs/  │    │  flash:/sbc/                │
   │   ├── _templates/<model>/  │    │   ├── pxelinux.cfg/01-<MAC>│
   │   └── <inventory_host>/    │    │   └── armbian/<model>/     │
   │   (NFS export)             │    │       ├── vmlinuz          │
   │                            │    │       ├── initrd.img       │
   │                            │    │       └── board.dtb        │
   │                            │    │                            │
   │                            │    │  /ip tftp rules per file   │
   └────────────────────────────┘    └────────────────────────────┘
                     ▲                           ▲
                     │ NFS rootfs (port 2049)    │ TFTP (port 69)
                     │                           │
                ┌────┴───────────────────────────┴────┐
                │       SBC (orange-pi-5-pro)         │
                │  U-Boot 2025.10 PXE bootmeth        │
                │   1. DHCP → siaddr=10.10.9.1        │
                │   2. TFTP pxelinux.cfg/01-<MAC>     │
                │   3. TFTP kernel + initrd + dtb     │
                │   4. Linux mounts NFS rootfs        │
                └─────────────────────────────────────┘
```

### Role responsibilities (post-design)

| Role | Owns |
|---|---|
| `armbian_build` | `.img.xz` published to TrueNAS HTTP. Unchanged. |
| `netboot_assets` (renamed from `nfs_content`) | Per-model rootfs template + per-host clones on TrueNAS NFS export. **New:** kernel/initrd/dtb fetched from TrueNAS to control-node cache, then `net_put` to rb5009 with `/ip tftp` row registration. |
| `routeros_dhcp` | **Reduced:** writes/removes per-board `pxelinux.cfg/01-<MAC>` on rb5009 + corresponding `/ip tftp` row. No DHCP option-set objects. No lease mutations. |
| `routeros_poe` | Unchanged. |
| `bootstrap_armbian`, `bootstrap_routeros_user` | Unchanged. |

### Removed

- `playbooks/setup_routeros_dhcp.yml` — deleted; option-set objects unnecessary.
- `roles/routeros_dhcp/tasks/preflight_next_server.yml` — replaced by `roles/netboot_assets/tasks/plumbing_check.yml`.
- DHCP option-set assignments on RouterOS leases (cleared as part of operator migration).

## Data flow per playbook

### `stage_netboot_assets.yml` (renamed from `populate_nfs_content.yml`)

```
Play 1: hosts: netboot_server (TrueNAS), become: true
  ├─ preflight: HEAD-check armbian_image_urls[<model>]
  ├─ download .img.xz to armbian_image_cache (existing)
  ├─ mount + extract _templates/<model>/ rootfs (existing)
  ├─ NEW: copy kernel/initrd/dtb from extracted tree to a known cache dir on TrueNAS
  │       (e.g. /mnt/ssd/netboot/cache/sbc-tftp/<model>/{vmlinuz,initrd.img,board.dtb})
  ├─ per-host clone via cp --reflink (existing)
  └─ NEW: ansible.builtin.fetch kernel/initrd/dtb to control-node cache
          ({{ playbook_dir }}/../.cache/sbc-tftp/<model>/)

Play 2: hosts: routeros_routers, gather_facts: false
  ├─ NEW: include_role netboot_assets, tasks_from: stage_rb5009.yml
  │       Per board model present in inventory:
  │         ├─ /file print count-only where name="sbc/armbian/<model>" type=directory
  │         ├─ /file add name=sbc/armbian/<model> type=directory   (if absent)
  │         ├─ For each of {vmlinuz, initrd.img, board.dtb}:
  │         │    ├─ /file print count-only where name=... and size=<local-size>
  │         │    ├─ net_put src=<local-cache>/<file>
  │         │    │           dest=sbc/armbian/<model>/<file>     (skip if size matches)
  │         │    └─ /ip tftp print count-only where req-filename=armbian/<model>/<file>
  │         │       /ip tftp add req-filename=...
  │         │                    real-filename=sbc/armbian/<model>/<file>
  │         │                    allow=yes read-only=yes          (if row absent)
  └─ NEW: plumbing_check.yml — assert /ip tftp rows for each {model, file} pair exist
```

### `enable_netboot.yml`

```
Play 1: hosts: routeros_routers, gather_facts: false
  ├─ Plumbing-check preflight (per target board's model):
  │   /ip tftp print count-only where req-filename=armbian/<model>/vmlinuz   (>=1 expected)
  │   fail_msg: "rb5009 has no per-model TFTP rows for <model>;
  │              run stage_netboot_assets.yml first."
  ├─ For each target board:
  │   ├─ Render pxelinux.cfg locally (template → control-node tempfile)
  │   ├─ /file print count-only where name=sbc/pxelinux.cfg type=directory
  │   ├─ /file add name=sbc/pxelinux.cfg type=directory          (if absent, once)
  │   ├─ /file print count-only where name=sbc/pxelinux.cfg/01-<MAC> and size=<local-size>
  │   ├─ net_put src=<local-rendered>
  │   │           dest=sbc/pxelinux.cfg/01-<MAC>                 (if size mismatch)
  │   ├─ /ip tftp print count-only where req-filename=pxelinux.cfg/01-<MAC>
  │   └─ /ip tftp add req-filename=pxelinux.cfg/01-<MAC>
  │                  real-filename=sbc/pxelinux.cfg/01-<MAC>
  │                  allow=yes read-only=yes                     (if row absent)

Play 2: hosts: <target_hosts>, gather_facts: false
  └─ reboot trigger (existing pattern; issue #34's async fragility unchanged)
```

### `disable_netboot.yml`

```
Play 1: hosts: routeros_routers, gather_facts: false
  ├─ For each target board:
  │   ├─ /ip tftp print count-only where req-filename=pxelinux.cfg/01-<MAC>
  │   ├─ /ip tftp remove [find req-filename=pxelinux.cfg/01-<MAC>]   (row first)
  │   ├─ /file print count-only where name=sbc/pxelinux.cfg/01-<MAC>
  │   └─ /file remove [find name=sbc/pxelinux.cfg/01-<MAC>]          (then file)

Play 2: hosts: <target_hosts>, gather_facts: false
  └─ reboot trigger (same pattern as enable)
```

`/ip tftp remove` happens *before* `/file remove` so that mid-teardown failures fail closed: a request for a still-present file won't be served once the row is gone.

### Rendering pxelinux.cfg

The current template renders directly via SSH to a TrueNAS path. The new flow renders locally then `net_put`s:

1. `ansible.builtin.template` (or `copy: content="{{ lookup('template', 'pxelinux_cfg.j2') }}"`) → control-node tempfile.
2. `net_put` from tempfile to `sbc/pxelinux.cfg/01-<MAC>` on rb5009.
3. `/ip tftp add` row.

The template body itself (`roles/routeros_dhcp/templates/pxelinux_cfg.j2`) is unchanged — paths inside (`KERNEL armbian/<model>/vmlinuz`, etc.) are TFTP-relative and resolve against rb5009's serving root (`flash:/sbc/`) via the per-file `/ip tftp` rules.

## Variable model

### Removed

| Variable | Was used by | Why removable |
|---|---|---|
| `tftp_server_ip` | Old preflight (next-server check), old `setup_routeros_dhcp.yml` (option 66 value) | Both consumers gone. pxelinux.cfg only references `nfs_server_ip`. |
| `tftp_nfs_export` | Old `write_pxelinux_cfg.yml` (TrueNAS file path) | TFTP root moves to rb5009; this TrueNAS-rooted path is dead. |
| `routeros_sbc_network_address` | Old preflight (find subnet by CIDR) | Plumbing-check preflight queries `/ip tftp` rows, not network rows. |
| `routeros_dhcp_server_name` | Old `setup_routeros_dhcp.yml` + lease mutations | Collection no longer mutates DHCP server / lease state. |

### Added

| Variable | Default | Used by | Purpose |
|---|---|---|---|
| `sbc_tftp_flash_dir` | `"sbc"` | `netboot_assets`, `routeros_dhcp` | Top-level dir on rb5009's flash. Used in `/file add name=…` and `real-filename=…` paths. |
| `sbc_tftp_cache_dir` | `"{{ playbook_dir }}/../.cache/sbc-tftp"` | `netboot_assets` | Control-node cache for kernel/initrd/dtb fetched from TrueNAS. Gitignored. |

Both live in `roles/netboot_assets/defaults/main.yml`. `inventory/group_vars/all.yml` documents them as override-rare.

### Unchanged

`netboot_server_ip`, `nfs_server_ip`, `nfs_rootfs_path`, `nfs_assets_export`, `armbian_image_urls`, `armbian_default_password`, `armbian_branch`.

### Inventory impact

`inventory/hosts.yml` (sample) and `.inventory/hosts.yml` (real): no structural changes. `routeros_routers` still contains rb5009; the collection treats it as the SBC TFTP server transparently. No new groups.

The "Split-host topology" comment in `inventory/group_vars/all.yml` needs rewording: TFTP for SBCs is now on rb5009 (per-subnet IP, e.g. 10.10.9.1 for vlan9); NFS rootfs remains on TrueNAS at 10.10.9.213.

## Failure handling and idempotency

### Idempotency primitives

Every state-mutating step is gated on a count or size check, mirroring `igou-ansible/playbooks/routeros/tasks/netboot_upload.yml`:

| Resource | Idempotency gate |
|---|---|
| Directory on rb5009 | `/file print count-only where name="<dir>" and type=directory` → `add` if zero |
| File on rb5009 | `/file print count-only where name="<path>" and size=<local-size>` → `net_put` if zero |
| `/ip tftp` row | `/ip tftp print count-only where req-filename="<X>" and real-filename="<Y>"` → `add` if zero |

Re-runs land as `ok=N changed=0`.

### Refresh detection

When `armbian_image_urls[<model>]` is bumped to a new image release, the new kernel/initrd/dtb have different sizes; the size-match gate triggers a re-upload automatically. No hash file or manifest needed at this layer. Edge case: an upstream image with identical kernel size to a prior version (vanishingly unlikely for kernels) would not trigger refresh — addressable post-v1 by switching the gate to a SHA256 stored in `/file print` `comment` field.

### Partial-failure recovery

| Scenario | Outcome | Recovery |
|---|---|---|
| `net_put` succeeds but `/ip tftp add` fails | File on flash, no row → not served | Re-run: file size matches (skip); row count zero (add). Self-heals. |
| `/ip tftp remove` succeeds but `/file remove` fails | Orphaned file, no row | Re-running `disable_netboot` retries file removal. ~50 KB orphan worst case. |
| `disable_netboot` interrupted mid-teardown | Same as above (fail-closed by row-first ordering) | Re-run completes idempotently. |

### Reachability failures

| Host unreachable | Failure surface | Recovery |
|---|---|---|
| TrueNAS (`netboot_server`) | `stage_netboot_assets.yml` Play 1 | Fix host, re-run; idempotent. |
| rb5009 (`routeros_routers`) | All three playbooks' RouterOS plays | Fix host, re-run; idempotent. |
| Control node mid-fetch | Local cache half-populated | Re-run `stage_netboot_assets.yml`; `fetch` overwrites. |

### Plumbing-check preflight

In `roles/netboot_assets/tasks/plumbing_check.yml`:

```yaml
For each (board_model, file ∈ {vmlinuz, initrd.img, board.dtb}):
  - /ip tftp print count-only where req-filename="armbian/<model>/<file>"
  - assert count >= 1
  - fail_msg: "rb5009 has no TFTP row for armbian/<model>/<file>.
               Run stage_netboot_assets.yml first to populate per-model assets."
```

Called from:
- End of `stage_netboot_assets.yml` Play 2 (verifies the `/ip tftp` rows landed; redundant but cheap).
- Start of `enable_netboot.yml` Play 1 (catches "operator forgot to stage assets first").

### Coordination with `igou-ansible`'s iPXE rules

`/ip tftp` namespace separation by construction:

| Owner | `req-filename` patterns |
|---|---|
| `igou-ansible` | `netboot.xyz.kpxe`, `netboot.xyz.efi`, `netboot.xyz-arm64.efi`, `menu.ipxe` |
| This collection | `pxelinux.cfg/01-<MAC>`, `armbian/<model>/{vmlinuz,initrd.img,board.dtb}` |

`flash:/` filesystem also non-overlapping: `flash:/netboot/` (igou-ansible) vs `flash:/sbc/` (this collection). `disable_netboot` removes only rows matching its own `req-filename` patterns.

### Concurrency

RouterOS API serialises `/ip tftp` and `/file` mutations. Concurrent runs of this collection or against `igou-ansible` are safe given namespace separation.

### Out of scope for failure handling

- rb5009 flash exhaustion check / proactive cleanup of unused per-model assets (post-v1).
- `/file remove` retry middleware for transient RouterOS errors (add if observed).
- Issue #34 (`async:1 poll:0` reboot fragility) — unchanged from PR #31; tracked separately.

## Migration (operator-run, once)

PR #31's deployed artifacts on the user's infra:
1. RouterOS DHCP option-set `armbian-nfsroot` + sub-options `armbian-tftp-server`, `armbian-nfsroot-bootfile`.
2. Per-lease `dhcp-option-set=armbian-nfsroot` assignments on any board enabled via PR #31's `enable_netboot.yml`.
3. Per-board `pxelinux.cfg/01-<MAC>` files on TrueNAS at `/mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/`.
4. Per-model `armbian/<model>/{vmlinuz,initrd.img,board.dtb}` on TrueNAS at the same TFTP root.

Manual cleanup (one-time, before deploying this design):

```bash
# On rb5009 (interactive)
/ip dhcp-server lease set [find dhcp-option-set=armbian-nfsroot] dhcp-option-set=""
/ip dhcp-server option/sets remove [find name=armbian-nfsroot]
/ip dhcp-server option remove [find name~"^armbian-"]

# On TrueNAS
sudo rm -rf /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/01-*
sudo rm -rf /mnt/ssd/containers/netbootxyz/config/menus/armbian/orange-pi-5-pro/
```

Verification:

```bash
# On rb5009
/ip dhcp-server lease print where dhcp-option-set=armbian-nfsroot   # expect: empty
/ip dhcp-server option print where name~"armbian"                   # expect: empty

# On TrueNAS
ls /mnt/ssd/containers/netbootxyz/config/menus/pxelinux.cfg/        # expect: ENOENT or empty
ls /mnt/ssd/containers/netbootxyz/config/menus/armbian/             # expect: ENOENT or empty
```

After verification, run `stage_netboot_assets.yml` from a clean slate.

## Testing

### Hardware-loop tests

`playbooks/test_hardware_e2e.yml` already cycles a board through SD → NFS → SD and asserts each transition by inspecting board state (SSH `cat /proc/cmdline`, `findmnt /`). The harness inspects neither RouterOS nor rb5009 plumbing, so it works unchanged post-refactor.

What needs hardware verification:

| Behavior | Verification |
|---|---|
| `stage_netboot_assets.yml` populates rb5009 idempotently | Run twice; second run = `changed=0`. `tftp 10.10.9.1 -c get armbian/orange-pi-5-pro/vmlinuz` from any LAN host succeeds. |
| `enable_netboot.yml` writes per-board pxelinux.cfg + row | Post-run `tftp 10.10.9.1 -c get pxelinux.cfg/01-<MAC>` returns the rendered config. |
| Board boots via NFS-root after enable | `test_hardware_e2e.yml` assertion: post-reboot SSH lands; `findmnt /` reports `nfs`. |
| `disable_netboot.yml` removes both row and file | Post-run `tftp 10.10.9.1 -c get pxelinux.cfg/01-<MAC>` returns `error 1: cannot read file`. |
| Board falls through to SD after disable | `findmnt /` reports the SD rootfs fstype. |
| iPXE chain unchanged for x86 PXE | Boot any x86 PXE laptop on vlan9; should land on netboot.xyz menu unchanged (no regression in `igou-ansible`'s territory). |

### Unit-ish

- `ansible-lint --profile=production` on the renamed role + playbook.
- `yamllint` on edited files.
- No molecule scenarios. Molecule against RouterOS is high-effort relative to the hardware loop's signal.

### Out of scope

- TFTP fetch latency under load.
- rb5009 flash exhaustion testing.
- Multi-board parallel enable_netboot (works by construction; not separately tested).
- Multi-VLAN SBC distribution (post-v1).

## Open questions deferred to implementation

- Exact form of the local-render-then-net_put pattern for pxelinux.cfg (`copy: content=…` from a template lookup, vs `template: dest=<tempfile>`). Either works; pick the cleaner one during implementation.
- Whether to keep a kernel/initrd/dtb cache on TrueNAS post-fetch, or delete it after `ansible.builtin.fetch` succeeds. Default: keep, gated by a `sbc_tftp_truenas_cache_keep` toggle so the next run can short-circuit the extract step. Decide during implementation.

## References

- PR #31 (the collection's prior NFS-root invariant restoration): https://github.com/david-igou/ansible-collection-armbian/pull/31
- igou-ansible's iPXE chainload deploy: `playbooks/routeros/deploy_netboot_binaries.yml`
- igou-ansible's parallel asset-management spec: `docs/superpowers/specs/2026-05-08-netboot-asset-management-design.md`
- Bootflow PXE-first design (the upstream invariant this design preserves): `docs/superpowers/specs/2026-05-07-bootflow-pxe-first-design.md`
- Followup issues: #32 (TFTP perm bug — narrowed in scope; iPXE chainload still affected), #33 (macvlan host-isolation), #34 (async reboot fragility — unchanged scope).
