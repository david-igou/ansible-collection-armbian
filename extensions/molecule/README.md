# Molecule scenarios

Each scenario lives in its own subdirectory and is invoked via
`molecule test -s <scenario>`. The `podman` provisioner (default) drives a
local container; `kubevirt` drives a VM through the cluster — see
`provisioners/`.

| Scenario | Purpose | Provisioner |
|---|---|---|
| `default` | Smoke scaffold — confirms a managed container starts. | podman |
| `rootfs_clone` | Synthetic template + identity-reset verification. | podman |
| `pxelinux_render` | Render in `nfs` / `sd` / verbose modes; assert template body. | podman |
| `image_build` | Real Armbian image build on a KubeVirt VM (heavy). | kubevirt |

## Not covered by molecule

- **`image_extract`** — requires `losetup` + `mount` of a loop device. Even with
  `privileged: true` on the podman container, nested-container loop access is
  unreliable in CI environments and was observed failing with "failed to setup
  loop device" on hardened UBI hosts. Verify against a real `netboot_server`
  via `playbooks/stage_netboot_assets.yml --check` or a live run.
- **`board_boot_wait`** — wraps `wait_for` (TCP/22) + `wait_for_connection`.
  Testing the wrapper exercises Ansible's own modules rather than role logic.
- **`board_boot_verify`** — gathers facts on a board and asserts
  `ansible_mounts['/']` matches `boot_mode`. Verifies real PXE/NFS state on
  hardware; exercised by `playbooks/test_hardware_e2e.yml`.
