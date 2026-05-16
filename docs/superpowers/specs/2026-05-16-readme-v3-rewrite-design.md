# README v3 rewrite — onboarding + dependency graph

Status: design
Owner: david.igou
Date: 2026-05-16
Related: [`docs/superpowers/specs/2026-05-16-role-refactor-v3-design.md`](2026-05-16-role-refactor-v3-design.md)

## Problem

The current README describes v2 (composite roles, `armbian_build`, `stage_nfs_rootfs.yml`,
`stage_tftp_assets.yml`, `bootstrap_routeros_user.yml`). The v3 refactor (PR #73)
renamed five playbooks, deleted five composite roles, added seven single-purpose
roles, introduced `playbooks/routeros/` reference playbooks, and split out
`playbooks/tasks/` helpers. A first-time reader can't run the collection from
the README as it stands, and there's no visual showing where each playbook
runs and what it composes.

## Goal

A first-time reader of `david_igou.armbian_netboot` can, within five minutes of
landing on the README:

1. Understand what the collection does in one paragraph.
2. Install it.
3. Confirm their environment satisfies the external prerequisites.
4. See a single diagram that maps every user-facing playbook to the roles,
   reference playbooks, and helper tasks it composes — and the host it
   targets.
5. Know which playbook to run first.

The middle and bottom of the README remain detailed operational reference; v3
renames are swept throughout.

## Non-goals

- No content moves out of README into separate docs.
- No new docs created.
- No diagrams in `docs/architecture.md` — that doc is updated separately if needed.
- No image assets; everything renders as markdown.

## Design

### Top section (replaces lines 1–47 of current README)

1. **Title + badges** — unchanged.
2. **One-paragraph what-it-is** — 3–4 sentences. Replaces the current 25-line
   intro + v2 status block. Mentions v3.0.0 once.
3. **Quickstart** — three numbered subsections:
   - 3.1 Install (`ansible-galaxy collection install david_igou.armbian_netboot`
     and the `requirements.yml` snippet).
   - 3.2 External prerequisites — bullet checklist (TrueNAS NFS export exists,
     rb5009 reachable via `network_cli`, SBC subnet's `next-server` points at
     rb5009, `armbian_builders` host reachable if building images). Each
     bullet links to the relevant deep doc.
   - 3.3 "First run sequence" — two short paths, each linking to the matching
     Lifecycle subsection lower in the README:
     - **One-time control-plane setup**: `routeros/bootstrap_user.yml` →
       `stage_netboot_assets.yml` → `stage_router.yml`
     - **Onboarding a board** (repeat per board): flash image → power on →
       `bootstrap_armbian.yml --limit <host>` → `converge_boot_mode.yml --limit <host>`
4. **How it works: dependency graph** — two artefacts:
   - **Mermaid `flowchart TB`** with all three tiers in one diagram:
     - Tier 1 (top): user-facing playbooks
     - Tier 2 (middle): roles and `playbooks/routeros/` reference playbooks
     - Tier 3 (bottom): `playbooks/tasks/` helpers and `playbooks/routeros/tasks/` shared primitives
     - Edges show composition (which composer invokes which composee). Style
       distinguishes "calls role" from "imports playbook" from "imports task
       file" using mermaid edge labels (no color reliance; readers may be on
       dark mode or screen-readers).
   - **Swim-lane table** — markdown table immediately after the diagram.
     Columns: `Playbook | Runs against (hosts: line) | Composes (roles) | Imports (reference playbooks)`.
     One row per user-facing playbook. Helper task imports are not in the
     table — they're in the diagram only — to keep the table skimmable.
5. **Mental model** — kept verbatim from current README (still accurate in v3).

### Middle section (existing — swept for v3 renames)

- **Status block**: rewrite the v2 paragraph as a v3.0.0 one-paragraph
  "single-purpose, transport-agnostic" summary; one sentence on the v2 → v3
  breaking change; link to v3 spec.
- **Requirements**: keep prose, replace "rb5009" specifics where they
  encoded v2 assumptions.
- **Included content / Roles table**: replace seven v2 rows with seven v3
  rows. Drop `armbian_build` row (renamed to `image_build`), drop the four
  composite v2 rows. Add `image_extract`, `rootfs_clone`, `pxelinux_render`,
  `board_boot_wait`, `board_boot_verify`.
- **Included content / Playbooks table**: rename the three renamed playbooks,
  drop `bootstrap_routeros_user.yml` (moved to `routeros/bootstrap_user.yml`).
  Add a separate small table for `playbooks/routeros/` reference playbooks
  with a one-liner about transport-swappability.
- **Lifecycle**: rewrite Phase 0 to use v3 playbook names. Drop
  `build_image.yml` from "you must do this first" — most consumers will use
  pre-built images. Link to it in an aside.
- **Daily operations**: rename `armbian_build` references; otherwise unchanged.

### Bottom section

- **Quick reference table**: rename to v3 playbook names.
- **Testing**: list current scenarios (`default`, `rootfs_clone`,
  `pxelinux_render`, `image_build` (kubevirt)). Mention which roles
  intentionally lack molecule coverage and where they're verified instead
  (cross-reference `extensions/molecule/README.md`).
- **Makefile / Docs / License**: minor sweeps.

## Mermaid graph specification

Three tiers in one `flowchart TB`:

**Tier 1 — User-facing playbooks (no parents):**
- `build_image.yml`
- `bootstrap_armbian.yml`
- `routeros/bootstrap_user.yml`
- `stage_netboot_assets.yml`
- `stage_router.yml`
- `converge_boot_mode.yml`
- `set_boot_mode.yml`
- `poe_control.yml`
- `persist_uboot_env.yml`
- `test_hardware_e2e.yml`

**Tier 2 — Roles + reference playbooks:**
- Roles: `image_build`, `image_extract`, `rootfs_clone`, `pxelinux_render`,
  `bootstrap_armbian`, `board_boot_wait`, `board_boot_verify`
- Reference playbooks: `routeros/upload_pxelinux_cfg.yml`,
  `routeros/upload_tftp_assets.yml`, `routeros/plumbing_check.yml`,
  `routeros/poe_control.yml`

**Tier 3 — Helpers and shared primitives:**
- `playbooks/tasks/cold_boot_with_retry.yml`
- `playbooks/tasks/cold_boot_single_attempt.yml`
- `playbooks/tasks/wait_for_ssh_with_cycle_retry.yml`
- `playbooks/tasks/auto_bootstrap_if_needed.yml`
- `playbooks/tasks/render_and_upload_pxelinux.yml`
- `playbooks/tasks/diagnostic_bundle.yml`
- `routeros/tasks/upload_file.yml`
- `routeros/tasks/poe_cycle.yml`
- `routeros/tasks/upload_pxelinux_one.yml`

Edge semantics (kept simple — readers shouldn't need a legend, but one is provided):

- Solid arrow = direct role include or playbook import
- Dashed arrow = task-file include (`ansible.builtin.include_tasks`)

## Risks

- **Diagram density**: ~30 nodes in one mermaid graph may render small on
  mobile. Mitigation: `flowchart TB` with explicit tier groupings using
  `subgraph` blocks for tier 2 (split by "roles" vs "routeros refs") and
  tier 3 (split by "playbooks/tasks" vs "routeros/tasks"). Reader can still
  zoom on GitHub.
- **Maintenance**: graph and swim-lane table both encode composition, so a
  refactor in either layer requires updating both. Mitigation: the swim-lane
  table only covers tier 1 → tier 2 edges; the diagram is the source of
  truth for helpers.
- **Drift from CLAUDE.md tables**: CLAUDE.md has overlapping content. Not in
  scope to dedupe; both serve different audiences (CLAUDE.md for agents,
  README for humans).

## Acceptance

- `README.md` rendered on GitHub shows the new top section above the fold (on
  a 1080p screen), with the mermaid diagram rendering inline.
- Every user-facing playbook listed in `playbooks/*.yml` appears in the
  swim-lane table.
- Every role under `roles/` appears in the diagram.
- No reference to `armbian_build` (role rename), `stage_nfs_rootfs.yml`,
  `stage_tftp_assets.yml`, or `bootstrap_routeros_user.yml` (playbook
  renames) remains anywhere in the README.
- v3.0.0 mentioned in status block; v2 → v3 migration link present.
