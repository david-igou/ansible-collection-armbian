# Best-practices fixes — collection hardening pass

Status: design 2026-05-20. Target releases: `david_igou.armbian`
3.1.1 (specs), 3.2.0 (docs / idempotency / style), 4.0.0
(variable rename — single breaking change).

Companion review: [`docs/ansible-best-practices-review.html`](../../ansible-best-practices-review.html).

## Why

The v3 refactor delivered single-purpose, transport-agnostic roles. A review
against Red Hat COP automation good practices and the Ansible
developing-modules best-practices guide turned up a small set of real issues
hidden by the otherwise-clean structure:

- **Missing argument contract.** Eight of nine roles ship
  `meta/argument_specs.yml`; `bootstrap_armbian` does not. A caller that
  forgets to define `armbian_bootstrap_ssh_keys` gets a board with no
  authorised keys and password auth disabled — i.e. a permanently
  unreachable host.
- **License split.** Seven role meta files declare MIT, two declare
  GPL-3.0-or-later. The collection cannot ship with two licences.
- **Idempotency theatre.** Three roles (`image_extract`, `disk_image`,
  `disk_provision`) declare `changed_when: true` on long-running shell
  pipelines. The `changed:` signal is meaningless; downstream handlers cannot
  rely on it; `--check` mode is uninformative.
- **Documentation gap.** Six of nine roles ship no README — including the
  three most complex (`disk_provision`, `rootfs_clone`, `image_extract`).
- **Convention drift.** Three different variable-prefix conventions are in
  use simultaneously (collection-prefixed, role-prefixed, unprefixed). A
  documented rule is overdue.

None of this is structural; all of it is addressable in a single sequenced
maintenance pass plus one coordinated rename.

## Goals

1. **Make every role's input contract machine-readable.** Nine of nine roles
   ship a complete, accurate `meta/argument_specs.yml`.
2. **Make every role discoverable.** Nine of nine roles ship a README with
   the same section structure.
3. **Make `changed:` mean changed.** Output-derived `changed_when` on every
   long-running shell pipeline; sentinel-file idempotency probe in
   `image_extract`.
4. **Document the variable-prefix rule once.** Apply it consistently and
   surface the breaking renames in a single 4.0.0 bump.
5. **Add a thin per-role test layer.** Molecule scenarios for
   `pxelinux_render` (golden-file diff, no privilege) and `disk_provision`
   (256 MiB sparse loop file) cover ~70 % of role logic at near-zero CI
   cost.

Out of scope: rewriting the v3 architecture; replacing `image_extract`'s
loop-device approach; adding new roles; touching the RouterOS reference
playbooks under `playbooks/routeros/` beyond what the rename in §3 requires.

## Conventions established by this pass

These rules become the collection contract once this spec lands. Document them
in `CLAUDE.md` so future roles inherit them without re-litigation.

### Variable naming

| Scope | Pattern | Example |
|---|---|---|
| Cross-role / inventory-facing input | `armbian_*` | `armbian_boot_mode`, `armbian_default_password` |
| Role-local input (only this role consumes it) | `<role>_*` | `image_build_force`, `disk_provision_source` |
| Role-internal fact (set_fact, register) | `__<role>_*` | `__image_build_patch_hash`, `__disk_provision_repart` |

The COP rule (double-underscore prefix) makes the role boundary visible to
readers and forecloses cross-role collisions like `_skip_build`.

### License

The collection's `LICENSE` file (and `galaxy.yml license_file`) is the source
of truth. Every `roles/*/meta/main.yml` `license:` field must match. Decision:
**MIT** (the majority, and the conventional choice for an Ansible collection
of utility roles). Update `bootstrap_armbian` and `image_build` to match.

### Meta consistency

Every role's `meta/main.yml` declares:

```yaml
galaxy_info:
  role_name: <role>
  author: David Igou
  author_email: igou.david@gmail.com
  description: "<one-line, imperative, what-it-does>"
  license: MIT
  min_ansible_version: "2.15"
  platforms:
    - name: Generic       # or specific where required (e.g. image_build on Debian/Ubuntu)
      versions: [all]
  galaxy_tags:
    - armbian
    - netboot
    - <role-specific tag>   # e.g. provisioning, build, pxe
```

### README layout

Every role's `README.md` has the same five sections in this order:

1. **Purpose.** One paragraph, what-it-does + when-to-use.
2. **Inputs.** Markdown table mirroring `meta/argument_specs.yml`.
3. **Outputs / side effects.** What state changes after a successful run.
4. **Idempotency &amp; check mode.** Explicit promise + known limitations.
5. **Example.** A 10–20 line `tasks:` snippet that someone can paste.

### `changed_when` rule

`changed_when: true` is **never** the right answer on a task that runs for
more than ~1 second. Either:

- the task is genuinely always-changed (e.g. atomic-write of a templated
  file with no upstream content match) — in which case use the underlying
  module's built-in change detection;
- the task is a shell pipeline — derive `changed_when` from `register`ed
  output (a stderr line, a JSON length, an exit code).

## Workstreams

Seven workstreams, grouped by which release they ship in.

### Release 3.1.1 — specs (non-breaking, ship as a patch)

#### WS-1: Argument specs

| Item | File | Change |
|---|---|---|
| 1.1 | `roles/bootstrap_armbian/meta/argument_specs.yml` (new) | Declare both required vars; assert `length > 0` on `ssh_keys`. |
| 1.2 | `roles/board_boot_wait/` (defaults vs specs reconcile) | Delete unused `armbian_boot_retry_attempts`, `armbian_ssh_wait_timeout`, `armbian_ssh_wait_retry_attempts` from `defaults/main.yml` (the retry logic lives in `playbooks/tasks/cold_boot_with_retry.yml`, not this role). |

### Release 3.2.0 — docs, idempotency, style (non-breaking, ship as a minor)

#### WS-2: Metadata consistency

| Item | File | Change |
|---|---|---|
| 2.1 | All `roles/*/meta/main.yml` | Standardise `author: David Igou`, add `author_email: igou.david@gmail.com`, align `license: MIT`. |
| 2.2 | All `roles/*/meta/main.yml` | Add `galaxy_tags:` (minimum: `armbian`, `netboot`, one role-specific). |
| 2.3 | `galaxy.yml` | Update `authors:` to `David Igou <igou.david@gmail.com>`. |
| 2.4 | `ansible.cfg` | `host_key_checking = False` → `host_key_checking = false`. |
| 2.5 | `vars/boards.yml` | Add a header comment explaining why this lives under `vars/` instead of `defaults/`. |

#### WS-3: Documentation

For each of the six roles missing a README — `board_boot_wait`,
`board_boot_verify`, `image_extract`, `pxelinux_render`, `rootfs_clone`,
`disk_provision` — write a `README.md` following the five-section layout from
the conventions section. Order by priority (highest user cost first):

1. `disk_provision`
2. `image_extract`
3. `rootfs_clone`
4. `pxelinux_render`
5. `board_boot_wait`
6. `board_boot_verify`

#### WS-4: Idempotency

| Item | File | Change |
|---|---|---|
| 4.1 | `roles/image_extract/tasks/main.yml` | Replace single-file existence probe with sentinel-file probe; write `.armbian_extract_complete` at end of success path. |
| 4.2 | `roles/disk_image/tasks/_write.yml` | All four streaming branches: `register` + derive `changed_when` from `"records out"` in stderr (exclude `"0+0"`). |
| 4.3 | `roles/disk_provision/tasks/_apply_repart.yml` | `systemd-repart` invocation: derive `changed_when` from JSON output length. |
| 4.4 | `roles/disk_provision/tasks/_populate.yml` | Add `--itemize-changes` to rsync; derive `changed_when` from non-empty change list. |
| 4.5 | `roles/image_extract/tasks/_cleanup.yml` | Replace `failed_when: false` silent swallow with `failed_when: false` + warning `debug` task. |

#### WS-5: Style

| Item | File | Change |
|---|---|---|
| 5.1 | `roles/disk_provision/tasks/_populate.yml` | Replace `command: rsync ...` with `ansible.posix.synchronize:`. |
| 5.2 | `roles/image_build/tasks/publish_scp.yml`, `roles/image_build/tasks/main.yml`, `roles/image_build/defaults/main.yml`, `roles/image_build/meta/argument_specs.yml`, `roles/image_build/README.md` | Delete dead `publish_scp.yml` + its `main.yml` include + the `armbian_publish_target` default and argspec entry. `armbian_publish_target` is set nowhere in the repo, and `playbooks/build_image.yml` already publishes the build artefact via `ansible.posix.synchronize` — the role builds, the workflow publishes. |
| 5.3 | `roles/rootfs_clone/tasks/main.yml` | Replace `shell: cp -a --reflink=auto` with `command: argv:` form. |
| 5.4 | `roles/rootfs_clone/tasks/_identity_reset.yml` | Replace `shell rm "{{ target_dir }}"/etc/ssh/ssh_host_*` with `find` + `file` loop. |
| 5.5 | `roles/bootstrap_armbian/handlers/main.yml` | `ansible.builtin.service` → `ansible.builtin.systemd_service`. |
| 5.6 | `roles/pxelinux_render/templates/pxelinux_cfg.j2` | Prepend `# {{ ansible_managed }}` line to header. |
| 5.7 | `roles/disk_image/tasks/_validate.yml` | Audit + standardise to FQCN throughout. |

### Release 4.0.0 — variable rename (single breaking change)

#### WS-6: Variable prefix rename

6.1 Rename `pxelinux_render` role variables to `pxelinux_render_*` (the most
exposed unprefixed names):

| Old | New |
|---|---|
| `sd_root` | `pxelinux_render_sd_root` |
| `local_root` | `pxelinux_render_local_root` |
| `pxe_verbose` | `pxelinux_render_pxe_verbose` |
| `tftp_kernel` | `pxelinux_render_tftp_kernel` |
| `tftp_initrd` | `pxelinux_render_tftp_initrd` |
| `tftp_dtb` | `pxelinux_render_tftp_dtb` |
| `earlycon` | `pxelinux_render_earlycon` |
| `boot_mode` | `pxelinux_render_boot_mode` |
| `extra_modes` | `pxelinux_render_extra_modes` |
| `hostname` | `pxelinux_render_hostname` |
| `model_name` | `pxelinux_render_model_name` |
| `board_mac` | `pxelinux_render_board_mac` |
| `nfs_server_ip` | `pxelinux_render_nfs_server_ip` |
| `nfs_root_path` | `pxelinux_render_nfs_root_path` |
| `output_dir` | `pxelinux_render_output_dir` |

Update `defaults/main.yml`, `meta/argument_specs.yml`, the template, every
caller (`playbooks/converge_boot_mode.yml`,
`playbooks/tasks/render_and_upload_pxelinux.yml`,
`playbooks/test_fleet_e2e.yml`, the routeros upload task), and the role
README.

6.2 Rename internal facts (non-breaking; do it under cover of 4.0.0 so the
diff is small):

| Old | New |
|---|---|
| `_patch_hash` | `__image_build_patch_hash` |
| `_manifest_inputs` | `__image_build_manifest_inputs` |
| `_skip_build` | `__image_build_skip_build` |
| `_is_url` (image_extract) | `__image_extract_is_url` |
| `_img_cache` | `__image_extract_img_cache` |
| `_loop_dev` | `__image_extract_loop_dev` |
| `_already_extracted` | `__image_extract_already_extracted` |
| `_target_stat` (disk_image) | `__disk_image_target_stat` |
| `_src_is_url` | `__disk_image_src_is_url` |
| `_fmt` | `__disk_image_fmt` |
| `_dp_*` | `__disk_provision_*` (across the role) |
| `_pxe_filename` | `__pxelinux_render_pxe_filename` |

### Release-independent

#### WS-7: Per-role molecule tests

Two scenarios; ship whenever convenient.

7.1 `roles/pxelinux_render/molecule/default/` — render against a fixture
inventory of two boards; golden-file diff the rendered `01-<mac>` files.
Runs unprivileged in `python:3.12-slim`. Target CI time: &lt;10s.

7.2 `roles/disk_provision/molecule/default/` — create a 256 MiB sparse loop
file in a privileged container, run the role with a 2-partition
`disk_binding`, assert the partition table (`sgdisk -p`) and rendered fstab.
Target CI time: ~30s.

## Versioning &amp; release notes

| Bump | Trigger | User impact |
|---|---|---|
| 3.1.1 | WS-1 ships | None. New `bootstrap_armbian` argument_specs fail-fast if `armbian_bootstrap_ssh_keys` is empty, which is a strict improvement on the previous silent footgun. |
| 3.2.0 | WS-2 + WS-3 + WS-4 + WS-5 ship | Possible `changed:` count delta in operator reports (previously always-changed steps will now sometimes report `ok`). Document this prominently in the release note. |
| 4.0.0 | WS-6 ships | All `pxelinux_render` callers must rename variables. Migration guide ships in the release note; the rename is a `git grep` away from mechanical for every consumer. |
| (any) | WS-7 ships | None. |

## Non-goals

- Replacing `image_extract`'s loop-device approach with `unarchive`/`mount`
  modules. Worth doing eventually; out of scope for this pass to keep the
  diff reviewable.
- Adding cross-role integration tests beyond what
  `playbooks/test_fleet_e2e.yml` already does.
- Migrating away from RouterOS as the reference transport.
- Adding custom Ansible modules. The collection's surface is roles +
  playbooks; that's the right shape.

## Acceptance criteria

The pass is done when:

- `ls roles/*/meta/argument_specs.yml | wc -l` == 9.
- `ls roles/*/README.md | wc -l` == 9.
- `grep -l 'license: MIT' roles/*/meta/main.yml | wc -l` == 9.
- `grep -rn 'changed_when: true' roles/*/tasks/` returns only tasks that are
  genuinely always-changed (the audit list lives in the WS-4 PR description).
- `ansible-lint roles/` passes with no FQCN or `risky-shell-pipe` findings.
- For 4.0.0 only: `grep -rEn '\b(sd_root|tftp_kernel|tftp_initrd|tftp_dtb|earlycon|pxe_verbose)\b' roles/ playbooks/`
  returns no matches outside the rename PR itself.
