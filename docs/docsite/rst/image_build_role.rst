.. _ansible_collections.david_igou.armbian.docsite.image_build_role:

david_igou.armbian.image_build role
===================================

Runs on a builder host. Builds a custom Armbian ``.img.xz`` with caller-supplied
userpatches via ``armbian/build`` (Docker mode) and rebuilds only when the inputs
hash (board, branch, release, ref, userpatches, compile args) changes. The
``plan`` entry point reports whether a build is due without compiling.

See the :ansplugin:`full role reference <david_igou.armbian.image_build#role>`
for all parameters and defaults.
