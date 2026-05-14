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
  / `write` permissions needed for `/file` and `/ip tftp` mutations on rb5009.
  `rest-api` and the legacy `api` are explicitly disabled — neither is needed.
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

### Provisioning the user with `bootstrap_routeros_user.yml`

`playbooks/bootstrap_routeros_user.yml` automates the user / group / SSH key
setup on **both** the rb5009 and crs328 in one parameterized run. It connects
as an existing admin user (default: `igou`) over SSH key auth, so it sidesteps
the chicken/egg of needing `ansible-netboot` before `ansible-netboot` exists.

Router and switch both want SSH-only key auth with the same policy, so a
single invocation against the `routeros_netboot` parent group (the playbook's
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

Each board needs a static lease on `dhcp_vlan70` keyed on its MAC address so
U-Boot's PXE request lands on a deterministic IP:

```routeros
/ip dhcp-server lease/add \
    server=dhcp_vlan70 \
    mac-address=AA:BB:CC:DD:EE:01 \
    address=10.10.70.101 \
    comment="orange-pi-5-01"
```

The `armbian_netboot_board_mac` value in `inventory/hosts.yml` must match exactly
(case-insensitive). For an example of the live pattern, see the existing
`rock-5b` lease (`10.10.70.249`, MAC `00:E0:4C:68:00:3B`) in
`05-router-dhcp-static.rsc`.

## Network-level `next-server` (owned externally)

U-Boot 2025.10's PXE bootmeth uses BOOTP `siaddr` (RFC 951 next-server) as the
TFTP source — it parses DHCP option 66 but silently ignores it for `serverip`
selection. So the **SBC subnet's `next-server` field must point at rb5009's IP
for that subnet** (e.g. `10.10.9.1` for vlan9, or whichever IP rb5009 carries
on the SBC's VLAN). Without it, U-Boot can't reach rb5009's TFTP daemon to
fetch per-board pxelinux.cfg + per-model kernel/initrd/dtb.

This collection does **not** write `next-server`. Network-level RouterOS
fields are owned by your separate routeros-config repository (e.g.
`igou-ansible`'s `deploy_netboot_binaries.yml`). The collection assumes
`next-server` is already correctly set and only manages per-file/per-row state
under `flash:/sbc/` and the `/ip tftp` namespace.

## What the collection writes on rb5009

`stage_nfs_rootfs.yml` stages NFS rootfs templates and per-host clones on the
netboot server (see TrueNAS paths elsewhere in this repo). `stage_tftp_assets.yml`
populates per-model assets (kernel/initrd/dtb) under `flash:/sbc/armbian/<model>/`
on rb5009 and registers an `/ip tftp` row per file. `converge_boot_mode.yml`
writes each board's `pxelinux.cfg/01-<MAC>` plus its `/ip tftp` row (in v2 these
always exist; the `default` directive selects nfs vs sd). For ad-hoc boot-mode
overrides without editing inventory, use `set_boot_mode.yml`. To inspect after a run:

```routeros
/file print where name~"^sbc/"
/ip tftp print where real-filename~"^sbc/"
```

To remove the per-board pxelinux file and TFTP row by hand (emergency cleanup;
normally change boot mode with `set_boot_mode.yml` or inventory-driven
`converge_boot_mode.yml` instead):

```routeros
/ip tftp remove [find req-filename="pxelinux.cfg/01-AA-BB-CC-DD-EE-01"]
/file remove [find name="sbc/pxelinux.cfg/01-AA-BB-CC-DD-EE-01"]
```

To power-cycle the board afterwards, toggle the PoE port on the crs328
(`crs328.igou.systems` — SSH port 3480). See `04-host-specific-crs328.rsc`
for the switch baseline.

## Firewall Rules

Boards on vlan70 need to reach the netboot server on vlan9 (NFS rootfs +
HTTP assets) and rb5009 itself for TFTP. The baseline `05-router-firewall.rsc`
only allows vlan70 → Internet (`!not_in_internet`), which excludes RFC1918 —
so without explicit rules, the relevant traffic is dropped.

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
| 2049    | TCP/UDP  | NFS               |
| 111     | TCP/UDP  | rpcbind (NFS)     |
| 80      | TCP      | nginx (images)    |

TFTP (UDP/69) is served by rb5009 itself, not the netboot server — no
forward-chain rule needed for it; rb5009's input chain handles it.

A single `dst-address=10.10.9.224` accept covers the netboot server's ports;
tighten with `dst-port`/`protocol` matches if you want.

Control node → RouterOS SSH:

| Port | Protocol | Service       |
|------|----------|---------------|
| 3480 | TCP      | RouterOS SSH  |

The control node lives on `10.10.0.0/16` and the rb5009 already accepts
management traffic on its mgmt VLAN — no extra rule needed if your control node
is on vlan99 / vlan10 / vlan9. Adjust the port to match the `ansible_port` set
on the RouterOS host entry if you've changed it from the default.

## Manual SSH Access

If you need to paste any of the above into the rb5009 / crs328 by hand, SSH is
on port **3480** (see `~/.ssh/config` host stanza for `rb5009.igou.systems` /
`crs328.igou.systems`):

```
ssh rb5009.igou.systems         # ssh_config sets Port 3480
ssh -p 3480 admin@10.10.99.1    # explicit form
```
