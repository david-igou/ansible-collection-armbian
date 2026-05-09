# 2026-05-05 — Collection direction: roles + workflow playbooks, with `armbian_build` as third primitive

## Mission

`david_igou.armbian_netboot` provides Ansible roles and playbooks to manage
Armbian-based ARM SBCs end-to-end. Three primitive roles each enforce one
external system's state; workflow playbooks compose them. PXE-netboot and
reprovisioning are workflows built on those primitives, not the framing of the
collection itself.

## Mental model

**Roles** are single-purpose, parameter-driven state enforcers. They do not
decide intent — callers do. A role asks "given these inputs, is the world in
the desired state, and if not, make it so."

| Role | Enforces / produces | Inputs |
|---|---|---|
| `routeros_poe` | PoE port state (on/off) | switch host, interface, action |
| `routeros_dhcp` | shared DHCP option-set objects + per-lease assignment | RouterOS host, lease MAC, option-set name |
| `bootstrap_routeros_user` | RouterOS user / group / SSH-key state | user, group, key |
| `armbian_build` *(new)* | `.img.xz` artifact + manifest, published to netboot server | board, branch, release, patches, output path |
| `netboot_assets` | rootfs / TFTP / pxelinux content under server exports | image URL, model, host identity |
| `bootloader` | U-Boot flashed on a target device | board metadata, target device, apt source |
| `bootstrap_armbian` | SSH-key user with passwordless sudo on a fresh board | user, key |
| `reprovision` | Armbian image flashed to a disk | image URL, target device |

**Playbooks** (`playbooks/*.yml`) are the workflow layer. Each one decides
which roles to invoke against which inventory, with which parameters, in what
order. Existing playbooks keep their names and shapes. New
`playbooks/build_image.yml` joins the set.

`README.md` and `docs/architecture.md` lead with this two-line model. Each
role README states which primitive or workflow it provides.

The collection name stays `david_igou.armbian_netboot` for v1. Renaming is
cheap to defer (and reversible if you ever publish); a third pillar landing
isn't reason enough to churn the namespace.

## v1 build pillar scope

- **Boards:** one — `orangepi5pro`. Designed to grow: adding a board is a
  per-board hook entry in `roles/armbian_build/vars/pxe_first_boards.yml`
  plus a per-host `host_board_overrides.armbian_build_enabled: true` flag.
  No role code changes needed for board N+1.
- **Output:** full `.img.xz` Armbian image with PXE-first `BOOT_TARGETS`
  patched at U-Boot compile time via the `pre_config_uboot_target__<board>_pxe_first`
  hook in `armbian/build`.
- **Build host:** `armbian_builders` inventory group, one host minimum.
  Docker ≥17.06 with privileged container support, ~50 GB free disk,
  unrestricted egress, SSH key-auth from the control node.
- **Publishing:** `nfs_assets_export/images/<board>/<file>.img.xz` plus a
  `manifest.json` sidecar (patch hash + `armbian/build` ref) so a re-run
  with the same patch + ref is a no-op.
- **Consumption:** for opted-in boards, override
  `armbian_image_urls[<board_model>]` in inventory to point at the local
  `image_server_url/<board>/<file>.img.xz`. `netboot_assets` and
  `reprovision` consume it through the existing path with no role changes.

## v1 immediate deliverables (this PR)

1. `README.md`, `CLAUDE.md`, `docs/architecture.md` updated to lead with the
   roles-plus-playbooks model and add `armbian_build` to the role tables.
2. WIP banners pivoted from "U-Boot debs" to "full images" to match the v1
   deliverable change.
3. Issue #16 retitled and rewritten so v1 = full image for `orangepi5pro`.
4. Five new follow-up issues filed for the build pillar: extend to remaining
   Rockchip boards, add the U-Boot deb path for boards on stock images, add
   Allwinner sunxi support, build a fully-headless image (bake user/keys,
   disable `armbian-firstlogin`), and document the inventory opt-in mechanism.

## Out of scope here

- Implementing the `armbian_build` role itself — that is #16's v1 work,
  separate plan.
- CI lint (#14) — unchanged.
- Renaming the collection.
- Decommissioning the `bootloader` role. It stays as the transition path for
  boards still running stock images. Once #16 v1 ships, opi5pro stops needing
  it for fresh provisions but it remains in the collection.

## Open implementation questions to resolve in #16's plan

These are tracked on the issue itself, not here. Listed for cross-reference
because they shape the role's parameterisation:

1. `armbian/build` git ref pinning — tag (e.g. `v25.05`) vs `main`.
2. Apt-version strategy if/when the deb path lands (epoch / vendor suffix /
   pin-priority) — defer until the deb-path issue is picked up.
3. Idempotency stamp format (`manifest.json` schema).
4. Build host bootstrapping — whether to include Docker install in
   `prep_build_host.yml` or require it pre-installed.

## Issue backlog after this PR lands

- **#16 (updated)** — `armbian_build` role v1: full image for orangepi5pro.
- **#14** — CI lint (unchanged).
- **NEW (build expansion)** — extend `armbian_build` to remaining Rockchip
  boards (orangepi5, orangepi5max, rock-5a, rock-5b).
- **NEW (deb path)** — `armbian_build` U-Boot-deb-only output for boards on
  stock images, consumed via `bootloader` role's `uboot_apt_source: local`.
- **NEW (Allwinner)** — `armbian_build` sunxi support; first board
  orange-pi-zero-3.
- **NEW (headless)** — full headless image: bake SSH-keys user, disable
  `armbian-firstlogin`. Eliminates `bootstrap_armbian.yml` for onboarded
  boards.
- **NEW (opt-in)** — document and implement
  `host_board_overrides.armbian_build_enabled: true` opt-in flag, plus the
  `armbian_image_urls` override convention for opted-in boards.
