# board_config

Turns layered inventory data into resolved facts for one board. Runs on the
board host and never connects to it (`gather_facts` is not needed). Three entry
points, each with its own argument spec in
[`meta/argument_specs.yml`](meta/argument_specs.yml).

## `main`: hardware facts

| Input | Default | Purpose |
|---|---|---|
| `board_config_family` | `{}` | SoC-family layer (lowest precedence) |
| `board_config_model` | `{}` | Board-model layer |
| `board_config_host` | `{}` | Per-host layer (highest precedence) |

Output: fact `board_config`, the recursive combine of the three layers. The
role fails naming the field when `armbian_board_name` or `console` is empty.
`dtb`, `earlycon` and any other key are optional and passed through.

## `tasks_from: build`: build profile

| Input | Default | Purpose |
|---|---|---|
| `board_config_build_defaults` | `{}` | Lowest build layer |
| `board_config_build_family` | undefined | SoC-family build layer |
| `board_config_build_model` | undefined | Board-model build layer |
| `board_config_build_host` | undefined | Per-host build layer |

Outputs:

- `board_config_build`: scalars and `compile_args` combined recursively in
  layer order; `userpatches` concatenated in layer order. A `dest` that appears
  twice fails the role.
- `board_config_build_enabled`: true when any of the family, model or host
  build layers is defined.

A userpatch entry is either `{dest, content}` or `{dest, template}`. A
`template` entry is rendered with the `ansible.builtin.template` lookup in the
board's variable context (so it can use that host's variables) and emitted as
`{dest, content}`. Use an absolute path such as
`"{{ inventory_dir }}/templates/hook.conf.j2"`; relative paths follow the
lookup's search path (the calling playbook's `templates/` directory).

## `tasks_from: rootfs_src`: rootfs image source

| Input | Default | Purpose |
|---|---|---|
| `board_config_assets_base_url` | undefined | Base URL of the published images tree |
| `board_config_rootfs_src_override` | `""` | Explicit image URL or path; skips the manifest |
| `board_config_rootfs_checksum_override` | `""` | Checksum used with the override |

Outputs: `board_config_rootfs_src` and `board_config_rootfs_checksum`.

Without an override the role fetches
`<base>/images/<inventory_hostname>/manifest.json` from the control node and
derives `<base>/images/<inventory_hostname>/<image_filename>` with checksum
`sha256:<that url>.sha` (the `get_url` checksum-URL form). A 404 or a manifest
without `image_filename` fails with a remediation message. The manifest is
the one `image_build` writes.

## Example

```yaml
- name: Resolve board facts
  hosts: boards
  gather_facts: false
  tasks:
    - name: Resolve hardware facts
      ansible.builtin.include_role:
        name: david_igou.armbian.board_config

    - name: Resolve the build profile
      ansible.builtin.include_role:
        name: david_igou.armbian.board_config
        tasks_from: build

    - name: Resolve the rootfs source
      ansible.builtin.include_role:
        name: david_igou.armbian.board_config
        tasks_from: rootfs_src
      vars:
        board_config_assets_base_url: https://assets.example.com/boot-files
```

Typical inventory layering:

```yaml
# group_vars/rk3588.yml
board_config_family:
  console: ttyS2,1500000
  earlycon: uart8250,mmio32,0xfeb50000

# group_vars/rock_5b.yml
board_config_model:
  armbian_board_name: rock-5b
  dtb: rockchip/rk3588-rock-5b.dtb
board_config_build_model:
  branch: current
  userpatches:
    - dest: config/boards/rock-5b.conf
      template: "{{ inventory_dir }}/templates/rock-5b.conf.j2"
```

## Idempotency and check mode

Only sets facts; never reports a change. The manifest GET runs in check mode
too (`check_mode: false`) because it is read-only.

## License

MIT
