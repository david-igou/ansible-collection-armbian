# rootfs_clone

## Purpose

Reflink-clone a rootfs template into a per-host directory, then reset
per-host identity so multiple clones of the same template boot with
independent identities on the wire. Copies the contents of
`template_dir` into `target_dir` using `cp -a --reflink=auto` (a
zero-cost CoW snapshot on XFS, btrfs, and ZFS; a full copy on ext4),
then writes a fresh hostname, zeroes machine-id files, and regenerates
the four standard SSH host keys directly inside the clone.

Runs on a single host that owns both the template path and the target
path — typically the netboot server. Knows nothing about NFS exports,
hostnames in inventory, or how the rootfs will be served.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `template_dir` | yes | — | Source rootfs template directory. |
| `target_dir` | yes | — | Destination per-host rootfs directory. |
| `hostname` | yes | — | Hostname to set inside the cloned rootfs. |
| `force_refresh` | no | `false` | When true, remove `target_dir` before cloning. |

## Outputs / side effects

After a successful run:

- `target_dir` exists and contains a complete Armbian rootfs.
- `target_dir/etc/hostname` holds `hostname`.
- `target_dir/etc/hosts` carries a `127.0.1.1\t{hostname}` line
  (silently skipped if the base image ships no `/etc/hosts`).
- `target_dir/etc/machine-id` and
  `target_dir/var/lib/dbus/machine-id` are zero-byte files (mode
  `0444`). Empty content — not deletion — is the signal systemd reads
  to gate `ConditionFirstBoot=yes`, which the first-boot
  `sshd-keygen.service` depends on.
- Four fresh SSH host keys (`ssh_host_rsa_key`, `ssh_host_ecdsa_key`,
  `ssh_host_ed25519_key`, plus the matching `.pub` files) exist under
  `target_dir/etc/ssh/`.
- `target_dir/root/.no_armbian_first_login` is touched, suppressing
  `armbian-firstrun-config`'s interactive password-change prompt the
  first time root logs in.

## Idempotency & check mode

- The clone copy itself uses `cp -a --reflink=auto`; re-running over
  an already-populated `target_dir` re-syncs file contents
  conservatively. Use `force_refresh: true` to delete `target_dir`
  first when you want a guaranteed-clean clone.
- Identity-reset tasks are individually idempotent:
  `lineinfile` reconciles `/etc/hosts`, `copy: content: ""` is a no-op
  when the file is already zero-byte, and `ssh-keygen` is gated on
  `creates:` so existing host keys are preserved on re-runs.
- `--check` mode: the clone step uses `shell: cp` and so reports
  `changed` regardless; identity-reset tasks work correctly under
  `--check`.

## Example

```yaml
- name: Clone the netboot rootfs template for a board
  hosts: netboot_server
  become: true
  tasks:
    - ansible.builtin.include_role:
        name: david_igou.armbian.rootfs_clone
      vars:
        template_dir: "{{ armbian_nfs_rootfs_path }}/_templates/orange-pi-5-pro"
        target_dir: "{{ armbian_nfs_rootfs_path }}/orange-pi-5-pro-01"
        hostname: orange-pi-5-pro-01
```

Typically reached via `playbooks/stage_netboot_assets.yml`, which loops
the role across every board in inventory.
