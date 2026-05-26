# Disk Provision DSL + Headless Local-Boot Lifecycle — Design

**Status**: Brainstormed, awaiting user spec review.
**Tracking issue**: [#77](https://github.com/david-igou/ansible-collection-armbian/issues/77).
**Related issues**: [#78](https://github.com/david-igou/ansible-collection-armbian/issues/78) (kernel updates — modules-sync cross-link), [#79](https://github.com/david-igou/ansible-collection-armbian/issues/79) (k3s example — direct consumer).
**Author**: David Igou.
**Date**: 2026-05-17.

## Background

The `disk_provision` role and `provision_local_disk.yml` playbook landed as a PoC in v3.1.0. They wipe a single disk, make one GPT partition spanning the disk, format it ext4, and rsync the running `/` onto it. Limitations:

- Partition layout is hardcoded to a single ext4 partition. No `/var`, no `/boot`, no ESP, no multi-disk hosts.
- The full lifecycle (boot to NFS → wipe → partition → format → rsync → flip pxelinux → cold boot → verify) is operator-driven via separate playbook invocations.
- Recovery from a failed local boot is manual — operator must run `set_boot_mode.yml -e armbian_boot_mode=nfs` to revive the board.

This spec promotes both concerns to first-class features:
1. A declarative partitioning DSL expressed inline per host.
2. A single headless lifecycle playbook with automatic recovery.
3. Custom user-defined boot modes (e.g. `usb_rescue`) coexisting in the same `pxelinux.cfg`.

## Goals / non-goals

**Goals**
- Inventory-declared multi-partition layouts: ESP, `/boot`, `/var`, `/`.
- Per-host multi-disk support (list of disk bindings; iterate per-disk).
- `/var` (or any labeled partition) preservation across re-provisions — idempotency keyed on filesystem label.
- Single playbook (`reprovision_to_local.yml`) takes a board from any mode to verified local-disk boot.
- Automatic revert to `nfs` mode on local-boot failure, with diagnostic capture before revert.
- User-defined named boot modes (e.g. `usb_rescue`) in `pxelinux.cfg`, alongside the built-in `nfs`/`sd`/`local`.
- Composable with existing roles (`pxelinux_render`, `board_boot_wait`, `board_boot_verify`) and RouterOS reference playbooks.

**Non-goals (v1)**
- LVM-on-LUKS, mdadm mirrors, ZFS root, encrypted root. Schema leaves a door open; implementation does not ship them.
- Named layout library (`vars/disk_layouts.yml`) or preset+override system. Board quirkiness (varying device names, varying disk presence) makes shared layouts a false economy. Layouts stay inline per-host.
- Multi-disk striping or tiered storage.
- Online migration. Always offline, reboot-mediated.
- Snapshotting / rollback of preserved partitions across re-provisions.
- Writing U-Boot SPL+main to the local disk so the SD/SPI can be removed (passthrough boot model requires PXE, which requires U-Boot on SD/SPI; out of scope).
- Disk selectors (e.g. `transport: nvme`). Inventory uses explicit `/dev/<path>` per host.

## Boot model: passthrough (settled)

`armbian_boot_mode: local` does **not** mean `localboot 0`. Mechanically:

- SD/SPI carries U-Boot. PXE-first ordering is patched into U-Boot by `image_build`.
- U-Boot performs PXE on every boot. `pxelinux.cfg/01-<MAC>` is fetched from rb5009 over TFTP.
- The `default <mode>` directive selects which `LABEL` fires.
- All labels (`nfs`, `sd`, `local`, custom) load the **same** kernel/initrd/dtb from TFTP. Only the `append root=...` clause differs:
  - `nfs`: `root=/dev/nfs nfsroot=<server>:<path>/<host>,nfsvers=3,rw ip=dhcp`
  - `sd`: `root=LABEL=armbi_root` (the SD's label)
  - `local`: `root=LABEL=armbi_root_local` (the locally-provisioned partition)
  - custom: `root=<user-supplied>` from `armbian_extra_modes[<name>].root`

Implication for `disk_provision`: `/boot` on the local disk is **not** on the boot path. Boot artifacts (kernel/initrd/dtb) come from TFTP. The role still rsyncs `/boot` onto the local disk so future `apt update-initramfs` runs produce coherent state, but boot doesn't read it.

Implication for #78: kernel updates land in TFTP; modules sync into per-host NFS clones (existing #78 work) **and** must also sync into local-disk rootfses. Modules-on-local-disk sync is a documented follow-up requirement in #78's MVP acceptance criteria.

## Architecture

Three role changes, one new playbook:

| Role | Change | Responsibility |
|---|---|---|
| `disk_provision` | Refactored | Given one disk binding (device + layout list + preserved labels), validate, render `.repart.d/*.conf`, invoke `systemd-repart`, mount, rsync source, write fstab, rewrite extlinux.conf, unmount. Single-disk contract; playbook loops over multi-disk bindings. |
| `pxelinux_render` | Modified | Template loops over `{nfs, sd, local} ∪ keys(armbian_extra_modes)`. `boot_mode` value validates against the union. |
| `board_boot_verify` | Light touch | Gains optional `verify_match: <pattern>` field per custom mode; asserts `ansible_mounts['/']['device']` matches when mode is custom. Built-in modes keep existing behavior. |

New playbook: `playbooks/reprovision_to_local.yml`.

### Component flow

```
[ INVENTORY ]                              [ ROLES ON THE BOARD ]              [ ON-BOARD STATE ]
armbian_local_disks:               ────────────────────────             ──────────────────
  - device: /dev/nvme0n1                   role: disk_provision                 /dev/nvme0n1
    wipe: true                             ────────────────────                 ├─ p1  ESP   (vfat,  armbi_esp)
    layout:                                For each disk in playbook loop:      ├─ p2  boot  (ext4,  armbi_boot)
      - {id: esp, ...}                       1. Validate                        ├─ p3  var   (ext4,  armbi_var) ← preserved
      - {id: boot, ...}                      2. Render .repart.d/*.conf         └─ p4  root  (ext4,  armbi_root_local)
      - {id: var, ...,                       3. Pre-scan preserved labels
          preserve_on_reprovision: true}     4. systemd-repart --empty=force
      - {id: root, ...}                      5. Mount in dep order
                                             6. rsync source → mounts
armbian_boot_mode: local                 with preserve excludes
                                             7. Write /etc/fstab (LABEL= refs)
armbian_extra_modes:                 8. Rewrite extlinux.conf root=
  usb_rescue:                                9. sync; umount
    menu_label: "USB rescue rootfs"
    root: "LABEL=rescue_root"               role: pxelinux_render (MODIFIED)
    rootfstype: ext4                        ──────────────────────────────
                                            Emits labels for
                                            {nfs, sd, local} + extra_modes;
                                            boot_mode value validates
                                            against the union.

                                            role: board_boot_verify (LIGHT TOUCH)
                                            ────────────────────────────────
                                            For custom modes, asserts
                                            ansible_mounts['/'].source matches
                                            verify_match pattern.

[ ORCHESTRATION ]
playbooks/reprovision_to_local.yml
─────────────────────────────────
1. set_boot_mode → nfs                     (router-side + board cycle+wait)
2. Assert / is on NFS                      (on board)
3. Loop: disk_provision per disk binding   (on board, NFS-rooted)
4. set_boot_mode → local                   (router-side + board cycle+wait+verify)
5. rescue: diagnostic capture + revert to nfs
```

Single-responsibility per role; transport-agnostic (no RouterOS knowledge in any role). RouterOS interactions stay in the existing reference playbooks under `playbooks/routeros/`.

## DSL

### Inventory schema

```yaml
# host_vars/<board>.yml
armbian_local_disks:
  - device: /dev/nvme0n1          # required, absolute, whole-disk
    wipe: true                    # optional, default true; set false to no-op-on-mismatch (debug)
    force: false                  # optional, default false; bypasses preserve idempotency
    layout:                       # required, list of partition specs
      - id: esp                   # required, unique within this disk's layout
        size: 512MiB              # required; supports MiB|GiB|TiB and 'grow'
        type: esp                 # required; values: esp | linux | root | var | home | srv | swap
        format: vfat              # required; values: vfat | ext4 | xfs | btrfs | swap
        label: armbi_esp          # required when preserve_on_reprovision is true; recommended otherwise
        mount: /boot/efi          # optional; path written into /etc/fstab if set
        mount_opts: defaults,noatime   # optional; default per-fstype
        preserve_on_reprovision: false # optional; default false
      - id: boot
        size: 1GiB
        type: linux
        format: ext4
        label: armbi_boot
        mount: /boot
      - id: var
        size: 20GiB
        type: var
        format: ext4
        label: armbi_var
        mount: /var
        preserve_on_reprovision: true
      - id: root
        size: grow                # exactly one partition per disk may use 'grow'
        type: root
        format: ext4
        label: armbi_root_local
        mount: /
```

Custom boot modes (independent of disks, may be set globally or per-host):

```yaml
# group_vars/all.yml or host_vars/<board>.yml
armbian_extra_modes:
  usb_rescue:
    menu_label: "USB rescue rootfs"   # required, free-form string
    root: "LABEL=rescue_root"          # required, kernel cmdline root= value
    rootfstype: ext4                   # optional, default ext4
    extra_append: ""                   # optional, extra kernel cmdline params
    verify_match: "^/dev/[sn]"         # optional, regex board_boot_verify uses
                                       # to assert ansible_mounts['/'].device
```

### systemd-repart translation

Each layout entry becomes one `.repart.d/NN-<id>.conf` file at `/run/disk_provision/<device-id>/repart.d/`:

```ini
# 10-esp.conf
[Partition]
Type=esp
Label=armbi_esp
Format=vfat
SizeMinBytes=512M
SizeMaxBytes=512M

# 40-root.conf (grow case)
[Partition]
Type=root
Label=armbi_root_local
Format=ext4
SizeMinBytes=4G
# no SizeMaxBytes → grows to fill remaining space
```

`Type=root` resolves to the architecture-appropriate GPT GUID (`root-arm64` on our boards) via systemd-repart's `Type=root` shorthand. `Type=var` → `var`. ESP → `esp`. `Label=` controls the filesystem label (which is what we match on for preserve idempotency). Numeric prefix on filenames controls partition order on disk.

### Generated `/etc/fstab`

```
# Generated by david_igou.armbian disk_provision role.
# Do not edit; re-run reprovision_to_local.yml to change.

LABEL=armbi_root_local  /          ext4  defaults,noatime  0 1
LABEL=armbi_boot        /boot      ext4  defaults,noatime  0 2
LABEL=armbi_esp         /boot/efi  vfat  defaults,noatime  0 2
LABEL=armbi_var         /var       ext4  defaults,noatime  0 2
```

Order: root first; deeper mount paths after their parents. Always `LABEL=` references — never `UUID=` or `/dev/<path>` (labels are the idempotency key and the kernel cmdline root= reference).

### Rendered `pxelinux.cfg` with custom mode

```
# pxelinux.cfg for orange-pi-5-pro-01 (orange-pi-5-pro)
# MAC: aa:bb:cc:dd:ee:11
# Active mode: local
# Generated by Ansible — do not edit manually.

default local
timeout 50
prompt  0

label nfs
  menu label Armbian NFS root (orange-pi-5-pro-01)
  kernel armbian/orange-pi-5-pro/vmlinuz
  initrd armbian/orange-pi-5-pro/initrd.img
  fdt    armbian/orange-pi-5-pro/board.dtb
  append root=/dev/nfs nfsroot=10.10.9.213:/mnt/ssd/netboot/rootfs/orange-pi-5-pro-01,nfsvers=3,rw ip=dhcp console=ttyS2,1500000n8 rootwait rw

label sd
  menu label Armbian on SD (orange-pi-5-pro-01)
  kernel armbian/orange-pi-5-pro/vmlinuz
  initrd armbian/orange-pi-5-pro/initrd.img
  fdt    armbian/orange-pi-5-pro/board.dtb
  append root=LABEL=armbi_root rootfstype=ext4 rootwait rw console=ttyS2,1500000n8

label local
  menu label Armbian on local disk (orange-pi-5-pro-01)
  kernel armbian/orange-pi-5-pro/vmlinuz
  initrd armbian/orange-pi-5-pro/initrd.img
  fdt    armbian/orange-pi-5-pro/board.dtb
  append root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000n8

label usb_rescue
  menu label USB rescue rootfs (orange-pi-5-pro-01)
  kernel armbian/orange-pi-5-pro/vmlinuz
  initrd armbian/orange-pi-5-pro/initrd.img
  fdt    armbian/orange-pi-5-pro/board.dtb
  append root=LABEL=rescue_root rootfstype=ext4 rootwait rw console=ttyS2,1500000n8
```

`localboot 0` does not appear anywhere. All labels load kernel/initrd/dtb from TFTP. Only `append root=...` differs.

## `disk_provision` algorithm (per disk binding)

1. **Validate**:
   - `device` exists, is block, is whole-disk (not partition).
   - `_root_source` (from `findmnt`) does not start with `device` — refuse to wipe booted-from disk (already in v3.1.0).
   - No two disks in `armbian_local_disks` declare the same mount path.
   - Every `preserve_on_reprovision: true` partition has a non-empty `label`.
   - Every `mount` value is an absolute path.
   - Exactly one partition across all disks declares `mount: /`.
2. **Render** `.repart.d/*.conf` files at `/run/disk_provision/<device-id>/repart.d/`.
3. **Pre-scan preserved labels**: for each `preserve_on_reprovision: true` entry, `lsblk -no LABEL <derived-partition-path>`; if the label matches, mark that slot as "skip" in the repart invocation (via separate `Type=root` matching, or by generating a sentinel that `disk_provision`'s post-repart logic respects).
4. **Invoke systemd-repart**: `systemd-repart --definitions=<dir> --empty=force --dry-run=no --discard=yes <device>`. Preserved slots are skipped per step 3.
5. **Mount filesystems** in dependency order (root first, then deeper paths) at temporary mount points under `/var/lib/armbian/disk_provision_mnt/`.
6. **rsync** source (`source` argument, default `/`) into the mounted root, with:
   - `-aAX --numeric-ids --one-file-system --delete`
   - excludes for `/dev/*`, `/proc/*`, `/sys/*`, `/run/*`, `/tmp/*`, `/mnt/*`, `/media/*`, `/var/log/journal`
   - additional excludes for every preserved partition's `mount` path
7. **Re-create empty virtual mountpoints** on the target (`/dev`, `/proc`, `/sys`, `/run`, `/tmp`, `/mnt`, `/media`) — existing v3.1.0 behavior.
8. **Write `/etc/fstab`** from template (LABEL= refs only, root first, deeper paths after).
9. **Rewrite `/boot/extlinux/extlinux.conf`** if present: substitute `root=` to point at the local root label. Belt-and-braces; not on the boot path under passthrough boot model.
10. **`sync`; unmount in reverse order**.

`force: true` per-binding bypasses idempotency (including preserve checks). Intentional escape hatch.

## Lifecycle: `reprovision_to_local.yml`

```yaml
---
- name: Boot board into NFS so we can safely wipe local disk
  import_playbook: set_boot_mode.yml
  vars:
    armbian_boot_mode: nfs
    target_hosts: "{{ target_hosts }}"

- name: Provision each local disk from NFS rootfs source
  hosts: "{{ target_hosts }}"
  gather_facts: true
  gather_subset: [mounts]
  pre_tasks:
    - name: Assert / is on NFS
      assert:
        that: >-
          ansible_mounts | selectattr('mount', 'equalto', '/')
          | map(attribute='fstype') | first in ['nfs', 'nfs4']
        fail_msg: "Board must be NFS-booted before reprovisioning local disks."
  tasks:
    - name: Provision each disk
      include_role:
        name: disk_provision
      vars:
        disk_binding: "{{ item }}"
      loop: "{{ armbian_local_disks }}"

- name: Flip pxelinux to local and verify
  import_playbook: tasks/_lifecycle_set_and_verify.yml
  vars:
    armbian_boot_mode: local
    target_hosts: "{{ target_hosts }}"
    on_failure_revert_to: nfs
```

`tasks/_lifecycle_set_and_verify.yml` is a new internal helper that wraps the set + verify + auto-revert pattern. It uses `block/rescue` over `include_tasks` (not `import_playbook`, which can't appear inside a block). The existing `set_boot_mode.yml` is also refactored: its body moves to `playbooks/tasks/_set_boot_mode.yml` (includable), and `set_boot_mode.yml` becomes a thin wrapper.

### Recovery path

If the local-mode cold boot fails (`cold_boot_with_retry`'s timeout expires, or `board_boot_verify` fails to assert local rootfs):

1. Capture diagnostic bundle via `tasks/diagnostic_bundle.yml`: `findmnt --json`, `/proc/cmdline`, `lsblk -O --json`, `journalctl -k -n 500`, `journalctl -b -n 1000`, last 200 lines of UART if `-e capture_serial=true`. Bundle persisted to `./diagnostics/<host>-<timestamp>/`.
2. Auto-revert: set boot mode to `nfs`, render+upload+cycle, verify board is healthy on NFS.
3. Fail the playbook with a message pointing at the captured bundle.

## Pre-flight validation summary

| Check | When |
|---|---|
| `device` starts with `/dev/`, whole-disk | Disk binding entry |
| `stat(device).isblk` | Disk binding entry |
| `_root_source` not on `device` | Disk binding entry |
| No mount-path collisions across disks | Across full `armbian_local_disks` list |
| `preserve_on_reprovision` partitions have non-empty `label` | Per partition |
| `mount` is absolute path | Per partition |
| Exactly one `mount: /` across all disks | Across full list |
| `boot_mode` ∈ `{nfs, sd, local} ∪ keys(armbian_extra_modes)` | Top of `pxelinux_render` |

All validations run before any destructive operation. Failures abort the playbook before partition tables touch.

## Idempotency rules

| Disk state | Action |
|---|---|
| Empty or wrong layout | Full provision (`systemd-repart --empty=force`) |
| Matches layout, no preserved partitions | Full provision (rsync refresh) |
| Matches layout with preserved partitions | Full provision skipping preserved slots; rsync excludes preserved mount paths |
| `force: true` (per-disk binding) | Full provision unconditionally — preserved partitions also wiped |

## Cross-link with #78

#78 (kernel updates) maintains per-host NFS clone's `/lib/modules/<ver>/` in lock-step with the TFTP'd kernel. Local-disk rootfses created by `disk_provision` carry their own `/lib/modules/<ver>/` (rsynced from the NFS source at provision time). Once #78 lands and template-side kernel updates produce a new version, every local-disk host's `/lib/modules/<old-ver>/` will be stale.

Resolution: #78's `update_kernel.yml` playbook gains a final step that walks `armbian_local_disks` for every host and rsyncs `/lib/modules/<new-ver>/` from the NFS source (or from the staging template) into the local-disk rootfs. Documented in #78's MVP acceptance criteria; not implemented as part of this spec.

Until #78 lands, kernel updates remain image-rebuild-driven; the rebuild → re-template → re-clone path naturally refreshes the NFS clone, but local-disk hosts require a manual `rsync /lib/modules/` step after each kernel bump.

## Testing strategy

Four layers, matching the collection's existing molecule + hardware E2E structure:

### Layer 1 — Pure layout rendering (molecule, podman)

`extensions/molecule/disk_provision_render/`. Run `disk_provision` with a render-only flag; verify `.repart.d/*.conf` files match fixture content. No block devices.

Fixtures cover: single-root, full ESP+boot+var+root, single partition with `grow`, two partitions with one preserved.

Negative tests: missing label on preserved partition, mount-path collision, non-absolute mount path, two `mount: /` partitions.

### Layer 2 — Real systemd-repart against loopback (molecule, podman privileged)

`extensions/molecule/disk_provision_loopback/`. Create sparse file, attach via `losetup`, run `disk_provision` against the loop device.

Verify: `lsblk -no NAME,FSTYPE,LABEL,SIZE` matches expected; preserved-partition idempotency (mtime survives re-run); `force: true` bypasses preserve.

CI risk: `losetup` in privileged podman is the same hazard that kept `image_extract` out of molecule. First-class attempt; fall back to hardware-only if CI proves flaky.

### Layer 3 — Extended pxelinux_render scenario (molecule, podman)

Extend `extensions/molecule/pxelinux_render/`:
- `boot_mode: local` with default `local_root` → assert `default local` + `append root=LABEL=armbi_root_local`
- `boot_mode: usb_rescue` with custom mode → assert extra label rendered
- `boot_mode: nonexistent_mode` → assert role fails fast

### Layer 4 — Hardware E2E (real board: orange-pi-5-max)

New `playbooks/test_reprovision_e2e.yml` modeled on `test_hardware_e2e.yml`. Canonical test target is `orange-pi-5-max-01` (the orangepi5-max bring-up board from v3.1.0, #76) — it has NVMe, is PoE-powered, and is already wired through the existing hardware E2E plumbing. Other boards may run the same playbook with `--limit`, but CI / acceptance defaults to orange-pi-5-max.

```
nfs (assert) → reprovision_to_local → local (assert findmnt / matches armbi_root_local)
            → re-run reprovision_to_local (no destructive change, preserved survives)
            → set_boot_mode → nfs (assert) → set_boot_mode → local (assert local rootfs intact)
            → cleanup: set_boot_mode → nfs
```

`-e leave_state=true` preserves failure state. `-e capture_serial=true` tails UART.

The board's inventory needs `armbian_local_disks` configured with the full ESP+boot+var+root layout (see DSL section above), `armbian_poe_switch` / `armbian_poe_port` set, and `armbian_boot_mode: local` declared so the test exercises the canonical path. A second pass in the test re-runs `reprovision_to_local.yml` to assert idempotency on the preserved `/var` partition.

## Open questions deferred to writing-plans

1. Exact mechanism for `disk_provision` to communicate "skip this slot in repart" — either generate a separate sentinel that the role respects post-repart, or use systemd-repart's existing matching predicates (`MatchPartitionType=`/`MatchLabel=`).
2. `set_boot_mode.yml` refactor mechanics (extract body to `tasks/_set_boot_mode.yml`, keep the playbook as thin wrapper) — verify no callers break.
3. Device-id derivation for `/run/disk_provision/<device-id>/`: `basename` of `device` is sufficient; verify no collisions when two disks have similar names.
4. `verify_match` patterns for built-in modes — `ansible_mounts['/'].device` is the resolved source (NFS as `server:/path`; local as `/dev/<name>`), not the `LABEL=` form. Inspect actual fact output on real hardware before pinning patterns; built-in modes (nfs/sd/local) keep existing `board_boot_verify` behavior, custom modes get the user-supplied pattern.

## MVP acceptance criteria

1. `armbian_local_disks` accepted as a list of disk bindings; each binding supports `esp`, `boot`, `var`, `root` partition types with sizes in `MiB|GiB|grow` and `preserve_on_reprovision: true` on any labeled partition.
2. `disk_provision` refactored to consume the inline DSL via systemd-repart; preserves matching-label partitions across re-runs.
3. `pxelinux_render` emits labels for `{nfs, sd, local}` plus every key in `armbian_extra_modes`; `boot_mode` value validates against the union.
4. `board_boot_verify` supports `verify_match` per custom mode.
5. `playbooks/reprovision_to_local.yml` runs end-to-end on a single board with `--limit`, leaves the board cold-booted on its local disk with `findmnt /` reporting the local-disk label.
6. Auto-revert to `nfs` on local-mode boot failure; diagnostic bundle captured to `./diagnostics/<host>-<timestamp>/` before revert.
7. Re-running against an already-provisioned board is a no-op (idempotent at the inventory level — same layout, same labels).
8. Layer 1 + Layer 3 molecule scenarios pass in CI. Layer 2 attempted; documented as hardware-only if CI unstable. Layer 4 (`test_reprovision_e2e.yml`) passes against `orange-pi-5-max-01` on real hardware.

## Out of scope (tracked elsewhere or deferred)

- Kernel-update integration with local-disk rootfses → #78.
- Example k3s cluster consuming this DSL → #79.
- Named layout library / preset+override system — rejected; layouts stay inline per-host.
- Disk selectors (`transport: nvme`) — explicit `/dev/<path>` only.
- LVM, LUKS, mdadm, ZFS, encryption — schema leaves room; not in v1.
- Writing U-Boot SPL+main to local disk to allow SD/SPI removal — incompatible with passthrough boot model.
