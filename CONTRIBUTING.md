# Contributing

Thanks for your interest in contributing to `david_igou.armbian`! This
collection is early-stage (0.0.x), so the public API is still moving;
breaking changes are expected between releases. The notes below cover
the basics — for general Ansible-collection contribution norms, see the
[Ansible community guide](https://docs.ansible.com/ansible/devel/community/index.html).

## Reporting bugs and requesting features

Open an issue at
<https://github.com/david-igou/ansible-collection-armbian/issues/new/choose>.
For bugs, include:

- Ansible / collection version (`ansible --version`, `ansible-galaxy collection list`)
- Board model + Armbian image source (URL or build)
- Minimal reproducer (playbook snippet + inventory excerpt)
- Relevant logs — ideally with `-vv` for failures inside roles and
  the diagnostic bundle path if the playbook produced one
- For boot/PXE issues: serial-console capture if you have one

## Development setup

The repository ships a `Makefile` with the common targets:

```bash
make install        # Install runtime collection dependencies
make install-lint   # Install everything ansible-lint needs
make lint           # yamllint + ansible-lint over roles/ + playbooks/ + inventory/
make test           # lint + the build_and_publish vars contract test + molecule
make molecule       # Run molecule scenarios (SCENARIO=<name> for one)
make collection-build       # Build the .tar.gz collection artifact
make collection-install     # Build and install locally
```

Molecule scenarios live under `extensions/molecule/`. Each scenario
declares its own backend — some run in podman containers, others in a
real qemu VM (which needs `/dev/kvm` access). See the scenario table
and driver-selection knobs in `extensions/molecule/README.md`.

## Before opening a PR

- `make test` passes locally.
- New behaviour has a changelog fragment under `changelogs/fragments/`
  ([format reference](https://docs.ansible.com/ansible/latest/community/development_process.html#changelogs)).
  A fragment is a small YAML file keyed by section, e.g.
  `changelogs/fragments/fix-disk-image-validation.yml`:

  ```yaml
  ---
  bugfixes:
    - disk_image - refuse to write when the target device is mounted (https://github.com/david-igou/ansible-collection-armbian/pull/123).
  ```

  Common sections are `minor_changes`, `bugfixes`, `breaking_changes`,
  and `deprecated_features`.
- Role inputs are declared in the role's `meta/argument_specs.yml`,
  not just documented in the README.
- The PR description explains the *why* — what was broken or missing,
  and how the change addresses it.

## Branching

Open PRs against `main`. Keep them focused; multiple unrelated changes
should be separate PRs. CI runs sanity, yamllint, ansible-lint,
build-import, and molecule scenarios — see `.github/workflows/tests.yml`.

## Adding a new board

Board metadata lives entirely in inventory — there is no per-board
data in the collection itself. Adding a new board means new inventory
layers (documented by example under `inventory/`):

- `inventory/group_vars/<family>.yml` — SoC-family defaults
  (`armbian_board_config_family`, `armbian_build_family`)
- `inventory/group_vars/<model_group>.yml` — model specifics
  (`armbian_board_config_model` with DTB/console/support tier,
  `armbian_build_model` with branch/userpatches)
- host entries in `inventory/hosts.yml` with `armbian_board_mac`,
  `armbian_board_model`, and `armbian_boot_mode`

The documentation-only sample inventory under `inventory/` shows the
full layering for several real boards — mirror one of those when
onboarding new hardware.
