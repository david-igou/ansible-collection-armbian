.. _ansible_collections.david_igou.armbian.docsite.board_boot_verify_role:

david_igou.armbian.board_boot_verify role
=========================================

Runs on a board. Gathers facts and asserts that ``ansible_mounts['/']`` matches
the declared boot mode (NFS for ``nfs``; a block device for ``sd`` / ``local`` /
``local_kernel``, with an additional NVMe check for ``local_kernel``).

See the :ansplugin:`full role reference <david_igou.armbian.board_boot_verify#role>`
for all parameters and defaults.
