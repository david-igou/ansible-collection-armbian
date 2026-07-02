.. _ansible_collections.david_igou.armbian.docsite.rootfs_provision_role:

david_igou.armbian.rootfs_provision role
========================================

Runs on the netboot server. Resolves a per-host ``.img.xz`` source, extracts the
rootfs directly into a per-host directory (hosts pointing at the same upstream
URL share only the download, via a URL-keyed image cache), and resets identity
(hostname, machine-id, SSH host keys) so same-model boards stay independent on
the wire.

See the :ansplugin:`full role reference <david_igou.armbian.rootfs_provision#role>`
for all parameters and defaults.
