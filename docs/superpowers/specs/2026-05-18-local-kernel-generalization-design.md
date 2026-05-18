# Local-Kernel Generalization + Declarative Boot Mode — Design

**Status**: Spec — supersedes [#78](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/78) and [#79](https://github.com/david-igou/ansible-collection-armbian_netboot/issues/79).
**Author**: David Igou.
**Date**: 2026-05-18.
**Tracking**: closes #78 and #79; cross-links to [`docs/superpowers/specs/2026-05-17-localboot-nvme-kernel-design.md`](2026-05-17-localboot-nvme-kernel-design.md) (#82, the OPi5Max-only `local_kernel` v1).

## Background

#82 introduced a fourth boot mode, `local_kernel`, in which U-Boot loads kernel/initrd/dtb directly off NVMe via a baked `localcmd` chain. On OPi5Max the strategic acceptance criterion holds: `apt install linux-image-edge-rockchip-rk3588=<new-ver>` followed by a PoE cycle results in the new kernel running. The board owns its boot stack; rb5009 serves only the pxelinux.cfg that selects the mode.

That dissolves the premise underneath #78. The original framing of #78 — "kernel updates require a centrally-orchestrated TFTP+modules-sync dance, optionally chrooted on the netboot server, with multi-label pxelinux for rollback" — was a workaround for boards that didn't own their kernel. `local_kernel` removes the workaround. The kernel-updates-direction memory (2026-05-17) had already pivoted toward reprovision-with-preservation, but `local_kernel` is structurally simpler than either direction. Per-host kernel updates ride `apt`; no preserved-paths overlay, no per-version TFTP, no chroot.

#79 (k3s example) listed #78 as a hard prerequisite because Patterns B/D's "cluster state survives kernel updates" promise hinged on preserving `/var/lib/rancher` across reprovisions. With `local_kernel`, k3s nodes use Pattern C (full local disk, native overlayfs, kernel updates via `apt`) and the preservation dependency goes away.

This spec generalizes the `local_kernel` mechanism from OPi5Max-only to any board that opts in, and defines the declarative inventory surface for picking that mode per host.

## Goals / non-goals

**Goals**

1. Generalize the OPi5Max-specific U-Boot build hook (`pre_config_uboot_target__999_orangepi5max_localcmd`) into a per-board dispatch table rendered from `vars/boards.yml`.
2. Define a per-host inventory shape for `local_kernel` that supports two delivery mechanisms for the `localcmd` value: compile-time bake (`persist_via: hook`) and runtime SPI write (`persist_via: spi`).
3. Generalize `playbooks/persist_uboot_env.yml` from rock-5b-only to any board with `uboot_env.storage: spi_flash`, with per-host `localcmd` plus an escape-hatch override (`armbian_netboot_uboot_env_extra`) for arbitrary U-Boot env vars.
4. Wire SPI persistence into `converge_boot_mode.yml` as a pre-step before cold-boot, with cycle ownership transferred to converge.
5. Roll `local_kernel` out across the 4 currently-`nfs` hosts in the fleet (opi5pro-01, rock-5b-01, orange-pi-5-01, rock-5a-01); opi5max-01 stays on `local_kernel`.
6. Verify mechanism in molecule (precedence + dispatch rendering) and verify hardware on three boards (opi5max regression, rock-5b SPI proof point, rock-5a NOWHERE-on-mainline proof point).

**Non-goals**

- Per-host U-Boot binaries (Approach 2 from brainstorming — rejected).
- Patching the OPi5Max defconfig to switch env storage to SPI or MMC.
- Non-rk3588 SoC families. The U-Boot config header (`include/configs/rk3588_common.h`) is rk3588-hardcoded; lift when a non-rk3588 board onboards.
- A k3s example (the #79 work). Unblocked by this spec but separately scoped.
- `test_hardware_e2e.yml` extension for `local_kernel` transitions. Manual hardware acceptance per Section 5 Layer 3.
- Auto-revert on local-kernel boot failure (operator flips `boot_mode` back).
- Deprecation of `preserve_on_reprovision` (from #77). The field stays — useful for orthogonal "data partition survives reprovision" cases. It is NOT the cluster-state-preservation strategy any more.

## Design

### Section 1 — Boot mode taxonomy + inventory surface

The four-mode taxonomy stays (`nfs` / `sd` / `local` / `local_kernel`). The single declarative knob remains `armbian_netboot_boot_mode`.

**Per-board metadata** (`vars/boards.yml`) — two new optional blocks per board entry:

```yaml
armbian_netboot_board_configs:
  orange-pi-5-max:
    armbian_dl_dir: orangepi5-max
    armbian_board_name: orangepi5-max
    armbian_support: community
    dtb: rockchip/rk3588-orangepi-5-max.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
    local_kernel:                  # absent => board doesn't support local_kernel
      storage: "nvme 0:4"          # U-Boot device address
      storage_scan: "nvme scan"    # how to enumerate the controller
    uboot_env:                     # board's U-Boot env characteristics
      storage: nowhere             # 'nowhere' | 'spi_flash' | 'mmc'

  rock-5b:
    armbian_dl_dir: rock-5b
    armbian_board_name: rock-5b
    armbian_support: standard
    dtb: rockchip/rk3588-rock-5b.dtb
    console: ttyS2,1500000n8
    earlycon: uart8250,mmio32,0xfeb50000
    local_kernel:
      storage: "nvme 0:4"
      storage_scan: "nvme scan"
    uboot_env:
      storage: spi_flash
      fw_env_config:               # only when storage allows runtime read/write
        device: /dev/mtd0
        offset:    "0xc00000"
        size:      "0x20000"
        sect_size: "0x1000"
      defaults:                    # vars to keep in SPI (today's hardcoded uboot_env_vars minus ethaddr)
        pxefile_addr_r: "0x00500000"
        kernel_addr_r:  "0x02080000"
        ramdisk_addr_r: "0x06000000"
        fdt_addr_r:     "0x08000000"
        scriptaddr:     "0x00c00000"
        bootmeths:      "pxe extlinux script efi"
```

Board lacking a `local_kernel:` block: setting `boot_mode: local_kernel` on a host of that model fails fast at convergence with `"board <model> does not support local_kernel — no local_kernel block in vars/boards.yml"`.

**Per-host inventory** — opt-in shape:

```yaml
# inventory/host_vars/<host>.yml (or inline in inventory.yaml)
armbian_netboot_boot_mode: local_kernel
armbian_netboot_local_kernel:
  persist_via: hook                # 'hook' (default) | 'spi'
  # Optional overrides (default from board's local_kernel block):
  # storage: "nvme 0:4"
  # storage_scan: "nvme scan"
  # root_label: armbi_root_local   # default armbian_netboot_local_root
```

`persist_via: hook` → use the U-Boot binary's compile-time default (baked by build hook). No runtime action. `persist_via: spi` → write per-host `localcmd` to SPI via `fw_setenv` at convergence time; only valid when the board's `uboot_env.storage: spi_flash`.

**Optional escape hatch** — `armbian_netboot_uboot_env_extra` (host or group scope), a flat dict of arbitrary U-Boot env vars merged into the converged set with highest precedence (see Section 3).

**What's deliberately not exposed**: the raw `localcmd` chain. Operators declare fields; the collection renders the chain. (One exception: setting `localcmd` directly via `armbian_netboot_uboot_env_extra.localcmd` is allowed as the escape-hatch override.)

**Validation layer** (runs at convergence entry):

- `boot_mode: local_kernel` AND `armbian_netboot_board_configs[<model>].local_kernel` undefined → fail with the message above.
- `persist_via: spi` AND `uboot_env.storage != spi_flash` → fail with `"<host>: local_kernel.persist_via=spi but board <model> uboot_env.storage=<storage>; change persist_via to 'hook' or pick a board with SPI env."`.
- `persist_via: spi` AND `uboot_env.fw_env_config` missing/incomplete → fail with `"<host>: uboot_env.fw_env_config required for SPI persistence; missing keys: <list>"`.

### Section 2 — Build hook generalization

The current hardcoded `pre_config_uboot_target__999_orangepi5max_localcmd` becomes one generic function plus a templated dispatch table:

```bash
function pre_config_uboot_target__999_local_kernel_bake() {
    [[ "${BRANCH}" != "edge" ]] && return 0

    # Dispatch table — one row per board with a `local_kernel:` block.
    # Rendered by Ansible from vars/boards.yml at playbook run time.
    declare -A LOCAL_KERNEL_CHAIN=(
        [orangepi5-max]='setenv bootargs root=LABEL=armbi_root_local rootfstype=ext4 rootwait rw console=ttyS2,1500000n8; nvme scan; ext4load nvme 0:4 ${kernel_addr_r} /boot/Image; ext4load nvme 0:4 ${ramdisk_addr_r} /boot/uInitrd; setenv ramdisk_size ${filesize}; ext4load nvme 0:4 ${fdt_addr_r} /boot/dtb/rockchip/rk3588-orangepi-5-max.dtb; booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}'
        [rock-5b]='setenv bootargs root=LABEL=armbi_root_local ...; nvme scan; ext4load nvme 0:4 ${kernel_addr_r} /boot/Image; ...; ext4load nvme 0:4 ${fdt_addr_r} /boot/dtb/rockchip/rk3588-rock-5b.dtb; booti ${kernel_addr_r} ...'
        # ... one row per board that opts into local_kernel
    )

    local chain="${LOCAL_KERNEL_CHAIN[${BOARD}]:-}"
    [[ -z "$chain" ]] && return 0   # board doesn't opt into local_kernel

    # Generic body: find CFG_EXTRA_ENV_SETTINGS in rk3588_common.h (fall
    # back to CONFIG_-prefixed for pre-v2024.01), idempotency guard on
    # the literal `localcmd=` substring, sed-insert one
    # `\t"localcmd=<chain>\\0" \\\n` continuation line after the macro
    # header, post-condition grep to defend against silent sed no-ops.
    # Same mechanics as the current OPi5Max-only hook, minus the BOARD gate.
    ...
}
```

**Where the dispatch table comes from.** A new pre_task in `playbooks/build_image.yml` enumerates unique board models in `groups['boards']`, filters to those whose `armbian_netboot_board_configs[<model>].local_kernel` block is set, renders one row per board via a Jinja macro that takes the board cfg and emits the U-Boot command string. Inputs to the macro: `cfg.local_kernel.storage`, `cfg.local_kernel.storage_scan`, `cfg.dtb`, `cfg.console`; collection defaults for `root_label` (`armbi_root_local`), `kernel_path` (`/boot/Image`), `initrd_path` (`/boot/uInitrd`), `rootfstype` (`ext4`).

**SoC family header path** — `include/configs/rk3588_common.h` is hardcoded in the hook. Every currently-onboarded board is rk3588(s). Documented as an assumption; non-rk3588 onboarding lifts to a per-family map. Missing macro → loud `exit_with_error`.

**Adding a new board** = add the `local_kernel:` and (if SPI-flash) `uboot_env:` blocks to its entry in `vars/boards.yml`. No code change to the hook.

**Build-time defconfig assertion.** A second pre_config_uboot_target hook (`pre_config_uboot_target__999_uboot_env_check`) runs after the defconfig has been laid down. Ansible renders it with a per-board expected-storage table (same shape as the dispatch table — keyed by `armbian_board_name`, value is `nowhere`/`spi_flash`/`mmc` from `armbian_netboot_board_configs[<m>].uboot_env.storage`). The hook greps the finalized defconfig for `CONFIG_ENV_IS_NOWHERE=y`, `CONFIG_ENV_IS_IN_SPI_FLASH=y`, `CONFIG_ENV_IS_IN_MMC=y`; maps the match back to one of the three classes; compares to the expected value. Mismatch → `exit_with_error` with `"<board>: defconfig reports CONFIG_ENV_IS_<X>=y but vars/boards.yml says uboot_env.storage=<Y>"`. Match → `display_alert "discovered env storage matches vars/boards.yml" "info"`. No Ansible-side post-build step needed; the build fails loudly if drift exists.

### Section 3 — SPI persistence path

`playbooks/persist_uboot_env.yml` is rewritten to be board-agnostic.

**1. Skip semantics.** The play iterates `hosts: boards`. First task filters out hosts where `armbian_netboot_board_configs[<model>].uboot_env.storage != 'spi_flash'` with `meta: end_host` and a debug message. No error — this is "host doesn't need persistence."

**2. Per-host `uboot_env_vars` composition** — three sources merged in this precedence (low → high):

| Layer | Source | Keys |
|---|---|---|
| Board defaults | `armbian_netboot_board_configs[<model>].uboot_env.defaults` | e.g. rock-5b's `pxefile_addr_r`, `kernel_addr_r`, `ramdisk_addr_r`, `fdt_addr_r`, `scriptaddr`, `bootmeths` |
| Collection-managed | computed | `ethaddr: "{{ armbian_netboot_board_mac \| lower }}"`; `localcmd: <rendered chain>` only when `persist_via == 'spi'` |
| Operator escape hatch | `armbian_netboot_uboot_env_extra` (host or group var) | Arbitrary; overrides anything above |

The localcmd render reuses the Jinja macro from Section 2, with per-host overrides applied on top of board defaults.

**3. `fw_env_config` generation** — from `armbian_netboot_board_configs[<model>].uboot_env.fw_env_config`. Written to `/etc/fw_env.config` by the play unconditionally (collection-owned).

**4. Drift detect → set → cold-cycle** — preserved from today's play:

- `fw_printenv -n <key>` per key, registered.
- `fw_setenv <key> <val>` only on drift (compare lowercased for hex robustness).
- Cold-cycle on any drift; ownership transferred to converge (see Section 4).

**5. Validation** — at play entry:

- `persist_via: spi` set on a host whose board's `uboot_env.storage != 'spi_flash'` → fail (caught at Section-1 entry validation, redundant safety here).
- `uboot_env.fw_env_config` missing required keys (`device`, `offset`, `size`, `sect_size`) → fail with the missing-keys message.

**6. The escape hatch.** `armbian_netboot_uboot_env_extra` is documented as "you own what you override; the collection won't fight you, but won't help you either if it breaks." Same drift-detect + cold-cycle pipeline applies. Setting `armbian_netboot_uboot_env_extra: { localcmd: "<your chain>" }` overrides the collection's rendered localcmd.

### Section 4 — Convergence integration

`converge_boot_mode.yml` gains a step 3.5 between pxelinux upload and cold-boot:

| Step | Play | Targets | When |
|---|---|---|---|
| 1 | Plumbing check | router | always |
| 2 | Render pxelinux locally | boards (delegate localhost) | always |
| 3 | Upload pxelinux to router | router (swappable transport) | always |
| **3.5** | **Persist U-Boot env (SPI)** | **boards** | **`uboot_env.storage == spi_flash`; reachable** |
| 4 | Cold-boot (PoE cycle) | boards | always |
| 5 | Wait for SSH + `board_boot_verify` | boards | always |

**Cycle ownership.** Today `persist_uboot_env.yml` cold-cycles on drift. When *imported* by converge it must NOT cold-cycle — step 4 owns that uniformly. Mechanism: a new play-level var `armbian_netboot_persist_uboot_env_cycle: true` (default true, standalone behavior). Converge sets it `false`. The persist play gates its cold-cycle include on this var.

**Bootstrap constraint** — to switch a host *to* `local_kernel + spi` for the first time, the host must currently be reachable on a previous boot mode. Sequence:

1. Operator sets `boot_mode: local_kernel`, `persist_via: spi` in inventory.
2. Board is currently on (say) `nfs` — reachable.
3. `converge_boot_mode.yml --limit <host>`.
4. Step 3 uploads the new pxelinux.cfg with `default local_kernel`.
5. Step 3.5 SSHes into the running board, writes localcmd + defaults to SPI.
6. Step 4 PoE-cycles. U-Boot boots, reads pxelinux.cfg → `default local_kernel` → `localboot 0` → runs `$localcmd` from SPI → loads kernel off NVMe.
7. Step 5 verifies root on NVMe.

If unreachable, step 3.5 fails at "ensure u-boot-tools is installed." Runbook: bring the board up on `nfs` first, then converge to `local_kernel`.

**Reverse direction** (`local_kernel` → `nfs`) — no special handling. The persist play still runs (converges SPI state independent of `boot_mode`; localcmd staying set in SPI is harmless when pxelinux.cfg's `default` points at `nfs`).

**Hook-mode hosts** (`persist_via: hook`) — no step 3.5 work. Identical to today's flow.

**New playbook-level knob** — `armbian_netboot_persist_uboot_env`:

- `auto` (default): run step 3.5 for hosts where `uboot_env.storage == spi_flash`.
- `always`: run step 3.5 unconditionally (no-op on NOWHERE hosts, useful for diagnostics).
- `never`: skip step 3.5 entirely (escape hatch for out-of-band SPI setup).

### Section 5 — Verification

**Layer 1 — molecule precedence (no hardware).** New scenario at `extensions/molecule/persist_uboot_env/` asserts the dict composition order. Fixture has one SPI-flash board host with `armbian_netboot_uboot_env_extra` overriding (a) a key from board defaults, (b) `ethaddr` from `board_mac`, (c) `localcmd` from structured render; plus a control host with no `_extra`. Converge invokes the composition logic (refactored into a `set_fact`-style include so it's callable without `fw_setenv` running), exports composed `uboot_env_vars` as a registered fact. Verify play asserts:

1. Every key from `uboot_env.defaults` present.
2. `ethaddr` derived from `armbian_netboot_board_mac` present; `localcmd` rendered from per-host overrides on `local_kernel`.
3. Override host: `_extra` wins for the three overridden keys.
4. Control host: no `_extra` keys in the composed dict.
5. Negative scenario: `persist_via: spi` on a NOWHERE board fails validation with a message containing both the host and the board's `env_storage` value.

**Layer 2 — molecule build-hook dispatch (no hardware).** Extends `extensions/molecule/image_build/`. Inventory fixture contains two `local_kernel`-opting boards. Verify play asserts:

1. Dispatch table has two rows keyed by `armbian_board_name`.
2. Each row's chain substitutes the correct per-board `dtb`, `console`, `storage`, `storage_scan`.
3. No cross-contamination (board A's chain doesn't appear in board B's row).
4. A board with no `local_kernel:` block produces no row.
5. The generic function body is present exactly once.

**Layer 3 — hardware E2E (out-of-band, manual, per board).** Follow the `testing-armbian-board-hardware` skill. Per-board tracker issues; this spec does not track per-iteration evidence.

| Board | Role | Must pass |
|---|---|---|
| **orange-pi-5-max-01** | Regression after generic dispatch replaces the OPi5Max-specific hook | Cold-boot via `localboot 0` → ext4load from NVMe → login. `findmnt /` shows `/dev/nvme0n1p4`. `apt install linux-image-*` + cycle picks up the new kernel. |
| **rock-5b-01** | SPI-persist proof point | Inventory sets `persist_via: spi`. `converge_boot_mode.yml` writes localcmd to SPI via fw_setenv, cold-cycles, board boots NVMe-resident kernel. `armbian_netboot_uboot_env_extra` override of one var (e.g. `bootdelay`) persists across the cycle. |
| **rock-5a-01** | NOWHERE proof point on a mainline-uboot board distinct from opi5max (which is on patched v2025.04; rock-5a is on mainline v2026.04 + Radxa-fork replacement) | `persist_via: hook`. Build hook bakes localcmd via the dispatch table. Cold-boot via `localboot 0` → ext4load from NVMe → login. `apt install linux-image-*` + cycle picks up the new kernel. |

Acceptance evidence lives on each board's per-board tracker issue. Spec is "done" when each row above has a green tracker comment.

**Layer 4 (deferred).** `test_hardware_e2e.yml` extension for `local_kernel` transitions is out of scope; follow-on once ≥2 boards are on `local_kernel`.

**`board_boot_verify` — no changes.** The existing `boot_mode == 'local_kernel'` branch already asserts `_root_device` is on local storage and `_root_fstype` is not NFS.

**`argument_specs.yml` updates** —

- `roles/image_build/meta/argument_specs.yml`: document the new `local_kernel` and `uboot_env` blocks in board configs.
- `inventory/group_vars/all.yml` sample: document `armbian_netboot_local_kernel`, `armbian_netboot_uboot_env_extra`, `armbian_netboot_persist_uboot_env`.
- `roles/pxelinux_render/meta/argument_specs.yml`: no change.
- `roles/board_boot_verify/meta/argument_specs.yml`: no change.

### Section 6 — Inventory rollout target state

Five boards in the live fleet. After this spec lands, the target inventory state is:

| Host | Board model | `uboot_env.storage` | `boot_mode` | `persist_via` | NVMe layout |
|---|---|---|---|---|---|
| opi5pro-01 | orange-pi-5-pro | nowhere¹ | local_kernel | hook | new |
| rock-5b-01 | rock-5b | spi_flash | local_kernel | **spi** | new |
| orange-pi-5-01 | orange-pi-5 | nowhere¹ | local_kernel | hook | new |
| rock-5a-01 | rock-5a | nowhere | local_kernel | hook | new |
| orange-pi-5-max-01 | orange-pi-5-max | nowhere | local_kernel | hook | existing |

¹ Verified at first build via the defconfig assertion in Section 2.

**Per-board metadata additions** (`vars/boards.yml`): every board gets a `local_kernel` block (storage = `"nvme 0:4"`, storage_scan = `"nvme scan"`) and a `uboot_env` block. rock-5b's `uboot_env` carries the `fw_env_config` + `defaults` migrated from today's `persist_uboot_env.yml` hardcoded values. The other four boards' `uboot_env: { storage: nowhere }` is trivial.

**Per-host NVMe layout** — for the four boards not currently on `local_disks`, the inventory gains an `armbian_netboot_local_disks` block matching opi5max-01's shape:

```yaml
armbian_netboot_local_disks:
  - device: /dev/nvme0n1
    wipe: true
    layout:
      - id: var
        size: 20GiB
        type: var
        format: ext4
        label: armbi_var
        mount: /var
        preserve_on_reprovision: true
      - id: root
        size: grow
        type: root
        format: ext4
        label: armbi_root_local
        mount: /
```

The `preserve_on_reprovision: true` on `/var` stays (orthogonal to the kernel-update story; useful for any data that should survive a rootfs swap). The rest of the spec does not depend on it.

**Bring-up sequence per board** (executed during plan execution, not in this spec):

1. Add the `local_kernel` and `uboot_env` blocks to the board's entry in `vars/boards.yml`.
2. Add the `armbian_netboot_local_disks` block to the host's inventory entry.
3. Set `armbian_netboot_boot_mode: local_kernel` and `armbian_netboot_local_kernel.persist_via: hook` (or `spi` for rock-5b-01).
4. Rebuild the image (`playbooks/build_image.yml`) so the binary carries the baked localcmd.
5. Reflash the SD card with the new image; bring the board up on `nfs` first.
6. Run `reprovision_to_local.yml` (#77's lifecycle) to partition NVMe + rsync rootfs.
7. Run `converge_boot_mode.yml --limit <host>` to flip the pxelinux default and (for rock-5b-01) write SPI env.
8. Verify per Section 5 Layer 3.

## Closing #78 and #79

### #78 — Kernel updates without full image rebuild + declarative rollback

Closing comment posts a link to this spec and the framing:

> `local_kernel` mode lands kernel ownership on the board. Kernel updates are now `apt install linux-image-<branch>-<family>=<version>` on the running board, followed by a PoE cycle. No pxelinux multi-label, no per-version TFTP layout, no chroot-on-the-netboot-server apt. Rollback is `apt install linux-image-<branch>-<family>=<older-version>` plus cycle. The "declarative rollback from inventory" property of the original framing is preserved — `armbian_netboot_local_kernel` is the declarative knob, and the kernel running on a host is observable via existing `board_boot_verify` facts.

### #79 — Example: k3s cluster on netbooted Armbian SBCs

Closing comment posts:

> #79's Pattern B/D dependency on #78's state-preservation was the whole reason it was blocked. With `local_kernel`, k3s nodes use Pattern C (full local disk, native overlayfs, kernel updates via apt). The k3s example becomes a separate, much smaller spec — Pattern C + upstream `k3s-io/k3s-ansible` wiring + a `docs/k3s-integration.md` covering the snapshotter / no_root_squash / kernel-module gotchas. Tracked separately.

## Open questions

1. **Default `persist_via` per board.** Currently the default in the inventory shape is `hook`. Should the default be inferred from the board's `uboot_env.storage` (i.e., `hook` on NOWHERE, `spi` on SPI-flash)? Trade-off: smarter default vs. surprise factor when a board's env storage changes. Leaning toward explicit `hook` default, but worth revisiting after rock-5b-01 bring-up evidence.
2. **Should `preserve_on_reprovision: true` on `/var` partitions stay as the recommended default?** The spec is framing it as orthogonal. Useful for any user data on `/var`. May want a separate doc note on when to enable / disable, since the original motivation (k3s state preservation across kernel updates) is no longer load-bearing.
3. **Defconfig assertion threshold.** The build-time assertion errors out on storage-class mismatch. Should it warn-only on first build of a new board (giving an operator time to align `vars/boards.yml`) and harden to error after? Probably error-only — silent storage-class drift would break Section-1 validation downstream.

## Sources

- #82 spec: [`docs/superpowers/specs/2026-05-17-localboot-nvme-kernel-design.md`](2026-05-17-localboot-nvme-kernel-design.md) — OPi5Max-only `local_kernel` v1 with Approach B (explicit `ext4load + booti`) rationale.
- #77 spec: [`docs/superpowers/specs/2026-05-17-disk-provision-dsl-design.md`](2026-05-17-disk-provision-dsl-design.md) — partitioning DSL + `reprovision_to_local.yml` lifecycle.
- Existing `playbooks/persist_uboot_env.yml` — rock-5b SPI-env Approach B that this spec generalizes.
- [U-Boot pxelinux docs](https://docs.u-boot.org/en/stable/usage/pxe.html) — `localboot <flag>` semantics.
- Debian `fw_env` man page — `/etc/fw_env.config` format.
