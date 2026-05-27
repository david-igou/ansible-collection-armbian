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
make test           # lint + the build_image vars contract test + molecule
make molecule       # Run molecule scenarios (SCENARIO=<name> for one)
make collection-build       # Build the .tar.gz collection artifact
make collection-install     # Build and install locally
```

Molecule scenarios live under `extensions/molecule/` and run with the
podman driver by default. Some scenarios run a real qemu VM
(`bootstrap_armbian`, `local_kernel_render`); these need
`/dev/kvm` access — see `extensions/molecule/README.md` for the
driver-selection knobs.

## Before opening a PR

- `make test` passes locally.
- New behaviour has a changelog fragment under `changelogs/fragments/`
  ([format reference](https://docs.ansible.com/ansible/latest/community/development_process.html#changelogs)).
- Role inputs are declared in the role's `meta/argument_specs.yml`,
  not just documented in the README.
- The PR description explains the *why* — what was broken or missing,
  and how the change addresses it.

## Branching

Open PRs against `main`. Keep them focused; multiple unrelated changes
should be separate PRs. CI runs sanity, yamllint, ansible-lint,
build-import, and molecule scenarios — see `.github/workflows/tests.yml`.

## Adding a new board

The `vars/boards.yml` file is the per-board source of truth (DTB,
console, support tier, etc.). Adding a new board usually means an
entry there plus an inventory example under
`inventory/group_vars/<model_group>.yml` and possibly per-board U-Boot
patches in `armbian_board_userpatches`.
