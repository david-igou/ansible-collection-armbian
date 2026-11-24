# image_build

Build an Armbian image with [`armbian/build`](https://github.com/armbian/build)
in Docker mode. The caller supplies the board, a per-target name and the
userpatches; the role checks out the pinned `armbian/build` ref, writes the
userpatches, builds when the inputs changed, and leaves the image and a
`manifest.json` under `<image_build_output_dir>/<image_build_name>/`.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml) for the full contract.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `image_build_board` | yes | — | Armbian `BOARD=` |
| `image_build_name` | yes | — | Per-target directory name, normally the board's inventory hostname |
| `image_build_cache_dir` | yes | — | Checkout root on the builder; checkouts land in `<cache_dir>/<name>/build` |
| `image_build_output_dir` | no | `<image_build_cache_dir>/output` | Image and manifest root |
| `image_build_branch` | no | `current` | `BRANCH=` |
| `image_build_release` | no | `bookworm` | `RELEASE=` |
| `image_build_ref` | no | `v26.2.0-trunk.844` | Pinned `armbian/build` ref |
| `image_build_userpatches` | no | `[]` | `{dest, content}` files under `userpatches/`; authoritative |
| `image_build_compile_args` | no | see defaults | Extra `KEY=value` arguments for `compile.sh` |
| `image_build_timeout` | no | `7200` | Seconds `compile.sh` may run |
| `image_build_min_free_gb` | no | `50` | Free GiB required at the cache directory |
| `image_build_force` | no | `false` | Build even if the manifest matches |
| `image_build_required_egress_hosts` | no | github.com, apt.armbian.com, ghcr.io, registry-1.docker.io | HTTPS HEAD checks before building |

## Outputs

Facts:

- `image_build_inputs_hash`: `sha256:` of the JSON of board, branch,
  release, ref, userpatches and compile args.
- `image_build_needed`: whether this run had to build.
- `image_build_manifest` (`main` only): the manifest of the image now in
  the output directory.

Files, for `image_build_name: orange-pi-5-pro-01`:

```text
<image_build_output_dir>/orange-pi-5-pro-01/
├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz
├── Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz.sha
└── manifest.json
```

```json
{
  "armbian_build_ref": "v26.2.0-trunk.844",
  "board": "orangepi5pro",
  "branch": "current",
  "built_at": "2026-05-05T12:34:56Z",
  "image_filename": "Armbian_26.2.0-trunk_Orangepi5pro_bookworm_current_6.12.img.xz",
  "inputs_hash": "sha256:…",
  "name": "orange-pi-5-pro-01",
  "release": "bookworm"
}
```

The `.sha` sidecar exists when `COMPRESS_OUTPUTIMAGE` includes `sha`.

## Entry points

- `main`: `plan`, then build and write the manifest when
  `image_build_needed` is true.
- `tasks_from: plan`: preflight, checkout, userpatches and the rebuild
  decision, without running `compile.sh`. Use it to find out whether a
  build is due.

## Rebuild decision

A build runs when `image_build_force` is true, when `manifest.json` is
missing or its `inputs_hash` differs from `image_build_inputs_hash`, or
when the image it names is missing. Changing any compile arg or userpatch
therefore triggers a build. The manifest is written only after a
successful build, so a failed build is retried on the next run.

`userpatches/` is authoritative: files under it that are not in
`image_build_userpatches` are removed before the decision, so a dropped
patch cannot linger in the next build.

## Preconditions

- Docker 17.06+ running, the connecting user in the `docker` group, and
  privileged containers allowed.
- The role runs without privilege escalation; the connecting user must
  be able to create and write `image_build_cache_dir` and
  `image_build_output_dir`.
- `image_build_min_free_gb` GiB free at the cache directory and HTTPS
  egress to `image_build_required_egress_hosts`.

The role is not check-mode safe. To rebuild from scratch, delete
`<image_build_cache_dir>/<name>/build` and run with `image_build_force: true`.

## Example

```yaml
- name: Build a PXE-first image
  hosts: armbian_builders
  gather_facts: false
  tasks:
    - name: Build the image
      ansible.builtin.include_role:
        name: david_igou.armbian.image_build
      vars:
        image_build_board: orangepi5pro
        image_build_name: orange-pi-5-pro-01
        image_build_cache_dir: /srv/armbian_build
        image_build_userpatches:
          - dest: config/boards/orangepi5pro.conf
            content: |
              function pre_config_uboot_target__orangepi5pro_pxe_first() {
                  declare -a t=("pxe" "dhcp" "mmc1" "mmc0" "nvme" "scsi" "usb" "spi")
                  sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${t[*]}\"/" \
                      include/configs/rockchip-common.h
              }
```
