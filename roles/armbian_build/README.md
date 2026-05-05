# armbian_build

Build a custom Armbian image with caller-supplied userpatches, using
[`armbian/build`](https://github.com/armbian/build) in Docker mode. The
role is single-purpose and intent-agnostic: it does not know (nor care)
what your userpatches do — callers (typically a workflow playbook) supply
the patch list and consume the resulting `.img.xz` + `manifest.json` from
`armbian_build_output_dir/<board>/`.

## Inputs

| Var | Default | Purpose |
|---|---|---|
| `armbian_build_board` | _required_ | Armbian board name, e.g. `orangepi5pro` |
| `armbian_build_branch` | `current` | Armbian kernel/U-Boot branch |
| `armbian_build_release` | `bookworm` | Userspace release |
| `armbian_build_ref` | `v26.2.0-trunk.844` | Pinned `armbian/build` git ref |
| `armbian_build_userpatches` | `[]` | List of `{ dest, content }` entries |
| `armbian_build_cache_dir` | `/var/lib/armbian_build` | Checkout + cache + userpatches root |
| `armbian_build_output_dir` | `/var/lib/armbian_build/output` | Where `<board>/<file>.img.xz` + `manifest.json` land |
| `armbian_build_min_free_gb` | `50` | Preflight threshold |
| `armbian_build_required_egress_hosts` | github.com, apt.armbian.com, ghcr.io | Preflight HEAD-checks |
| `armbian_build_compile_args` | _see defaults_ | Per-run knobs forwarded to `compile.sh` |
| `armbian_build_timeout` | `7200` | Build timeout in seconds |
| `armbian_build_force` | `false` | Force rebuild even if manifest matches |

## Outputs

`<armbian_build_output_dir>/<board>/`:
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

## Idempotency

The role skips the build (and the manifest write) when an existing
`manifest.json` matches all five decision fields: `patch_hash`,
`armbian_build_ref`, `board`, `branch`, `release`. `patch_hash` is
`sha256` of the canonical-JSON-encoded `armbian_build_userpatches`. Pass
`-e armbian_build_force=true` to override.

## Preflight assumptions

The role does not install Docker or modify the host beyond its own
`armbian_build_cache_dir` and `armbian_build_output_dir`. Preflight
hard-fails if any prerequisite is missing.

- Docker ≥17.06 is installed and runnable by the connecting user.
- Privileged containers work (`docker run --privileged hello-world`).
- Free space at `armbian_build_cache_dir` ≥ `armbian_build_min_free_gb` GB.
- `armbian_build_required_egress_hosts` are HTTPS-reachable.

## Example

```yaml
- ansible.builtin.include_role:
    name: armbian_build
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
