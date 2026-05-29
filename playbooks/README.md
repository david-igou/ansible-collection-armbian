# `playbooks/`

> **Disclaimer.** These playbooks are what the author runs to test the
> collection in their own homelab environment. They are provided as-is, with
> **no guarantee of functionality, stability, or fitness** for any other setup.
> Expect to read and adapt them before relying on them.

Workflow playbooks for the `david_igou.armbian` collection. **Roles** (under
`../roles/`) are single-purpose, parameter-driven state enforcers; **playbooks**
compose them into workflows — deciding which roles to invoke, against which
inventory, with which parameters, in what order.

## Layout convention — three buckets, sorted by purpose

| Location | Purpose | FQCN-addressable |
|---|---|---|
| **top level** (here) | Operational workflow playbooks — the "verbs" you run | yes (`david_igou.armbian.<name>`) |
| [`examples/`](examples/) | One demo playbook per role; minimal known-good role calls | no (run by path) |
| [`tests/`](tests/) | Hardware E2E harnesses + localhost var-contract tests | no (run by path) |
| [`routeros/`](routeros/) | Swappable RouterOS transport reference playbooks | no (imported via hook vars) |
| [`tasks/`](tasks/) | Internal `include_tasks`/`import_tasks` fragments shared by the workflows | n/a (not standalone) |

Only top-level playbooks are addressable by FQCN. A new playbook belongs in
whichever bucket matches its purpose; keep the top level limited to operational
workflows.

## Top-level workflow playbooks

| Playbook | Runs on | Does |
|---|---|---|
| `bootstrap_armbian.yml` | boards (as `root`) | Provision the inventory `ansible_user` with passwordless-sudo SSH-key auth |
| `build_and_publish_from_inventory.yml` | `armbian_builders` → netboot server | Build per-host custom `.img.xz` and publish to the netboot server |
| `stage_netboot_assets.yml` | netboot server | Per-host `rootfs_provision` (extract template + reflink-clone + identity reset) |
| `stage_router.yml` | netboot server (fetch) → router (push) | Stage per-model kernel/initrd/dtb + `/ip tftp` rows |
| `converge_boot_mode.yml` | router + boards | Converge board(s) to their inventory-declared boot mode |
| `set_boot_mode.yml` | (import wrapper) | Ad-hoc boot-mode override via `-e armbian_boot_mode=` |
| `persist_uboot_env.yml` | rock-5b boards | Write SPI U-Boot env vars via `fw_setenv` for autonomous PXE |
| `provision_local_disk.yml` | a board | Ad-hoc: provision one local disk with a copy of the running rootfs |
| `reprovision_to_local.yml` | a board | Headless full lifecycle: boot NFS → reprovision local disk(s) → flip to local → verify |
| `cleanup_boot_files.yml` | router | Remove stale per-host pxelinux.cfg + per-model TFTP rows |

## Running

Run from the collection root. Install runtime deps first; if you touch RouterOS,
also install the optional transport deps:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection install -r playbooks/routeros/requirements.yml
```

See the repo `CLAUDE.md` and [`docs/`](../docs/) for full per-playbook usage,
required inventory variables, and the boot-mode model.
