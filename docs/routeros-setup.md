# RouterOS Setup Guide

This guide reflects the live `igou.systems` topology: boards live on **vlan70
(DMZ, `10.10.70.0/24`, `dmz.igou.systems`)** with DHCP served by **`dhcp_vlan70`**
on the **rb5009** router (`rb5009.igou.systems` / `10.10.99.1`). The netboot
server is `igounas.igou.systems` (`10.10.9.224`) on vlan9. PoE for the boards is
controlled separately by the **crs328** switch (`crs328.igou.systems` /
`10.10.99.20`).

The full RouterOS bootstrap lives in
[`igou-io/routeros-setup`](https://github.com/igou-io/routeros-setup) — the
snippets below cover only what this collection needs on top of that baseline.

## Prerequisites

- RouterOS 7.x on the rb5009
- `/ip service` `ssh` enabled and reachable from the Ansible control node on
  `10.10.0.0/16`
- A dedicated `ansible-netboot` user with key-based SSH access (created below)
- SSH listens on **port 3480**, not 22 — set `ansible_port: 3480` on the
  RouterOS host entry in `inventory/hosts.yml`

The collection connects via `ansible.netcommon.network_cli` using
`community.routeros.routeros` as the cliconf. No REST/HTTP API or TLS
certificate setup is required.

## Ansible User Setup

Already provisioned by `01-hardening.rsc` in the routeros-setup repo. For
reference, this is what gets created:

```routeros
/user/group
add name=ansible-netboot policy="read,write,ssh,!local,!telnet,!ftp,\
    !reboot,!policy,!test,!winbox,!password,!web,!sniff,!sensitive,!romon,!rest-api,!api"

/user
add name=ansible-netboot \
    group=ansible-netboot \
    address=10.10.0.0/16 \
    comment="ansible — armbian_netboot collection"

/user/ssh-keys
import public-key-file=ansible-netboot.pub user=ansible-netboot
```

Notes:
- The policy enables `ssh` (the protocol this collection uses) plus the `read`
  / `write` permissions needed for `/ip dhcp-server` changes. `rest-api` and
  the legacy `api` are explicitly disabled — neither is needed.
- Authentication is SSH-key only; no password is set on the user.
- The `address=10.10.0.0/16` constraint pins the user to the management
  subnet — adjust if your control node lives elsewhere.

Set the matching values in your inventory. SSH connection details on the
RouterOS host entry in `inventory/hosts.yml`:

```yaml
routeros:
  hosts:
    rb5009:
      ansible_host: 10.10.99.1
      ansible_user: ansible-netboot
      ansible_port: 3480
```

Collection-level settings in `inventory/group_vars/all.yml`:

```yaml
routeros_dhcp_server_name: "dhcp_vlan70"
```

### Provisioning the user with `bootstrap_routeros_user.yml`

`playbooks/bootstrap_routeros_user.yml` automates the user / group / SSH key
setup on **both** the rb5009 and crs328 in one parameterized run. It connects
as an existing admin user (default: `igou`) over SSH key auth, so it sidesteps
the chicken/egg of needing `ansible-netboot` before `ansible-netboot` exists.

Router and switch both want SSH-only key auth with the same policy, so a
single invocation against the `routeros_devices` parent group (the playbook's
default `hosts:` target) covers both:

```bash
ansible-playbook playbooks/bootstrap_routeros_user.yml \
  -e ansible_user=igou+cet1024w \
  -e ansible_port=3480 \
  -e routeros_user_ssh_keys='["ssh-ed25519 AAAA... ansible-netboot@control"]'
```

`-e ansible_user=...` overrides the inventory-pinned `ansible-netboot` for
this bootstrap run; that user does not yet exist on the RouterOS device.
After bootstrap, every other playbook authenticates as the inventory-set
`ansible-netboot` automatically.

Add `-e routeros_disable_password_ssh=true` once you've verified key auth
works for every user that needs SSH (including `igou`) — it sets
`/ip ssh always-allow-password-login=no` globally.

## Static DHCP Leases

Each board needs a static lease on `dhcp_vlan70` keyed on its MAC address before
the playbooks can flip PXE options on it:

```routeros
/ip dhcp-server lease/add \
    server=dhcp_vlan70 \
    mac-address=AA:BB:CC:DD:EE:01 \
    address=10.10.70.101 \
    comment="orange-pi-5-01"
```

The `board_mac` value in `inventory/hosts.yml` must match exactly
(case-insensitive). For an example of the live pattern, see the existing
`rock-5b` lease (`10.10.70.249`, MAC `00:E0:4C:68:00:3B`) in
`05-router-dhcp-static.rsc`.

## Remove the legacy `boottest` option set on vlan70

`05-router-specific.rsc` previously assigned a `boottest` option set at the
**network** level on `10.10.70.0/24`:

```routeros
# This is what you want to REMOVE — it forces every vlan70 lease into PXE
/ip dhcp-server network
set [find address=10.10.70.0/24] dhcp-option-set=""
```

The collection's whole control surface is **per-lease** `dhcp-option`
assignment — a network-level option set would override it and make
`enable_netboot` / `disable_netboot` no-ops from the board's perspective.

The old `next-server-rock5b` and `netboot.xyz-rpi4-snp.efi` option entries can
stay or be removed; they don't conflict with the role's own object names
(`armbian-tftp-server`, `armbian-{nfsroot,reprovision}-bootfile`).

## DHCP Server PXE Objects

`playbooks/setup_routeros_dhcp.yml` creates these on the rb5009 automatically. For
reference / manual recovery:

```routeros
# Option 66 — TFTP server (= netboot_server_ip = 10.10.9.224)
/ip dhcp-server option/add \
    name=armbian-tftp-server code=66 value="'10.10.9.224'"

# Option 67 — boot file for NFS root mode
/ip dhcp-server option/add \
    name=armbian-nfsroot-bootfile code=67 value="'pxelinux.cfg/nfsroot-default'"

# Option 67 — boot file for reprovision mode
/ip dhcp-server option/add \
    name=armbian-reprovision-bootfile code=67 \
    value="'pxelinux.cfg/reprovision-default'"

# Option sets
/ip dhcp-server option sets/add \
    name=armbian-nfsroot \
    options=armbian-tftp-server,armbian-nfsroot-bootfile

/ip dhcp-server option sets/add \
    name=armbian-reprovision \
    options=armbian-tftp-server,armbian-reprovision-bootfile
```

## Triggering Netboot Manually

To queue a board for reprovision without Ansible:

```routeros
/ip dhcp-server lease/set \
    [find mac-address="AA:BB:CC:DD:EE:01"] \
    dhcp-option-set=armbian-reprovision
```

To revert to disk boot:

```routeros
/ip dhcp-server lease/set \
    [find mac-address="AA:BB:CC:DD:EE:01"] \
    dhcp-option-set=""
```

To power-cycle the board after flipping the option, toggle the PoE port on the
crs328 (`crs328.igou.systems` — SSH port 3480). See `04-host-specific-crs328.rsc`
for the switch baseline.

## Firewall Rules

Boards on vlan70 need to reach the netboot server on vlan9. The baseline
`05-router-firewall.rsc` only allows vlan70 → Internet (`!not_in_internet`),
which excludes RFC1918 — so without an explicit rule, TFTP/NFS to
`10.10.9.224` is dropped.

Add to `05-router-firewall.rsc`:

```routeros
/ip firewall filter
add action=accept chain=forward \
    comment="VLAN70 (dmz boards) → netboot server (igounas)" \
    in-interface=vlan70 dst-address=10.10.9.224
```

Required ports (board → netboot server):

| Port    | Protocol | Service           |
|---------|----------|-------------------|
| 69      | UDP      | TFTP              |
| 2049    | TCP/UDP  | NFS               |
| 111     | TCP/UDP  | rpcbind (NFS)     |
| 80      | TCP      | nginx (images)    |
| 8080    | TCP      | netboot.xyz HTTP  |

A single `dst-address=10.10.9.224` accept covers all of these; tighten with
`dst-port`/`protocol` matches if you want.

Reprovision-environment → RouterOS SSH (control node → rb5009):

| Port | Protocol | Service       |
|------|----------|---------------|
| 3480 | TCP      | RouterOS SSH  |

The control node lives on `10.10.0.0/16` and the rb5009 already accepts
management traffic on its mgmt VLAN — no extra rule needed if your control node
is on vlan99 / vlan10 / vlan9. Adjust the port to match the `ansible_port` set
on the RouterOS host entry if you've changed it from the default.

## Verifying DHCP PXE Options

After assigning an option set, verify the lease shows it:

```routeros
/ip dhcp-server lease/print detail \
    where mac-address="AA:BB:CC:DD:EE:01"
```

Look for `dhcp-option-set: armbian-reprovision` (or `armbian-nfsroot`) in the
output.

## Manual SSH Access

If you need to paste any of the above into the rb5009 / crs328 by hand, SSH is
on port **3480** (see `~/.ssh/config` host stanza for `rb5009.igou.systems` /
`crs328.igou.systems`):

```
ssh rb5009.igou.systems         # ssh_config sets Port 3480
ssh -p 3480 admin@10.10.99.1    # explicit form
```
