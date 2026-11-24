# bootstrap_armbian

Takes over a freshly flashed Armbian board: creates an SSH-key-only
automation user with passwordless sudo. Run it as `root`, which stock Armbian
accepts with its default password before first login. Password login needs
`sshpass` on the control node. After it runs:

- `bootstrap_armbian_user` exists with `bootstrap_armbian_ssh_keys` authorized;
- `/etc/sudoers.d/<user>` (visudo-validated) grants `NOPASSWD: ALL`;
- `/root/.not_logged_in_yet` is gone, so unattended SSH sessions do not hang in
  Armbian's first-login prompt;
- `/etc/ssh/sshd_config.d/00-bootstrap-armbian.conf` (validated with
  `sshd -t`) sets `PasswordAuthentication no`, plus `PermitRootLogin no` when
  `bootstrap_armbian_lock_root` is true; sshd is restarted when it changes;
- with `bootstrap_armbian_lock_root`, the root password is locked.

## Inputs

See [`meta/argument_specs.yml`](meta/argument_specs.yml).

| Variable | Default | Purpose |
|---|---|---|
| `bootstrap_armbian_user` | `armbian` | User to create; match the `ansible_user` later plays use |
| `bootstrap_armbian_ssh_keys` | required | Public keys to authorize; must not be empty |
| `bootstrap_armbian_lock_root` | `false` | Also disable root SSH login and lock the root password |

The role fails before changing anything when the key list is empty: with
password authentication disabled the board would be unreachable.

## Example

```yaml
- name: Bootstrap freshly flashed boards
  hosts: boards
  gather_facts: false
  vars:
    ansible_user: root
    ansible_password: "{{ armbian_first_boot_password }}"
  roles:
    - role: david_igou.armbian.bootstrap_armbian
      vars:
        bootstrap_armbian_user: automation
        bootstrap_armbian_ssh_keys:
          - ssh-ed25519 AAAAC3Nza... automation@example
        bootstrap_armbian_lock_root: true
```

Pair it with `board_boot_wait` and `board_boot_wait_ssh: false` when the
automation user does not exist yet.

## Idempotency and check mode

A second run changes nothing. Check mode is supported; the sshd restart
handler does not run in check mode. With `bootstrap_armbian_lock_root` a
re-run has to connect as `bootstrap_armbian_user` with `become: true`.

## Recovery

If the role fails part way, connect as `root` (password or serial console),
remove the partial user (`userdel -r <user>`) and `/etc/sudoers.d/<user>`, and
run it again.

## Security note

The user is root-equivalent by design: it exists to be the automation user.
Narrow its sudo rules afterwards if your threat model needs it. Losing its
private key means losing SSH access to the board.

## License

MIT
