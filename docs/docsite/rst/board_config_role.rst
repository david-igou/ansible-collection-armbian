.. _ansible_collections.david_igou.armbian.docsite.board_config_role:

david_igou.armbian.board_config role
====================================

Runs on a board without connecting to it. Merges the family, model and host
inventory layers into the ``board_config`` fact; with ``tasks_from: build`` merges
the build layers into ``board_config_build`` (rendering template userpatches in the
board's variable context); with ``tasks_from: rootfs_src`` resolves the board's
image URL and checksum from its published manifest or an explicit override.

See the :ansplugin:`full role reference <david_igou.armbian.board_config#role>`
for all parameters and defaults.
