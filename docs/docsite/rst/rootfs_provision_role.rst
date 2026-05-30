.. _ansible_collections.david_igou.armbian.docsite.rootfs_provision_role:

david_igou.armbian.rootfs_provision role
========================================

Runs on the netboot server. Resolves a per-host ``.img.xz`` source, extracts the
rootfs into a per-model template, reflink-clones it into a per-host directory, and
resets identity (hostname, machine-id, SSH host keys) so same-model boards stay
independent on the wire.

See the :ansplugin:`full role reference <david_igou.armbian.rootfs_provision#role>`
for all parameters and defaults.
