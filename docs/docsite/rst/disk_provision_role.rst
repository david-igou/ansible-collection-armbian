.. _ansible_collections.david_igou.armbian.docsite.disk_provision_role:

david_igou.armbian.disk_provision role
======================================

Runs on a board. Applies a declarative GPT layout to one block device with
``systemd-repart``, copies a source root filesystem onto it and regenerates a
label-keyed ``/etc/fstab``, preserving partitions marked ``preserve_on_reprovision``.

See the :ansplugin:`full role reference <david_igou.armbian.disk_provision#role>`
for all parameters and defaults.
