# Boot Mode Override Methods

Three ways to change a board's boot mode, ranked by durability.

## Comparison

| Method | Durability | Touches rb5009? | Use case |
|---|---|---|---|
| Inventory (`armbian_netboot_boot_mode`) | Permanent | Yes (on converge) | Fleet-level default |
| Ansible `-e` (`set_boot_mode.yml`) | Until next converge | Yes | Ad-hoc testing, one-off flip |
| U-Boot env (`pxe_label_override`) | Single boot (non-SPI) or until cleared (SPI) | No | Serial console triage |

## Method 1: Inventory (permanent)

Set `armbian_netboot_boot_mode` on the host in your inventory, then run
`converge_boot_mode.yml`:

```yaml
# inventory/host_vars/orange-pi-5-pro-01.yml  (or inline in hosts.yml)
armbian_netboot_boot_mode: sd
```

```bash
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01
```

The rendered pxelinux.cfg on rb5009 is updated to `default sd`. Every
subsequent `converge_boot_mode.yml` run re-reads the inventory value, so
the change persists across automation runs.

To revert, change the inventory back and re-converge:

```yaml
armbian_netboot_boot_mode: nfs
```

```bash
ansible-playbook playbooks/converge_boot_mode.yml -e target_hosts=orange-pi-5-pro-01
```

## Method 2: Ansible `-e` override (ad-hoc)

Use `set_boot_mode.yml` with an extra-var — no inventory edit needed:

```bash
# Flip to sd boot temporarily
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 \
  -e armbian_netboot_boot_mode=sd

# Flip back to nfs
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 \
  -e armbian_netboot_boot_mode=nfs
```

The `-e` value wins over inventory for this run. The pxelinux.cfg on
rb5009 is re-rendered with the override. On the *next* run of
`converge_boot_mode.yml` (which reads from inventory), the inventory
value takes effect again.

To write rb5009 state without cycling the board:

```bash
ansible-playbook playbooks/set_boot_mode.yml \
  --limit orange-pi-5-pro-01 \
  -e armbian_netboot_boot_mode=sd \
  -e armbian_netboot_cycle_board=false
```

## Method 3: U-Boot environment variable (single boot)

At the board's serial console (or via `fw_setenv` from Linux), set
`pxe_label_override`:

```
# At U-Boot prompt:
setenv pxe_label_override sd
boot

# Or from Linux (persists in env storage):
sudo fw_setenv pxe_label_override sd
```

This requires the pxelinux.cfg template to check for
`pxe_label_override` (a future enhancement — the current template does
not implement this). When implemented, U-Boot's `pxe boot` command
would read the env var and select the matching label instead of the
`default` directive.

### SPI vs non-SPI boards

- **Non-SPI boards** (e.g. Orange Pi 5 Pro): U-Boot env lives in RAM.
  `setenv` at the console is volatile — lost on the next power cycle.
  Effective as a single-boot override.
- **SPI boards** (e.g. Rock 5B): U-Boot env persists in SPI flash.
  `fw_setenv` (or `saveenv` at the console) survives reboots. Clear
  with `fw_setenv pxe_label_override` (empty value) or re-run
  `persist_uboot_env.yml`.
