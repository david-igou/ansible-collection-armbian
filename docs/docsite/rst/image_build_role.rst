.. _ansible_collections.david_igou.armbian.docsite.image_build_role:

david_igou.armbian.image_build role
===================================

Runs on an ``armbian_builders`` host. Builds a custom Armbian ``.img.xz`` with
caller-supplied userpatches via ``armbian/build`` (Docker mode), baking PXE-first
U-Boot ``BOOT_TARGETS`` into the image so a board reliably netboots from power-up.

See the :ansplugin:`full role reference <david_igou.armbian.image_build#role>`
for all parameters and defaults.
