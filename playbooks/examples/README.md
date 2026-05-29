# `playbooks/examples/`

One demo playbook per role — each shows the **minimal known-good way to call a
single role**, so you can read a file and see exactly what inputs the role
needs. These are documentation, not production workflows: they hard-code or
default their inputs and skip the inventory resolution, retry loops, and
multi-host composition the real workflows in `../` do.

Run by path (they are not FQCN-addressable):

```bash
ansible-playbook playbooks/examples/<name>.yml --limit <host>
```

| Demo | Role exercised | Notes |
|---|---|---|
| `image_build.yml` | `image_build` | Build one `.img.xz`; real pipeline is `../build_and_publish_from_inventory.yml` |
| `rootfs_provision.yml` | `rootfs_provision` | Per-host NFS rootfs; real workflow is `../stage_netboot_assets.yml` |
| `disk_image.yml` | `disk_image` | Stream an `.img.xz` onto a block device |
| `disk_provision.yml` | `disk_provision` | Declarative GPT layout + rsync; full lifecycle is `../reprovision_to_local.yml` |
| `pxelinux_render.yml` | `pxelinux_render` | Render one per-board pxelinux.cfg locally |
| `board_boot_wait.yml` | `board_boot_wait` | TCP/22 + SSH wait (no power knowledge) |
| `board_boot_verify.yml` | `board_boot_verify` | Assert rootfs matches declared boot mode |

Each role's own `README.md` (under `../../roles/<role>/`) is the authoritative
parameter reference; these playbooks are the worked example.
