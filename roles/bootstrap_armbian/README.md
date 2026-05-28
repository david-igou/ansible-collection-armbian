# bootstrap_armbian

Provisions a passwordless-sudo, SSH-key-only user on a freshly flashed
Armbian board. Connects as `root` with `armbian_default_password`
(`"1234"` on stock Armbian) since this is the only user that exists
before bootstrap. After this runs:

- `armbian_bootstrap_user` exists with the listed SSH keys in
  `~/.ssh/authorized_keys`
- `/etc/sudoers.d/<user>` grants passwordless sudo
- `/root/.not_logged_in_yet` is gone (drops Armbian's first-login TUI
  prompt so subsequent unattended SSH sessions don't hang)
- `PasswordAuthentication no` in `/etc/ssh/sshd_config` (sshd
  restarted via handler)

Idempotent — re-running against a board already bootstrapped reconciles
authorized_keys and is otherwise a no-op.

This is the **first** play in the bootstrap sequence. Subsequent
playbooks (e.g. `stage_netboot_assets.yml`) connect as the provisioned
user — set `ansible_user` on `inventory/group_vars/all.yml` (or
per-host) to match `armbian_bootstrap_user`.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `armbian_bootstrap_user` | `armbian` | User to create. Should match `ansible_user` set elsewhere in inventory so subsequent plays connect as this user. |
| `armbian_bootstrap_ssh_keys` | `[]` | **Required.** List of public-key strings. The role asserts the list is non-empty before doing anything destructive. |

The connecting credentials (`ansible_user: root`,
`ansible_password`) are set on the playbook, not the role —
`armbian_default_password` (`inventory/group_vars/all.yml`,
default `"1234"`) supplies the password.

## Example

```yaml
- name: Bootstrap Armbian user with SSH key auth
  hosts: boards
  gather_facts: false
  vars:
    ansible_user: root
    ansible_password: "{{ armbian_default_password }}"
    armbian_bootstrap_ssh_keys:
      - "ssh-ed25519 AAAA... ansible@control"
  roles:
    - role: david_igou.armbian.bootstrap_armbian
```

Most users invoke this role indirectly via
`playbooks/bootstrap_armbian.yml`.

## Generated assets

With `armbian_bootstrap_user: armbian`, the role leaves these files on
the board:

```text
/home/armbian/.ssh/authorized_keys     # the supplied public key(s)
/etc/sudoers.d/armbian                  # mode 0440, visudo-validated
```

`/etc/sudoers.d/armbian` contains a single line:

```text
armbian ALL=(ALL) NOPASSWD: ALL
```

It also removes `/root/.not_logged_in_yet` (drops Armbian's first-login
TUI) and sets `PasswordAuthentication no` in `/etc/ssh/sshd_config`.

## Idempotency & check mode

Re-running against an already-bootstrapped board reconciles
`~/.ssh/authorized_keys` and `/etc/sudoers.d/<user>`, and is otherwise
a no-op. The role connects as `root` with a password; if the board has
already had `PasswordAuthentication no` set, re-runs require that the
SSH key already be present. `--check` mode is supported for the
assertion and key tasks, but the handler (sshd restart) will not fire.

## Rollback / Recovery

If the role fails mid-run, the user may or may not exist. To recover:
connect as `root` (with the default Armbian password or a serial console),
delete the partial user state (`userdel -r <user>`), remove
`/etc/sudoers.d/<user>` if present, and re-run the role. Because the
role creates the user before installing the SSH key, a failure between
those steps leaves a passwordless-login-blocked account — safe to delete
and retry.

## Security note

The created user gets unrestricted `NOPASSWD: ALL` sudo via
`/etc/sudoers.d/<user>`. This is intentional — the role exists to
provide an automation user that's root-equivalent over SSH key auth.
If your threat model wants narrower scope, tighten that sudoers entry
out-of-band after bootstrap. Don't bake a tighter scope into this
role; the cost is real (your own subsequent playbooks need to know
which commands the user can run unprivileged), and the gain is
limited (anyone with shell as this user controls the configuration
that tightens the scope).

The board also has `PasswordAuthentication no` set in sshd_config
after this role runs, so loss of the SSH private key is loss of the
board.

## License

MIT
