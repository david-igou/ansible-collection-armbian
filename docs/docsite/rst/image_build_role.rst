.. _ansible_collections.david_igou.armbian.docsite.image_build_role:

david_igou.armbian.image_build role
===================================

Runs on a Docker-capable builder. Builds an Armbian image with ``armbian/build`` and
the caller's userpatches, skipping the build when the inputs are unchanged, and writes
the image, its checksum and a ``manifest.json`` per target.

See the :ansplugin:`full role reference <david_igou.armbian.image_build#role>`
for all parameters and defaults.
