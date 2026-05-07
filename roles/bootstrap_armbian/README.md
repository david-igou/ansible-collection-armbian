# bootstrap_armbian

Provisions a passwordless-sudo, SSH-key-only user on a freshly flashed
Armbian board. Connects as `root` with `armbian_default_password`
(`"1234"` on stock Armbian) since this is the only user that exists
before bootstrap. After this runs:

- `bootstrap_armbian_user` exists with the listed SSH keys in
  `~/.ssh/authorized_keys`
- `/etc/sudoers.d/<user>` grants passwordless sudo
- `/root/.not_logged_in_yet` is gone (drops Armbian's first-login TUI
  prompt so subsequent unattended SSH sessions don't hang)
- `PasswordAuthentication no` in `/etc/ssh/sshd_config` (sshd
  restarted via handler)

Idempotent — re-running against a board already bootstrapped reconciles
authorized_keys and is otherwise a no-op.

This is the **first** play in the bootstrap sequence. Subsequent
playbooks (e.g. `populate_nfs_content.yml`) connect as the provisioned
user — set `ansible_user` on `inventory/group_vars/all.yml` (or
per-host) to match `bootstrap_armbian_user`.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `bootstrap_armbian_user` | `igou` | User to create. Should match `ansible_user` set elsewhere in inventory so subsequent plays connect as this user. |
| `bootstrap_armbian_ssh_keys` | `[]` | **Required.** List of public-key strings. The role asserts the list is non-empty before doing anything destructive. |

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
    bootstrap_armbian_ssh_keys:
      - "ssh-ed25519 AAAA... ansible@control"
  roles:
    - role: david_igou.armbian_netboot.bootstrap_armbian
```

Most users invoke this role indirectly via
`playbooks/bootstrap_armbian.yml`.

## License

GPL-3.0-or-later
