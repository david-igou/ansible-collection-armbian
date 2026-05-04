# bootstrap_routeros_user

Idempotently provisions a RouterOS user, user group, and SSH public keys
needed by the rest of this collection. Solves the chicken/egg of needing the
`ansible-netboot` user before `ansible-netboot` exists by connecting as an
already-trusted admin user (default: `igou`) over SSH key auth, then creating
the target user/group/keys.

The role talks to RouterOS via `community.routeros.command` over
`ansible.netcommon.network_cli` — no REST/HTTP API is used.

## Role variables

| Variable | Default | Description |
|---|---|---|
| `routeros_user_name` | `ansible-netboot` | RouterOS user to create / update. |
| `routeros_user_group_name` | `{{ routeros_user_name }}` | RouterOS user group to create / update. |
| `routeros_user_address_scope` | `10.10.0.0/16` | Source-address restriction on the user. |
| `routeros_user_comment` | `ansible — armbian_netboot collection` | Comment field on the user. |
| `routeros_user_policy` | `read,write,ssh,!...,!rest-api,!api` | Comma-separated policy string. NO whitespace. |
| `routeros_user_ssh_keys` | `[]` | **Required.** List of public-key strings. |
| `routeros_disable_password_ssh` | `false` | If true, also sets `/ip ssh always-allow-password-login=no` globally. Verify key auth works for ALL users first. |
| `routeros_user_initial_password` | random 32-char string | Placeholder password applied at first `/user add` only — required because some RouterOS builds (factory-software 7.4.x+, e.g. RB5009UG) prompt interactively for a password and hang `network_cli` when one is omitted. Unreachable for login because the default `routeros_user_policy` denies `password`. |

The play that consumes this role is responsible for selecting the connection
user (`ansible_user`) and port (`ansible_port`) — typically the existing
admin account, since the user being provisioned doesn't exist yet.

## Example

```yaml
- name: Bootstrap RouterOS user with key-based SSH access
  hosts: routeros_devices
  gather_facts: false
  connection: ansible.netcommon.network_cli
  vars:
    ansible_network_os: community.routeros.routeros
    ansible_user: igou
    ansible_port: 3480
    routeros_user_ssh_keys:
      - "ssh-ed25519 AAAA... ansible-netboot@control"
  roles:
    - role: david_igou.armbian_netboot.bootstrap_routeros_user
```

Most users invoke this role indirectly via
`playbooks/bootstrap_routeros_user.yml`.

## License

GPL-3.0-or-later
