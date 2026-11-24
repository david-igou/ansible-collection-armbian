# Molecule scenarios

One scenario per role. Run from the collection root so molecule finds the
shared base config `extensions/molecule/config.yml`:

```bash
make molecule SCENARIO=<scenario>   # one scenario
make molecule                       # all scenarios
```

`make` exports `MOLECULE_GLOB=extensions/molecule/*/molecule.yml`; set it
yourself when calling `molecule` directly.

Instances come from `david_igou.molecule_provisioners`, pinned in
`requirements-test.yml` and installed by molecule's `dependency` step. The
shared lifecycle playbooks are in `shared/`; a scenario only keeps its own
`prepare.yml` when it builds a fixture, and scenarios without one point
`ansible.playbooks.prepare` at `../shared/prepare.yml`.

| Scenario | Backend | Instance |
|---|---|---|
| `board_config` | none (local-connection hosts) | the controller; `prepare.yml` serves a manifest over HTTP on 127.0.0.1:18580 |
| `pxelinux_render` | podman | `geerlingguy/docker-ubuntu2404-ansible` |
| `board_boot_wait` | qemu | Debian 13 genericcloud |
| `board_boot_verify` | qemu | Debian 13 genericcloud |
| `bootstrap_armbian` | qemu (UEFI) | Armbian Trixie UEFI x86 cloud_minimal, as shipped |
| `disk_image` | qemu | Debian 13 genericcloud |
| `disk_provision` | qemu | Debian 13 genericcloud |
| `image_build` | qemu | Debian 13 genericcloud |
| `rootfs_provision` | qemu | Debian 13 genericcloud |

The default sequence includes `idempotence`; a scenario whose role always
writes overrides `scenario.test_sequence` and says why.

## Controller prerequisites

| Backend | Needs |
|---|---|
| podman | `podman` |
| qemu | `qemu-system-x86_64`, `qemu-img`, the `pycdlib` Python package, OVMF for UEFI guests, `sshpass` for `bootstrap_armbian`; `/dev/kvm` for usable speed |

## Notes

- `board_boot_wait` and `board_boot_verify` need a VM: the first probes the
  guest's own sshd through the forwarded port, the second needs a real
  block-device root.
- `bootstrap_armbian` boots the Armbian image, which has no cloud-init, so
  its `prepare.yml` logs in as root with Armbian's first-boot password,
  authorizes the run's key and points the runtime inventory at root.
