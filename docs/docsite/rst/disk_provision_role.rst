.. _ansible_collections.david_igou.armbian.docsite.disk_provision_role:

david_igou.armbian.disk_provision role
======================================

Runs on a board. Applies a declarative GPT layout to one block device via
``systemd-repart``, rsyncs a source rootfs onto it, and regenerates a LABEL-keyed
``/etc/fstab``. Idempotent, with per-partition ``preserve_on_reprovision`` support
for state (e.g. ``/var``) that must survive a re-provision.

See the :ansplugin:`full role reference <david_igou.armbian.disk_provision#role>`
for all parameters and defaults.
