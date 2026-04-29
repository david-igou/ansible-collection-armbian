# RouterOS Setup Guide

## Prerequisites

- RouterOS 7.x (REST API required for reprovision script callback)
- SSH enabled on the router for Ansible
- A dedicated Ansible user with API access

## Ansible User Setup

Create a user group with minimal required permissions:

```routeros
/user/group/add name=ansible-netboot \
  policy=read,write,api,!ftp,!reboot,!password,!policy,!test,!winbox,!web,!sniff,!sensitive,!romon,!rest-api

/user/add name=ansible \
  group=ansible-netboot \
  password=<strong-password>
```

Enable the REST API (RouterOS 7+):
```routeros
/ip/service/enable www-ssl
/ip/service/set www-ssl certificate=your-cert
```

> Self-signed certificate is acceptable for a homelab; set
> `ansible_httpapi_validate_certs: false` in the routeros group_vars.

## Static DHCP Leases

Each board needs a static DHCP lease with its MAC address before the Ansible
playbooks can assign PXE options to it:

```routeros
/ip/dhcp-server/lease/add \
  server=dhcp1 \
  mac-address=AA:BB:CC:DD:EE:01 \
  address=192.168.1.101 \
  comment="orange-pi-5-01"
```

Create one entry per board. The `board_mac` value in `inventory/hosts.yml`
must match exactly (case-insensitive).

## DHCP Server PXE Objects

The `setup_server.yml` playbook creates these objects automatically via Ansible.
To create them manually for reference:

```routeros
# Option 66 — TFTP server
/ip/dhcp-server/option/add \
  name=armbian-tftp-server code=66 value="'192.168.1.10'"

# Option 67 — boot file for NFS root mode
/ip/dhcp-server/option/add \
  name=armbian-nfsroot-bootfile code=67 value="'pxelinux.cfg/nfsroot-default'"

# Option 67 — boot file for reprovision mode
/ip/dhcp-server/option/add \
  name=armbian-reprovision-bootfile code=67 value="'pxelinux.cfg/reprovision-default'"

# Option sets
/ip/dhcp-server/option/sets/add \
  name=armbian-nfsroot \
  options=armbian-tftp-server,armbian-nfsroot-bootfile

/ip/dhcp-server/option/sets/add \
  name=armbian-reprovision \
  options=armbian-tftp-server,armbian-reprovision-bootfile
```

## Triggering Netboot Manually

To queue a board for reprovision without Ansible:

```routeros
/ip/dhcp-server/lease/set \
  [find mac-address="AA:BB:CC:DD:EE:01"] \
  dhcp-option=armbian-reprovision
```

To revert to disk boot:

```routeros
/ip/dhcp-server/lease/set \
  [find mac-address="AA:BB:CC:DD:EE:01"] \
  dhcp-option=""
```

## Firewall Notes

The following ports must be reachable from boards to the netboot server:

| Port    | Protocol | Service        |
|---------|----------|----------------|
| 69      | UDP      | TFTP           |
| 2049    | TCP/UDP  | NFS            |
| 111     | TCP/UDP  | rpcbind (NFS)  |
| 80      | TCP      | nginx images   |
| 8080    | TCP      | netboot.xyz HTTP|

From the reprovision environment to RouterOS:

| Port    | Protocol | Service          |
|---------|----------|------------------|
| 443     | TCP      | RouterOS REST API|

## Verifying DHCP PXE Options

After assigning an option set, verify the lease shows the options:

```routeros
/ip/dhcp-server/lease/print detail \
  where mac-address="AA:BB:CC:DD:EE:01"
```

Look for `dhcp-option: armbian-reprovision` in the output.
