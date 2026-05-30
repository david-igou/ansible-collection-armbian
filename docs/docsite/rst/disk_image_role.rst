.. _ansible_collections.david_igou.armbian.docsite.disk_image_role:

david_igou.armbian.disk_image role
==================================

Runs on a board (or any host owning the target). Streams one ``.img.xz`` / ``.img``
source onto a whole block device via ``curl | xz | dd``, refusing to write to a
device that is currently mounted.

See the :ansplugin:`full role reference <david_igou.armbian.disk_image#role>`
for all parameters and defaults.
