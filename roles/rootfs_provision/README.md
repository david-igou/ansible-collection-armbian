# rootfs_provision

## Purpose

Provision a per-host NFS rootfs from an `.img.xz` source. Downloads or
copies an Armbian `.img.xz`, extracts the rootfs into a per-host directory
on the netboot server, stages kernel/initrd/dtb to a TFTP cache directory,
and resets host identity (hostname, machine-id, SSH host keys).

Replaces the two-step `image_extract` + `rootfs_clone` workflow with a
single role invocation. With per-host builds each host may have a unique
image, so extract-and-provision happens in one shot; there is no shared
rootfs-template cross-contamination across hosts.

Runs on the **netboot server** (the host that exports NFS rootfs). The
caller supplies `armbian_rootfs_src`, `armbian_rootfs_host`, and
`armbian_rootfs_dtb`; everything else has defaults.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml) for the full contract.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `armbian_rootfs_src` | yes | — | `.img.xz` source: `https://` URL, `http://` URL, or absolute path on the netboot server. |
| `armbian_rootfs_host` | yes | — | `inventory_hostname` this rootfs is for. Drives identity reset and the target directory suffix. |
| `armbian_rootfs_dtb` | yes | — | DTB path under `/boot/dtb/` to stage as the TFTP `board.dtb` (e.g. `rockchip/rk3588-rock-5b.dtb`). |
| `armbian_rootfs_target_dir` | no | `{{ armbian_nfs_rootfs_path }}/{{ armbian_rootfs_host }}` | NFS rootfs destination directory. |
| `armbian_rootfs_tftp_dir` | no | `{{ armbian_image_cache }}/sbc-tftp/{{ armbian_rootfs_host }}` | Per-host TFTP staging directory. |
| `armbian_rootfs_image_cache` | no | `{{ armbian_image_cache }}/downloads` | URL-keyed shared download cache. Hosts pointing at the same URL share the `.img.xz` download. |
| `armbian_rootfs_force_refresh` | no | `false` | Force re-extract regardless of sentinel. |

## Outputs / side effects

After a successful run:

- `<armbian_rootfs_target_dir>/` is populated with the extracted rootfs.
  Machine-id is zeroed, SSH host keys are regenerated, and `/etc/hostname`
  is updated to `armbian_rootfs_host`.
- `<armbian_rootfs_tftp_dir>/vmlinuz`, `initrd.img`, and `board.dtb` are
  staged and ready for `stage_router.yml` to push to the TFTP server.
- `<armbian_rootfs_target_dir>/.armbian_rootfs_provision_complete` sentinel
  JSON is written; subsequent invocations with the same `src` + `host` skip
  the full provision.
- `<armbian_rootfs_image_cache>/<url-hash>/` holds the cached `.img.xz`;
  shared across all hosts that reference the same URL, so only one download
  occurs per unique URL per run.

## Idempotency & check mode

**Sentinel-based skip.** The role writes a JSON sentinel at
`<armbian_rootfs_target_dir>/.armbian_rootfs_provision_complete` on success.
On subsequent runs it skips the full provision if the sentinel's `src` and
`host` fields match the current inputs. Force a re-extract with
`armbian_rootfs_force_refresh: true` (or `-e armbian_rootfs_force_refresh=true`
on the command line).

**Not check-mode safe.** The extraction pipeline uses `losetup`, `mount`,
and `dd` — these require real kernel interaction and will fail under
`--check`. Do not run this role with `--check`; the sentinel check runs
cleanly but any host that needs extraction will fail at the loop-device step.

## Rollback

If a provision fails mid-extract, the `always:` cleanup block in `main.yml`
detaches loop devices and unmounts any in-progress mount. The
`<armbian_rootfs_target_dir>` may be partially populated. To recover:

1. Manually `rm -rf <armbian_rootfs_target_dir>` on the netboot server.
2. Re-run with `armbian_rootfs_force_refresh: true` to bypass any stale
   sentinel and start fresh.

## Generated assets

Per host, the role populates two directories. The NFS rootfs target gets
the extracted rootfs with identity rewritten inside it; the TFTP staging
dir gets the three boot artefacts U-Boot needs. With the defaults and
`armbian_rootfs_host: orange-pi-5-pro-01`:

```text
/srv/netboot/rootfs/orange-pi-5-pro-01/          # armbian_rootfs_target_dir
├── etc/
│   ├── hostname                                  # → orange-pi-5-pro-01
│   ├── hosts                                     # + 127.0.1.1 line (best-effort)
│   ├── machine-id                                # zeroed (first-boot trigger)
│   └── ssh/
│       ├── ssh_host_rsa_key(.pub)                # freshly regenerated
│       ├── ssh_host_ecdsa_key(.pub)
│       └── ssh_host_ed25519_key(.pub)
├── var/lib/dbus/machine-id                        # zeroed
├── root/.no_armbian_first_login                   # touched
├── ...                                            # rest of extracted rootfs
└── .armbian_rootfs_provision_complete             # idempotency sentinel (JSON)

<armbian_image_cache>/sbc-tftp/orange-pi-5-pro-01/   # armbian_rootfs_tftp_dir
├── vmlinuz
├── initrd.img
└── board.dtb                                       # located via armbian_rootfs_dtb
```

The DTB is always staged under the fixed name `board.dtb` (the
`armbian_rootfs_dtb` value only locates the source under `/boot/dtb/`).
The sentinel records what it was provisioned from (the `src` + `host`
fields are what subsequent runs compare against to decide whether to
skip):

```json
{
  "host": "orange-pi-5-pro-01",
  "provisioned_at": "2026-05-28T12:34:56Z",
  "src": "https://images.example.org/orange-pi-5-pro.img.xz",
  "src_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
}
```

## Example inventory

The example below reads `armbian_rootfs_src` and `armbian_board_config.dtb`
from each board's hostvars. A matching inventory (doc-safe placeholders):

```yaml
# inventory/hosts.yml
all:
  children:
    netboot_server:               # exports the NFS rootfs
      hosts:
        truenas-01:
          ansible_host: 192.0.2.10
          ansible_user: admin
          ansible_become: true
    boards:
      children:
        orange_pi_5_pro:          # <model_group> — carries the model layer
          hosts:
            orange-pi-5-pro-01:
              ansible_host: 192.0.2.111
              armbian_board_model: orange-pi-5-pro
              armbian_rootfs_src: "https://images.example.lan/orange-pi-5-pro-01.img.xz"

# inventory/group_vars/orange_pi_5_pro.yml   (model layer sets the dtb)
armbian_board_config_model:
  armbian_board_name: orangepi5pro
  dtb: rockchip/rk3588s-orangepi-5-pro.dtb

# inventory/group_vars/all.yml
armbian_nfs_rootfs_path: /srv/netboot/rootfs
armbian_image_cache: /var/lib/armbian/cache
```

`armbian_board_config` is the resolved fact produced by merging the
family/model/host layers — run `tasks/_resolve_board_config.yml` on the
board hosts before this role reads `armbian_board_config.dtb` (the
`playbooks/rootfs_provision.yml` and `stage_netboot_assets.yml` plays do
this in a first play).

## Example

```yaml
- name: Provision per-host NFS rootfs on the netboot server
  hosts: netboot_server
  become: true
  gather_facts: false
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.rootfs_provision
      vars:
        armbian_rootfs_src:    "{{ hostvars[item].armbian_rootfs_src }}"
        armbian_rootfs_host:   "{{ item }}"
        armbian_rootfs_dtb:    "{{ hostvars[item].armbian_board_config.dtb }}"
      loop: "{{ groups['boards'] }}"
```

Typically reached via `playbooks/stage_netboot_assets.yml`.
