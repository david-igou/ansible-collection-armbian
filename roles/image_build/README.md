# image_build

Build a custom Armbian image with caller-supplied userpatches, using
[`armbian/build`](https://github.com/armbian/build) in Docker mode. The
role is single-purpose and intent-agnostic: it does not know (nor care)
what your userpatches do — callers (typically a workflow playbook) supply
the patch list and consume the resulting `.img.xz` + `manifest.json` from
`armbian_build_output_dir/<host>/`.

## Inputs

| Var | Default | Purpose |
|---|---|---|
| `armbian_build_board` | _required_ | Armbian board name, e.g. `orangepi5pro` |
| `armbian_build_branch` | `current` | Armbian kernel/U-Boot branch |
| `armbian_build_release` | `bookworm` | Userspace release |
| `armbian_build_ref` | `v26.2.0-trunk.844` | Pinned `armbian/build` git ref |
| `armbian_build_userpatches` | `[]` | List of `{ dest, content }` entries |
| `armbian_build_cache_dir` | `/var/lib/armbian_build` | Checkout + cache + userpatches root |
| `armbian_build_output_dir` | `/var/lib/armbian_build/output` | Where `<host>/<file>.img.xz` + `manifest.json` land |
| `armbian_build_min_free_gb` | `50` | Preflight threshold |
| `armbian_build_required_egress_hosts` | github.com, apt.armbian.com, ghcr.io, registry-1.docker.io | Preflight HEAD-checks |
| `armbian_build_compile_args` | _see defaults_ | Per-run knobs forwarded to `compile.sh` |
| `armbian_build_timeout` | `7200` | Build timeout in seconds |
| `armbian_build_force` | `false` | Force rebuild even if manifest matches |

## Outputs

`<armbian_build_output_dir>/<host>/`:
- `Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz`
- `Armbian_<version>_<board>_<release>_<branch>_<kernel>.img.xz.sha` (when `COMPRESS_OUTPUTIMAGE` includes `sha`)
- `manifest.json`

## Manifest schema

```json
{
  "patch_hash": "sha256:…",
  "armbian_build_ref": "v26.2.0-trunk.844",
  "board": "orangepi5pro",
  "branch": "current",
  "release": "bookworm",
  "image_filename": "Armbian_…img.xz",
  "built_at": "2026-05-05T12:34:56Z"
}
```

## Idempotency & check mode

The role skips the build (and the manifest write) when an existing
`manifest.json` matches all five decision fields: `patch_hash`,
`armbian_build_ref`, `board`, `branch`, `release`. `patch_hash` is
`sha256` of the canonical-JSON-encoded `armbian_build_userpatches`. Pass
`-e armbian_build_force=true` to override. The role is not check-mode
safe: `compile.sh` runs in Docker and always writes to the build cache.

## Rollback / Recovery

If the build fails mid-run, the manifest is not written (it is only
written on success), so a subsequent run will re-trigger the build.
The partial Docker build artifacts under `armbian_build_cache_dir/build/`
are safe to leave in place — `armbian/build` handles incremental
rebuilds. To force a clean rebuild from scratch, delete
`armbian_build_cache_dir/<host>/build/` and re-run with
`armbian_build_force: true`.

## Preflight assumptions

The role does not install Docker or modify the host beyond its own
`armbian_build_cache_dir` and `armbian_build_output_dir`. Preflight
hard-fails if any prerequisite is missing.

- Docker ≥17.06 is installed and runnable by the connecting user.
- Privileged containers work (`docker run --privileged hello-world`).
- `armbian_build_cache_dir` and `armbian_build_output_dir` are writable
  by the connecting user. The role runs entirely without `become` — if
  you keep the defaults under `/var/lib/`, pre-create + chown the two
  directories once before the first run.
- Free space at `armbian_build_cache_dir` ≥ `armbian_build_min_free_gb` GB.
- `armbian_build_required_egress_hosts` are HTTPS-reachable.

## Publish prerequisites (when used with `playbooks/build_and_publish_from_inventory.yml`)

The role itself only writes to `armbian_build_output_dir` on the builder. The
companion `playbooks/build_and_publish_from_inventory.yml` publishes the artifacts builder→netboot
server using rsync over SSH (the controller mediates the transfer). That
publish step requires:

- The controller can SSH to both the builder and the netboot server as
  the inventory-declared `ansible_user`.
- The netboot server's `ansible_user` has passwordless sudo (the publish
  task uses `--rsync-path=sudo rsync` so the receive side runs as root,
  writing the root-owned per-board directories with `--mkpath`).

## Example

```yaml
- ansible.builtin.include_role:
    name: image_build
  vars:
    armbian_build_board: orangepi5pro
    armbian_build_userpatches:
      - dest: "config/boards/orangepi5pro.conf"
        content: |
          function pre_config_uboot_target__orangepi5pro_pxe_first() {
              declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
              sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                  include/configs/rockchip-common.h
          }
```
